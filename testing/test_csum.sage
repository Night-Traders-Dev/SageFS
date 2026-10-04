## test_csum.sage — the on-disk per-block checksum region.

import sys
import csum
from checksum import checksum_block, CHECKSUM_NONE

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check(name: String, cond: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if cond:
        TESTS_PASSED = TESTS_PASSED + 1
        print("    PASS  " + name)
    else:
        print("    FAIL  " + name)

proc check_eq(name: String, got, expected):
    check(name, got == expected)

## make_region — Build an in-memory image with a region at the end.
##
## data_blocks of payload followed by enough region blocks for one LE32 each.
proc make_region(data_blocks: Int, block_size: Int) -> csum.CsumRegion:
    let rb: Int = csum.region_blocks_for(data_blocks, block_size)
    let img: Bytes = bytes((data_blocks + rb) * block_size)
    var b: Int = 0
    while b < data_blocks:
        var i: Int = 0
        while i < block_size:
            bytes_set(img, b * block_size + i, (b * 7 + i * 13) & 0xFF)
            i = i + 1
        b = b + 1
    return csum.CsumRegion(img, block_size, data_blocks, rb)

## --- sizing ---------------------------------------------------------------

proc test_region_sizing():
    ## 4096 blocks of 4096-byte blocks need 16384 bytes = 4 region blocks.
    check_eq("region blocks for 4096 blocks", csum.region_blocks_for(4096, 4096), 4)
    ## Exactly one block's worth.
    check_eq("region blocks for 1024 blocks", csum.region_blocks_for(1024, 4096), 1)
    ## One entry past the boundary pushes into a second block.
    check_eq("region blocks for 1025 blocks", csum.region_blocks_for(1025, 4096), 2)
    check_eq("no blocks needs no region", csum.region_blocks_for(0, 4096), 0)
    check_eq("no region for zero block size", csum.region_blocks_for(4096, 0), 0)

proc test_absent_region():
    ## A volume formatted before this feature has no region. Every operation must
    ## degrade to "untracked" rather than reading outside the image.
    let r = csum.CsumRegion(bytes(4096), 4096, 0, 0)
    check("absent region reports absent", not r.present())
    check_eq("absent region entry is NONE", r.get(0), CHECKSUM_NONE)
    r.set(0, 1234)
    check_eq("write to absent region is dropped", r.get(0), CHECKSUM_NONE)
    check_eq("absent region does not fit", r.entries_fit(10), false)
    check_eq("verify reports untracked", r.verify(0, 0), "untracked")

## --- entry access ---------------------------------------------------------

proc test_record_and_verify():
    let r = make_region(16, 4096)
    check("region present", r.present())
    check("entries fit", r.entries_fit(16))
    r.record(0, 0)
    r.record(5, 0)
    check_eq("recorded block verifies", r.verify(0, 0), "ok")
    check_eq("other recorded block verifies", r.verify(5, 0), "ok")
    check_eq("unrecorded block is untracked", r.verify(3, 0), "untracked")

proc test_detects_corruption():
    ## The whole point: change one byte of a block that has an entry, and verify
    ## must say so.
    let r = make_region(16, 4096)
    r.record(7, 0)
    bytes_set(r.buf, 7 * 4096 + 100, bytes_get(r.buf, 7 * 4096 + 100) ^ 0xFF)
    check_eq("single flipped byte is caught", r.verify(7, 0), "mismatch")

proc test_detects_whole_block_swap():
    let r = make_region(16, 4096)
    var b: Int = 0
    while b < 16:
        r.record(b, 0)
        b = b + 1
    ## Overwrite block 2's payload with block 3's.
    var i: Int = 0
    while i < 4096:
        bytes_set(r.buf, 2 * 4096 + i, bytes_get(r.buf, 3 * 4096 + i))
        i = i + 1
    check_eq("swapped block is caught", r.verify(2, 0), "mismatch")
    check_eq("the source block is still fine", r.verify(3, 0), "ok")

proc test_zero_payload_block():
    ## An all-zero block must still get a real entry, not be mistaken for
    ## untracked -- unless its checksum genuinely is zero.
    let rb: Int = csum.region_blocks_for(4, 4096)
    let img: Bytes = bytes(8 * 4096)
    let r = csum.CsumRegion(img, 4096, 4, rb)
    r.record(0, 0)
    let v: Int = r.get(0)
    let actual: Int = checksum_block(csum.csum_slice(img, 0, 4096), 0)
    check_eq("zero block entry matches its true checksum", v, actual)
    check_eq("zero block verifies", r.verify(0, 0), "ok")

proc test_entries_do_not_collide():
    ## Adjacent entries must not share bytes. This is the failure mode of any
    ## hand-rolled packing: entry n+1 overwrites entry n's top byte.
    let r = make_region(8, 4096)
    var b: Int = 0
    while b < 8:
        r.set(b, 0x01020300 + b)
        b = b + 1
    var all_ok: Bool = true
    b = 0
    while b < 8:
        if r.get(b) != (0x01020300 + b):
            all_ok = false
        b = b + 1
    check("adjacent entries do not collide", all_ok)

proc test_entries_span_region_blocks():
    ## 2000 entries at 4 bytes each cross several 4096-byte region blocks. If the
    ## offset arithmetic only worked within one block, the tail would be wrong.
    let r = make_region(2000, 4096)
    check("region spans multiple blocks", r.region_blocks >= 2)
    var b: Int = 0
    while b < 2000:
        r.set(b, b)
        b = b + 1
    var ok: Bool = true
    b = 0
    while b < 2000:
        if r.get(b) != b:
            ok = false
        b = b + 1
    check("entries spanning region blocks all round-trip", ok)
    r.record(1999, 0)
    check_eq("last entry verifies", r.verify(1999, 0), "ok")

proc test_out_of_range_is_safe():
    let r = make_region(16, 4096)
    ## Far past the region. Must report untracked, not read the heap.
    check_eq("entry past the region is NONE", r.get(100000), CHECKSUM_NONE)
    r.set(100000, 42)
    check_eq("write past the region is dropped", r.get(100000), CHECKSUM_NONE)
    check_eq("verify past the region is untracked", r.verify(100000, 0), "untracked")

proc test_entries_fit_rejects_short_region():
    ## A region sized for fewer entries than there are blocks would checksum only
    ## a prefix, and scrub would then report full coverage over a fraction of the
    ## volume.
    ## 2000 entries need 2 region blocks; give it 1.
    let r = csum.CsumRegion(bytes(8192 * 4096), 4096, 4000, 1)
    check("short region is present", r.present())
    check_eq("short region does not fit", r.entries_fit(2000), false)
    let st = r.stats(2000)
    check_eq("stats report it does not fit", st["fits"], false)

proc test_load_tree():
    let r = make_region(16, 4096)
    r.record(2, 0)
    r.record(9, 0)
    let t = r.load_tree(16, 0)
    check_eq("tree holds only tracked blocks", t.count(), 2)
    check("tree verifies a tracked block", t.verify(2, csum.csum_slice(r.buf, 2 * 4096, 3 * 4096)))
    ## Corrupt it and the tree must disagree.
    bytes_set(r.buf, 2 * 4096 + 5, bytes_get(r.buf, 2 * 4096 + 5) ^ 0xFF)
    check_eq("tree catches corruption", t.verify(2, csum.csum_slice(r.buf, 2 * 4096, 3 * 4096)), false)

proc test_stats():
    let r = make_region(64, 4096)
    var b: Int = 0
    while b < 10:
        r.record(b, 0)
        b = b + 1
    let st = r.stats(64)
    check_eq("stats count tracked", st["tracked"], 10)
    check_eq("stats report data blocks", st["data_blocks"], 64)
    check_eq("stats report fit", st["fits"], true)

proc test_slice_helper():
    ## Hand-rolled because slice() returns an array here: it indexes correctly
    ## but bytes_len() is 0, so hashing it would hash nothing.
    let b: Bytes = bytes(8)
    var i: Int = 0
    while i < 8:
        bytes_set(b, i, i + 1)
        i = i + 1
    let s = csum.csum_slice(b, 2, 5)
    check_eq("slice length", bytes_len(s), 3)
    check_eq("slice contents", bytes_get(s, 0), 3)
    check_eq("clamped slice length", bytes_len(csum.csum_slice(b, 6, 99)), 2)
    check_eq("inverted slice is empty", bytes_len(csum.csum_slice(b, 5, 2)), 0)

proc main():
    print("=== SageFS Checksum Region Tests ===")
    test_region_sizing()
    test_absent_region()
    test_record_and_verify()
    test_detects_corruption()
    test_detects_whole_block_swap()
    test_zero_payload_block()
    test_entries_do_not_collide()
    test_entries_span_region_blocks()
    test_out_of_range_is_safe()
    test_entries_fit_rejects_short_region()
    test_load_tree()
    test_stats()
    test_slice_helper()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
