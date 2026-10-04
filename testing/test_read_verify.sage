## test_read_verify.sage — read-path checksum verification.
##
## Until now a corrupt block was only found by scrub, which you have to think to
## run. Recording the checksum without checking it on the way back out means the
## filesystem stores the evidence of damage and then never looks at it.
##
## These tests drive VFS._read_block() directly against a hand-built volume so a
## corrupted block can be introduced deliberately.

import sys
import vfs as vfs_module
import fileio
import imgio
import csum
from checksum import checksum_block
from superblock import SageFSSuperblock, deserialize_superblock

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

## make_volume — An image with a superblock, a checksum region, and `data_blocks`
## payload blocks whose checksums are recorded.
proc make_volume(path: String, data_blocks: Int, block_size: Int) -> Bytes:
    sys.exec("rm -f " + path)
    let rb: Int = csum.region_blocks_for(data_blocks, block_size)
    let img: Bytes = bytes((data_blocks + rb) * block_size)
    var b: Int = 0
    while b < data_blocks:
        var i: Int = 0
        while i < block_size:
            bytes_set(img, b * block_size + i, (b * 31 + i * 7) & 0xFF)
            i = i + 1
        b = b + 1
    let sb = SageFSSuperblock()
    sb.block_size = block_size
    sb.segment_size = 32
    sb.total_blocks = data_blocks
    sb.total_segments = int(data_blocks / 32)
    sb.image_size = (data_blocks + rb) * block_size
    sb.inode_entry_start_blk = 2
    sb.inode_entry_byte_size = 2 * block_size
    sb.journal_start_blk = 4
    sb.journal_block_count = 4
    sb.nat_start_blk = 8
    sb.sit_start_blk = 8
    sb.ssa_start_blk = 8
    sb.main_start_blk = 8
    sb.csum_start_blk = data_blocks
    sb.csum_block_count = rb
    let sbbuf = sb.serialize()
    var k: Int = 0
    while k < bytes_len(sbbuf):
        bytes_set(img, k, bytes_get(sbbuf, k))
        k = k + 1
    ## Record checksums for the payload blocks.
    let region = csum.CsumRegion(img, block_size, data_blocks, rb)
    b = 0
    while b < data_blocks:
        region.record(b, sb.checksum_algo)
        b = b + 1
    fileio.write_at(path, 0, img)
    return img

