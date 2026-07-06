# Superblock & Checkpoint Manager

**Module:** [`src/superblock.sage`](../src/superblock.sage) · **Phase:** 1 (Foundation) · **Status:** ✅ Implemented

## Purpose

The superblock is the on-disk root of a SageFS volume. It records the filesystem geometry, feature set, and pointers to every other metadata region. The checkpoint manager provides atomic metadata commits via a dual-pack scheme, so a crash mid-write never leaves the filesystem in an inconsistent state.

## On-Disk Layout

```
Block 0        : Primary Superblock
Block 1        : Mirror  Superblock   (identical copy for redundancy)
Blocks 2-3     : Checkpoint Pack 1    (2 blocks = 8 KiB)
Blocks 4-7     : Checkpoint Pack 2    (4 blocks = 16 KiB, extra room)
Block N_nat    : NAT  (Node Address Table)
Block N_sit    : SIT  (Segment Info Table)
Block N_ssa    : SSA  (Segment Summary Area)
Block N_main   : Main area (file data + node blocks)
```

Two superblock copies (primary at offset 0, mirror at offset 4096) allow recovery from superblock corruption. Two checkpoint packs alternate: writes always target the *inactive* pack, then flip the active pointer atomically.

## Constants

| Constant | Value | Meaning |
|----------|-------|---------|
| `SAGEFS_MAGIC` | `0x53414745` | "SAGE" magic number |
| `SAGEFS_VERSION_MAJOR` / `MINOR` | `1` / `0` | On-disk format version |
| `DEFAULT_BLOCK_SIZE` | `4096` | Block size (bytes) |
| `DEFAULT_SEGMENT_SIZE` | `512` | Segment size (blocks) = 2 MiB |
| `MAX_LABEL_LEN` | `256` | Volume label max (UTF-8 bytes) |

### Feature Flags (bitfield in `superblock.flags`)

| Flag | Value | Feature |
|------|-------|---------|
| `FEATURE_CHECKSUM` | `0x0001` | Data-integrity checksums |
| `FEATURE_COMPRESS` | `0x0002` | Transparent compression |
| `FEATURE_ENCRYPT` | `0x0004` | Per-file encryption |
| `FEATURE_DEDUP` | `0x0008` | Deduplication |
| `FEATURE_SNAPSHOTS` | `0x0010` | CoW snapshots & subvolumes |
| `FEATURE_RAID` | `0x0020` | Integrated RAID |
| `FEATURE_INLINE_DATA` | `0x0040` | Inline small-file data |
| `FEATURE_XATTR` | `0x0080` | Extended attributes |

### Algorithm & State Identifiers

- **Checksum:** `CHECKSUM_CRC32C=0`, `CHECKSUM_XXHASH=1`, `CHECKSUM_SHA256=2`
- **Compression:** `COMPRESS_NONE=0`, `COMPRESS_LZ4=1`, `COMPRESS_ZSTD=2`, `COMPRESS_ZLIB=3`
- **State:** `STATE_CLEAN=0`, `STATE_DIRTY=1`, `STATE_ERROR=2`

## Key Structures

### `SageFSSuperblock`

Holds `magic`, `version_*`, `block_size`, `segment_size`, `total_segments`, `total_blocks`, `free_segments`, `root_inode`, `checkpoint_ver`, region start blocks (`nat_start_blk`, `sit_start_blk`, `ssa_start_blk`, `main_start_blk`), `uuid`, `label`, `flags`, algorithm selectors, timestamps, mount counters, `state`, and a self-`checksum`.

### `SageFSCheckpoint`

A point-in-time snapshot of consistent filesystem metadata, self-checksummed.

### `CheckpointManager`

Manages the dual-pack atomic commit protocol.

## Public API

### `SageFSSuperblock`
| Method | Description |
|--------|-------------|
| `validate() -> Bool` | Sanity-check geometry (magic, block size power-of-two, etc.) |
| `compute_checksum() -> Int` | Deterministic checksum over all fields |
| `update_checksum()` | Recompute and store `self.checksum` |
| `verify_checksum() -> Bool` | Compare stored vs. freshly computed |
| `has_feature(flag) / set_feature(flag) / clear_feature(flag)` | Feature-flag management |
| `serialize() -> Bytes` | Little-endian on-disk encoding |
| `to_dict() -> Dict` / `to_string() -> String` | Introspection |

### `CheckpointManager`
| Method | Description |
|--------|-------------|
| `get_active() / get_inactive() -> SageFSCheckpoint` | Access the active/inactive pack |
| `commit() -> Bool` | Write to inactive pack, then flip active pointer |
| `rollback()` | Discard uncommitted changes |
| `create_initial()` | Initialize both packs on a fresh volume |

## Design Notes

- The on-disk byte offsets for every field are documented inline in `serialize()` (e.g. `checksum_algo` at byte 388, `checksum` at byte 424).
- The current `compute_checksum()` uses the FNV-1a `hash()` builtin as a placeholder; Phase 3 will migrate it to `checksum.sage`'s `checksum_block()` so the superblock uses the same CRC32C/xxHash/SHA-256 pipeline as data blocks.

## Related

[checksum.md](checksum.md) · [nat.md](nat.md) · [segment.md](segment.md)
