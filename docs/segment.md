# Segment Manager & Segment Information Table (SIT)

**Module:** [`src/segment.sage`](../src/segment.sage) · **Phase:** 1 (Foundation) · **Status:** ✅ Implemented

## Purpose

SageFS's storage layer is log-structured, inspired by F2FS. Physical space is divided into fixed-size **segments** (default 512 blocks = 2 MiB). The Segment Manager tracks per-segment valid-block bitmaps and implements **multi-head logging** with 6 concurrent log zones, separating hot/warm/cold data and node blocks to minimize garbage-collection overhead.

## Constants

| Constant | Value | Meaning |
|----------|-------|---------|
| `BLOCKS_PER_SEGMENT` | `512` | Blocks per segment (2 MiB @ 4K blocks) |
| `SIT_ENTRY_SIZE` | `72` | On-disk SIT entry size (bytes) |
| `MAX_SIT_ENTRIES` | `65536` | Maximum segments tracked |

## Multi-Head Logging Zones

Six log heads separate data by temperature and node type:

- **Data:** hot, warm, cold
- **Node:** hot, warm, cold

Cold segments accumulate few invalidations, so GC relocates fewer valid blocks — reducing write amplification and extending SSD lifespan.

## Key Structures

### `SITEntry` (72 bytes on disk)

Per-segment metadata: valid block count, segment type, modification time, and age (used for GC victim selection). Uses a bitmap array (not packed bits) for O(1) per-block operations.

| Method | Description |
|--------|-------------|
| `mark_valid(block_offset)` / `mark_invalid(block_offset)` | Update the valid bitmap |
| `is_valid(block_offset) -> Bool` | Test a block |
| `is_full() -> Bool` / `is_empty() -> Bool` | Segment occupancy checks |
| `utilization() -> Int` | Valid-block percentage |
| `find_free_block() -> Int` | Next free block offset, or -1 |
| `serialize() -> Bytes` / `to_dict() -> Dict` | Encoding & introspection |

### `SegmentManager`

Owns all SIT entries and the active log heads.

| Method | Description |
|--------|-------------|
| `get_entry(segno) -> SITEntry` | Fetch a segment's SIT entry |
| `allocate_segment(seg_type_str) -> Int` | Reserve a fresh segment for a type |
| `allocate_block(seg_type_str) -> Dict` | Allocate the next log-tail block |
| `free_segment(segno)` | Release an empty segment |
| `invalidate_block(segno, block_offset)` | Mark a block dead (CoW/overwrite) |
| `get_physical_block(segno, block_offset) -> Int` | Segment-relative → absolute block |
| `free_segment_count() -> Int` / `dirty_segment_count() -> Int` | Space accounting |
| `get_victim_greedy() -> Int` | GC victim by fewest valid blocks |
| `get_victim_cost_benefit() -> Int` | GC victim by cost-benefit (age-aware) |
| `get_segments_by_type(seg_type_str) -> Array` | Filter segments by type |
| `summary() -> Dict` | Aggregate stats |

## Helper Functions

- `seg_type_to_int(type_str) -> Int` / `seg_type_to_string(type_int) -> String` — bidirectional segment-type mapping.

## GC Victim Selection

Two policies are provided:

- **Greedy** — pick the segment with the fewest valid blocks (cheapest to clean).
- **Cost-benefit** — weigh cleaning cost against how long the segment has been stable (age), preferring to clean cold segments that won't soon be rewritten.

## Related

[allocator.md](allocator.md) · [nat.md](nat.md) · [superblock.md](superblock.md)
