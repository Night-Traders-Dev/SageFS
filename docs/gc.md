# Garbage Collector
**Module:** [`src/fsgc.sage`](../src/fsgc.sage) · **Phase:** 5 (Performance) · **Status:** ✅ Implemented

## Purpose
Maintains free segment availability in SageFS's log-structured layout.

## Mechanics
- **Foreground GC:** Triggers synchronously when free segments fall below the threshold. Uses a **Greedy** victim selection policy (picks segment with fewest valid blocks).
- **Background GC:** Runs during idle periods. Uses a **Cost-Benefit** policy (considers segment age, hotness, and valid block count).
- `do_gc(seg_id)`: **Does not relocate anything.** It walks the victim's
  validity bitmap, increments `blocks_moved` for each valid block, and then
  calls `free_segment()`, which clears the bitmap and returns the segment to
  the free list. Any live data in that segment is discarded. This is a
  data-destroying stub and must be implemented before GC is ever called.
  It is currently latent only because nothing invokes `run_foreground()` or
  `run_background()`.

## API
- `run_foreground() -> Bool`
- `run_background() -> Bool`
- `select_victim(policy) -> Int`
- `do_gc(seg_id) -> Bool`

## Related
[segment.md](segment.md) · [allocator.md](allocator.md)
