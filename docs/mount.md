# Mount Helper

| Module | `src/mount.sage` |
|--------|------------------|
| Status | ✅ Implemented |
| Phase  | 6 — Tooling & Integration |

## Purpose

The mount helper is the entry point for making a SageFS filesystem available for use. It reads the superblock, replays the journal if a dirty unmount was detected, initialises the in-memory VFS state, and hands off to the FUSE daemon.

## Usage

```
sage --runtime bytecode -I src src/mount.sage <image> [mountpoint]
```

For full FUSE mounting with userspace access:

```
./build/sagefs-fuse <image> <mountpoint>
```

## Mount Workflow

```
mount.sage
│
├─ 1. Read image via imgio.read_image()
├─ 2. Parse superblock via `deserialize_superblock()` (validate magic 0x53414745)
├─ 3. Check filesystem state flag
│      └─ if dirty → replay journal
├─ 4. Initialise VFS (src/vfs.sage)
├─ 5. Print filesystem info
├─ 6. Hand off to FUSE bridge
│      └─ build/sagefs-fuse <image> <mountpoint>
└─ 7. Return
```

## Filesystem State

| State | Value | Description |
|-------|-------|-------------|
| CLEAN | 0 | Clean unmount — no journal replay needed |
| DIRTY | 1 | Dirty unmount — journal replay required |
| ERROR | 2 | Error state — fsck recommended |

## FUSE Bridge

The `build/sagefs-fuse` script is a Python FUSE driver that mounts a SageFS binary image as a userspace filesystem. It reads the image directly and presents it via FUSE. This is separate from the SageLang VFS but compatible with the binary image format.

### Mount Options

| Option | Description |
|--------|-------------|
| `ro` | Read-only mount |
| `allow_other` | Allow other users to access (requires `user_allow_other` in `/etc/fuse.conf`) |

### Example

```bash
# Format a 256MB image
./build/mkfs.sagefs --size 256 --force /tmp/sage.img

# Create mountpoint and mount
mkdir -p /mnt/sagefs
./build/sagefs-fuse /tmp/sage.img /mnt/sagefs

# Access the filesystem
ls /mnt/sagefs
cat /mnt/sagefs/README.txt

# Unmount
fusermount3 -u /mnt/sagefs
```

## Related Modules

- `src/vfs.sage` — VFS interface layer initialised during mount
- `src/fuse.sage` — FUSE protocol handlers for operation dispatch
- `src/imgio.sage` — binary image persistence
- `src/journal.sage` — journal replay for crash recovery
- `build/sagefs-fuse` — Python FUSE driver script
