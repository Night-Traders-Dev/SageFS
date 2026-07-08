## ============================================================================
## SageFS Journal — Write-Ahead Log (WAL)
## ============================================================================
##
## Phase 3 — Data Integrity & Recovery.
##
## SageFS uses HYBRID journaling:
##
##   * Metadata  -> write-ahead log (this module).  Every metadata mutation is
##                  appended to the journal *before* it is applied in place, so
##                  an interrupted operation can be replayed (redo) on the next
##                  mount, or safely discarded if it never committed.
##   * Data      -> log-structured (F2FS style).  All data writes go to fresh
##                  blocks, so no separate data journal is required; the
##                  checkpoint mechanism already provides atomicity.
##
## On-disk journal region
## ----------------------
## The journal occupies a fixed, contiguous run of blocks reserved at format
## time.  It is treated as a CIRCULAR log: records are appended at the tail and
## the head advances past records that a checkpoint has made durable.  Each
## record is self-describing and individually checksummed, so a torn write at
## the tail (an interrupted append) is detected by a checksum mismatch and
## discarded during recovery.
##
## Record wire format (all integers little-endian)
## -----------------------------------------------
##   0   : magic        (LE32)  JOURNAL_MAGIC — frames a valid record
##   4   : lsn          (LE64)  monotonically increasing log sequence number
##   12  : txn_id       (LE64)  owning transaction id (0 = standalone)
##   20  : rec_type     (LE32)  REC_* record type
##   24  : target_blk   (LE64)  physical block this record mutates (0 if n/a)
##   32  : payload_len  (LE32)  length of the payload that follows
##   36  : checksum     (LE32)  CRC32C over bytes [0, 36) + payload
##   40  : payload      (payload_len bytes)
##
## The checksum covers the header (with the checksum field itself treated as 0)
## plus the payload, giving end-to-end integrity for each record.
## ============================================================================

from checksum import checksum_block, CHECKSUM_CRC32C

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## "SJRN" — SageFS JouRNal record magic.
let JOURNAL_MAGIC: Int = 0x534A524E

## Fixed record header size in bytes (offsets above).
let JREC_HEADER_SIZE: Int = 40

## Byte offset of the checksum field within the header (zeroed while hashing).
let JREC_CKSUM_OFF: Int = 36

## 32-bit mask for fixed-width arithmetic.
let JMASK32: Int = 0xFFFFFFFF

## Record types.
let REC_BEGIN: Int = 1        # transaction begin marker
let REC_UPDATE: Int = 2       # metadata block update (redo image in payload)
let REC_COMMIT: Int = 3       # transaction commit marker (durability point)
let REC_ABORT: Int = 4        # transaction abort marker
let REC_CHECKPOINT: Int = 5   # checkpoint barrier (log may be truncated here)

# ===========================================================================
# JournalRecord
# ===========================================================================

class JournalRecord:
    ## A single write-ahead-log record.

    proc init(self, lsn: Int, txn_id: Int, rec_type: Int, target_blk: Int, payload: Bytes):
        self.magic = JOURNAL_MAGIC
        self.lsn = lsn
        self.txn_id = txn_id
        self.rec_type = rec_type
        self.target_blk = target_blk
        if payload == nil:
            self.payload = bytes()
        else:
            self.payload = payload

    proc payload_len(self) -> Int:
        return bytes_len(self.payload)

    proc total_size(self) -> Int:
        ## On-disk size of this record (header + payload).
        return JREC_HEADER_SIZE + bytes_len(self.payload)

    proc serialize(self) -> Bytes:
        ## Encode the record to its on-disk byte form, computing and embedding
        ## the CRC32C checksum over the header (checksum field = 0) + payload.
        let buf: Bytes = bytes()
        jwrite_le32(buf, self.magic)
        jwrite_le64(buf, self.lsn)
        jwrite_le64(buf, self.txn_id)
        jwrite_le32(buf, self.rec_type)
        jwrite_le64(buf, self.target_blk)
        jwrite_le32(buf, bytes_len(self.payload))
        ## Placeholder for the checksum (filled in after we can hash).
        jwrite_le32(buf, 0)
        ## Append payload.
        var i: Int = 0
        let n: Int = bytes_len(self.payload)
        while i < n:
            bytes_push(buf, bytes_get(self.payload, i))
            i = i + 1

        ## Compute checksum over the whole buffer (checksum field currently 0)
        ## and patch it into place.
        let csum: Int = checksum_block(buf, CHECKSUM_CRC32C)
        jset_le32(buf, JREC_CKSUM_OFF, csum)
        return buf


