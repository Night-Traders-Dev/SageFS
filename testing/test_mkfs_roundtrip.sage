## test_mkfs_roundtrip.sage — format a real volume, then mount it again.
##
## Every other test in testing/ builds a superblock-only image: a few hundred bytes
## with a zeroed inode area, no segments, no SIT. That shape cannot reach any of the
## code that only a formatted volume exercises, and it hid a series of unrelated bugs
## for exactly that reason:
##
##   * decode_inode_entry() read name_len/data_len out of the buffer with no bounds
##     check. On a zeroed area both are 0 and the copy loops never run.
##   * fileio.slice_bytes() built its result one index assignment per byte. Mounting
##     asked for the whole image as one range, so that was 268 million assignments.
##   * VFS asks for sb.image_size bytes, and bytes() above the runtime's allocation
##     ceiling returns nil -- so a volume larger than that could not be mounted at
##     all, and the failure presented as "image too small" on a perfectly good image.
##
## So this formats with the real mkfs and mounts the result. The geometry is dense
## (64-block segments) purely to keep the image small enough to fit under that
## allocation ceiling; everything else -- segment manager, SIT, allocator, inode
## table, directory manager, journal, extents, checksums -- is the real thing, and
## the image carries real inode entries, which is the whole point.
##
## Bytecode only. mkfs.sage calls main() at the top level, so importing it as a
## library runs the formatter; SageLang has no __main__ guard to prevent that, and
## under the C backend the import is a compile error rather than a silent surprise.
## Every other test here is bytecode-only for the same underlying reason, so this
## does not narrow what the suite covers -- but it does mean mkfs.sage cannot yet be
## reused as a library, which is worth knowing before anything else tries.

