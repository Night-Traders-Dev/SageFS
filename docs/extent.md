# Extent Map

**Module:** [`src/extent.sage`](../src/extent.sage) · **Phase:** 2 (Trees & Namespace) · **Status:** ✅ Implemented

## Purpose

The extent map provides extent-based file allocation: instead of tracking every block individually, contiguous runs of blocks are recorded as a single **extent** (logical offset → physical block run). This minimizes metadata overhead for large, contiguous files.

## Constants

| Constant | Value | Meaning |
|----------|-------|---------|
| `MAX_EXTENT_LEN` | `32768` | Max blocks in a single extent |

## Structures

### `Extent`

A contiguous run of physical blocks at a logical file offset.

- Fields: `file_offset`, `block_addr`, `length`.
- `end_offset() -> Int` — logical offset immediately after this extent.
- `serialize() -> Bytes` — 24-byte encoding (offset, block, length).

### `ExtentTree`

Manages an inode's extents, keeping them sorted and merged.

| Method | Description |
|--------|-------------|
| `insert_extent(file_offset, block_addr, length)` | Insert, merging with contiguous neighbors |
| `lookup_extent(file_offset) -> Extent` | Find the extent covering an offset (or nil) |
| `truncate(new_size)` | Drop/trim extents past a new file size |
| `punch_hole(offset, length)` | Remove or split extents within a hole range |

### `ExtentAllocator`

Coordinates with the [BlockAllocator](allocator.md) to request contiguous runs.

| Method | Description |
|--------|-------------|
| `allocate_run(temperature, count) -> Array[Extent]` | Allocate `count` blocks, ideally as one extent |

## Merging & Splitting

- **Insert** attempts to merge with the left and right neighbors when both the logical offsets and physical addresses are contiguous (subject to `MAX_EXTENT_LEN`).
- **Punch-hole** handles four cases: full swallow, overlap-start, overlap-end, and mid-extent split (producing two extents).

## Related

[inode.md](inode.md) · [allocator.md](allocator.md) · [btree.md](btree.md)