# ===========================================================================
# Journal — the write-ahead log manager
# ===========================================================================

class Journal:
    ## Manages the circular WAL region.
    ##
    ## `device` must expose two methods:
    ##     write_block(block_addr: Int, data: Bytes)
    ##     read_block(block_addr: Int) -> Bytes
    ## matching the BlockAllocator/device abstraction used elsewhere.  For unit
    ## testing an in-memory device is sufficient.

    proc init(self, device: Any, start_blk: Int, block_count: Int, block_size: Int):
        self.device = device
        self.start_blk = start_blk
        self.block_count = block_count
        self.block_size = block_size
        self.next_lsn = 1
        self.next_txn_id = 1
        self.buffer = bytes()
        self.head_lsn = 1

    # -----------------------------------------------------------------------
    # Transaction lifecycle
    # -----------------------------------------------------------------------

    proc begin_txn(self) -> Int:
        ## Start a new transaction, returning its id.  Emits a BEGIN record.
        let txn_id: Int = self.next_txn_id
        self.next_txn_id = self.next_txn_id + 1
        self.append(txn_id, REC_BEGIN, 0, bytes())
        return txn_id

    proc log_update(self, txn_id: Int, target_blk: Int, redo_image: Bytes) -> Int:
        ## Log a metadata block mutation.  `redo_image` is the full new contents
        ## of `target_blk`.  Returns the record's LSN.
        return self.append(txn_id, REC_UPDATE, target_blk, redo_image)

    proc commit_txn(self, txn_id: Int) -> Int:
        ## Emit a COMMIT record and sync the log to disk.  Once this returns,
        ## the transaction is durable and will be replayed after a crash.
        let lsn: Int = self.append(txn_id, REC_COMMIT, 0, bytes())
        self.sync()
        return lsn

    proc abort_txn(self, txn_id: Int) -> Int:
        ## Emit an ABORT record; the transaction's updates will NOT be replayed.
        return self.append(txn_id, REC_ABORT, 0, bytes())

    proc checkpoint_barrier(self) -> Int:
        ## Emit a CHECKPOINT record and advance the head.  After a checkpoint
        ## has flushed all dirty metadata in place, everything up to this
        ## barrier can be reclaimed from the log.
        let lsn: Int = self.append(0, REC_CHECKPOINT, 0, bytes())
        self.sync()
        self.head_lsn = self.next_lsn
        return lsn

    # -----------------------------------------------------------------------
    # Low-level append / sync
    # -----------------------------------------------------------------------

    proc append(self, txn_id: Int, rec_type: Int, target_blk: Int, payload: Bytes) -> Int:
        ## Append a record to the in-memory log tail and return its LSN.
        let lsn: Int = self.next_lsn
        self.next_lsn = self.next_lsn + 1
        let rec: JournalRecord = JournalRecord(lsn, txn_id, rec_type, target_blk, payload)
        let encoded: Bytes = rec.serialize()
        var i: Int = 0
        let n: Int = bytes_len(encoded)
        while i < n:
            bytes_push(self.buffer, bytes_get(encoded, i))
            i = i + 1
        return lsn

    proc capacity_bytes(self) -> Int:
        ## Total journal capacity in bytes.
        return self.block_count * self.block_size

    proc used_bytes(self) -> Int:
        ## Bytes currently staged in the log tail.
        return bytes_len(self.buffer)

    proc sync(self):
        ## Flush the staged buffer to the journal region, block by block.
        ## The buffer is zero-padded up to a block boundary.  Raises if the
        ## log would overflow its reserved region (caller must checkpoint).
        let total: Int = bytes_len(self.buffer)
        if total > self.capacity_bytes():
            raise "journal overflow: checkpoint required before further writes"

        var off: Int = 0
        var blk: Int = self.start_blk
        while off < total:
            let chunk: Bytes = bytes()
            var j: Int = 0
            while j < self.block_size:
                if off + j < total:
                    bytes_push(chunk, bytes_get(self.buffer, off + j))
                else:
                    bytes_push(chunk, 0)
                j = j + 1
            self.device.write_block(blk, chunk)
            off = off + self.block_size
            blk = blk + 1

    # -----------------------------------------------------------------------
    # Recovery
    # -----------------------------------------------------------------------

    proc recover(self) -> Array:
        ## Scan the journal from the beginning, verifying each record's
        ## checksum.  Returns the list of REC_UPDATE records belonging to
        ## transactions that reached a COMMIT — i.e. the redo set to replay,
        ## in LSN order.  Scanning stops at the first invalid/torn record
        ## (its checksum won't verify), which marks the true log tail.
        ##
        ## Two passes:
        ##   1. Collect all valid records and note which txn_ids committed.
        ##   2. Emit UPDATE records whose txn committed (or standalone commits).
        let raw: Bytes = self.read_all()
        let total: Int = bytes_len(raw)

        var records: Array = []
        var records: Array = []
        var committed: Dict[String, Bool] = {}
        var aborted: Dict[String, Bool] = {}

        var off: Int = 0
        while off + JREC_HEADER_SIZE <= total:
            let magic: Int = jread_le32(raw, off)
            if magic != JOURNAL_MAGIC:
                break   # no more framed records — end of log
            let payload_len: Int = jread_le32(raw, off + 32)
            let rec_total: Int = JREC_HEADER_SIZE + payload_len
            if off + rec_total > total:
                break   # truncated tail

            ## Verify checksum: recompute over the record with the checksum
            ## field zeroed and compare against the stored value.
            let stored_csum: Int = jread_le32(raw, off + JREC_CKSUM_OFF)
            let frame: Bytes = jslice(raw, off, off + rec_total)
            jset_le32(frame, JREC_CKSUM_OFF, 0)
            let calc_csum: Int = checksum_block(frame, CHECKSUM_CRC32C)
            if calc_csum != stored_csum:
                break   # torn / corrupt record — this is the tail

            let lsn: Int = jread_le64(raw, off + 4)
            let txn_id: Int = jread_le64(raw, off + 12)
            let rec_type: Int = jread_le32(raw, off + 20)
            let target_blk: Int = jread_le64(raw, off + 24)
            let payload: Bytes = jslice(raw, off + JREC_HEADER_SIZE, off + rec_total)

            let rec: JournalRecord = JournalRecord(lsn, txn_id, rec_type, target_blk, payload)
            push(records, rec)

            if rec_type == REC_COMMIT:
                committed[str(txn_id)] = true
            elif rec_type == REC_ABORT:
                aborted[str(txn_id)] = true

            off = off + rec_total

        ## Build the redo set: UPDATE records whose txn committed and was not
        ## aborted, in LSN order (records are already in append/LSN order).
        var redo: Array = []
        for rec in records:
            if rec.rec_type == REC_UPDATE:
                if dict_has(committed, str(rec.txn_id)) and not dict_has(aborted, str(rec.txn_id)):
                    push(redo, rec)
        return redo

    proc replay(self) -> Int:
        ## Recover and apply the redo set to the device, returning the number
        ## of blocks rewritten.  This is idempotent: replaying twice yields the
        ## same on-disk state because each UPDATE carries the full block image.
        let redo: Array = self.recover()
        var applied: Int = 0
        for rec in redo:
            self.device.write_block(rec.target_blk, rec.payload)
            applied = applied + 1
        return applied

    proc read_all(self) -> Bytes:
        ## Read the entire journal region into one contiguous buffer.
        let buf: Bytes = bytes()
        var blk: Int = self.start_blk
        var read: Int = 0
        while read < self.block_count:
            let chunk: Bytes = self.device.read_block(blk)
            var i: Int = 0
            let n: Int = bytes_len(chunk)
            while i < n:
                bytes_push(buf, bytes_get(chunk, i))
                i = i + 1
            blk = blk + 1
            read = read + 1
        return buf

    proc reset(self):
        ## Clear the in-memory tail (used after a full checkpoint).
        self.buffer = bytes()
        self.head_lsn = self.next_lsn

    proc stats(self) -> Dict:
        let d: Dict = {}
        d["next_lsn"] = self.next_lsn
        d["next_txn_id"] = self.next_txn_id
        d["head_lsn"] = self.head_lsn
        d["used_bytes"] = self.used_bytes()
        d["capacity_bytes"] = self.capacity_bytes()
        return d


