## test_scrub.sage — scrub verifies against a real reference, or admits it can't.
##
## The tool used to build a fresh ChecksumTree, look every block up in it, find
## nothing recorded anywhere and compare nothing -- then report "filesystem is
## clean". A checker that cannot fail is worse than no checker: it gets trusted,
## and it is always wrong in the direction that hides damage. These tests pin
## down that it can no longer claim a clean bill of health it did not earn.

import sys
import fileio
import scrub
from superblock import SAGEFS_MAGIC

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check(name: String, cond: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if cond:
        TESTS_PASSED = TESTS_PASSED + 1
        print("    PASS  " + name)
    else:
        print("    FAIL  " + name)

proc put_byte(buf: Bytes, off: Int, v: Int):
    bytes_set(buf, off, v)

proc put_le32(buf: Bytes, off: Int, v: Int):
    put_byte(buf, off, v & 0xFF)
    put_byte(buf, off + 1, (v >> 8) & 0xFF)
    put_byte(buf, off + 2, (v >> 16) & 0xFF)
    put_byte(buf, off + 3, (v >> 24) & 0xFF)

proc put_le64(buf: Bytes, off: Int, v: Int):
    put_le32(buf, off, v & 0xFFFFFFFF)
    put_le32(buf, off + 4, (v >> 32) & 0xFFFFFFFF)

proc check_eq(name: String, got, expected):
    check(name, got == expected)

## build_image — A structurally valid volume, filled with a recognisable
## pattern so a corrupted block reads as a content difference, not a length one.
##
## Only the fields the scrubber reads are populated. That is enough to exercise
## every path it takes, and keeps the test from depending on mkfs.
proc build_image(path: String, total_blocks: Int, block_size: Int, shorten_to: Int):
    sys.exec("rm -f " + path)
    let img: Bytes = bytes(total_blocks * block_size)
    put_le32(img, 0, SAGEFS_MAGIC)
    put_le32(img, 4, 1)
    put_le32(img, 8, 5)
    put_le32(img, 12, block_size)
    put_le64(img, 28, total_blocks)
    put_le32(img, 388, 0)
    var b: Int = 8
    while b < total_blocks:
        var i: Int = 0
        while i < block_size:
            put_byte(img, b * block_size + i, (b * 7 + i * 13) & 0xFF)
            i = i + 1
        b = b + 1
    fileio.write_at(path, 0, img)
    if shorten_to > 0 and shorten_to < total_blocks * block_size:
        ## Simulate a truncated volume: the superblock still claims full size.
        fileio.truncate(path, shorten_to)

proc corrupt_byte(path: String, offset: Int):
    let one: Bytes = fileio.read_at(path, offset, 1)
    let b1: Bytes = bytes(1)
    put_byte(b1, 0, bytes_get(one, 0) ^ 0xFF)
    fileio.write_at(path, offset, b1)

## --- superblock handling --------------------------------------------------

proc test_rejects_non_volume():
    ## A 512-byte file of zeros: right size, wrong magic.
    fileio.write_at("/tmp/scrub_bad.img", 0, bytes(512))
    let s = scrub.Scrubber("/tmp/scrub_bad.img")
    check_eq("a non-volume is rejected", not s.ok(), true)
    let r = s.scrub("/tmp/scrub_bad.img")
    check_eq("scrubbing a non-volume errors", r.verdict, scrub.SCRUB_ERROR)

proc test_rejects_missing_file():
    let s = scrub.Scrubber("/tmp/scrub_absent.img")
    check_eq("a missing file is rejected", not s.ok(), true)

proc test_reads_superblock_fields():
    build_image("/tmp/scrub_info.img", 20, 512, 0)
    let s = scrub.Scrubber("/tmp/scrub_info.img")
    check_eq("superblock parsed", s.ok(), true)
    check_eq("block size read", s.block_size(), 512)
    check_eq("total blocks read", s.total_blocks(), 20)
    let info = s.info()
    check_eq("format read", str(info["version_major"]) + "." + str(info["version_minor"]), "1.5")
    check_eq("checksum algo named", info["checksum_algo"], "crc32c")
    check_eq("image size read", info["image_bytes"], 20 * 512)

proc test_rejects_implausible_geometry():
    ## A superblock claiming zero-length blocks would make every loop below it a
    ## no-op and report a clean pass over nothing.
    build_image("/tmp/scrub_zero.img", 0, 0, 0)
    fileio.write_at("/tmp/scrub_zero.img", 0, bytes(4096))
    let sb = bytes(4096)
    put_le32(sb, 0, SAGEFS_MAGIC)
    put_le32(sb, 12, 0)
    fileio.write_at("/tmp/scrub_zero.img", 0, sb)
    let s = scrub.Scrubber("/tmp/scrub_zero.img")
    let r = s.scrub("")
    check_eq("zero block size is an error", r.verdict, scrub.SCRUB_ERROR)

## --- the verdict that matters ---------------------------------------------

proc test_no_reference_is_inconclusive():
    ## This is the fix. With nothing to verify against, the old tool recorded a
    ## checksum from each block and compared the block against itself, then
    ## printed "filesystem is clean". It must now refuse to claim a pass.
    build_image("/tmp/scrub_nr.img", 16, 512, 0)
    let s = scrub.Scrubber("/tmp/scrub_nr.img")
    let r = s.scrub("")
    check_eq("no reference is inconclusive, not clean", r.verdict, scrub.SCRUB_INCONCLUSIVE)
    check_eq("inconclusive is not clean", r.is_clean(), false)
    check_eq("inconclusive explains itself", len(r.messages) > 0, true)

proc test_identical_images_pass():
    build_image("/tmp/scrub_p1.img", 16, 512, 0)
    build_image("/tmp/scrub_p2.img", 16, 512, 0)
    let r = scrub.Scrubber("/tmp/scrub_p1.img").scrub("/tmp/scrub_p2.img")
    check_eq("identical volumes scrub clean", r.verdict, scrub.SCRUB_OK)
    check_eq("clean is clean", r.is_clean(), true)
    check_eq("every block examined", r.blocks_examined, 16)
    check_eq("full coverage", r.coverage_pct(), 100)
    check_eq("no mismatches", r.mismatches, 0)

proc test_corruption_detected():
    ## Flip one bit deep inside a data block. The case the old tool could never
    ## catch, because it compared each block against a checksum it had just
    ## derived from that same block.
    build_image("/tmp/scrub_c1.img", 16, 512, 0)
    build_image("/tmp/scrub_c2.img", 16, 512, 0)
    corrupt_byte("/tmp/scrub_c2.img", 10 * 512 + 7)
    let r = scrub.Scrubber("/tmp/scrub_c1.img").scrub("/tmp/scrub_c2.img")
    check_eq("a single flipped byte fails the scrub", r.verdict, scrub.SCRUB_DAMAGE)
    check_eq("the mismatch is counted", r.mismatches, 1)
    check_eq("damage is not clean", r.is_clean(), false)

proc test_many_corruptions_all_found():
    build_image("/tmp/scrub_m1.img", 16, 512, 0)
    build_image("/tmp/scrub_m2.img", 16, 512, 0)
    var b: Int = 8
    while b < 16:
        corrupt_byte("/tmp/scrub_m2.img", b * 512 + 3)
        b = b + 1
    let r = scrub.Scrubber("/tmp/scrub_m1.img").scrub("/tmp/scrub_m2.img")
    check_eq("all eight corrupt blocks are found", r.mismatches, 8)
    check_eq("multiple damage still fails", r.verdict, scrub.SCRUB_DAMAGE)

proc test_superblock_corruption_detected():
    ## The metadata region is data too; a volume whose superblock differs must
    ## not pass, even though every "content" block matches.
    build_image("/tmp/scrub_s1.img", 16, 512, 0)
    build_image("/tmp/scrub_s2.img", 16, 512, 0)
    corrupt_byte("/tmp/scrub_s2.img", 20)
    let r = scrub.Scrubber("/tmp/scrub_s1.img").scrub("/tmp/scrub_s2.img")
    check_eq("a corrupted superblock fails the scrub", r.verdict, scrub.SCRUB_DAMAGE)

proc test_truncated_volume_detected():
    ## The superblock claims 16 blocks; the file holds 10. The old code read the
    ## whole image, saw a short tail, and zero-padded it -- so a truncated
    ## volume matched a healthy reference across the missing tail.
    build_image("/tmp/scrub_t1.img", 16, 512, 0)
    build_image("/tmp/scrub_t2.img", 16, 512, 10 * 512)
    let r = scrub.Scrubber("/tmp/scrub_t1.img").scrub("/tmp/scrub_t2.img")
    check_eq("a truncated volume fails the scrub", r.verdict, scrub.SCRUB_DAMAGE)
    check_eq("truncation is explained", len(r.messages) > 0, true)

proc test_truncated_against_reference_detected():
    build_image("/tmp/scrub_t3.img", 16, 512, 0)
    build_image("/tmp/scrub_t4.img", 16, 512, 10 * 512)
    ## Scrubbing the short one against the long one must also fail.
    let r = scrub.Scrubber("/tmp/scrub_t4.img").scrub("/tmp/scrub_t3.img")
    check_eq("a short volume fails even against a long reference",
          r.verdict, scrub.SCRUB_DAMAGE)

proc test_geometry_mismatch_rejected():
    ## Comparing a 16-block volume against a 32-block one is meaningless: the
    ## blocks do not line up and every one would "differ".
    build_image("/tmp/scrub_g1.img", 16, 512, 0)
    build_image("/tmp/scrub_g2.img", 32, 512, 0)
    let r = scrub.Scrubber("/tmp/scrub_g1.img").scrub("/tmp/scrub_g2.img")
    check_eq("mismatched geometry is an error, not damage", r.verdict, scrub.SCRUB_ERROR)

proc test_block_size_mismatch_rejected():
    build_image("/tmp/scrub_k1.img", 16, 512, 0)
    build_image("/tmp/scrub_k2.img", 16, 1024, 0)
    let r = scrub.Scrubber("/tmp/scrub_k1.img").scrub("/tmp/scrub_k2.img")
    check_eq("mismatched block size is an error", r.verdict, scrub.SCRUB_ERROR)

proc test_large_volume_coverage():
    ## The old code built the whole image in memory, and io.readbytes() returns
    ## nil past 100 MiB, so a bigger volume silently scrubbed a fraction of
    ## itself and still said "clean". Ranged reads have no such ceiling.
    build_image("/tmp/scrub_big.img", 256, 4096, 0)
    build_image("/tmp/scrub_big2.img", 256, 4096, 0)
    let r = scrub.Scrubber("/tmp/scrub_big.img").scrub("/tmp/scrub_big2.img")
    check_eq("a 1 MiB volume scrubs clean", r.verdict, scrub.SCRUB_OK)
    check_eq("all 256 blocks examined", r.blocks_examined, 256)
    check_eq("full coverage on a larger volume", r.coverage_pct(), 100)

proc test_result_dict_shape():
    ## Scripts consume this; the keys are part of the interface.
    build_image("/tmp/scrub_d1.img", 16, 512, 0)
    build_image("/tmp/scrub_d2.img", 16, 512, 0)
    let d = scrub.Scrubber("/tmp/scrub_d1.img").scrub("/tmp/scrub_d2.img").to_dict()
    check_eq("result reports verdict", dict_has(d, "verdict"), true)
    check_eq("result reports coverage", dict_has(d, "coverage_pct"), true)
    check_eq("result reports totals", dict_has(d, "total_blocks"), true)
    check_eq("verdict value", d["verdict"], scrub.SCRUB_OK)

proc test_algo_names():
    check_eq("crc32c named", scrub.algo_name(0), "crc32c")
    check_eq("xxhash named", scrub.algo_name(1), "xxhash32")
    check_eq("sha256 named", scrub.algo_name(2), "sha256/32")
    check_eq("unknown algo labelled", scrub.algo_name(99), "unknown(99)")

proc cleanup():
    sys.exec("rm -f /tmp/scrub_bad.img /tmp/scrub_absent.img /tmp/scrub_info.img "
             + "/tmp/scrub_zero.img /tmp/scrub_nr.img /tmp/scrub_p1.img /tmp/scrub_p2.img "
             + "/tmp/scrub_c1.img /tmp/scrub_c2.img /tmp/scrub_m1.img /tmp/scrub_m2.img "
             + "/tmp/scrub_s1.img /tmp/scrub_s2.img /tmp/scrub_t1.img /tmp/scrub_t2.img "
             + "/tmp/scrub_t3.img /tmp/scrub_t4.img /tmp/scrub_g1.img /tmp/scrub_g2.img "
             + "/tmp/scrub_k1.img /tmp/scrub_k2.img /tmp/scrub_big.img /tmp/scrub_big2.img "
             + "/tmp/scrub_d1.img /tmp/scrub_d2.img")

proc main():
    print("=== SageFS Scrub Tests ===")
    test_rejects_non_volume()
    test_rejects_missing_file()
    test_reads_superblock_fields()
    test_rejects_implausible_geometry()
    test_no_reference_is_inconclusive()
    test_identical_images_pass()
    test_corruption_detected()
    test_many_corruptions_all_found()
    test_superblock_corruption_detected()
    test_truncated_volume_detected()
    test_truncated_against_reference_detected()
    test_geometry_mismatch_rejected()
    test_block_size_mismatch_rejected()
    test_large_volume_coverage()
    test_result_dict_shape()
    test_algo_names()
    cleanup()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
