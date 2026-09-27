## Block-mapped files must survive unmount/remount.
##
## Three separate defects hid behind this, and each one had to be fixed before
## the next became visible:
##
## 1. The extent tree was rebuilt at root block 0 on every mount, which the tree
##    treats as "empty", so a remount started with no extent map at all. The root
##    is now recorded in the superblock (format v1.4) and restored on mount.
##
## 2. _ensure_stub_inode() only restored an inode's size when the inline payload
##    was non-empty. A block-mapped file has an empty payload and a non-zero
##    size, so every such file reported size 0 after a remount even though the
##    right size was in the inode-entry area on disk.
##
## 3. VFS.write() allocated a single block per call and handed the whole buffer
##    to _write_block(), which copies at most one block. A write larger than the
##    block size therefore kept only its first 4 KiB, still reported the full
##    count as written, and set the inode size to the full length. Silent
##    truncation, with no error anywhere.
##
## The third was only observable once the first two were fixed -- before that
## the file read back as empty, so the shortfall had nothing to compare against.

import superblock
import imgio
import vfs

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check(name: String, got: Bool, expected: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc check_int(name: String, got: Int, expected: Int):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc make_image(dev: String) -> Bool:
    let features: Dict = {"checksum_algo": superblock.CHECKSUM_CRC32C}
    let sb = superblock.create_superblock(4096, "Persist", 4096, 32, features)
    let buf = sb.serialize()
    let bs: Int = sb.block_size
    let inode_area: Int = sb.inode_entry_start_blk * bs
    var pad = bytes_len(buf)
    while pad < inode_area + 200:
        bytes_push(buf, 0)
        pad = pad + 1
    let readme = "root\n"
    let S_IFREG: Int = 0x8000
    imgio.write_inode_entry_at(buf, inode_area, 2, S_IFREG | 0x1A4,
                               len(readme), "README.txt", readme)
    let min_image: Int = sb.inode_entry_start_blk * sb.block_size + sb.inode_entry_byte_size
    if bytes_len(buf) > min_image:
        sb.image_size = bytes_len(buf)
    else:
        sb.image_size = min_image
    var j = bytes_len(buf)
    while j < sb.image_size:
        bytes_push(buf, 0)
        j = j + 1
    let sb_bytes = sb.serialize()
    var k = 0
    while k < bytes_len(sb_bytes):
        buf[k] = sb_bytes[k]
        k = k + 1
    return imgio.write_image(dev, buf)

## A payload with a recognisable byte at every position, so truncation or a
## mis-offset extent is visible rather than just short.
proc patterned(n: Int) -> Bytes:
    let alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
    var out = bytes()
    var i = 0
    while i < n:
        bytes_push(out, bytes_get(bytes(alphabet), i % 36))
        i = i + 1
    return out

proc matches(got: Bytes, want: Bytes) -> Bool:
    if bytes_len(got) != bytes_len(want):
        return false
    var i = 0
    while i < bytes_len(want):
        if bytes_get(got, i) != bytes_get(want, i):
            return false
        i = i + 1
    return true

proc main():
    print("=== SageFS Persistence Tests ===")

    ## 8192 bytes is two blocks, comfortably past the 3400-byte inline limit.
    let size = 8192
    let dev = "/tmp/sagefs_persist.img"
    check("format image", make_image(dev), true)

    let fs = vfs.VFS(dev)
    check("mount", fs.mount(), true)
    check("extent tree starts empty", fs.extent.btree.root_block, 0)

    let fd = fs.open("/big.bin", vfs.O_CREAT | vfs.O_RDWR)
    check("create big.bin", fd >= 0, true)

    let payload = patterned(size)
    check_int("write reports the full count", fs.write(fd, payload), size)
    fs.close(fd)

    ## One extent per block, so two.
    let ino = fs.resolve_path("/big.bin")
    let extents = fs.extent._collect_extents(ino)
    check_int("two extents recorded for a two-block file", len(extents), 2)
    check("extent tree has a root now", fs.extent.btree.root_block > 0, true)

    let before = fs.read_inode_data(ino)
    check("reads back before unmount", matches(before, payload), true)

    check("unmount", fs.unmount(), true)
    check_int("root recorded in the superblock", fs.sb.extent_root_blk,
              fs.extent.btree.root_block)

    let fs2 = vfs.VFS(dev)
    check("remount", fs2.mount(), true)
    check_int("extent tree root restored", fs2.extent.btree.root_block,
              fs.sb.extent_root_blk)
    check_int("extents survive the remount", len(fs2.extent._collect_extents(ino)), 2)

    let st = fs2.stat("/big.bin")
    check("file exists after remount", st["exists"], true)
    check_int("size survives the remount", st["size"], size)

    let after = fs2.read_inode_data(ino)
    check_int("full payload length after remount", bytes_len(after), size)
    check("payload is byte-for-byte intact after remount", matches(after, payload), true)

    let fd2 = fs2.open("/big.bin", fs2.O_RDONLY)
    check("reopen after remount", fd2 >= 0, true)
    let head = fs2.read(fd2, 64)
    check_int("read() returns what was asked for", bytes_len(head), 64)
    let head_want = bytes()
    var i = 0
    while i < 64:
        bytes_push(head_want, bytes_get(payload, i))
        i = i + 1
    check("read() content matches", matches(head, head_want), true)
    fs2.close(fd2)

    ## An inline file must be unaffected by any of this.
    let fd3 = fs2.open("/small.txt", fs2.O_CREAT | fs2.O_RDWR)
    let small = bytes("hello inline world")
    check_int("inline write", fs2.write(fd3, small), bytes_len(small))
    fs2.close(fd3)
    fs2.unmount()

    let fs3 = vfs.VFS(dev)
    check("remount for the inline case", fs3.mount(), true)
    let ino3 = fs3.resolve_path("/small.txt")
    ## Tripwire, not an endorsement. A *fourth*, separate defect: _persist_all()
    ## loses an inode entry when several are written, so a third mount can come
    ## up without this file's inode even though its extents are still in the tree.
    ## The entries that do land are framed correctly, so this is about entries
    ## going missing rather than being misread -- writer and reader disagree about
    ## where the next entry starts once more than one is present.
    ##
    ## Not fixed here. The three defects this test was written for are all fixed
    ## and asserted above; folding a fourth in would mean guessing at the framing
    ## without a clean reproduction.
    let got3 = fs3.read_inode_data(ino3b)
    check("KNOWN BUG: _persist_all loses an inode entry when several are written",
          matches(got3, payload), true)
    fs3.unmount()

    ## The superblock checksum must describe the superblock as written.
    ##
    ## Both mkfs and unmount() mutate fields -- image_size, extent_root_blk,
    ## extent_generation -- and then serialise, and neither recomputed the
    ## checksum. So the stored value described the superblock as it was before
    ## those changes, and verify_checksum() failed on a cleanly unmounted volume.
    ## That matters beyond tidiness: fsck's first check is ISSUE_SB_CHECKSUM at
    ## SEV_FATAL, so every healthy volume was reported corrupt.
    let raw = imgio.read_image(dev)
    let on_disk = superblock.deserialize_superblock(raw)
    check("superblock checksum verifies after a clean unmount",
          on_disk.verify_checksum(), true)
    check_int("stored checksum matches a fresh computation",
              on_disk.checksum, on_disk.compute_checksum())

    ## And it must still fail when the superblock is actually damaged, or it is
    ## not detecting anything.
    let tampered = imgio.read_image(dev)
    bytes_set(tampered, 24, bytes_get(tampered, 24) ^ 0xFF)   ## block_size field
    let bad = superblock.deserialize_superblock(tampered)
    check("tampering is detected", bad.verify_checksum(), false)

    print("  Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("  ALL PERSISTENCE TESTS PASSED")

main()
