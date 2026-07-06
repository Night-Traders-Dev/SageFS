# Journal & Transaction Manager

**Module:** [`src/journal.sage`](../src/journal.sage), [`src/transaction.sage`](../src/transaction.sage) · **Phase:** 3 (Integrity & Recovery) · **Status:** 🚧 In progress

## Purpose

SageFS uses **hybrid journaling** for crash recovery:

- **Metadata** — protected by a write-ahead log (WAL). Metadata changes are recorded in the journal *before* being applied, so an interrupted operation can be replayed or rolled back on the next mount.
- **Data** — log-structured (F2FS style). Because all data writes are append-only to fresh blocks, no separate data journal is required; the checkpoint mechanism already provides atomicity.

## Planned Design

### Write-Ahead Log (`journal.sage`)

- Fixed-size circular log region on disk.
- Each record: header (LSN, type, length), payload, and a per-record checksum computed via [`checksum_block()`](checksum.md).
- Append records to the log tail; a commit record marks a transaction durable.
- On mount, scan from the last checkpoint LSN, verify record checksums, and replay committed transactions (skipping torn/uncommitted tails).

### Transaction Manager (`transaction.sage`)

- Groups related metadata changes into atomic transactions.
- Supports nested transactions (subtransactions commit into their parent).
- Coordinates with the [checkpoint manager](superblock.md) so a checkpoint truncates the journal up to the last durable LSN.

## Recovery Flow (planned)

1. Read the active checkpoint to find the last consistent LSN.
2. Replay journal records after that LSN whose checksums verify and that belong to committed transactions.
3. Discard any torn record at the log tail (identified by checksum mismatch).
4. Clean up orphan inodes and mark the volume `STATE_CLEAN`.

## Related

[checksum.md](checksum.md) · [superblock.md](superblock.md)

---

*This document will be expanded with the concrete API as `journal.sage` and `transaction.sage` land.*