# ===========================================================================
# Little-endian helpers (self-contained; deduplicated at link time)
# ===========================================================================

proc jwrite_le32(buf: Bytes, value: Int):
    bytes_push(buf, value & 0xFF)
    bytes_push(buf, (value >> 8) & 0xFF)
    bytes_push(buf, (value >> 16) & 0xFF)
    bytes_push(buf, (value >> 24) & 0xFF)

proc jwrite_le64(buf: Bytes, value: Int):
    bytes_push(buf, value & 0xFF)
    bytes_push(buf, (value >> 8) & 0xFF)
    bytes_push(buf, (value >> 16) & 0xFF)
    bytes_push(buf, (value >> 24) & 0xFF)
    bytes_push(buf, (value >> 32) & 0xFF)
    bytes_push(buf, (value >> 40) & 0xFF)
    bytes_push(buf, (value >> 48) & 0xFF)
    bytes_push(buf, (value >> 56) & 0xFF)

proc jread_le32(buf: Bytes, offset: Int) -> Int:
    let b0: Int = bytes_get(buf, offset)
    let b1: Int = bytes_get(buf, offset + 1)
    let b2: Int = bytes_get(buf, offset + 2)
    let b3: Int = bytes_get(buf, offset + 3)
    return (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) & JMASK32

