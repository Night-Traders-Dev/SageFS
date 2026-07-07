# Garbage Collector
**Module:** [`src/gc.sage`](../src/gc.sage) · **Phase:** 5 (Performance) · **Status:** ✅ Implemented

## Purpose
Maintains free segment availability in SageFS's log-structured layout.

## Mechanics
- **Foreground GC:** Triggers synchronously when free segments fall below the threshold. Uses a **Greedy** victim selection policy (picks segment with fewest valid blocks).
- **Background GC:** Runs during idle periods. Uses a **Cost-Benefit** policy (considers segment age, hotness, and valid block count).
- `do_gc(seg_id)`: Reads all valid blocks from the victim segment, writes them to a new segment, updates NAT/SIT, and marks the victim free.

## API
- `run_foreground() -> Bool`
- `run_background() -> Bool`
- `select_victim(policy) -> Int`
- `do_gc(seg_id) -> Bool`

## Related
[segment.md](segment.md) · [allocator.md](allocator.md)
