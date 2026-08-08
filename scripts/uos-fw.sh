#!/usr/bin/env bash
# Shared helper for resolving UniFi OS Server firmware from Ubiquiti's firmware API.
# Sourced by other scripts — do not execute directly.
set -euo pipefail

UOS_FW_API_URL="${UOS_FW_API_URL:-https://fw-update.ubnt.com/api/firmware-latest?filter=eq~~product~~unifi-os-server}"

# Fetch the firmware API JSON. Retries 3 times, fails on HTTP errors.
uos_fw_json() {
    curl --fail --location --silent --show-error --retry 3 "$UOS_FW_API_URL"
}

# Map docker arch to Ubiquiti platform string.
# Usage: uos_platform_for_arch <amd64|arm64>
uos_platform_for_arch() {
    case "${1:-}" in
        amd64) echo "linux-x64" ;;
        arm64) echo "linux-arm64" ;;
        *) echo "uos_platform_for_arch: unsupported arch '${1:-}' (expected amd64|arm64)" >&2; return 1 ;;
    esac
}

# Resolve a firmware entry.
# Usage: uos_resolve <platform> <version|latest>
# Echoes: <url>\t<sha256>\t<version-without-v>
uos_resolve() {
    local platform="${1:?platform required}" version="${2:-latest}"
    local json
    json="$(uos_fw_json)"

    local jq_filter
    if [[ "$version" == "latest" ]]; then
        # First release-channel entry for the platform is the newest.
        jq_filter='
            ._embedded.firmware
            | map(select(.product == "unifi-os-server" and .platform == $platform))
            | first
        '
    else
        jq_filter='
            ._embedded.firmware
            | map(select(.product == "unifi-os-server" and .platform == $platform
                         and .version == ("v" + $version)))
            | first
        '
    fi

    local entry
    entry="$(jq -c --arg platform "$platform" --arg version "$version" "$jq_filter" <<<"$json")"
    if [[ -z "$entry" || "$entry" == "null" ]]; then
        echo "uos_resolve: no firmware entry for platform=$platform version=$version" >&2
        return 1
    fi

    jq -r '[._links.data.href, .sha256_checksum, (.version | ltrimstr("v"))] | @tsv' <<<"$entry"
}
