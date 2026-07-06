# Node Address Table (NAT)

**Module:** [`src/nat.sage`](../src/nat.sage) · **Phase:** 1 (Foundation) · **Status:** ✅ Implemented

## Purpose

The NAT is a core F2FS-derived structure that maps logical **node IDs (nids)** to **physical block addresses**. This indirection layer eliminates the "wandering tree" problem:

> In BTRFS, updating a leaf block triggers CoW of every ancestor up to the root — O(depth) write amplification. With the NAT, each node has a fixed logical ID. When a node is rewritten to a new physical location (log-structured), only its NAT entry changes — no parent nodes are touched.

## Structures

### `NATEntry`

One nid → block-address mapping plus liveness state.

| Method | Description |
|--------|-------------|
| `is_alive() -> Bool` | Whether the node is currently referenced |
| `update(new_block_addr)` | Point the nid at a new physical block |
| `invalidate()` | Mark the node dead (freed) |
| `serialize() -> Bytes` / `to_dict() -> Dict` | Encoding & introspection |

### `NATJournal`

An in-memory delta log of NAT changes since the last checkpoint, batched and flushed together to amortize write cost.

| Method | Description |
|--------|-------------|
| `add(entry) -> Bool` | Record a pending change |
| `get(nid) -> NATEntry` | Read a journaled entry |
| `remove(nid)` | Drop a journaled entry |
| `is_full() -> Bool` | Whether the journal should be flushed |
| `flush() -> Array` | Drain the journal for checkpoint |
| `count() -> Int` | Pending entry count |

### `NodeAddressTable`

The top-level manager combining the on-disk NAT with the journal and a free-nid pool.

| Method | Description |
|--------|-------------|
| `allocate_nid() -> Int` | Reserve a fresh node ID |
| `free_nid(nid)` | Return a nid to the free pool |
| `lookup(nid) -> Int` | Resolve nid → physical block address |
| `update(nid, block_addr)` | Repoint a nid (log-structured rewrite) |
| `batch_update(updates)` | Apply many updates at once |
| `get_entry(nid) -> NATEntry` | Full entry access |
| `get_dirty_entries() -> Array` | Entries changed since last flush |
| `flush_journal()` | Merge journal into the main table |
| `checkpoint()` | Persist a consistent NAT snapshot |
| `prefill_free_nids(count)` | Warm the free-nid pool |
| `stats() -> Dict` / `to_string() -> String` | Introspection |

## Helper Functions

- `nid_to_nat_block(nid, nat_start_blk) -> Int` — which NAT block holds a nid.
- `nid_to_nat_offset(nid) -> Int` — byte offset within that block.

## Design Notes

- **Journal + batch flush** keeps hot-path updates cheap (append to journal) while amortizing disk writes at checkpoint time.
- The free-nid pool avoids scanning the table on every allocation.

## Related

[allocator.md](allocator.md) · [segment.md](segment.md) · [inode.md](inode.md)
