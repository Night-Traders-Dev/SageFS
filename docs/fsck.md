# fsck — Offline Consistency Checker

**Module:** [`src/fsck.sage`](../src/fsck.sage) · **Phase:** 3 (Integrity & Recovery) · **Status:** ✅ Implemented

## Purpose

Performs an offline, read-mostly consistency check of a SageFS volume by cross-referencing the three core metadata structures — the inode table, the [Node Address Table](nat.md) (NAT), and the [Segment Information Table](segment.md) (SIT). Issues are collected into a report and, with `repair=true`, safe well-understood fixes are applied automatically.

## Checks Performed

| # | Check | Issue code | Severity |
|---|-------|-----------|----------|
| 1 | Superblock validity & self-checksum | `ISSUE_SB_CHECKSUM` | FATAL |
| 2 | Every referenced nid resolves to a NAT entry | `ISSUE_DANGLING_NID` | ERROR |
| 3 | Alive NAT entries point at blocks the SIT marks valid | `ISSUE_NAT_SIT_MISMATCH` | ERROR |
| 4 | SIT valid-block counts match the actual bitmaps | `ISSUE_SIT_COUNT` | WARN |
| 5 | Directory tree walk: reachability (orphans) | `ISSUE_ORPHAN_INODE` | WARN |
| 5 | Link counts match observed directory references | `ISSUE_LINK_COUNT` | ERROR |
| 6 | Per-block checksum verification (if a `ChecksumTree` is supplied) | `ISSUE_BLOCK_CHECKSUM` | ERROR |

## Structures

### `FsckIssue`

A single finding: `code`, `severity` (`SEV_INFO`/`WARN`/`ERROR`/`FATAL`), `target` (inode/nid/segno/block), `message`, and a `repaired` flag. `to_string()` renders it for the report.

### `FsckReport`

Aggregates issues and counters.

| Method | Description |
|--------|-------------|
| `add(issue)` | Record a finding |
| `error_count() -> Int` | Count of `ERROR`+`FATAL` issues |
| `is_clean() -> Bool` | True when no errors |
| `summary() -> Dict` | Scanned/issue/repair counters |
| `print_report()` | Human-readable dump |

### `Fsck`

The checker itself. Managers are injected so it can run against a mounted image or a freshly loaded volume; missing managers cause dependent checks to be skipped.

| Method | Description |
|--------|-------------|
| `run() -> FsckReport` | Run all checks and return the report |
| `check_superblock(report)` | Superblock checksum |
| `check_nat_sit(report)` | NAT ↔ SIT agreement |
| `check_sit_counts(report)` | SIT count vs. bitmap popcount |
| `check_inode_tree(report)` | Tree walk, orphans, link counts |
| `walk(ino, reachable, report)` | Depth-first reference counting (cycle-guarded) |

## Repair Policy

With `repair=true`, fsck applies only safe fixes: recompute SIT valid counts, re-mark blocks valid to match live NAT entries, clear unreachable orphan inodes, and correct link counts to observed references. The superblock checksum is recomputed. Structural corruption beyond these is reported but left for a human or a higher-tier (RAID repair-on-read) recovery path.

## Online Scrub (future)

Phase 3's offline fsck lays the groundwork for the online scrub daemon (background checksum verification) and RAID repair-on-read, which reuse `Fsck`'s block-checksum check against a live [`ChecksumTree`](checksum.md).

## Related

[nat.md](nat.md) · [segment.md](segment.md) · [inode.md](inode.md) · [checksum.md](checksum.md) · [journal.md](journal.md)
