## The journal must not be pointed at the filesystem's own metadata.
##
## VFS.mount() used to construct Journal(self, 0, 16, bs), i.e. blocks 0-15:
## the primary superblock, its mirror, both checkpoint packs, and the whole
## reserved inode-entry area. Nothing had reserved a region for the journal,
## because the layout never had one.
##
## That was survivable only by luck. Journal.sync() always rewrites its whole
## buffer starting at start_blk, and any write too large to inline (>3400 bytes)
## goes through txmgr.begin()/commit(), which syncs the journal. So the first
## such write stamped JOURNAL_MAGIC over the superblock in the in-memory image.
## unmount() re-serialises the superblock afterwards, so the volume came back
## fine -- and a crash in between left a volume that would not mount.
##
## Format v1.3 reserves a real region (JOURNAL_RESERVED_BLKS after the reserved
## metadata area) and records it in the superblock. Volumes written before v1.3
## have no region, and get a *disabled* journal rather than a dangerous one.
##
## This asserts the superblock magic is still intact in the image after a
## non-inline write, which is the thing that used to break.

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
        print("  FAIL  " + name)

## Build a real image the way src/mkfs.sage does: superblock, zero-padding out
## to the reserved inode-entry area, and the image padded to image_size.
proc make_image(dev: String) -> Bool:
    let features: Dict = {"checksum_algo": superblock.CHECKSUM_CRC32C}
    let sb = superblock.create_superblock(4096, "JournalRegion", 4096, 32, features)
    let buf = sb.serialize()

    let bs: Int = sb.block_size
    let inode_area: Int = sb.inode_entry_start_blk * bs
    var pad = bytes_len(buf)
    while pad < inode_area + 200:
        bytes_push(buf, 0)
        pad = pad + 1

    let readme = "SageFS Journal Region Test\n"
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

    ## Re-serialise so the superblock records the final image_size.
    let sb_bytes = sb.serialize()
    var k = 0
    while k < bytes_len(sb_bytes):
        buf[k] = sb_bytes[k]
        k = k + 1

    return imgio.write_image(dev, buf)

proc magic_int(buf: Bytes) -> Int:
    let a: Int = bytes_get(buf, 0)
    let b: Int = bytes_get(buf, 1)
    let c: Int = bytes_get(buf, 2)
    let d: Int = bytes_get(buf, 3)
    return a | (b << 8) | (c << 16) | (d << 24)

proc main():
    print("=== SageFS Journal Region Tests ===")

    let dev: String = "/tmp/sagefs_journal_region.img"
    check("format image", make_image(dev), true)

    let raw = imgio.read_image(dev)
    check("superblock magic before mount", magic_int(raw), superblock.SAGEFS_MAGIC)

    let fs = vfs.VFS(dev)
    check("mount", fs.mount(), true)

    ## The superblock must describe a journal region, and it must not overlap
    ## the metadata blocks at the front of the volume.
    let sb = fs.sb
    check("journal region reserved", sb.journal_block_count > 0, true)
    check("journal starts after reserved metadata",
          sb.journal_start_blk >= superblock.RESERVED_BLKS, true)
    check("journal does not overlap the inode-entry area",
          sb.journal_start_blk >= sb.inode_entry_start_blk +
              superblock.INODE_ENTRY_RESERVED_BLKS, true)
    check("journal does not overlap the NAT",
          sb.journal_start_blk + sb.journal_block_count <= sb.nat_start_blk, true)

    ## A write large enough to skip the inline path goes through the transaction
    ## manager, which is what synced the journal over the superblock before.
    let fd: Int = fs.open("/bigfile.bin", vfs.O_CREAT | vfs.O_RDWR)
    check("create bigfile.bin", fd >= 0, true)

    let payload = ""
    var i = 0
    while i < 8192:
        payload = payload + "x"
        i = i + 1
    let written: Int = fs.write(fd, bytes(payload))
    check("wrote more than the inline limit", written > 3400, true)
    fs.close(fd)

    ## The heart of it: the superblock in the live image is untouched.
    let live = imgio.read_image(dev)
    check("superblock magic survives a non-inline write",
          magic_int(live), superblock.SAGEFS_MAGIC)
    check("in-memory image still starts with the superblock magic",
          magic_int(fs.image_buf), superblock.SAGEFS_MAGIC)

    fs.unmount()

    ## And the volume still mounts and reads back afterwards.
    let fs2 = vfs.VFS(dev)
    check("remount", fs2.mount(), true)
    let st = fs2.stat("/bigfile.bin")
    check("bigfile.bin exists after remount", st["exists"], true)
    ## Tripwire, not an endorsement: the payload of a block-mapped file does not
    ## survive a remount yet, because VFS.mount() builds the extent tree as
    ## BTreeEngine(self, 0, 1) -- root block 0, i.e. permanently empty -- and the
    ## inode's data_offset/size are not written to the reserved inode-entry area.
    ## That is a separate defect from journalling and is tracked on its own; this
    ## assertion exists so that when it is fixed, this test says so.
    check("KNOWN BUG: block-mapped payload does not survive remount",
          st["size"], 0)
    fs2.unmount()

    print("  Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("  ALL JOURNAL REGION TESTS PASSED")

main()
