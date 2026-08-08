# Convenience targets for building UniFi OS Server images locally.
# Honours:
#   UOS_SERVER_VERSION  - UniFi OS Server version (default 5.1.21, or "latest")
#   IMAGE               - image name to tag (default ghcr.io/schaerfl/unifi-os-server-docker)

UOS_SERVER_VERSION ?= 5.1.21
IMAGE              ?= ghcr.io/schaerfl/unifi-os-server-docker

export UOS_SERVER_VERSION

.PHONY: extract-amd64 extract-arm64 build-amd64 build-arm64 build \
        compose-up compose-down clean

## Download the installer and extract the base rootfs (amd64).
extract-amd64:
	./scripts/extract-base.sh --arch amd64

## Download the installer and extract the base rootfs (arm64).
extract-arm64:
	./scripts/extract-base.sh --arch arm64

## Build the runtime image for amd64.
build-amd64: extract-amd64
	docker build \
		--build-arg BASE_IMAGE=uosserver-base:$(UOS_SERVER_VERSION)-amd64 \
		--build-arg UOS_SERVER_VERSION=$(UOS_SERVER_VERSION) \
		--build-arg BUILD_DATE=$$(date -u +%Y-%m-%dT%H:%M:%SZ) \
		--build-arg VCS_REF=$$(git rev-parse --short HEAD 2>/dev/null || echo unknown) \
		-t $(IMAGE):$(UOS_SERVER_VERSION)-amd64 .

## Build the runtime image for arm64.
build-arm64: extract-arm64
	docker build \
		--build-arg BASE_IMAGE=uosserver-base:$(UOS_SERVER_VERSION)-arm64 \
		--build-arg UOS_SERVER_VERSION=$(UOS_SERVER_VERSION) \
		--build-arg BUILD_DATE=$$(date -u +%Y-%m-%dT%H:%M:%SZ) \
		--build-arg VCS_REF=$$(git rev-parse --short HEAD 2>/dev/null || echo unknown) \
		-t $(IMAGE):$(UOS_SERVER_VERSION)-arm64 .

## Extract and build both architectures.
build: build-amd64 build-arm64

compose-up:
	docker compose up -d

compose-down:
	docker compose down

## Remove extracted base images, built images and the installer cache.
clean:
	-docker rmi $(IMAGE):$(UOS_SERVER_VERSION)-amd64 $(IMAGE):$(UOS_SERVER_VERSION)-arm64 2>/dev/null
	-docker rmi uosserver-base:$(UOS_SERVER_VERSION)-amd64 uosserver-base:$(UOS_SERVER_VERSION)-arm64 2>/dev/null
	rm -rf .cache
