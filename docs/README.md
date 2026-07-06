# SageFS Documentation

This directory contains per-component design and API documentation for SageFS. Each document corresponds to one source module under [`../src/`](../src/) and describes its purpose, on-disk format, key data structures, and public API.

## Component Index

| Document | Module | Phase | Status |
|----------|--------|-------|--------|
| [superblock.md](superblock.md) | `src/superblock.sage` | 1 | ✅ Implemented |
| [segment.md](segment.md) | `src/segment.sage` | 1 | ✅ Implemented |
| [nat.md](nat.md) | `src/nat.sage` | 1 | ✅ Implemented |
| [allocator.md](allocator.md) | `src/allocator.sage` | 1 | ✅ Implemented |
| [inode.md](inode.md) | `src/inode.sage` | 1 | ✅ Implemented |
| [btree.md](btree.md) | `src/btree.sage` | 2 | ✅ Implemented |
| [dir.md](dir.md) | `src/dir.sage` | 2 | ✅ Implemented |
| [extent.md](extent.md) | `src/extent.sage` | 2 | ✅ Implemented |
| [checksum.md](checksum.md) | `src/checksum.sage` | 3 | ✅ Implemented |
| [journal.md](journal.md) | `src/journal.sage`, `src/transaction.sage` | 3 | ✅ Implemented |
| [fsck.md](fsck.md) | `src/fsck.sage` | 3 | ✅ Implemented |

## Reading Order

For newcomers, we recommend reading the documentation in dependency order:

1. **[superblock.md](superblock.md)** — the on-disk root of everything; layout, feature flags, checkpoints
2. **[segment.md](segment.md)** — how physical space is carved into log-structured segments (SIT)
3. **[nat.md](nat.md)** — the node-address indirection layer that eliminates the wandering-tree problem
4. **[allocator.md](allocator.md)** — how SIT + NAT combine into a unified block allocation API
5. **[inode.md](inode.md)** — file/directory metadata, inline data, block pointers
6. **[btree.md](btree.md)** — the CoW B+ tree that backs directories, extents, and snapshots
7. **[dir.md](dir.md)** — namespace operations built on inodes + B+ trees
8. **[extent.md](extent.md)** — extent-based file allocation and hole punching
9. **[checksum.md](checksum.md)** — per-block integrity (CRC32C / xxHash / SHA-256)
10. **[journal.md](journal.md)** — write-ahead logging & transactions for crash recovery
11. **[fsck.md](fsck.md)** — offline consistency checker (NAT ↔ SIT ↔ inode tree)

## Conventions

- **Endianness:** all multi-byte integers are serialized little-endian for cross-architecture portability.
- **Block size:** 4096 bytes (configurable, power-of-two, ≥ 4096).
- **Segment size:** 512 blocks = 2 MiB (default).
- **Integers:** SageLang `Int` is a tagged 64-bit value; fixed-width arithmetic is enforced by masking (`& 0xFFFFFFFF`, `& 0xFFFFFFFFFFFFFFFF`).

See the top-level [plan.md](../plan.md) for the full development roadmap and [README.md](../README.md) for the project overview.