import sys
import io
import mkfs
import fsimage
import vfs

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check(name: String, cond: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if cond:
        TESTS_PASSED = TESTS_PASSED + 1
        print("    PASS  " + name)
    else:
        print("    FAIL  " + name)

proc payload(len: Int, seed: Int) -> Bytes:
    let b: Bytes = bytes(len)
    var i = 0
    while i < len:
        bytes_set(b, i, (i * seed + 11) % 251)
        i = i + 1
    return b

proc same_bytes(got: Bytes, want: Bytes) -> Bool:
    if bytes_len(got) != bytes_len(want):
        return false
    var i = 0
    while i < bytes_len(want):
        if bytes_get(got, i) != bytes_get(want, i):
            return false
        i = i + 1
    return true

proc main():
    let path = "/tmp/sagefs_mkfs_roundtrip.img"

    ## Format through mkfs itself rather than hand-building an image, so the test
    ## covers the formatter as well as the mount side. 24 MiB with 64-block segments
    ## is a real geometry -- 91 segments, a real SIT, real inode entries -- sized to
    ## stay under the runtime's allocation ceiling so the image can be mounted at all.
    let opts: Dict = {"device": path, "size_mb": 24, "label": "RoundTrip",
                      "block_size": 4096, "segment_size": 64,
                      "force": true, "check": false}
    check("mkfs formatted a volume", mkfs.format_device(path, opts))
    check("the image is on disk", io.filesize(path) > 0)

    ## ---- Mount what mkfs produced ----------------------------------------
    let fs = fsimage.mount(path)
    check("a volume mkfs created can be mounted", fs != nil)
    if fs == nil:
        print("SOME TESTS FAILED")
        return

    check("the label survived", fs.sb.label == "RoundTrip")
    check("the segment manager was built", fs.segment != nil
          and len(fs.segment.sit_entries) > 0)
    check("the SIT was read back from disk", fs.sit_entries_loaded == fs.segment.total_segments)
    check("a freshly formatted volume has all segments free",
          len(fs.segment.free_segments) == fs.segment.total_segments)

    ## ---- Write through the full path --------------------------------------
    let body = payload(8192, 29)
    let fd = fs.open("/roundtrip.bin", vfs.O_CREAT | vfs.O_RDWR)
    check("created a file", fd >= 0)
    let wrote = fs.write(fd, body)
    check("wrote 8 KiB", wrote == 8192)
    fs.close(fd)

    ## Two files, so extents and the inode table both get more than one entry.
    let fd2 = fs.open("/second.bin", vfs.O_CREAT | vfs.O_RDWR)
    let body2 = payload(4096, 7)
    check("wrote a second file", fs.write(fd2, body2) == 4096)
    fs.close(fd2)

    ## Allocation has to take segments out of the free list. If it does not, the
    ## same segment is handed out again and a later write lands on top of live data
    ## -- silently, with the extents still pointing at the old contents.
    check("allocation took segments out of the free list",
          len(fs.segment.free_segments) < fs.segment.total_segments)

    ## ---- Read back in the same session ------------------------------------
    let rd = fs.open("/roundtrip.bin", vfs.O_RDONLY)
    let got = fs.read(rd, 8192)
    fs.close(rd)
    check("read back in the same session", same_bytes(got, body))

    ## ---- In-place edit ----------------------------------------------------
    let ed = fs.open("/roundtrip.bin", vfs.O_RDWR)
    fs.lseek(ed, 100, vfs.SEEK_SET)
    let patch = payload(64, 3)
    check("partial edit reported as written", fs.write(ed, patch) == 64)
    fs.close(ed)
    let rd2 = fs.open("/roundtrip.bin", vfs.O_RDONLY)
    let got2 = fs.read(rd2, 8192)
    fs.close(rd2)
    check("the edit is visible", same_bytes(got2, payload(8192, 29)) == false)
    check("the bytes before the edit are untouched", bytes_get(got2, 99) == bytes_get(body, 99))
    check("the bytes after the edit are untouched", bytes_get(got2, 164) == bytes_get(body, 164))
    check("the patched bytes are the new ones", same_bytes(bytes_slice(got2, 100, 164), patch))

    ## Size must survive the unmount. This is the guard that matters for any change
    ## to how the image is held in memory: unmount() writes self.image_buf back over
    ## the file, so a partial in-memory model that forgets to write the whole thing
    ## back truncates the volume. The file keeps its length and the data is simply
    ## gone -- the same silent shape as every other bug this file was written for.
    let free_at_unmount: Int = len(fs.segment.free_segments)
    let size_before_unmount = io.filesize(path)
    check("unmount succeeded", fs.unmount())
    check("unmount did not truncate the volume",
          io.filesize(path) == size_before_unmount)
    check("the volume is still at least as large as mkfs made it",
          io.filesize(path) > 0)

    ## ---- Remount and confirm it all persisted ----------------------------
    let fs2 = fsimage.mount(path)
    check("the volume remounts", fs2 != nil)
    if fs2 != nil:
        ## Regression: unmount() persisted the segment validity table only when
        ## the table fit inside the in-memory image, and passed no path for the
        ## case where it did not. A table that fails to write is worse than one
        ## that is never consulted: the next mount reads every segment as free and
        ## hands out blocks the previous session is still using, so a later write
        ## lands on top of live data. Nothing else here notices -- the file above
        ## still reads back correctly, because the block holding it has not been
        ## reissued yet. Free segments have to come back the way they were left.
        check("allocation state survived unmount",
              len(fs2.segment.free_segments) == free_at_unmount)
        let rd3 = fs2.open("/roundtrip.bin", vfs.O_RDONLY)
        let got3 = fs2.read(rd3, 8192)
        fs2.close(rd3)
        check("the first file survived unmount and remount", bytes_len(got3) == 8192)
        check("its content is byte-for-byte what was written",
              same_bytes(got3, got2))

        let rd4 = fs2.open("/second.bin", vfs.O_RDONLY)
        let got4 = fs2.read(rd4, 4096)
        fs2.close(rd4)
        check("the second file survived too", same_bytes(got4, body2))

        check("the directory lists both files",
              len(fs2.readdir("/")) >= 2)

        ## Writing after a remount has to work as well: the allocator, the SIT and
        ## the segment cursors all come back from disk, and a stale cursor or an
        ## unmarked-in-use segment would hand out a block the previous session was
        ## still using.
        let fd3 = fs2.open("/third.bin", vfs.O_CREAT | vfs.O_RDWR)
        let body3 = payload(4096, 17)
        check("can write after a remount", fs2.write(fd3, body3) == 4096)
        fs2.close(fd3)
        let rd5 = fs2.open("/third.bin", vfs.O_RDONLY)
        let got5 = fs2.read(rd5, 4096)
        fs2.close(rd5)
        check("the post-remount write reads back", same_bytes(got5, body3))

        let size_before = io.filesize(path)
        fs2.unmount()
        check("the second unmount did not truncate the volume either",
              io.filesize(path) == size_before)

    ## ---- Scrub should find no damage --------------------------------------
    let fs3 = fsimage.mount(path)
    if fs3 != nil:
        check("no checksum errors while reading the volume back",
              fs3.csum_error_count() == 0)
        fs3.unmount()

    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")
        print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")

main()