proc jread_le64(buf: Bytes, offset: Int) -> Int:
    let b0: Int = bytes_get(buf, offset)
    let b1: Int = bytes_get(buf, offset + 1)
    let b2: Int = bytes_get(buf, offset + 2)
    let b3: Int = bytes_get(buf, offset + 3)
    let b4: Int = bytes_get(buf, offset + 4)
    let b5: Int = bytes_get(buf, offset + 5)
    let b6: Int = bytes_get(buf, offset + 6)
    let b7: Int = bytes_get(buf, offset + 7)
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24) | (b4 << 32) | (b5 << 40) | (b6 << 48) | (b7 << 56)

proc jset_le32(buf: Bytes, offset: Int, value: Int):
    ## Overwrite 4 bytes in-place at `offset` with a little-endian 32-bit value.
    bytes_set(buf, offset, value & 0xFF)
    bytes_set(buf, offset + 1, (value >> 8) & 0xFF)
    bytes_set(buf, offset + 2, (value >> 16) & 0xFF)
    bytes_set(buf, offset + 3, (value >> 24) & 0xFF)

proc jslice(buf: Bytes, start: Int, end: Int) -> Bytes:
    ## Return a copy of bytes [start, end) — a self-contained slice helper.
    let out: Bytes = bytes()
    var i: Int = start
    while i < end:
        bytes_push(out, bytes_get(buf, i))
        i = i + 1
    return out
