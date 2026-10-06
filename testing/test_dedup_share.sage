## test_dedup_share.sage — dedup sharing and copy-on-write, end to end.
##
## This is the test that matters most in the suite, because a failure here is
## silent data loss rather than a wrong answer. Dedup lets two files point at one
## physical block; writing into that block without copying first hands the edit to
## every other holder. Nothing reports an error at the time -- the file keeps its
## length, reads back plausible bytes, and the other file's content is simply gone.
##
## The same program runs under the bytecode VM and under the C backend. An earlier
## version of the sharing write path passed here and destroyed 4080 bytes in the
## compiled build, which is the only reason these cases are checked in both.

import sys
import vfs
import superblock
import imgio
import dedup
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
    ## Deterministic, block-sized content that is identical across two files when
    ## asked to be, and different when not.
    let b: Bytes = bytes()
    var i = 0
    while i < len:
        bytes_push(b, (seed * 7 + i * 13) % 251)
        i = i + 1
    return b

## patched_head — What a partial edit should leave behind: the patch at the
## front, the original content after it. Comparing a whole-block read against the
## 64-byte patch alone cannot match, because the file is still block-sized.
proc patched_head(patch: Bytes, original: Bytes) -> Bytes:
    let out: Bytes = bytes()
    var i = 0
    while i < bytes_len(patch):
        bytes_push(out, bytes_get(patch, i))
        i = i + 1
    i = bytes_len(patch)
    while i < bytes_len(original):
        bytes_push(out, bytes_get(original, i))
        i = i + 1
    return out

proc fresh_volume(path: String, label: String):
    let features: Dict = {"checksum_algo": superblock.CHECKSUM_CRC32C}
    let sb = superblock.create_superblock(4096, label, 4096, 64, features)
    imgio.write_image(path, sb.serialize())
    ## dedup_eng is the 16th constructor argument. The write path asks it for
    ## reference counts on every full block, so a nil engine there is not an
    ## optional configuration -- it means sharing cannot be tracked at all.
    let f = vfs.VFS(path, nil, nil, nil, nil, nil, nil, nil, nil, nil,
                    nil, nil, nil, nil, nil, dedup.DedupEngine())
    f.mount()
    return f

## mount_only — Re-open an existing volume without formatting it again.
##
## Deliberately not fresh_volume(): that writes a new superblock over the image,
## which is how a volume is created, not how it is reopened. Calling it here
## silently discarded everything the first half of the test wrote, so the
## remount check was reading back an empty filesystem and failing for a reason
## that had nothing to do with sharing.
proc mount_only(path: String):
    let f = vfs.VFS(path, nil, nil, nil, nil, nil, nil, nil, nil, nil,
                    nil, nil, nil, nil, nil, dedup.DedupEngine())
    f.mount()
    return f

