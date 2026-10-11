## A volume larger than the old 2 GiB ceiling, through the filesystem rather
## than just the file layer.
##
## Mount reads only the metadata region and serves data blocks from the file on
## demand, so the interesting property here is not that a big volume works but
## that it works without ever holding one: the window has to stay at the size of
## the metadata area whatever the volume behind it is. A volume that is large
## and sparse, so the test costs a few kilobytes of disk rather than five
## gigabytes of it.
##
## The offsets here sit past 2 GiB on purpose. That is where the 32-bit length
## used to wrap: a file measured negative, and an offset was refused outright, so
## everything past the wrap was silently unreachable rather than loudly broken.

import fsimage
import vfs
import mkfs
import fileio
import sys

let PATH: String = "/tmp/sagefs_large_volume.img"
let SIZE_MB: Int = 5120
let TWO_GIB: Int = 2147483648

var TESTS_RUN = 0
var TESTS_PASSED = 0

proc check(name: String, cond: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if cond:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name)

## A block of recognisable bytes, so a read back from the far end of the volume
## can be told apart from the zeros a failed read leaves behind.
proc pattern_block(bs: Int) -> Bytes:
    let blk = bytes(bs)
    var i = 0
    while i < bs:
        bytes_set(blk, i, (i * 13 + 5) % 251)
        i = i + 1
    return blk

proc matches_pattern(buf: Bytes, bs: Int) -> Bool:
    if bytes_len(buf) != bs:
        return false
    var k = 0
    while k < bs:
        if bytes_get(buf, k) != (k * 13 + 5) % 251:
            return false
        k = k + 1
    return true

sys.exec("rm -f " + PATH)
let opts: Dict = {"device": PATH, "size_mb": SIZE_MB, "label": "LARGE",
                  "block_size": 4096, "segment_size": 64, "force": true, "check": false}

## ---- The volume exists and is the size it was asked to be ------------------
check("a 5 GiB volume can be formatted",
      mkfs.format_device(PATH, opts))
let apparent: Int = fileio.size_of(PATH)
check("the formatted volume is the length it was asked for",
      apparent == SIZE_MB * 1024 * 1024)
check("the volume is longer than the old 32-bit wrap", apparent > TWO_GIB)

## ---- Mount, and check that mounting it does not allocate it ----------------
let fs = fsimage.mount(PATH)
check("a 5 GiB volume mounts", fs != nil)

if fs != nil:
    let window: Int = bytes_len(fs.image_buf)
    print("        window = " + str(window) + " bytes, volume = " + str(apparent))
    check("the in-memory window is a small fraction of the volume",
          window > 0 and window * 64 < apparent)
    check("the superblock records the full volume size",
          fs.sb.image_size == apparent)

    ## ---- A block beyond the old wrap, read and written through the VFS -------
    let bs: Int = fs._init_block_size()
    let far_blk: Int = (TWO_GIB / bs) + 4096
    let far_off: Int = far_blk * bs
    print("        far block = " + str(far_blk) + " at offset " + str(far_off))
    check("the far offset chosen really is past the wrap", far_off > TWO_GIB)
    check("that offset cannot be held in 32 bits", far_off > 2147483647)

    let want = pattern_block(bs)
    fs._write_block(far_blk, want)
    check("a block past the wrap reads back unchanged",
          matches_pattern(fs._read_block(far_blk), bs))
    check("reading the far block did not pull it into memory",
          bytes_len(fs.image_buf) == window)

    ## ---- An ordinary file still persists across unmount ---------------------
    let fd = fs.create_file("/large.bin", 577)
    check("a file can be created on a 5 GiB volume", fd >= 0)
    if fd >= 0:
        let body = bytes(65536)
        var i = 0
        while i < 65536:
            bytes_set(body, i, (i * 7 + 3) % 251)
            i = i + 1
        check("a 64 KiB write lands", fs.write(fd, body) == 65536)
        fs.close(fd)

    check("the 5 GiB volume unmounts", fs.unmount())
    check("unmounting left the file at full length", fileio.size_of(PATH) == apparent)

    ## ---- And comes back with everything intact ------------------------------
    let fs2 = fsimage.mount(PATH)
    check("the 5 GiB volume remounts", fs2 != nil)
    if fs2 != nil:
        check("the window is small again after remount",
              bytes_len(fs2.image_buf) == window)
        check("the far block survived the unmount",
              matches_pattern(fs2._read_block(far_blk), bs))
        let rd = fs2.open("/large.bin", vfs.O_RDONLY)
        let got = fs2.read(rd, 65536)
        check("the file survived unmount and remount", bytes_len(got) == 65536)
        if bytes_len(got) == 65536:
            var same = true
            var k = 0
            while k < 65536:
                if bytes_get(got, k) != (k * 7 + 3) % 251:
                    same = false
                k = k + 1
            check("every byte of it is intact", same)
        ## Allocation state has to cross the unmount too, or the next mount
        ## hands out blocks the previous one is still using.
        check("the volume still reports free segments",
              len(fs2.segment.free_segments) > 0)
        fs2.unmount()

sys.exec("rm -f " + PATH)

print("  Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
if TESTS_RUN == TESTS_PASSED:
    print("ALL LARGE VOLUME TESTS PASSED")
else:
    print("LARGE VOLUME TESTS FAILED")
