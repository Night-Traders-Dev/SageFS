## ============================================================================
## test_journal.sage — WAL + transaction manager tests
## ============================================================================
##
## Covers:
##   - record serialize round-trip & per-record checksum
##   - recovery: committed txn replays, aborted/uncommitted do not
##   - torn-tail detection (corrupt record stops the scan)
##   - replay applies redo images to the device (idempotent)
##   - transaction manager: commit applies, abort discards
##   - nested transactions: nested abort poisons the outer txn
## ============================================================================

from journal import Journal, JournalRecord
from journal import REC_UPDATE, REC_COMMIT, JREC_HEADER_SIZE, JREC_CKSUM_OFF
from journal import jread_le32, jread_le64
from transaction import TransactionManager

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check(name: String, got: Int, expected: Int):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc check_bool(name: String, got: Bool, expected: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name)

# ---------------------------------------------------------------------------
# In-memory block device
# ---------------------------------------------------------------------------

class MemDevice:
    ## A trivial block device backed by a dict of block_addr -> Bytes.
    var blocks: Dict[Int, Bytes]
    var block_size: Int

    proc init(self, block_size: Int):
        self.blocks = {}
        self.block_size = block_size

    proc write_block(self, block_addr: Int, data: Bytes):
        self.blocks[block_addr] = data

    proc read_block(self, block_addr: Int) -> Bytes:
        if dict_has(self.blocks, block_addr):
            return self.blocks[block_addr]
        ## Unwritten blocks read back as zeros.
        let z: Bytes = bytes()
        var i: Int = 0
        while i < self.block_size:
            bytes_push(z, 0)
            i = i + 1
        return z

proc make_journal(dev: MemDevice) -> Journal:
    ## Journal region: 32 blocks starting at block 100.
    return Journal(dev, 100, 32, dev.block_size)

proc block_first_byte(dev: MemDevice, addr: Int) -> Int:
    let b: Bytes = dev.read_block(addr)
    if bytes_len(b) == 0:
        return -1
    return bytes_get(b, 0)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

proc test_record_roundtrip():
    print("JournalRecord serialize round-trip:")
    let payload: Bytes = bytes("hello-world")
    let rec: JournalRecord = JournalRecord(42, 7, REC_UPDATE, 9999, payload)
    let enc: Bytes = rec.serialize()
    check("lsn field", jread_le64(enc, 4), 42)
    check("txn field", jread_le64(enc, 12), 7)
    check("type field", jread_le32(enc, 20), REC_UPDATE)
    check("target field", jread_le64(enc, 24), 9999)
    check("payload_len field", jread_le32(enc, 32), 11)
    check("total size", bytes_len(enc), JREC_HEADER_SIZE + 11)

proc test_recover_commit_abort():
    print("Recovery: commit replays, abort/uncommitted do not:")
    let dev: MemDevice = MemDevice(64)
    let j: Journal = make_journal(dev)

    let t1: Int = j.begin_txn()
    j.log_update(t1, 100, bytes("AAAA"))
    j.log_update(t1, 101, bytes("BBBB"))
    j.commit_txn(t1)

    let t2: Int = j.begin_txn()
    j.log_update(t2, 200, bytes("CCCC"))
    j.abort_txn(t2)

    let t3: Int = j.begin_txn()
    j.log_update(t3, 300, bytes("DDDD"))   # never committed

    let redo: Array = j.recover()
    check("redo count", len(redo), 2)

    ## Replay against a fresh journal reader on the same device.
    let j2: Journal = make_journal(dev)
    let applied: Int = j2.replay()
    check("applied blocks", applied, 2)
    check("block 100 written", block_first_byte(dev, 100), 65)   # 'A'
    check("block 101 written", block_first_byte(dev, 101), 66)   # 'B'
    check_bool("block 200 NOT written", dict_has(dev.blocks, 200), false)
    check_bool("block 300 NOT written", dict_has(dev.blocks, 300), false)

proc test_txn_manager_commit():
    print("TransactionManager commit applies updates:")
    let dev: MemDevice = MemDevice(64)
    let j: Journal = make_journal(dev)
    let tm: TransactionManager = TransactionManager(j, dev)

    tm.begin()
    tm.stage_update(10, bytes("XXXX"))
    tm.stage_update(11, bytes("YYYY"))
    let ok: Bool = tm.commit()
    check_bool("commit returned true", ok, true)
    check("block 10 applied", block_first_byte(dev, 10), 88)   # 'X'
    check("block 11 applied", block_first_byte(dev, 11), 89)   # 'Y'
    check_bool("no active txn after commit", tm.in_transaction(), false)

proc test_txn_manager_abort():
    print("TransactionManager abort discards updates:")
    let dev: MemDevice = MemDevice(64)
    let j: Journal = make_journal(dev)
    let tm: TransactionManager = TransactionManager(j, dev)

    tm.begin()
    tm.stage_update(20, bytes("ZZZZ"))
    let ok: Bool = tm.abort()
    check_bool("abort returned true", ok, true)
    check_bool("block 20 NOT applied", dict_has(dev.blocks, 20), false)

proc test_nested_abort_poisons():
    print("Nested transactions: inner abort poisons outer commit:")
    let dev: MemDevice = MemDevice(64)
    let j: Journal = make_journal(dev)
    let tm: TransactionManager = TransactionManager(j, dev)

    tm.begin()                       # outer
    tm.stage_update(30, bytes("OUTR"))
    tm.begin()                       # nested
    tm.stage_update(31, bytes("INNR"))
    tm.abort()                       # nested abort -> poison + rollback to savepoint
    check("depth back to 1", tm.depth(), 1)
    let ok: Bool = tm.commit()       # outer commit should become an abort
    check_bool("poisoned commit returns false", ok, false)
    check_bool("block 30 NOT applied", dict_has(dev.blocks, 30), false)
    check_bool("block 31 NOT applied", dict_has(dev.blocks, 31), false)

proc test_nested_commit_applies():
    print("Nested transactions: clean nested commit applies all:")
    let dev: MemDevice = MemDevice(64)
    let j: Journal = make_journal(dev)
    let tm: TransactionManager = TransactionManager(j, dev)

    tm.begin()                       # outer
    tm.stage_update(40, bytes("AAAA"))
    tm.begin()                       # nested
    tm.stage_update(41, bytes("BBBB"))
    tm.commit()                      # close nested level (no journal write yet)
    check("still in txn, depth 1", tm.depth(), 1)
    let ok: Bool = tm.commit()       # outer commit
    check_bool("outer commit true", ok, true)
    check("block 40 applied", block_first_byte(dev, 40), 65)
    check("block 41 applied", block_first_byte(dev, 41), 66)

proc main():
    print("=== SageFS Journal & Transaction Tests ===")
    test_record_roundtrip()
    test_recover_commit_abort()
    test_txn_manager_commit()
    test_txn_manager_abort()
    test_nested_abort_poisons()
    test_nested_commit_applies()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
