#!/usr/bin/env bash
# carve-oci.sh — carve the embedded OCI image out of the UniFi OS Server installer ELF.
# Runs inside the extractor container. Usage: carve-oci <installer-path> <output-dir>
# Result: a valid OCI image layout at <output-dir>/oci (oci-layout + index.json present).
set -euo pipefail

INSTALLER="${1:?usage: carve-oci <installer-path> <output-dir>}"
OUTDIR="${2:?usage: carve-oci <installer-path> <output-dir>}"
WORK="$OUTDIR/work"

log() { echo "[carve-oci] $*" >&2; }

[[ -f "$INSTALLER" ]] || { echo "[carve-oci] ERROR: installer not found: $INSTALLER" >&2; exit 1; }

rm -rf "$WORK" "$OUTDIR/oci"
mkdir -p "$WORK"

log "running binwalk extraction on $INSTALLER"
binwalk --extract --directory="$WORK" "$INSTALLER"

# --- helpers -----------------------------------------------------------------

# is_oci_dir <dir> — true if dir is a valid OCI image layout
is_oci_dir() { [[ -f "$1/oci-layout" && -f "$1/index.json" ]]; }

# is_docker_tar_dir <dir> — true if dir is an unpacked docker save tarball
is_docker_tar_dir() { [[ -f "$1/manifest.json" ]]; }

# docker_dir_to_oci <docker-dir> <oci-dir> — convert unpacked docker-save layout to OCI via skopeo
docker_dir_to_oci() {
    local src="$1" dst="$2"
    local repo_tag
    repo_tag="$(python3 - "$src/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))[0]
tags = m.get("RepoTags") or ["carved:latest"]
print(tags[0])
PY
)"
    mkdir -p "$WORK/docker-archive"
    (cd "$src" && tar -cf "$WORK/docker-archive/image.tar" .)
    skopeo copy "docker-archive:$WORK/docker-archive/image.tar:$repo_tag" "oci:$dst:carved"
}

# try_candidate <path> — attempt to normalise a candidate path to $OUTDIR/oci.
# Returns 0 on success.
try_candidate() {
    local p="$1"

    if [[ -d "$p" ]]; then
        if is_oci_dir "$p"; then
            log "found OCI layout at $p"
            cp -a "$p" "$OUTDIR/oci"
            return 0
        fi
        if is_docker_tar_dir "$p"; then
            log "found docker manifest layout at $p — converting to OCI"
            docker_dir_to_oci "$p" "$OUTDIR/oci"
            return 0
        fi
    elif [[ -f "$p" ]]; then
        # Candidate archive: tar / tar.gz containing an OCI or docker layout.
        if file "$p" | grep -Eq 'tar archive|gzip compressed'; then
            local unpack="$WORK/unpack-$(echo "$p" | md5sum | cut -c1-8)"
            mkdir -p "$unpack"
            if tar -xf "$p" -C "$unpack" 2>/dev/null; then
                # Check top level and one level deep.
                if is_oci_dir "$unpack"; then cp -a "$unpack" "$OUTDIR/oci"; return 0; fi
                if is_docker_tar_dir "$unpack"; then docker_dir_to_oci "$unpack" "$OUTDIR/oci"; return 0; fi
                local sub
                while IFS= read -r sub; do
                    if is_oci_dir "$sub"; then
                        log "found OCI layout at $sub"
                        cp -a "$sub" "$OUTDIR/oci"
                        return 0
                    fi
                    if is_docker_tar_dir "$sub"; then
                        log "found docker manifest layout at $sub — converting to OCI"
                        docker_dir_to_oci "$sub" "$OUTDIR/oci"
                        return 0
                    fi
                done < <(find "$unpack" -mindepth 1 -maxdepth 3 -type d)
            fi
        fi
    fi
    return 1
}

# --- search ------------------------------------------------------------------

log "searching extracted payload for an OCI image layout"

# 1) Direct hits: any directory that already looks like an OCI or docker layout.
INSPECTED=()
while IFS= read -r d; do
    INSPECTED+=("$d")
    if try_candidate "$d"; then break; fi
done < <(find "$WORK" -type f \( -name 'oci-layout' -o -name 'index.json' -o -name 'manifest.json' \) -printf '%h\n' 2>/dev/null | sort -u)

# 2) Archive payloads: any tar/tar.gz file in the extraction tree (payload may be nested).
if ! is_oci_dir "$OUTDIR/oci"; then
    while IFS= read -r f; do
        INSPECTED+=("$f")
        if try_candidate "$f"; then break; fi
    done < <(find "$WORK" -type f \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' \))
fi

# 3) Last resort: every extracted directory whose name hints at an image payload.
if ! is_oci_dir "$OUTDIR/oci"; then
    while IFS= read -r d; do
        INSPECTED+=("$d")
        if try_candidate "$d"; then break; fi
    done < <(find "$WORK" -type d -iname '*image*')
fi

if ! is_oci_dir "$OUTDIR/oci"; then
    echo "[carve-oci] ERROR: no valid OCI image layout found inside the installer." >&2
    echo "[carve-oci] Inspected paths:" >&2
    printf '[carve-oci]   %s\n' "${INSPECTED[@]:-<none>}" >&2
    exit 1
fi

rm -rf "$WORK"
log "success: OCI image layout at $OUTDIR/oci"
