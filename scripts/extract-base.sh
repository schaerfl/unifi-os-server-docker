#!/usr/bin/env bash
# extract-base.sh — download a UniFi OS Server installer and load the embedded
# container image into the local Docker daemon as a base image.
#
# The installer is an ELF executable with a standard ZIP archive appended to
# it. One of the ZIP entries, image.tar, is an OCI-layout archive (blobs/sha256/
# + oci-layout + index.json) of the full UniFi OS rootfs, and is loaded directly.
#
# REQUIRES Docker >= 25: older engines' `docker load` accepts only the
# docker-save format and will reject an OCI archive. The CI agents pin docker 28.
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

ARCH=""
VERSION="${UOS_SERVER_VERSION:-5.1.21}"
INSTALLER=""
TAG=""
CACHE_DIR=".cache/installers"

usage() {
    grep '^#' "${BASH_SOURCE[0]}" | head -11 >&2
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

# --- 3: extract image.tar from the installer and load it ----------------------

if ! unzip -l "$INSTALLER" image.tar >/dev/null; then
    echo "[extract-base] ERROR: no 'image.tar' entry in $INSTALLER" >&2
    echo "[extract-base]   installer layout is not the expected ELF with an appended ZIP archive" >&2
    exit 1
fi

# Info-ZIP locates the End Of Central Directory at the end of the file and
# compensates for the prepended ELF automatically; it may print an
# "extra bytes at beginning" warning to stderr, which is expected and harmless.
#
# `unzip -p` streams the entry to stdout, so the 870 MB tar is never written
# to disk, and `docker load` streams it over the Docker API, which works
# against a remote/TCP daemon (the CI dind sidecar).
log "extracting image.tar from $INSTALLER into the docker daemon"
LOAD_OUTPUT="$(unzip -p "$INSTALLER" image.tar | docker load)"

# `docker load` prints either "Loaded image: <repo:tag>" (archive carries
# RepoTags) or "Loaded image ID: sha256:<id>". This archive is an untagged OCI
# layout, so the ID form is the one normally seen here — hence the retag
# below, and hence both forms must be parsed. sed, not
# grep -P: the CI build container is Alpine, where grep is busybox without PCRE.
LOADED_REF="$(sed -n 's/^Loaded image: //p; s/^Loaded image ID: //p' <<<"$LOAD_OUTPUT" | head -1)"
if [[ -z "$LOADED_REF" ]]; then
    echo "[extract-base] ERROR: could not parse a loaded image reference from docker load output:" >&2
    echo "$LOAD_OUTPUT" >&2
    exit 1
fi

log "tagging $LOADED_REF as $TAG"
docker tag "$LOADED_REF" "$TAG"

log "done"
echo "$TAG"
