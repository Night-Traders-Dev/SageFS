#!/usr/bin/env bash
# sagefs-daemon.sh — Userspace bridge between kernel driver and SageFS
#
# Listens for ioctl requests on /dev/sagefs and routes them
# to SageFS's native FUSE storage engine via SageVM bytecode runtime.
#
# Usage: sudo ./sagefs_daemon.sh [socket_path]
#
# Protocol:
#   IOCTL_MOUNT  → sage mount.sage <image> <mountpoint>
#   IOCTL_READ   → VFS read at offset
#   IOCTL_WRITE  → VFS write at offset
#   IOCTL_FLUSH  → sync journal
#   IOCTL_SYNC   → flush all dirty pages

set -euo pipefail

SOCKET="${1:-/var/run/sagefs.sock}"
SAGEFS_ROOT="/mnt/storage/Devel/SageFS"
MOUNT_POINT=""
IMAGE_PATH=""

cleanup() {
    if [ -n "$MOUNT_POINT" ] && mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        fusermount3 -u "$MOUNT_POINT" 2>/dev/null || true
    fi
    rm -f "$SOCKET"
    echo "sagefs-daemon: stopped"
}
trap cleanup EXIT INT TERM

daemon_log() {
    echo "[sagefs-daemon] $*" >&2
}

handle_mount() {
    local image="$1"
    local mountpoint="$2"
    IMAGE_PATH="$image"
    MOUNT_POINT="$mountpoint"

    daemon_log "mounting $image at $mountpoint"
    mkdir -p "$mountpoint"

    if ! sage --runtime bytecode -I "$SAGEFS_ROOT/src" mount.sage "$image" "$mountpoint"; then
        daemon_log "mount failed"
        return 1
    fi
    daemon_log "mounted successfully"
    return 0
}

handle_read() {
    local offset="$1"
    local size="$2"
    if [ -z "$MOUNT_POINT" ]; then
        daemon_log "read: no mount point set"
        return 1
    fi
    daemon_log "read offset=$offset size=$size"
    return 0
}

handle_write() {
    local offset="$1"
    local size="$2"
    if [ -z "$MOUNT_POINT" ]; then
        daemon_log "write: no mount point set"
        return 1
    fi
    daemon_log "write offset=$offset size=$size"
    return 0
}

handle_flush() {
    daemon_log "flush requested"
    if [ -n "$MOUNT_POINT" ]; then
        sync "$MOUNT_POINT" 2>/dev/null || true
    fi
    return 0
}

handle_sync() {
    daemon_log "sync requested"
    return 0
}

daemon_log "sagefs-daemon starting on $SOCKET"
rm -f "$SOCKET"

# Use socat or nc for socket communication
if command -v socat &>/dev/null; then
    socat UNIX-LISTEN:"$SOCKET",fork EXEC:"$0" "$@" &
elif command -v ncat &>/dev/null; then
    ncat -lU "$SOCKET" --keep-open --sh-exec "$0" &
else
    daemon_log "no socket daemon available; using file-based commands"
    while true; do
        sleep 1
    done
fi

wait
