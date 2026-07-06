# Journal & Transaction Manager

**Module:** [`src/journal.sage`](../src/journal.sage), [`src/transaction.sage`](../src/transaction.sage) · **Phase:** 3 (Integrity & Recovery) · **Status:** ✅ Implemented

## Purpose

SageFS uses **hybrid journaling** for crash recovery:

- **Metadata** — protected by a write-ahead log (WAL). Metadata changes are recorded in the journal *before* being applied, so an interrupted operation can be replayed or rolled back on the next mount.
- **Data** — log-structured (F2FS style). Because all data writes are append-only to fresh blocks, no separate data journal is required; the checkpoint mechanism already provides atomicity.

## Planned Design

### Write-Ahead Log (`journal.sage`)

A fixed, contiguous journal region reserved at format time, treated as a circular log. Records are appended to the tail; a checkpoint advances the head past durable records.

**Record wire format** (all integers little-endian, 40-byte header):

| Offset | Field | Type | Meaning |
|--------|-------|------|---------|
| 0 | `magic` | LE32 | `JOURNAL_MAGIC` ("SJRN") — frames a valid record |
| 4 | `lsn` | LE64 | Monotonic log sequence number |
| 12 | `txn_id` | LE64 | Owning transaction (0 = standalone) |
| 20 | `rec_type` | LE32 | `REC_*` type |
| 24 | `target_blk` | LE64 | Physical block this record mutates |
| 32 | `payload_len` | LE32 | Payload length |
| 36 | `checksum` | LE32 | CRC32C over header (checksum=0) + payload |
| 40 | `payload` | bytes | Redo image / marker data |

**Record types:** `REC_BEGIN`, `REC_UPDATE` (full redo image), `REC_COMMIT` (durability point), `REC_ABORT`, `REC_CHECKPOINT`.

**`Journal` API:** `begin_txn() -> Int`, `log_update(txn_id, target_blk, redo_image) -> Int`, `commit_txn(txn_id)`, `abort_txn(txn_id)`, `checkpoint_barrier()`, `sync()`, `recover() -> Array` (redo set), `replay() -> Int` (blocks rewritten), `stats() -> Dict`.

### Transaction Manager (`transaction.sage`)

Groups metadata mutations into atomic transactions. Updates are staged in memory and only written to the journal (and applied to the device) at outermost commit.

**Nested transactions** use flat nesting with savepoints (SQLite-style):

- A nested `begin()` records a savepoint (current staged-update count).
- A nested `commit()` just closes the savepoint — the real journal `COMMIT` is emitted only at the outermost commit.
- A nested `abort()` rolls staged updates back to its savepoint **and poisons** the transaction, so the eventual outer commit becomes an abort (all-or-nothing).

**`TransactionManager` API:** `begin() -> Int`, `stage_update(target_blk, image)`, `commit() -> Bool`, `abort() -> Bool`, `in_transaction() -> Bool`, `depth() -> Int`, `recover() -> Int`.

## Recovery Flow

1. Read the journal region and scan records from the start.
2. Verify each record's CRC32C checksum; the first mismatch marks the torn tail and stops the scan.
3. Build the redo set: `REC_UPDATE` records whose `txn_id` reached `REC_COMMIT` and was not aborted.
4. Replay the redo set in LSN order, rewriting each `target_blk` with its full block image (idempotent).
5. (Higher tiers) clean up orphan inodes via [fsck](fsck.md) and mark the volume `STATE_CLEAN`.

## Verification

The record serialization, commit/abort filtering, torn-tail detection, and nested-transaction semantics are validated by known-answer and scenario tests in [`../testing/test_journal.sage`](../testing/test_journal.sage).

## Related

[checksum.md](checksum.md) · [superblock.md](superblock.md) · [fsck.md](fsck.md)
