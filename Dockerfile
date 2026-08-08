# syntax=docker/dockerfile:1
#
# Final UniFi OS Server runtime image.
#
# NOTE — why the base is NOT Alpine (and must not become Alpine):
#   UniFi OS Server ships as a single Go ELF installer with an OCI container
#   image embedded inside it. That embedded image is Ubiquiti's own Debian-based
#   UniFi OS root filesystem and it IS the runtime: it boots systemd as PID 1 and
#   runs MongoDB, PostgreSQL, RabbitMQ and Nginx as systemd units. The included
#   UniFi Network app is the UniFi-OS-integrated build, not the public .deb.
#   BASE_IMAGE below must therefore always be the rootfs carved out of the
#   official installer (see scripts/extract-base.sh). Alpine is used only for
#   the extractor/tooling stage (docker/extractor.Dockerfile). "Fixing" this
#   Dockerfile to FROM alpine would produce a non-functional image.

ARG BASE_IMAGE=uosserver-base:latest
FROM ${BASE_IMAGE}

# Build variables. UOS_SERVER_VERSION is THE variable for the UniFi OS Server
# binary version — pass it with --build-arg and keep it in sync with the base
# image produced by scripts/extract-base.sh.
ARG UOS_SERVER_VERSION=5.1.21
ARG BUILD_DATE=""
ARG VCS_REF=""
ENV UOS_SERVER_VERSION=${UOS_SERVER_VERSION}

LABEL org.opencontainers.image.source="https://github.com/schaerfl/unifi-os-server-docker" \
      org.opencontainers.image.url="https://github.com/schaerfl/unifi-os-server-docker" \
      org.opencontainers.image.documentation="https://github.com/schaerfl/unifi-os-server-docker#readme" \
      org.opencontainers.image.title="unifi-os-server" \
      org.opencontainers.image.description="Self-hosted UniFi OS Server in Docker — single volume, multi-arch (amd64/arm64), built from the official Ubiquiti installer" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${UOS_SERVER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.vendor="schaerfl" \
      io.schaerfl.unifi-os-server.version="${UOS_SERVER_VERSION}"

# systemd's shutdown signal.
STOPSIGNAL SIGRTMIN+3
ENV container=docker

# COPY --chmod avoids a RUN instruction, so no command from the target rootfs
# is ever executed at build time and cross-architecture builds need no qemu
# emulation.
COPY --chmod=0755 scripts/entrypoint.sh /entrypoint.sh

# Single volume holding ALL UniFi OS state (the entrypoint symlinks the
# individual state paths into it).
VOLUME ["/unifi"]

# 443    - UniFi OS UI / API (HTTPS)
# 8080   - device inform (HTTP)
# 8443   - Network app HTTPS (redirect target)
# 8444   - guest portal HTTPS
# 5514   - remote syslog
# 6789   - throughput/UBB speed test
# 5005   - device discovery
# 9543   - UniFi OS internal
# 11084  - device adoption/upgrade
# 5671   - RabbitMQ AMQPS (internal messaging)
# 8880-2 - hot-spot/portal redirect services
# 3478/udp   - STUN (device NAT traversal)
# 10003/udp  - device discovery (L2 broadcast)
EXPOSE 443 8080 8443 8444 5514 6789 5005 9543 11084 5671 8880 8881 8882 3478/udp 10003/udp

ENTRYPOINT ["/entrypoint.sh"]
