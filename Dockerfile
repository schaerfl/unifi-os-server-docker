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
#   official installer (see scripts/extract-base.sh). "Fixing" this
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

# Stop the container journal and the host kernel log from bleeding into each
# other in both directions. See the file itself for what each setting prevents.
COPY --chmod=0644 config/journald-container.conf \
     /etc/systemd/journald.conf.d/10-container.conf

# Single volume holding ALL UniFi OS state (the entrypoint symlinks the
# individual state paths into it).
VOLUME ["/unifi"]

# Port list taken from portmap.json inside the official installer.
# 443        - UniFi OS web UI / API (HTTPS, served by the host-level nginx)
# 8080       - device inform
# 8444       - guest portal HTTPS
# 5671       - RabbitMQ AMQPS (internal messaging)
# 6789       - throughput / speed test
# 8880-8882  - hotspot/portal redirect services
# 9543       - identity hub
# 28082      - UniFi Network internal
# 11084      - ucore API (installer binds this to 127.0.0.1 only)
# 3478/udp   - STUN (device NAT traversal)
# 5514/udp   - remote syslog
# 10003/udp  - device discovery
EXPOSE 443 8080 8444 5671 6789 8880 8881 8882 9543 28082 11084 3478/udp 5514/udp 10003/udp

ENTRYPOINT ["/entrypoint.sh"]
