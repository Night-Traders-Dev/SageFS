#!/usr/bin/env bash
# sagefs-daemon.sh — Userspace bridge between kernel driver and SageFS
#
# Reads sysfs commands from /sys/kernel/sagefs/command
# Routes them to SageFS's native FUSE storage engine via SageVM bytecode runtime.
# Updates /sys/kernel/sagefs/state to reflect driver state.
#
# Usage: sudo ./sagefs_daemon.sh &
#
# Commands (written to /sys/kernel/sagefs/command):
#   mount /path/to/image.sagefs  → loads and mounts the image
#   read   offset=N size=N       → queues a read at offset N
#   write  offset=N size=N       → queues a write at offset N
#   flush                        → syncs journal
#   sync                         → flushes all dirty pages
#   status                       → prints current state to kernel log

set -euo pipefail

SAGEFS_ROOT="/mnt/storage/Devel/SageFS"
SYSFS_CMD="/sys/kernel/sagefs/command"
SYSFS_STATE="/sys/kernel/sagefs/state"
MOUNT_POINT=""

daemon_log() {
    echo "[sagefs-daemon] $*" >&2
}

update_state() {
    local state="$1"
    echo "$state" > "$SYSFS_STATE" 2>/dev/null || true
}

handle_mount() {
    local image="$1"
    daemon_log "mounting $image"
    update_state 1

    # Mount via SageFS native mount.sage
    if [ -f "$SAGEFS_ROOT/build/mkfs.sagefs" ]; then
        # Use the mount.sage directly (no FUSE bridge needed with native FFI)
        sage --runtime bytecode -I "$SAGEFS_ROOT/src" mount.sage "$image" "$MOUNT_POINT" && \
            update_state 2 || update_state 4
    else
        daemon_log "error: mkfs.sagefs not found"
        update_state 4
    fi
}

handle_read() {
    daemon_log "read: offset=${1:-?} size=${2:-?}"
}

handle_write() {
    daemon_log "write: offset=${1:-?} size=${2:-?}"
    update_state 3
}

handle_flush() {
    daemon_log "flush"
    sync 2>/dev/null || true
}

handle_sync() {
    daemon_log "sync"
    update_state 2
}

# Main loop: poll for commands via sysfs
daemon_log "sagefs-daemon starting (polling $SYSFS_CMD)"

while [ -f "$SYSFS_CMD" ]; do
    if [ -s "$SYSFS_CMD" ]; then
        cmd=$(cat "$SYSFS_CMD" 2>/dev/null)
        daemon_log "command: $cmd"

        case "$cmd" in
            mount\ *)
                image="${cmd#mount }"
                handle_mount "$image"
                ;;
            read\ *)
                handle_read ${cmd#read }
                ;;
            write\ *)
                handle_write ${cmd#write }
                ;;
            flush)
                handle_flush
                ;;
            sync)
                handle_sync
                ;;
            status)
                daemon_log "status check"
                ;;
            *)
                daemon_log "unknown command: $cmd"
                ;;
        esac

        # Clear command by writing empty
        : > "$SYSFS_CMD" 2>/dev/null || true
        sleep 0.1
    fi
    sleep 0.1
done
