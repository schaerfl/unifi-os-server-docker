# UniFi OS Server in Docker

Run [Ubiquiti's UniFi OS Server](https://ui.com/download/) as a self-hosted Docker
container — multi-arch (`amd64`/`arm64`), a single data volume, built from the
official Ubiquiti installer.

Published images: **`ghcr.io/schaerfl/unifi-os-server-docker`**

---

## Why the base image is not Alpine

UniFi OS Server ships as a ~880 MB Go executable installer — one per platform —
with a complete **OCI container image embedded inside it**. That embedded image is
Ubiquiti's own Debian-based UniFi OS root filesystem, and it *is* the runtime: it
boots **systemd** as PID 1 and runs MongoDB, PostgreSQL, RabbitMQ and Nginx as
systemd units inside the container. The bundled UniFi Network app is the
UniFi-OS-integrated build, not the public `.deb`.

So the runtime base of this image is the rootfs carved out of the official
installer — it cannot be Alpine (or any other distro) without breaking the whole
stack. Alpine is used only for the installer-extraction tooling stage, never for
the runtime.

## Quick start

```bash
cp .env.example .env
# edit .env — set UOS_SYSTEM_IP to this host's IP/hostname (required)
docker compose up -d
```

Then open `https://<host>:11443`.

## Full `docker run` equivalent

```bash
docker run -d \
  --name unifi-os-server \
  --restart unless-stopped \
  --stop-timeout 120 \
  --cgroupns host \
  --cap-drop ALL \
  --cap-add SYS_ADMIN --cap-add NET_ADMIN --cap-add NET_RAW \
  --cap-add NET_BIND_SERVICE --cap-add DAC_OVERRIDE --cap-add DAC_READ_SEARCH \
  --cap-add FOWNER --cap-add CHOWN --cap-add SETUID --cap-add SETGID \
  --cap-add KILL --cap-add SYS_CHROOT --cap-add SYS_PTRACE \
  --cap-add SYS_RESOURCE --cap-add AUDIT_WRITE --cap-add MKNOD \
  --tmpfs /run:exec \
  --tmpfs /run/lock \
  --tmpfs /tmp:exec \
  --tmpfs /var/lib/journal \
  --tmpfs /var/opt/unifi/tmp:size=64m \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v unifi_data:/unifi \
  -e UOS_SYSTEM_IP=192.168.1.10 \
  -p 11443:443 -p 8080:8080 \
  -p 3478:3478/udp -p 10003:10003/udp \
  ghcr.io/schaerfl/unifi-os-server-docker:latest
```

## Volumes / mounts

| Mount | Type | Purpose |
|---|---|---|
| `/unifi` | named volume `unifi_data` | **All** UniFi OS state: `/data`, `/persistent`, `/srv`, `/var/lib/unifi`, PostgreSQL, MongoDB, logs and RabbitMQ SSL are symlinked into this one volume by the entrypoint |
| `/sys/fs/cgroup` | host bind, **rw** | Required by systemd inside the container |
| `/run`, `/run/lock`, `/tmp` | tmpfs (exec) | systemd runtime dirs |
| `/var/lib/journal` | tmpfs | systemd journal |
| `/var/opt/unifi/tmp` | tmpfs, 64m | UniFi temp files |

## Ports

Ports below match `portmap.json` inside the official installer.

| Port | Protocol | Purpose |
|---|---|---|
| `11443 → 443` | TCP | UniFi OS web UI / API (HTTPS) |
| `8080` | TCP | device inform |
| `3478` | UDP | STUN (device NAT traversal) |
| `10003` | UDP | device discovery |
| `8444` | TCP | guest portal HTTPS (optional) |
| `5671` | TCP | RabbitMQ AMQPS (optional) |
| `6789` | TCP | throughput / speed test (optional) |
| `8880–8882` | TCP | hotspot / portal redirect services (optional) |
| `9543` | TCP | identity hub (optional) |
| `28082` | TCP | UniFi Network internal (optional) |
| `11084` | TCP | ucore API (optional; installer binds to 127.0.0.1 only) |
| `5514` | UDP | remote syslog (optional) |

## Environment variables

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `UOS_SYSTEM_IP` | **yes** | — | Hostname or IP of the host, used by UniFi devices for adoption |
| `UOS_UUID` | no | auto-generated, persisted in `/unifi/uuid` | Pin a fixed machine UUID across host/volume moves |
| `UOS_SERVER_VERSION` | build-time | `5.1.21` | UniFi OS Server version baked into the image (build arg) |

## Building locally

You need `unzip`, `curl`, `jq` and a working `docker` on PATH. The installer
is an ELF with a ZIP archive appended; `extract-base.sh` streams the embedded
`image.tar` entry straight into `docker load`.

With make (honours `UOS_SERVER_VERSION` and `IMAGE`):

```bash
make extract-amd64      # download installer + carve rootfs -> uosserver-base:<ver>-amd64
make extract-arm64      # same for arm64
make build-amd64        # build runtime image for amd64
make build-arm64        # build runtime image for arm64
make build              # extract + build both arches
```

Without make:

```bash
./scripts/extract-base.sh --arch amd64            # -> prints uosserver-base:5.1.21-amd64
./scripts/extract-base.sh --arch arm64            # -> prints uosserver-base:5.1.21-arm64

docker build \
  --build-arg BASE_IMAGE=uosserver-base:5.1.21-amd64 \
  --build-arg UOS_SERVER_VERSION=5.1.21 \
  -t ghcr.io/schaerfl/unifi-os-server-docker:5.1.21-amd64 .
```

`--version latest` resolves the newest release from Ubiquiti's firmware API at
runtime; installer downloads are checksum-verified and cached under `.cache/`.
The carve step is pure file extraction and works on either host architecture
(no QEMU needed).

## Tags

| Tag | Meaning |
|---|---|
| `latest` | newest release, multi-arch manifest |
| `<uos-version>` (e.g. `5.1.21`) | multi-arch manifest for that UniFi OS Server version |
| `<uos-version>-<arch>` (e.g. `5.1.21-amd64`) | per-architecture image |
| `<uos-version>-<git-sha>` | immutable build variant |

## Disclaimer

This project is not affiliated with, endorsed by, or supported by Ubiquiti Inc.
UniFi and UniFi OS are trademarks of Ubiquiti Inc. The images contain Ubiquiti's
proprietary software, extracted unmodified from the official installer.
