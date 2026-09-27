> **Status: working, and tested.** `test_btree.sage` (27 assertions)
> covers insert, search, split, borrow, merge, delete and copy-on-write. The
> on-disk node header and the keys are **big-endian**, which is inconsistent
> with the little-endian superblock, journal, NAT, SIT and inode-entry
> structures — see the note in the repository README.
>
> Two invariants the test previously asserted were arithmetically impossible and
> have been replaced: 200 keys cannot fit in two leaves at an 84-key limit, and
> after deleting 85 keys the root cannot become a leaf because 115 keys remain.

# CoW B+ Tree Engine

**Module:** [`src/btree.sage`](../src/btree.sage) · **Phase:** 2 (Trees & Namespace) · **Status:** ✅ Implemented

## Purpose

A Copy-on-Write B+ tree is the core index structure for SageFS. It backs directory entries, extent maps, extended-attribute indexes, and snapshot trees. Because every modification copies the affected node (rather than mutating in place), snapshots are created by simply cloning the tree root — an O(1) operation.

## Constants

| Constant | Value | Meaning |
|----------|-------|---------|
| `BTREE_NODE_SIZE` | `4096` | Node block size (bytes) |
| `BTREE_MAGIC` | `0x42545245` | "BTRE" node magic |
| `BTREE_MAX_KEYS` | `84` | Max keys per node |

## Design Decisions

- **Copy-on-Write:** any node modification produces a new node at a new block; the parent is updated to point at it (up to a new root). Old nodes remain valid for existing snapshots.
- **Block-backed:** nodes are read/written through a `BlockAllocator` abstraction so the tree can live on disk.
- **B+ layout:** all values live in leaf nodes; internal nodes hold only keys and child pointers, keeping fan-out high (up to 84 keys/node).

## Structures

| Type | Role |
|------|------|
| `BlockAllocator` | Node block allocation & raw I/O (`alloc_block`, `free_block`, `read_block`, `write_block`) |
| `BTreeKey` | Comparable key (`compare(other) -> Int`, `serialize`) |
| `BTreeItem` | Key + payload leaf item |
| `BTreePointer` | Internal-node child pointer |
| `SplitResult` | Result of a node split (median key + new sibling) |
| `BTreeNode` | A single node (`search`, `insert`, `split`, `serialize`) |
| `BTreeEngine` | Top-level tree operations |

### `BTreeEngine` Public API

| Method | Description |
|--------|-------------|
| `search(key) -> Bytes` | Look up a key's payload |
| `insert(key, data)` | Insert a key/value (CoW path, splits as needed) |
| `delete(key)` | Remove a key (CoW path, merges as needed) |
| `update(key, new_data)` | Replace a key's payload |
| `read_node(block_addr) -> BTreeNode` | Load a node from disk |
| `write_node(node)` | Persist a node |
| `cow_node(node) -> BTreeNode` | Clone a node to a new block for CoW |

## CoW Insert Flow

1. Walk from the root to the target leaf, recording the path.
2. `cow_node()` each node on the path (allocate a fresh block, copy contents).
3. Insert into the copied leaf; if it overflows, `split()` and propagate the median up.
4. Rewrite parents along the copied path so they reference the new children.
5. The new root becomes the tree's root; the old root is retained by any snapshot referencing it.

## Snapshots

Cloning the root pointer yields an independent, writable tree that shares all unchanged nodes with the original — the foundation for the Phase 4 snapshot engine.

## Related

[dir.md](dir.md) · [extent.md](extent.md) · [inode.md](inode.md)
