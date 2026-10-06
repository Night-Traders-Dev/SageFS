## test_imgio_large.sage — reading back an image larger than the whole-file read cap.
##
## io.readbytes() refuses a whole-file read over 100 MiB and returns nil rather than
## reporting an error. read_image_range() was written to work around that, and used
## it; read_image() -- the function every mount goes through -- did not. So any image
## over the cap came back as length 0 with nothing logged, and mount reported a
## corrupt superblock for an image that was perfectly fine.
##
## A default SageFS volume is larger than the cap, which means this was not an edge
## case: a volume mkfs had just formatted could not be reopened at all.

import sys
import imgio
import fileio
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

proc main():
    let path = "/tmp/sagefs_imgio_large.img"

    ## Build the file with ranged writes rather than one big buffer: this runtime
    ## cannot allocate a 300 MiB Bytes value at all -- bytes(300 MiB) returns
    ## length 0 -- so an in-memory buffer would silently produce an empty file and
    ## the test would assert nothing. A marker every 4 KiB is enough to catch a
    ## truncated or mis-offset read, and keeps each write small.
    let big = 300 * 1024 * 1024 + 4096
    ## Start from nothing: write_at() never shrinks an existing file, so a run
    ## that overshot left the file longer than this one asks for and the size and
    ## content assertions failed against a stale tail.
    fileio.truncate(path, 0)
    let chunk: Bytes = bytes(1024 * 1024)
    var wrote_all = true
    var off = 0
    while off < big:
        var k = 0
        while k < bytes_len(chunk):
            ## Marker pattern keyed to the absolute offset, so a chunk written to
            ## the wrong place does not match.
            bytes_set(chunk, k, ((off + k) + 7) % 251)
            k = k + 1
        ## The final chunk is usually a partial one. Writing the whole buffer
        ## regardless made the file 301 MiB rather than the 300 MiB asked for, so
        ## the size assertion below failed for a reason that had nothing to do with
        ## the reader.
        var piece = chunk
        let remaining = big - off
        if remaining < bytes_len(chunk):
            piece = fileio.slice_bytes(chunk, 0, remaining)
        let put = fileio.write_at(path, off, piece)
        if put < 0:
            wrote_all = false
        off = off + bytes_len(piece)
    check("built a large file with ranged writes", wrote_all)
    check("the file on disk is the size we asked for", fileio.size_of(path) == big)

    ## This is the assertion that matters: before the fix, read_image() returned
    ## length 0 for anything over the 100 MiB cap and mount reported a corrupt
    ## superblock for an image that was fine.
    let back = imgio.read_image(path)
    check("read_image returns the whole image, not length 0",
          bytes_len(back) == big)

    ## Spot-check markers across the whole span, including past the 100 MiB cap
    ## where the old read gave up entirely.
    var markers_ok = bytes_len(back) == big
    var m = 0
    while m < big and markers_ok:
        if bytes_get(back, m) != ((m + 7) % 251):
            markers_ok = false
        m = m + 4096
    check("read_image content matches across the whole span, past the cap", markers_ok)

    ## A bounded range over the same file at an offset beyond the cap, which is the
    ## path a superblock read actually takes.
    let tail = imgio.read_image_range(path, big - 8192, 8192)
    check("read_image_range works past the cap", bytes_len(tail) == 8192)
    var same = bytes_len(tail) == 8192
    var t = 0
    while t < 8192:
        if bytes_get(tail, t) != ((big - 8192 + t + 7) % 251):
            same = false
        t = t + 1
    check("read_image_range returns the right bytes", same)

    ## A small image must still take the ordinary whole-file path -- the fallback
    ## is only for when that read comes back empty.
    let small_path = "/tmp/sagefs_imgio_small.img"
    let small: Bytes = bytes(4096)
    var j = 0
    while j < 4096:
        bytes_set(small, j, (j + 3) % 251)
        j = j + 1
    imgio.write_image(small_path, small)
    let small_back = imgio.read_image(small_path)
    check("a small image still reads back whole",
          bytes_len(small_back) == 4096
          and checksum_block(small_back, 0) == checksum_block(small, 0))

    ## A file that does not exist must not spin or invent data.
    let missing = imgio.read_image("/tmp/sagefs_no_such_image.img")
    check("a missing image reads as empty, not as data", bytes_len(missing) == 0)

    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")
        print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")

main()
