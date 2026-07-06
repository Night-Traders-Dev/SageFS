# Block Allocator

**Module:** [`src/allocator.sage`](../src/allocator.sage) · **Phase:** 1 (Foundation) · **Status:** ✅ Implemented

## Purpose

The allocator is the central coordination layer that ties the [Segment Manager](segment.md) (SIT) and [Node Address Table](nat.md) (NAT) into a single block-allocation interface used by every other subsystem.

## Design Principles

- **Log-structured allocation** — new writes always append to the tail of the active log segment for the appropriate temperature.
- **Multi-head logging** — 6 active log heads (3 data temperatures × 2 node types) separate hot/warm/cold data and reduce GC overhead.
- **Pre-allocation caching** — blocks are pre-allocated in batches to amortize per-block overhead.

## Temperature Mapping

`map_temperature_to_seg_type(temp, is_node) -> String` maps a temperature string (`"hot"`, `"warm"`, `"cold"`) and a node/data flag to one of the six segment types.

## Structures

### `AllocationResult`

Returned by every allocation call.

| Method | Description |
|--------|-------------|
| `is_success() -> Bool` | Whether allocation succeeded |
| `to_dict() -> Dict` | Result details (nid, physical block, segment) |

### `BlockAllocator`

| Method | Description |
|--------|-------------|
| `allocate_data_block(temperature) -> AllocationResult` | Allocate a data block in the right zone |
| `allocate_node_block(temperature) -> AllocationResult` | Allocate a node block |
| `allocate_meta_block() -> AllocationResult` | Allocate a metadata block |
| `free_block(nid) -> Bool` | Free a block by node ID |
| `batch_allocate(count, temperature, is_node) -> Array` | Bulk allocation |
| `lookup_physical(nid) -> Int` | Resolve nid → physical block (via NAT) |
| `needs_gc() -> Bool` / `needs_urgent_gc() -> Bool` | GC pressure signals |
| `space_available() -> Int` | Free space (blocks) |
| `utilization() -> Int` | Used-space percentage |
| `classify_temperature(access_count, age) -> String` | Heuristic hot/warm/cold classification |
| `preallocate(seg_type, count)` | Warm the pre-allocation cache |
| `get_preallocated(seg_type) -> Dict` | Inspect cached blocks |
| `summary() -> Dict` | Aggregate allocator state |

## Allocation Flow

1. Caller requests a block with a temperature (and node/data flag).
2. Allocator maps that to a segment type and picks the matching log head.
3. If the pre-allocation cache has blocks, one is handed out immediately.
4. Otherwise the Segment Manager allocates the next log-tail block.
5. A NAT entry is created/updated so the logical nid resolves to the physical block.
6. An `AllocationResult` is returned.

## Related

[segment.md](segment.md) · [nat.md](nat.md) · [inode.md](inode.md)
