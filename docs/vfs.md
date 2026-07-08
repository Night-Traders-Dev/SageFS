# VFS Interface Layer

| Module | `src/vfs.sage` |
|--------|----------------|
| Status | ✅ Implemented |
| Phase  | 6 — Tooling & Integration |

## Purpose

The VFS (Virtual Filesystem) layer provides the POSIX-like file and directory operations that bridge userspace file I/O with SageFS on-disk structures. It is the central orchestration layer that coordinates all core subsystems (superblock, inode, segment, journal, transaction, dir, btree) into a coherent filesystem interface.

## Design

The VFS operates in two modes:

1. **Native (SageVM / compiled):** Direct block I/O via the core engine modules, suitable for kernel integration and high-performance native binaries. Every POSIX operation maps to a sequence of SageFS metadata mutations.

2. **Python FUSE bridge:** The `build/sagefs-fuse` script reads the hex-text image format directly and provides a userspace FUSE mount. This uses the hex-text persistence layer from `src/imgio.sage`.

## Key Data Structures

### FileDescriptor

```sage
class FileDescriptor:
    ino: Int        # inode number
    flags: Int      # open flags (O_RDONLY, O_WRONLY, O_RDWR, O_CREAT, ...)
    pos: Int        # current read/write position
```

### VFS

```sage
class VFS:
    image_path: String    # path to the hex-text image file
    mounted: Bool          # mount state flag
    sb: SageFSSuperblock   # parsed superblock (after mount)
    fds: Array             # open file descriptor table
    next_fd: Int           # next available fd number
    dentries: Array        # root-level directory entries
```

## Public API

| Method | Signature | Description |
|--------|-----------|-------------|
| mount | `mount() -> Bool` | Reads and validates the superblock, initialises VFS state |
| unmount | `unmount() -> Bool` | Flushes and releases VFS resources |
| open | `open(path, flags) -> Int` | Opens a file; returns fd or -1 |
| close | `close(fd) -> Bool` | Closes a file descriptor |
| read | `read(fd, size) -> Bytes` | Reads up to `size` bytes at current position |
| write | `write(fd, data) -> Int` | Writes `data` at current position |
| lseek | `lseek(fd, offset, whence) -> Int` | Repositions file offset |
| stat | `stat(path) -> Dict` | Returns file/directory metadata |
| readdir | `readdir(path) -> Array[String]` | Lists directory entries |
| mkdir | `mkdir(path, mode) -> Bool` | Creates a directory |
| unlink | `unlink(path) -> Bool` | Removes a file |
| rmdir | `rmdir(path) -> Bool` | Removes an empty directory |
| rename | `rename(oldpath, newpath) -> Bool` | Renames a file/directory |

## Open Flags

| Constant | Value | Description |
|----------|-------|-------------|
| O_RDONLY | 0x0000 | Read-only |
| O_WRONLY | 0x0001 | Write-only |
| O_RDWR | 0x0002 | Read-write |
| O_CREAT | 0x0040 | Create file if it doesn't exist |
| O_EXCL | 0x0080 | Exclusive create (fail if exists) |
| O_TRUNC | 0x0200 | Truncate on open |
| O_APPEND | 0x0400 | Append mode |

## Seek Constants

| Constant | Value | Description |
|----------|-------|-------------|
| SEEK_SET | 0 | Absolute offset from start |
| SEEK_CUR | 1 | Relative to current position |
| SEEK_END | 2 | Relative to end of file |

## File Modes

| Constant | Value | Description |
|----------|-------|-------------|
| S_IFMT | 0xF000 | Type bit mask |
| S_IFREG | 0x8000 | Regular file |
| S_IFDIR | 0x4000 | Directory |
| S_IFLNK | 0xA000 | Symbolic link |

## Inline Data I/O

The VFS reads file content directly from inode directory entries stored
after the superblock in the hex-text image.  `read_inode_data(ino)` looks
up the inode number in the in-memory inode table and returns its inline
data buffer.  This is the F2FS-style inline data path — small files up to
~3.4 KiB are stored directly in the inode with zero extra block I/O.

The inode directory is written by `mkfs.sagefs` using `imgio.write_inode_entry()`
and parsed by `VFS.mount()` using `imgio.read_inode_entries()`.

## Mount Workflow

1. `VFS.mount()` reads the hex-text image via `imgio.read_image()`
2. Calls `superblock.deserialize_superblock()` to parse the 428-byte superblock
3. If the image has data beyond the superblock, reads the inode directory via `imgio.read_inode_entries()` and populates `self.inodes` and `self.dentries`
4. Validates the magic (`0x53414745` = "SAGE") via `SAGEFS_MAGIC`
5. Sets the `mounted` flag to true
4. Subsequent VFS operations check `mounted` before proceeding
5. `VFS.unmount()` clears the flag and releases resources

## Related Modules

- `src/fuse.sage` — FUSE protocol handlers that dispatch to VFS methods
- `src/mount.sage` — mount helper that initialises VFS and starts the FUSE bridge
- `src/imgio.sage` — hex-text image persistence used by VFS.mount()
- `build/sagefs-fuse` — Python FUSE driver wrapping the VFS interface
