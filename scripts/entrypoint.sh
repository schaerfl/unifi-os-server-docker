#!/usr/bin/env bash
# entrypoint.sh — runtime entrypoint for the UniFi OS Server container.
#
# Responsibilities:
#   1. Require UOS_SYSTEM_IP.
#   2. Consolidate all UniFi OS state into the single /unifi volume via symlinks.
#   3. Persist a stable machine UUID across container recreations.
#   4. Export UOS_SYSTEM_IP for the UniFi services.
#   5. Hand over to systemd (/sbin/init) as PID 1.
set -euo pipefail

log()  { echo "[entrypoint] $*" >&2; }
fail() { echo "[entrypoint] ERROR: $*" >&2; exit 1; }

# --- 1: required configuration -------------------------------------------------

if [[ -z "${UOS_SYSTEM_IP:-}" ]]; then
    fail "UOS_SYSTEM_IP is not set. Set it to the hostname or IP of this host that
       UniFi devices should use for adoption (e.g. -e UOS_SYSTEM_IP=192.168.1.10
       or via the .env file / compose environment)."
fi

# --- 6: cgroup sanity check (checked early, fatal-free warning) -----------------

# NOTE: probe with mkdir, not touch. cgroup v2 rejects creating regular files
# even on a read-write mount (only directories = cgroups may be created), so a
# touch-based probe reports a false failure on every modern host. `mountpoint`
# is not guaranteed to exist in the rootfs either, hence the /proc/mounts read.
if ! grep -q ' /sys/fs/cgroup ' /proc/mounts 2>/dev/null \
   || ! mkdir /sys/fs/cgroup/.uos-rw-check 2>/dev/null; then
    log "WARNING: /sys/fs/cgroup is not mounted read-write from the host."
    log "WARNING: systemd inside the container requires:"
    log "WARNING:   docker run ... -v /sys/fs/cgroup:/sys/fs/cgroup:rw"
    log "WARNING: (already included in docker-compose.yml)"
else
    rmdir /sys/fs/cgroup/.uos-rw-check
fi

# --- 2: consolidate state into /unifi --------------------------------------------
# One named volume holds everything; each real path becomes a symlink into it.
# Idempotent: existing symlinks are left alone, existing data is migrated once.

mkdir -p /unifi

link_into_volume() {
    local real_path="$1" name="$2"
    local vol_path="/unifi/$name"

    if [[ -L "$real_path" ]]; then
        # Already linked on a previous run.
        mkdir -p "$vol_path"
        return 0
    fi

    # Capture the ORIGINAL ownership and mode before the directory is replaced.
    # Several UniFi OS units run as a non-root User= (mongodb, postgres, unifi,
    # rabbitmq) and need to write inside their state directory. `cp -a` only
    # preserves ownership of the *contents* it copies, and on a fresh install
    # these directories are empty, so nothing is copied and the plain `mkdir -p`
    # below would leave the volume directory root:root. mongod then exits 100
    # ("Started" immediately followed by "Failed with result exit-code") and the
    # UniFi UI on 443 never comes up, which surfaces as a Traefik 502.
    local owner="" mode=""
    if [[ -d "$real_path" ]]; then
        owner="$(stat -c '%u:%g' "$real_path")"
        mode="$(stat -c '%a' "$real_path")"

        mkdir -p "$vol_path"
        # First run with pre-existing data: migrate it, but only into an empty target.
        if [[ -z "$(ls -A "$vol_path")" ]] && [[ -n "$(ls -A "$real_path")" ]]; then
            log "migrating $real_path -> $vol_path"
            cp -a "$real_path"/. "$vol_path"/
        fi
        rm -rf "$real_path"
    fi

    mkdir -p "$vol_path"

    # Re-apply the original uid/gid/mode to the volume directory itself.
    if [[ -n "$owner" ]]; then
        chown "$owner" "$vol_path"
        chmod "$mode" "$vol_path"
    fi

    mkdir -p "$(dirname "$real_path")"
    ln -sfn "$vol_path" "$real_path"
}

link_into_volume /data                 data
link_into_volume /persistent           persistent
link_into_volume /srv                  srv
link_into_volume /var/lib/unifi        unifi
link_into_volume /var/lib/postgresql   postgresql
link_into_volume /var/lib/mongodb      mongodb
link_into_volume /var/log              log
link_into_volume /etc/rabbitmq/ssl     rabbitmq-ssl

# --- 3: stable machine UUID ------------------------------------------------------
# UniFi OS identifies the instance by a machine UUID. Without persistence every
# container recreation looks like a new machine. Priority:
#   1. $UOS_UUID (explicit user pinning)
#   2. /unifi/uuid (persisted from a previous run)
#   3. freshly generated and written to /unifi/uuid
# The UUID is written to /data/uos_uuid — that exact path is what `ubnt-tools id`
# reads (`UOS_UUID=$(cat /data/uos_uuid)`), and /data is symlinked into the volume
# above, so it persists. Do not "tidy" this to another path.

