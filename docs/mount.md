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
│      └─ ⚠️ **Requires FFI**: VFS in-memory state rebuilt each mount
├─ 5. Print filesystem info
├─ 6. Hand off to FUSE bridge
│      └─ native FFI loop via /dev/fuse (ABI 7.26)
│      └─ fallback: Python FUSE bridge (build/sagefs-fuse)
└─ 7. Return
```

## Filesystem State

| State | Value | Description |
|-------|-------|-------------|
| CLEAN | 0 | Clean unmount — no journal replay needed |
| DIRTY | 1 | Dirty unmount — journal replay required |
| ERROR | 2 | Error state — fsck recommended |

## FUSE Bridge

The FUSE bridge uses **native FFI** (via `/dev/fuse` direct I/O) to register with the Linux kernel's FUSE subsystem. SageFS implements the FUSE ABI 7.26 binary protocol in SageLang (`src/fuse.sage`), communicating with the kernel through libc's `open()`/`read()`/`write()` calls via SageVM FFI. This eliminates the Python bridge dependency for production use.

### Bridge Modes

| Mode | Implementation | Status |
|------|---------------|--------|
| **Native FFI** | `/dev/fuse` direct I/O via libc FFI | ✅ Primary |
| **Python Bridge** | `build/sagefs-fuse` (Python FUSE) | ⚠️ Fallback |

### Mount Options

| Option | Description |
|--------|-------------|
| `ro` | Read-only mount |
| `allow_other` | Allow other users to access (requires `user_allow_other` in `/etc/fuse.conf`) |

### Example

```bash
# Format a 256MB image
./build/mkfs.sagefs --size 256 --force /tmp/sage.img

# Create mountpoint and mount using native FFI bridge
mkdir -p /mnt/sagefs
sage --runtime bytecode -I src mount.sage /tmp/sage.img /mnt/sagefs

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