## open_fs — A VFS over the image with verification toggled the way the field
## wants it, without a full mount (which would replay the journal and rewrite
## the volume).
proc open_fs(path: String, verify: Bool):
    let fs = vfs_module.VFS(path, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
    fs.image_buf = imgio.read_image(path)
    fs.sb = deserialize_superblock(fs.image_buf)
    fs.verify_on_read = verify
    return fs

## --- the property that matters --------------------------------------------

proc test_clean_block_verifies():
    let p: String = "/tmp/rv_a.img"
    make_volume(p, 8, 4096)
    let fs = open_fs(p, true)
    let before: Int = fs.csum_error_count()
    fs._read_block(3)
    check_eq("a clean block raises nothing", fs.csum_error_count(), before)

proc test_corrupted_block_is_caught():
    let p: String = "/tmp/rv_b.img"
    make_volume(p, 8, 4096)
    let fs = open_fs(p, true)
    let before: Int = fs.csum_error_count()
    ## Flip one bit in block 5, the way silent disk rot would.
    let off: Int = 5 * 4096 + 123
    let cur: Int = bytes_get(fs.image_buf, off)
    bytes_set(fs.image_buf, off, cur ^ 0x01)
    fs._read_block(5)
    check("a corrupted block is caught on read", fs.csum_error_count() > before)

proc test_every_block_position_is_checked():
    ## Not just the first block: an off-by-one in the region offset would verify
    ## block 0 and silently skip the rest.
    let p: String = "/tmp/rv_c.img"
    make_volume(p, 8, 4096)
    let fs = open_fs(p, true)
    var caught: Int = 0
    var b: Int = 0
    while b < 8:
        let off: Int = b * 4096 + 500
        bytes_set(fs.image_buf, off, bytes_get(fs.image_buf, off) ^ 0xFF)
        let before: Int = fs.csum_error_count()
        fs._read_block(b)
        if fs.csum_error_count() > before:
            caught = caught + 1
        b = b + 1
    check_eq("every block position is verified", caught, 8)

proc test_verification_off_by_default():
    ## Hashing every block read is not free, so it is opt-in. It must also be
    ## genuinely off: with it off, a corrupted block passes silently.
    let p: String = "/tmp/rv_d.img"
    make_volume(p, 8, 4096)
    let fs = open_fs(p, false)
    let off: Int = 2 * 4096 + 9
    bytes_set(fs.image_buf, off, bytes_get(fs.image_buf, off) ^ 0xFF)
    fs._read_block(2)
    check_eq("with verification off nothing is reported", fs.csum_error_count(), 0)

proc test_untracked_block_is_not_an_error():
    ## A block with no entry must read cleanly. If untracked counted as damaged,
    ## every freshly formatted volume would report errors on first read.
    let p: String = "/tmp/rv_e.img"
    make_volume(p, 8, 4096)
    let fs = open_fs(p, true)
    let region = csum.CsumRegion(fs.image_buf, 4096, 8, csum.region_blocks_for(8, 4096))
    region.set(6, 0)
    fs.csum_region_cache = nil
    let before: Int = fs.csum_error_count()
    fs._read_block(6)
    check_eq("an untracked block is not an error", fs.csum_error_count(), before)

proc test_region_blocks_are_not_verified():
    ## The region cannot verify against itself: writing an entry changes the
    ## block holding it. Verifying region blocks would flag the whole region.
    let p: String = "/tmp/rv_f.img"
    make_volume(p, 8, 4096)
    let fs = open_fs(p, true)
    let before: Int = fs.csum_error_count()
    fs._read_block(8)
    fs._read_block(9)
    check_eq("region blocks are never verified", fs.csum_error_count(), before)

proc test_volume_without_region_is_unaffected():
    ## Backward compatibility: a volume formatted before the region existed must
    ## mount and read normally, not report every block as damaged.
    let p: String = "/tmp/rv_g.img"
    make_volume(p, 8, 4096)
    let fs = open_fs(p, true)
    fs.sb.csum_start_blk = 0
    fs.sb.csum_block_count = 0
    fs.csum_region_cache = nil
    var b: Int = 0
    while b < 8:
        fs._read_block(b)
        b = b + 1
    check_eq("a volume with no region reports nothing", fs.csum_error_count(), 0)

proc test_read_returns_correct_data():
    ## Verification must not alter what comes back.
    let p: String = "/tmp/rv_h.img"
    make_volume(p, 8, 4096)
    let fs = open_fs(p, true)
    let got: Bytes = fs._read_block(4)
    check_eq("read returns a full block", bytes_len(got), 4096)
    var ok: Bool = true
    var i: Int = 0
    while i < 4096:
        if bytes_get(got, i) != bytes_get(fs.image_buf, 4 * 4096 + i):
            ok = false
        i = i + 1
    check("read returns the stored bytes", ok)

proc test_repeat_reads_report_once():
    ## A hot loop re-reading a damaged block must not flood output. The count
    ## still increments so a caller can see how many reads were affected.
    let p: String = "/tmp/rv_i.img"
    make_volume(p, 8, 4096)
    let fs = open_fs(p, true)
    bytes_set(fs.image_buf, 7 * 4096 + 3, bytes_get(fs.image_buf, 7 * 4096 + 3) ^ 0xFF)
    var i: Int = 0
    while i < 5:
        fs._read_block(7)
        i = i + 1
    check_eq("repeated reads of a bad block are all counted", fs.csum_error_count(), 5)

proc cleanup():
    sys.exec("rm -f /tmp/rv_a.img /tmp/rv_b.img /tmp/rv_c.img /tmp/rv_d.img /tmp/rv_e.img "
             + "/tmp/rv_f.img /tmp/rv_g.img /tmp/rv_h.img /tmp/rv_i.img")

proc main():
    print("=== SageFS Read-Path Verification Tests ===")
    test_clean_block_verifies()
    test_corrupted_block_is_caught()
    test_every_block_position_is_checked()
    test_verification_off_by_default()
    test_untracked_block_is_not_an_error()
    test_region_blocks_are_not_verified()
    test_volume_without_region_is_unaffected()
    test_read_returns_correct_data()
    test_repeat_reads_report_once()
    cleanup()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
