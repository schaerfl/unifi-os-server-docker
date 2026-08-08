#!/usr/bin/env bash
# extract-base.sh — download a UniFi OS Server installer and turn the embedded
# OCI rootfs into a local Docker base image.
#
# Usage:
#   extract-base.sh --arch <amd64|arm64> [--version <ver|latest>]
#                   [--installer <path>] [--tag <image:tag>] [--cache-dir <dir>]
#
# Prints the resulting image tag on stdout as the last line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=uos-fw.sh
source "$SCRIPT_DIR/uos-fw.sh"

EXTRACTOR_IMAGE="${EXTRACTOR_IMAGE:-uos-extractor:latest}"
EXTRACTOR_DOCKERFILE="${EXTRACTOR_DOCKERFILE:-$SCRIPT_DIR/../docker/extractor.Dockerfile}"

ARCH=""
VERSION="${UOS_SERVER_VERSION:-5.1.21}"
INSTALLER=""
TAG=""
CACHE_DIR=".cache/installers"

usage() {
    grep '^#' "${BASH_SOURCE[0]}" | head -8 >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) ARCH="${2:?}"; shift 2 ;;
        --version) VERSION="${2:?}"; shift 2 ;;
        --installer) INSTALLER="${2:?}"; shift 2 ;;
        --tag) TAG="${2:?}"; shift 2 ;;
        --cache-dir) CACHE_DIR="${2:?}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "extract-base.sh: unknown option '$1'" >&2; usage ;;
    esac
done

[[ -n "$ARCH" ]] || { echo "extract-base.sh: --arch is required" >&2; usage; }
PLATFORM="$(uos_platform_for_arch "$ARCH")"

log() { echo "[extract-base] $*" >&2; }

sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# --- 1/2: resolve and download (unless a local installer was given) -----------

mkdir -p "$CACHE_DIR"

if [[ -z "$INSTALLER" ]]; then
    log "resolving firmware: platform=$PLATFORM version=$VERSION"
    RESOLVED="$(uos_resolve "$PLATFORM" "$VERSION")"
    URL="$(cut -f1 <<<"$RESOLVED")"
    SHA256="$(cut -f2 <<<"$RESOLVED")"
    VERSION="$(cut -f3 <<<"$RESOLVED")"
    log "resolved version $VERSION: $URL"

    INSTALLER="$CACHE_DIR/unifi-os-server-${VERSION}-${ARCH}.bin"
    if [[ -f "$INSTALLER" ]] && [[ "$(sha256_of "$INSTALLER")" == "$SHA256" ]]; then
        log "cached installer matches checksum — skipping download"
    else
        log "downloading to $INSTALLER"
        curl -fL --retry 3 --continue-at - -o "$INSTALLER" "$URL"
        ACTUAL="$(sha256_of "$INSTALLER")"
        if [[ "$ACTUAL" != "$SHA256" ]]; then
            echo "[extract-base] ERROR: sha256 mismatch for $INSTALLER" >&2
            echo "[extract-base]   expected: $SHA256" >&2
            echo "[extract-base]   actual:   $ACTUAL" >&2
            rm -f "$INSTALLER"
            exit 1
        fi
        log "checksum verified"
    fi
else
    [[ -f "$INSTALLER" ]] || { echo "[extract-base] ERROR: installer not found: $INSTALLER" >&2; exit 1; }
fi

TAG="${TAG:-uosserver-base:${VERSION}-${ARCH}}"

# --- 3: build extractor image -------------------------------------------------

if ! docker image inspect "$EXTRACTOR_IMAGE" >/dev/null 2>&1; then
    log "building extractor image $EXTRACTOR_IMAGE"
    docker build -f "$EXTRACTOR_DOCKERFILE" -t "$EXTRACTOR_IMAGE" "$SCRIPT_DIR/.."
fi

# --- 4: carve the embedded OCI image inside the extractor container -----------

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

log "carving embedded OCI image out of $INSTALLER"
docker run --rm \
    -v "$(cd "$(dirname "$INSTALLER")" && pwd)/$(basename "$INSTALLER"):/installer:ro" \
    -v "$OUT_DIR:/out" \
    "$EXTRACTOR_IMAGE" \
    /usr/local/bin/carve-oci /installer /out

[[ -f "$OUT_DIR/oci/oci-layout" && -f "$OUT_DIR/oci/index.json" ]] || {
    echo "[extract-base] ERROR: extraction did not produce a valid OCI layout at $OUT_DIR/oci" >&2
    exit 1
}

# --- 5: import into the local docker daemon -----------------------------------
# skopeo runs from the extractor image; the docker socket is mounted so the
# docker-daemon: transport talks to the host daemon.
log "importing OCI image as $TAG"
docker run --rm \
    -v "$OUT_DIR/oci:/oci:ro" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "$EXTRACTOR_IMAGE" \
    skopeo copy "oci:/oci" "docker-daemon:$TAG"

log "done"
echo "$TAG"
