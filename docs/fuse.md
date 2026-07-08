# FUSE Protocol Interface

| Module | `src/fuse.sage` |
|--------|-----------------|
| Status | ✅ Implemented |
| Phase  | 6 — Tooling & Integration |

## Purpose

The FUSE module defines the kernel FUSE protocol structures and operation dispatch for the SageFS mount helper. It maps FUSE request types to VFS method calls, allowing a userspace FUSE daemon to present the SageFS as a mounted filesystem.

## Architecture

```
Userspace                          Kernel
─────────                          ──────
sagefs-fuse (Python)               VFS
  └─ fusepy / libfuse                └─ syscalls → VFS
       └─ /dev/fuse                       └─ ext4, btrfs, etc.
            └─ kernel VFS
```

For SageFS, the userspace FUSE daemon can run in two modes:

1. **Python bridge (current):** `build/sagefs-fuse` uses `fusepy` (and falls back to `--info` if unavailable) and reads the native binary image format directly. This is the recommended mode for the current development environment. It presents a read-only README.txt with superblock metadata.

2. **SageLang native (future):** Once SageLang supports FFI calls to `libfuse3`, the `fuse.sage` module can register its handlers directly with `fuse_session_loop()`.

## FUSE Operations

| Opcode | Constant | Handler | Description |
|--------|----------|---------|-------------|
| 1 | FUSE_LOOKUP | `on_op_lookup` | Look up a directory entry by name |
| 3 | FUSE_GETATTR | `on_op_getattr` | Get file/directory attributes |
| 14 | FUSE_OPEN | `on_op_open` | Open a file |
| 15 | FUSE_READ | `on_op_read` | Read data from a file |
| 16 | FUSE_WRITE | `on_op_write` | Write data to a file |
| 17 | FUSE_STATFS | `on_op_statfs` | Get filesystem statistics |
| 18 | FUSE_RELEASE | `on_op_release` | Close/release a file |
| 27 | FUSE_MKDIR | `on_op_mkdir` | Create a directory |
| 28 | FUSE_READDIR | `on_op_readdir` | Read directory entries |
| 29 | FUSE_RMDIR | `on_op_rmdir` | Remove a directory |
| 30 | FUSE_UNLINK | `on_op_unlink` | Remove a file |
| 35 | FUSE_CREATE | `on_op_create` | Create and open a file |
| 38 | FUSE_RENAME | `on_op_rename` | Rename a file/directory |
| 39 | FUSE_DESTROY | `on_op_destroy` | Clean up on unmount |

## Handler Signatures

Each handler accepts the VFS instance as its first argument, plus operation-specific parameters:

| Handler | Parameters | Returns | Delegates To |
|---------|------------|---------|--------------|
| `on_op_lookup` | `fs, parent, name` | `Int` (ino) | `fs.resolve_path()` |
| `on_op_getattr` | `fs, ino` | `Dict` | `fs.stat()` |
| `on_op_read` | `fs, ino, offset, size` | `Bytes` | `fs.open()` + `fs.read()` |
| `on_op_write` | `fs, ino, offset, data` | `Int` (written) | `fs.open()` + `fs.write()` |
| `on_op_mkdir` | `fs, parent, name, mode` | `Bool` | `fs.mkdir()` |
| `on_op_readdir` | `fs, ino` | `Array[String]` | `fs.readdir()` |
| `on_op_unlink` | `fs, parent, name` | `Bool` | `fs.unlink()` |
| `on_op_rmdir` | `fs, parent, name` | `Bool` | `fs.rmdir()` |
| `on_op_rename` | `fs, parent, name, newparent, newname` | `Bool` | `fs.rename()` |
| `on_op_create` | `fs, parent, name, mode` | `Int` (fd) | `fs.open()` |
| `on_op_statfs` | `fs` | `Dict` | superblock stats |
| `on_op_destroy` | `fs` | `void` | `fs.unmount()` |

## FUSE Protocol Structure

Each FUSE request from the kernel is a fixed-size header (40 bytes) followed by an operation-specific payload:

```
Offset  Size  Field
──────  ────  ─────
0       4     len (total request size)
4       4     opcode
8       8     unique (request identifier)
16      8     nodeid (inode to operate on)
24      8     uid (caller UID)
32      8     gid (caller GID)
40      var   payload (operation-specific)
```

Responses follow a similar header structure. The handlers in `fuse.sage` process the payload and produce the response data.

## Related Modules

- `src/vfs.sage` — VFS interface that handlers delegate to
- `src/mount.sage` — mount helper that initialises VFS + started FUSE
- `build/sagefs-fuse` — Python FUSE driver that bridges Python ↔ SageFS
