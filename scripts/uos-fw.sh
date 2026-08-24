#!/usr/bin/env bash
# Shared helper for resolving UniFi OS Server firmware from Ubiquiti's firmware API.
# Sourced by other scripts — do not execute directly.
set -euo pipefail

# NOTE — this must be `firmware`, not `firmware-latest`.
#
# `firmware-latest` returns only the newest build per platform, so pinning an
# exact version works only for as long as that version happens to be the latest.
# When Ubiquiti published v5.1.37, every build pinned to v5.1.21 started failing
# with "no firmware entry for platform=linux-x64 version=5.1.21" even though
# nothing in this repo had changed.
#
# The unsuffixed `firmware` endpoint carries the full history (v4.3.6 through
# v5.1.37 at the time of writing), so exact pins keep resolving after a release.
# It is NOT ordered newest-first, which is why uos_resolve sorts explicitly
# rather than taking the first match.
UOS_FW_API_URL="${UOS_FW_API_URL:-https://fw-update.ubnt.com/api/firmware?filter=eq~~product~~unifi-os-server&limit=200}"

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
        # The full firmware endpoint is not ordered, so sort by version instead
        # of taking the first match: v5.1.37 comes back *after* v5.0.6 there.
        # Compare numerically per component — a lexical sort puts v5.1.9 above
        # v5.1.37.
        jq_filter='
            ._embedded.firmware
            | map(select(.product == "unifi-os-server" and .platform == $platform))
            | sort_by(.version | ltrimstr("v") | split(".") | map(tonumber? // 0))
            | last
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
