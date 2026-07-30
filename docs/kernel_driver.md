# SageFS Kernel Driver (Phase 9)

## Overview

SageFS includes a native Linux VFS kernel module (`src/kernel/sagefs.c`) that registers
as a filesystem type, enabling `mount -t sagefs /dev/sdb /mnt/sagefs` directly through
the kernel block layer — no FUSE or userspace daemon required.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  mount -t sagefs /dev/sdb /mnt                                  │
├──────────────────────────────────────────────────────────────────┤
│  VFS Layer (kernel)                                              │
│    init_fs_context → get_tree_nodev/get_tree_bdev               │
│    fill_super → sagefs_iget → inode/address_space_ops           │
│    readdir / read_iter / write_iter / lookup / create            │
├──────────────────────────────────────────────────────────────────┤
│  sagefs.ko                                                       │
│    super_ops: alloc_inode, destroy_inode, write_inode, put_super │
│    inode_ops: create, lookup, unlink, setattr, getattr           │
│    file_ops: read_iter, write_iter, iterate_shared, fsync        │
│    aops: read_folio                                              │
├──────────────────────────────────────────────────────────────────┤
│  Block Layer (kernel)                                            │
│    sb_bread / brelse — direct block device I/O                   │
├──────────────────────────────────────────────────────────────────┤
│  SageFS On-Disk Format                                           │
│    Superblock (block 0), inode entries (blocks 8-15),            │
│    inline data, hex-encoded directory entries                    │
└──────────────────────────────────────────────────────────────────┘
```

## Current Status

| Capability | Status |
|------------|--------|
| Module init/exit, superblock operations | ✅ Working |
| `get_tree_nodev` (mount without block device) | ✅ Working |
| `get_tree_bdev` (mount with block device `/dev/sdb`) | 🔄 In progress |
| Inode creation via `sagefs_iget` (iget_locked) | ✅ Working |
| `stat` on root inode | ✅ Working |
| `ls` directory iteration | ⚠️ OOM on large directories |
| `umount` | ⚠️ OOM (i_lru list corruption) |
| Block device sb_bread path | 🚧 Not tested |
| Write operations (create, write) | 🚧 Not tested |

## Known Issues (Kernel 7.1-x64v3-xanmod1)

1. **`i_lru` not initialized by `inode_init_always`** — Kernel 7.1's `inode_init_always`
   does not call `INIT_LIST_HEAD(&inode->i_lru)`, causing `list_lru_del` to dereference
   NULL during inode eviction. Workaround: manual `INIT_LIST_HEAD` in `sagefs_alloc_inode`.
2. **OOM during readdir/umount** — The module leaks memory in the inode entry scan loop
   during readdir or persist, exhausting system memory.
3. **`rmmod` blocked after mount crash** — Module refcnt stuck at 1; requires `rmmod -f`
   or reboot to unload.

## Building

```bash
cd src/kernel
make CC=clang LD=ld.lld
sudo insmod sagefs.ko
```

Kernel headers: `7.1.5-x64v3-xanmod1` (Debian Sid). The Makefile is compatible with
the kernel module build system (kbuild).

## Usage

```bash
# Load the module
sudo insmod sagefs.ko

# Mount (nodev — no block device required)
sudo mount -t sagefs none /mnt/sagefs

# Verify
stat /mnt/sagefs           # Should show directory with inode 3

# Unmount
sudo umount /mnt/sagefs

# Unload
sudo rmmod sagefs
```

## On-Disk Format

SageFS v1.2 uses a simple on-disk format:

- **Superblock** (block 0): 452-byte structure with magic (`0x53414745`), version,
  block size, segment size, inode entry location, label (256 bytes), UUID, checksum.
- **Inode entries** (blocks 8-15, 32 KB total): Variable-length records:
  - `__le32 ino`, `__le32 mode`, `__le32 size`, `__le16 name_len`, `__le16 data_len`
  - Followed by name (name_len bytes) and inline data (data_len bytes)
  - Records are scanned linearly — empty slots are zero-filled headers.
- **Root inode** (ino=3): Stores directory entries as hex-encoded inline data.
  - Encoding: LE16 count + repeated (LE32 ino, LE16 name_len, LE8 ftype, name)
  - Hex string stored in the inode entry's inline data area.

## API Reference

### Key Functions

| Function | Purpose |
|----------|---------|
| `sagefs_init` / `sagefs_exit` | Module load/unload, register filesystem type |
| `sagefs_fill_super` | Allocate sb_info, create root inode, set up superblock ops |
| `sagefs_iget` | Get/create VFS inode via `iget_locked`, read on-disk entry |
| `sagefs_read_inode_entry` | Scan inode entry area (blocks 8-15) for matching inode |
| `sagefs_readdir` | Decode hex-encoded directory entries from root inode's inline data |
| `sagefs_read_iter` | Read file data from inline storage |
| `sagefs_write_iter` | Write file data to inline storage |
| `sagefs_lookup` | Scan inode entries for matching dentry name |
| `sagefs_create` | Allocate new inode number and create file |
| `sagefs_persist_inode` | Write/update inode entry on block device |

### Operations Tables

```c
struct super_operations sagefs_super_ops = {
    .alloc_inode = sagefs_alloc_inode,     // From slab cache
    .destroy_inode = sagefs_destroy_inode, // Return to slab
    .write_inode = sagefs_write_inode,     // Persist on writeback
    .put_super = sagefs_put_super,         // Cleanup on unmount
    .sync_fs = sagefs_sync_fs,             // Sync superblock
    .statfs = simple_statfs,
};

static const struct file_operations sagefs_dir_file_ops = {
    .iterate_shared = sagefs_readdir,
    .llseek = default_llseek,
};
```

## Kernel Compatibility Notes

The module targets **kernel 7.1-x64v3-xanmod1**. Key API differences from older kernels:

| API | Modern (7.1+) | Legacy |
|-----|---------------|--------|
| Mount | `init_fs_context` + `get_tree_nodev`/`get_tree_bdev` | `mount` callback |
| Inode LRU | `INIT_LIST_HEAD(&inode->i_lru)` in alloc_inode | Initialized by `inode_init_always` |
| Page ops | `read_folio` (folio-based) | `readpage` (page-based) |
| Inode times | `inode_set_atime`/`inode_set_mtime`/`inode_set_ctime` | Direct field access |
| i_nlink | `set_nlink(inode, n)` | Direct `inode->i_nlink = n` |
| Setattr | `simple_setattr(idmap, dentry, attr)` | `inode_change_ok` + `setattr_copy` |
| kmem_cache_create | 4-arg (no ctor) | 5-arg (with ctor) |

## Filesystem Layout (On-Disk)

```
Block 0:     Superblock (452 bytes)
Blocks 1-7:  Reserved
Blocks 8-15: Inode entries (32 KB, variable-length records)
Blocks 16+:  Data blocks (segment-aligned)
```