# The UUID must be a **version 5** (SHA-1, name-based) UUID. A real UniFi OS
# Server install uses one, and the UniFi Network application validates the
# version: given a random v4 UUID it refuses to start, crash-looping with
#     Factory method 'systemService' threw exception ... Invalid uuid version - 4
# and UniFi Core then reports "Network application is not ready for setup",
# which surfaces in the browser as "an error occurred" after the boot screen.
# /proc/sys/kernel/random/uuid yields v4, so it cannot be used directly.

# RFC 4122 v5 in pure bash (verified to match Python's uuid.uuid5 with the
# standard DNS namespace). Only sha1sum is required.
uuid5() {
    local ns="6ba7b8109dad11d180b400c04fd430c8" name="$1" esc="" i hex b6 b8
    for ((i = 0; i < 32; i += 2)); do esc+="\\x${ns:i:2}"; done
    hex="$( { printf '%b' "$esc"; printf '%s' "$name"; } | sha1sum | cut -d' ' -f1 )"
    b6=$(( (0x${hex:12:2} & 0x0f) | 0x50 ))   # version 5
    b8=$(( (0x${hex:16:2} & 0x3f) | 0x80 ))   # RFC 4122 variant
    printf '%s-%s-%02x%s-%02x%s-%s\n' \
        "${hex:0:8}" "${hex:8:4}" "$b6" "${hex:14:2}" "$b8" "${hex:18:2}" "${hex:20:12}"
}

uuid_is_v5() {
    [[ "${1:-}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

UUID=""
if [[ -n "${UOS_UUID:-}" ]]; then
    UUID="$UOS_UUID"
elif [[ -s /unifi/uuid ]]; then
    UUID="$(cat /unifi/uuid)"
fi

# Also re-generates when a v4 UUID was persisted by an older build of this image.
if ! uuid_is_v5 "$UUID"; then
    [[ -n "$UUID" ]] && log "discarding non-v5 machine UUID: $UUID"
    # Seed from the MAC, which is what `ubnt-tools id` reports as board.serialno,
    # so the UUID is stable for as long as the interface is.
    SEED="$(tr -d ':' < /sys/class/net/eth0/address 2>/dev/null || true)"
    [[ -z "$SEED" ]] && SEED="$(hostname)-$(cat /proc/sys/kernel/random/uuid)"
    UUID="$(uuid5 "$SEED")"
    echo "$UUID" > /unifi/uuid
    log "generated machine UUID (v5): $UUID"
fi
export UOS_UUID="$UUID"
echo "$UUID" > /data/uos_uuid

# --- 3b: identity files the official installer normally provides -----------------
# Upstream, the `uosserver` supervisor binary prepares the container before
# starting it. Running the rootfs directly skips that, so three things it creates
# have to be recreated here or UniFi Core never starts:
#
#   /usr/lib/version   `ubnt-tools id` derives the console model from the FIRST
#                      dot-separated field (APP_MODEL=$(cut -d. -f1 ...)), and
#                      unifi-core aborts with `Unsupported console model: ""`
#                      when it is missing. Format matches a real install:
#                      UOSSERVER.0000000.<version>.0000000.000000.0000
#   /data/unifi-core/config/http
#                      unifi-core's pre-start hook does `mkdir -p` on
#                      .../config but then copies into .../config/http, so the
#                      leaf directory must already exist.
#
# /usr/lib/product_name is deliberately NOT created: it is absent on a real
# UniFi OS Server install too (board.name comes back empty there as well).

if [[ ! -s /usr/lib/version ]]; then
    echo "UOSSERVER.0000000.${UOS_SERVER_VERSION}.0000000.000000.0000" > /usr/lib/version
    log "wrote /usr/lib/version for UOSSERVER ${UOS_SERVER_VERSION}"
fi

mkdir -p /data/unifi-core/config/http

# --- 4: publish UOS_SYSTEM_IP to the services ------------------------------------
# systemd services started later source /etc/default/unifi-os-server; writing the
# env there makes the adoption address visible to the UniFi service stack without
# modifying any unit files.

cat > /etc/default/unifi-os-server <<EOF
# Generated by /entrypoint.sh — do not edit, changes are overwritten on start.
UOS_SYSTEM_IP=${UOS_SYSTEM_IP}
UOS_UUID=${UOS_UUID}
EOF
export UOS_SYSTEM_IP

# --- 5: hand over to systemd -------------------------------------------------------

log "starting systemd (UOS_SYSTEM_IP=$UOS_SYSTEM_IP, UOS_UUID=$UOS_UUID)"
exec /sbin/init
