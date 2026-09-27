# Snapshot & Subvolume Engine
**Module:** [`src/snapshot.sage`](../src/snapshot.sage) · **Phase:** 4 (Advanced) · **Status:** ✅ Implemented

## Purpose
Provides BTRFS-style copy-on-write subvolumes and snapshots. Because SageFS uses a Node Address Table (NAT) and CoW B+ Trees, creating a snapshot is largely a matter of cloning the root node of the filesystem tree and incrementing reference counts.

## Structures
### `Snapshot`
Represents a point-in-time snapshot.
- `name: String`
- `root_block: Int`
- `creation_time: Int`
- `diff(other_snapshot) -> Array` — **does not diff.** It returns the two
  `root_block` values and the two generations. There is no comparison.

  More fundamentally, a snapshot cannot be read. `SnapshotEngine` records a
  name, a root block and a generation; nothing resolves a path through a
  snapshot, and there is no read-only flag. The CoW machinery a real
  snapshot would build on *is* implemented in `btree.sage`, but `VFS.mount()`
  constructs the tree as `BTreeEngine(self, 0, 1)` — root block 0, always
  "empty" — so snapshot roots do not survive a remount. See the repository
  README's known issues.

### `Subvolume`
An independent namespace that can have its own snapshots.
- `id: Int`
- `name: String`
- `root_block: Int`
- `create_snapshot(snap_name, current_time) -> Snapshot`

### `SnapshotEngine`
Manages all subvolumes and coordinates snapshot lifecycle.

## Related
[btree.md](btree.md) · [nat.md](nat.md)