proc main():
    let img = "/tmp/sagefs_dedup_share_test.img"

    let fs = fresh_volume(img, "DedupShare")

    let bs = fs._init_block_size()

    ## ---- Two files with identical content end up sharing one block ----------
    let content = pattern(1, bs)
    let fd_a = fs.open("/a.bin", vfs.O_CREAT | vfs.O_RDWR)
    check("created /a.bin", fd_a >= 0)
    let wrote_a = fs.write(fd_a, content)
    check("wrote a full block to /a.bin", wrote_a == bs)
    fs.close(fd_a)

    let fd_b = fs.open("/b.bin", vfs.O_CREAT | vfs.O_RDWR)
    check("created /b.bin", fd_b >= 0)
    let wrote_b = fs.write(fd_b, content)
    check("wrote a full block to /b.bin", wrote_b == bs)
    fs.close(fd_b)

    ## Both must still read back what was written. Sharing is only allowed to
    ## change where the bytes live.
    let fd_a2 = fs.open("/a.bin", vfs.O_RDONLY)
    let read_a = fs.read(fd_a2, bs)
    fs.close(fd_a2)
    let fd_b2 = fs.open("/b.bin", vfs.O_RDONLY)
    let read_b = fs.read(fd_b2, bs)
    fs.close(fd_b2)
    check("/a.bin reads back intact after sharing",
          bytes_len(read_a) == bs and checksum_block(read_a, 0) == checksum_block(content, 0))
    check("/b.bin reads back intact after sharing",
          bytes_len(read_b) == bs and checksum_block(read_b, 0) == checksum_block(content, 0))
    ## Dedup has to have actually engaged. If sharing never happened then every
    ## case below would pass for the wrong reason -- nothing would be shared to
    ## protect -- so this is asserted rather than assumed.
    let stats = fs.dedup.get_stats()
    check("dedup engaged: the second block was recognised as a duplicate",
          stats["hits"] > 0 and stats["total_deduped"] > 0)
    ## Two files' extents must name the same physical block for /b.bin. That is
    ## what sharing means here, and it is what copy-on-write below has to protect.
    let ea = fs.extent.lookup_extent(fs.resolve_path("/a.bin"), 0)
    let eb = fs.extent.lookup_extent(fs.resolve_path("/b.bin"), 0)
    check("dedup engaged: both files point at one physical block",
          ea != nil and eb != nil and ea.block_addr == eb.block_addr)

    ## ---- Editing one must not disturb the other ---------------------------
    ##
    ## The case that loses data. /a.bin is overwritten in place at offset 0 while
    ## /b.bin still points at the same physical block.
    let patch = pattern(99, 64)
    let fd_a3 = fs.open("/a.bin", vfs.O_RDWR)
    fs.lseek(fd_a3, 0, vfs.SEEK_SET)
    let patched = fs.write(fd_a3, patch)
    fs.close(fd_a3)
    check("partial edit to /a.bin reported as written", patched == 64)

    let fd_b3 = fs.open("/b.bin", vfs.O_RDONLY)
    let read_b_after = fs.read(fd_b3, bs)
    fs.close(fd_b3)
    check("/b.bin is unchanged after /a.bin was edited",
          bytes_len(read_b_after) == bs
          and checksum_block(read_b_after, 0) == checksum_block(content, 0))

    ## /a.bin must show its own edit, and only the bytes it wrote.
    let fd_a4 = fs.open("/a.bin", vfs.O_RDONLY)
    let read_a_after = fs.read(fd_a4, bs)
    fs.close(fd_a4)
    ## The file is still a whole block: the patch replaced the first 64 bytes and
    ## the remaining bytes are the original content, untouched.
    let want_a = patched_head(patch, content)
    check("/a.bin shows the edit, and the rest of the block is intact",
          bytes_len(read_a_after) == bs
          and checksum_block(read_a_after, 0) == checksum_block(want_a, 0))

    ## ---- A full-block rewrite must also leave the other file alone ---------
    let new_content = pattern(2, bs)
    let fd_b5 = fs.open("/b.bin", vfs.O_RDWR)
    fs.lseek(fd_b5, 0, vfs.SEEK_SET)
    let rewrote = fs.write(fd_b5, new_content)
    fs.close(fd_b5)
    check("full block rewrite of /b.bin reported as written", rewrote == bs)

    let fd_a6 = fs.open("/a.bin", vfs.O_RDONLY)
    let read_a_after2 = fs.read(fd_a6, bs)
    fs.close(fd_a6)
    check("/a.bin survives /b.bin being fully rewritten",
          bytes_len(read_a_after2) == bs
          and checksum_block(read_a_after2, 0) == checksum_block(want_a, 0))

    let fd_b6 = fs.open("/b.bin", vfs.O_RDONLY)
    let read_b_after2 = fs.read(fd_b6, bs)
    fs.close(fd_b6)
    check("/b.bin holds its new content",
          bytes_len(read_b_after2) == bs
          and checksum_block(read_b_after2, 0) == checksum_block(new_content, 0))

    ## ---- Three files sharing, then one diverges ---------------------------
    let shared = pattern(5, bs)
    var i = 0
    while i < 3:
        let name = "/m" + str(i) + ".bin"
        let fd = fs.open(name, vfs.O_CREAT | vfs.O_RDWR)
        fs.write(fd, shared)
        fs.close(fd)
        i = i + 1
    ## All three must still agree before and after one of them is edited.
    var j = 0
    while j < 3:
        let name = "/m" + str(j) + ".bin"
        let fd = fs.open(name, vfs.O_RDONLY)
        let got = fs.read(fd, bs)
        fs.close(fd)
        check(name + " intact while shared three ways",
              bytes_len(got) == bs and checksum_block(got, 0) == checksum_block(shared, 0))
        j = j + 1

    let fd_m0 = fs.open("/m0.bin", vfs.O_RDWR)
    fs.lseek(fd_m0, 0, vfs.SEEK_SET)
    let diverge = pattern(77, bs)
    fs.write(fd_m0, diverge)
    fs.close(fd_m0)

    ## m1 and m2 are the ones that matter: they still reference the original.
    let fd_m1 = fs.open("/m1.bin", vfs.O_RDONLY)
    let got1 = fs.read(fd_m1, bs)
    fs.close(fd_m1)
    check("/m1.bin intact after /m0.bin diverged",
          bytes_len(got1) == bs and checksum_block(got1, 0) == checksum_block(shared, 0))

    let fd_m2 = fs.open("/m2.bin", vfs.O_RDONLY)
    let got2 = fs.read(fd_m2, bs)
    fs.close(fd_m2)
    check("/m2.bin intact after /m0.bin diverged",
          bytes_len(got2) == bs and checksum_block(got2, 0) == checksum_block(shared, 0))

    let fd_m0b = fs.open("/m0.bin", vfs.O_RDONLY)
    let got0 = fs.read(fd_m0b, bs)
    fs.close(fd_m0b)
    check("/m0.bin holds its new content",
          bytes_len(got0) == bs and checksum_block(got0, 0) == checksum_block(diverge, 0))

    ## ---- Content survives unmount and remount ------------------------------
    fs.unmount()
    let fs2 = mount_only(img)
    if fs2 == nil:
        check("remount after sharing", false)
    else:
        check("remount after sharing", true)
        let fd_r = fs2.open("/b.bin", vfs.O_RDONLY)
        let got_r = fs2.read(fd_r, bs)
        fs2.close(fd_r)
        check("/b.bin intact after remount",
              bytes_len(got_r) == bs
              and checksum_block(got_r, 0) == checksum_block(new_content, 0))
        fs2.unmount()


    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")
        print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")

main()
