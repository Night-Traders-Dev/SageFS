# Directory & Namespace Manager

**Module:** [`src/dir.sage`](../src/dir.sage) · **Phase:** 2 (Trees & Namespace) · **Status:** ✅ Implemented

## Purpose

Implements the POSIX namespace on top of [inodes](inode.md) and the [CoW B+ tree](btree.md). Small directories keep their entries inline in the inode; larger directories are backed by a hashed B+ tree for O(log n) lookups.

## Constants

| Constant | Value | Meaning |
|----------|-------|---------|
| `MAX_NAME_LEN` | `255` | Max filename length |
| `DIR_ENTRY_SIZE` | `16` | Fixed portion of a dentry (hash 4 + ino 4 + len 2 + type 1 + pad 5) |
| `MAX_INLINE_DENTRIES` | `200` | Entries kept inline before converting to a B+ tree |

### Directory Entry Types (`type` field)

`DT_UNKNOWN=0`, `DT_FIFO=1`, `DT_CHR=2`, `DT_DIR=4`, `DT_BLK=6`, `DT_REG=8`, `DT_LNK=10`, `DT_SOCK=12`.

## Structures

### `DirEntry`

A single directory entry (name hash, target inode, name length, type, name).

| Method | Description |
|--------|-------------|
| `serialize() -> Bytes` / `deserialize(data)` | On-disk encoding |

### `DirManager`

| Method | Description |
|--------|-------------|
| `hash_filename(name) -> Int` | Compute the entry hash for fast lookup |
| `add_entry(dir_ino, name, ino, type) -> Bool` | Add a name → inode mapping |
| `remove_entry(dir_ino, name) -> Bool` | Remove an entry |
| `lookup(dir_ino, name) -> Int` | Resolve a name to an inode number |
| `read_dir(dir_ino) -> Array[DirEntry]` | List a directory |
| `is_empty(dir_ino) -> Bool` | Emptiness check (for rmdir) |
| `rename(old_dir, old_name, new_dir, new_name) -> Bool` | Atomic rename/move |
| `make_dir(parent_ino, name, uid, gid) -> Int` | Create a subdirectory |

## Inline → B+ Tree Promotion

Directories start with entries stored inline in the inode. Once they exceed `MAX_INLINE_DENTRIES`, the manager promotes them to a hashed B+ tree keyed by `hash_filename(name)`, keeping lookups fast as directories grow.

## Related

[inode.md](inode.md) · [btree.md](btree.md)
