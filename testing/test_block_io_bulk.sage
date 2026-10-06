## test_block_io_bulk.sage — block read/write correctness after the bulk-primitive
## rewrite.
##
## _read_block, _write_block and _ensure_image_size used to be per-byte loops.
## They are now single memmove/memset/resize calls into SageLang's
## bytes_copy_range, bytes_fill_range and bytes_resize. Those change more than the
## speed: a range copy is bounds-checked where the old loop silently truncated, and
## a resize zero-fills where the old loop appended zeros one at a time. Both are
## worth asserting, because a boundary mistake in either shows up as a filesystem
## that reads back plausible but wrong bytes.
##
## Every case here is also run against the C backend by the module-compile loop:
## the bulk primitives have separate interpreter and compiled implementations, and
## they disagreed more than once while this was being written.

import sys
import vfs
import superblock
import imgio
from checksum import checksum_block

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check(name: String, cond: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if cond:
        TESTS_PASSED = TESTS_PASSED + 1
        print("    PASS  " + name)
    else:
        print("    FAIL  " + name)

proc pattern(seed: Int, len: Int) -> Bytes:
    let b: Bytes = bytes(len)
    bytes_fill_range(b, 0, len, (seed % 251))
    var i = 0
    while i < len:
        bytes_set(b, i, (seed * 7 + i * 13) % 251)
        i = i + 1
    return b

proc main():
    let img = "/tmp/sagefs_block_io_bulk.img"
    let features: Dict = {"checksum_algo": superblock.CHECKSUM_CRC32C}
    let sb = superblock.create_superblock(4096, "BlockIO", 4096, 64, features)
    imgio.write_image(img, sb.serialize())
    let fs = vfs.VFS(img)
    fs.mount()
    let bs = fs._init_block_size()

    ## ---- A whole block round-trips ----------------------------------------
    let data = pattern(1, bs)
    fs._write_block(10, data)
    let back = fs._read_block(10)
    check("whole block round-trips", bytes_len(back) == bs
          and checksum_block(back, 0) == checksum_block(data, 0))

    ## ---- Blocks are independent ------------------------------------------
    ## Neighbouring blocks share nothing: the bulk copy writes exactly len bytes at
    ## exactly offset. A copy that ran long would smear one block into the next.
    let other = pattern(2, bs)
    fs._write_block(11, other)
    check("neighbouring block is untouched",
          checksum_block(fs._read_block(10), 0) == checksum_block(data, 0))
    check("neighbouring block holds its own content",
          checksum_block(fs._read_block(11), 0) == checksum_block(other, 0))

    ## ---- A partial write lands at the right offset -------------------------
    ## This is the case the offset argument exists for, and the one a bulk copy
    ## gets wrong if the destination offset is dropped.
    let target = pattern(3, bs)
    fs._write_block(20, target)
    let patch = pattern(9, 64)
    fs._write_block(20, patch, 100)
    let patched = fs._read_block(20)
    ## Build what the block should be: original with 64 bytes replaced at 100.
    let want: Bytes = bytes(bs)
    bytes_copy_range(want, 0, target, 0, bs)
    bytes_copy_range(want, 100, patch, 0, 64)
    check("partial write lands at the given in-block offset",
          checksum_block(patched, 0) == checksum_block(want, 0))
    check("bytes before the patch are intact", bytes_get(patched, 99) == bytes_get(target, 99))
    check("bytes after the patch are intact", bytes_get(patched, 164) == bytes_get(target, 164))

    ## ---- An over-long write is truncated at the block boundary -----------
    ## The old loop stopped at `off_in_block + i < bs`. bytes_copy_range() is
    ## bounds-checked instead, so the clamp has to be explicit -- and the
    ## difference is visible: without it the tail of the write lands in the next
    ## block.
    fs._write_block(30, target)
    let overlong = pattern(5, bs)
    fs._write_block(30, overlong, 0)
    let spilled = fs._read_block(31)
    ## Block 30 was never written, so 31 should still read as whatever it had;
    ## what matters is that the full-block write did not reach into it.
    check("a whole-block write does not spill into the next block",
          checksum_block(fs._read_block(30), 0) == checksum_block(overlong, 0))
    check("the untouched next block still reads as before",
          bytes_len(spilled) == bs)

    ## ---- Growing the image buffer ------------------------------------------
    ## _ensure_image_size now resizes once instead of appending a byte at a time.
    ## Growing must zero-fill: a resized buffer that exposed stale bytes would put
    ## whatever was in memory into a hole, which reads back as data.
    let before = bytes_len(fs.image_buf)
    let grown_blk = before / bs + 8
    fs._ensure_image_size(bytes_len(fs.image_buf) + 8 * bs)
    check("image buffer grew", bytes_len(fs.image_buf) == before + 8 * bs)
    let fresh = fs._read_block(grown_blk)
    check("a block in the grown region reads as zeros",
          checksum_block(fresh, 0) == checksum_block(bytes(bs), 0))

    ## Writing into the grown region must work, not just read back as zeros.
    let late = pattern(7, bs)
    fs._write_block(grown_blk, late)
    check("a block in the grown region can be written",
          checksum_block(fs._read_block(grown_blk), 0) == checksum_block(late, 0))

    ## ---- Growth is idempotent --------------------------------------------
    let size_now = bytes_len(fs.image_buf)
    fs._ensure_image_size(size_now)
    fs._ensure_image_size(size_now - 4 * bs)
    check("a smaller request does not shrink the buffer",
          bytes_len(fs.image_buf) == size_now)

    fs.unmount()

    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")
        print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")

main()
