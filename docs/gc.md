# Garbage Collector
**Module:** [`src/fsgc.sage`](../src/fsgc.sage) · **Phase:** 5 (Performance) · **Status:** ✅ Implemented

## Purpose
Maintains free segment availability in SageFS's log-structured layout.

## Mechanics
- **Foreground GC:** Triggers synchronously when free segments fall below the threshold. Uses a **Greedy** victim selection policy (picks segment with fewest valid blocks).
- **Background GC:** Runs during idle periods. Uses a **Cost-Benefit** policy (considers segment age, hotness, and valid block count).
- `do_gc(seg_id)`: **Refuses to reclaim a segment that holds live data.**
  Relocation is not implemented. It counts the valid blocks and, if there are
  any, increments `segments_refused` and returns false without touching the
  segment. A segment with no live blocks is freed, since there is nothing to
  lose.

  It previously walked the validity bitmap, incremented `blocks_moved` for each
  valid block, and then called `free_segment()` — which clears the bitmap and
  returns the segment to the free list. Every live block in it was discarded,
  and `blocks_moved` was incremented for data that had not been moved anywhere.

  Doing this properly requires knowing which inode owns each block so its mapping
  can be rewritten after the copy. That question cannot be answered today:
  `NodeAddressTable` resolves a nid to a block and can update one, but there is
  no block -> nid index, and the extent tree — which is what actually locates
  file data — is not persisted at all. Copying bytes under those conditions
  yields a filesystem that finds neither the old data nor the new copy.

  A consequence worth knowing: `needs_gc()` can report true while nothing can be
  reclaimed, because every candidate still holds live data. That is the honest
  state, and preferable to reporting progress that is not being made.

## API
- `run_foreground() -> Bool`
- `run_background() -> Bool`
- `select_victim(policy) -> Int`
- `do_gc(seg_id) -> Bool`

## Related
[segment.md](segment.md) · [allocator.md](allocator.md)
