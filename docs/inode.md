# Inode Manager

**Module:** [`src/inode.sage`](../src/inode.sage) · **Phase:** 1 (Foundation) · **Status:** ✅ Implemented

## Purpose

Inodes are the core metadata structure for files and directories. SageFS inodes support **F2FS-style inline data** (small files stored directly in the inode) and **BTRFS-style generation numbers** for snapshot consistency and stale-reference detection.

## Constants

| Constant | Value | Meaning |
|----------|-------|---------|
| `INODE_SIZE` | `4096` | On-disk inode block size |
| `INLINE_DATA_MAX` | `3400` | Max bytes stored inline (~3.4 KiB) |
| `INLINE_DENTRY_MAX` | `200` | Max inline directory entries |
| `MAX_DIRECT_PTRS` | `923` | Direct block pointers per inode |
| `ROOT_INO` | `1` | Root directory inode number |

### File-Type Bits (`mode` field, standard POSIX)

`S_IFREG=0x8000`, `S_IFDIR=0x4000`, `S_IFLNK=0xA000`, `S_IFIFO=0x1000`, `S_IFSOCK=0xC000`, `S_IFBLK=0x6000`, `S_IFCHR=0x2000`, mask `S_IFMT=0xF000`.

### Inode Flags

`INODE_FLAG_INLINE_DATA=0x0001`, `INLINE_DENTRY=0x0002`, `COMPRESSED=0x0004`, `ENCRYPTED=0x0008`, `IMMUTABLE=0x0010`, `APPEND_ONLY=0x0020`, `NODUMP=0x0040`, `NOATIME=0x0080`.

## Structures

### `SageFSInode`

| Method | Description |
|--------|-------------|
| `is_file() / is_dir() / is_symlink() -> Bool` | Type predicates |
| `is_inline() / has_inline_dentry() -> Bool` | Inline-storage predicates |
| `is_compressed() / is_encrypted() -> Bool` | Feature predicates |
| `set_flag(flag) / clear_flag(flag) / has_flag(flag)` | Flag management |
| `set_inline_data(data) -> Bool` | Store small-file data inline (fails if too large) |
| `get_inline_data() -> String` / `clear_inline_data()` | Inline data access |
| `add_block_ptr(block_addr) -> Int` | Append a direct block pointer |
| `get_block_ptr(index) -> Int` / `remove_block_ptr(index)` | Block-pointer access |
| `count_block_ptrs() -> Int` | Number of block pointers |
| `update_times(access, modify, change)` | Update atime/mtime/ctime |
| `compute_checksum() / update_checksum() / verify_checksum()` | Integrity |
| `serialize() -> Bytes` / `to_dict() / to_string()` | Encoding & introspection |

### `InodeManager`

| Method | Description |
|--------|-------------|
| `create_inode(mode, uid, gid) -> SageFSInode` | Allocate a new inode |
| `create_root() -> SageFSInode` | Create the root directory inode |
| `get_inode(ino) -> SageFSInode` | Load an inode |
| `delete_inode(ino) -> Bool` | Remove an inode |
| `update_inode(ino)` | Mark dirty / persist |
| `get_dirty_inodes() -> Array` | Inodes changed since checkpoint |
| `checkpoint()` | Flush dirty inodes |
| `link(ino) / unlink(ino) -> Bool` | Hard-link refcount management |
| `count() -> Int` / `stats() -> Dict` | Introspection |

## Inline Data & Directories

Files ≤ `INLINE_DATA_MAX` bytes are stored directly in the inode block — zero extra block reads for tiny files. Directories with ≤ `INLINE_DENTRY_MAX` entries keep those entries inline before converting to a B+ tree (see [dir.md](dir.md)).

## Related

[dir.md](dir.md) · [allocator.md](allocator.md) · [extent.md](extent.md) · [checksum.md](checksum.md)
