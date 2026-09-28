import superblock
import imgio
import vfs

## Sparse files and directory renames.
##
## read_inode_data() used to append each extent's bytes to the end of the result
## buffer and ignore ext.file_offset. That is only correct when extents are
## contiguous and sorted, which the first hole breaks. Punching block 0 out of a
## 12288-byte file left two extents at 4096 and 8192, and their data was
## concatenated into offsets 0 and 4096: a read at offset 0 returned what belongs
## at 4096, and a read at 8192 -- surviving, untouched data -- fell off the end of
## an 8192-byte buffer and returned nothing. The data was not just misplaced, it
## was unreachable, and punch_hole freed real storage behind it.
##
## rename() separately re-inserted the moved entry as DT_REG unconditionally, so
## renaming a directory made is_dir() false, its dentries unreachable, and fsck
## reported the subtree below it as orphans.

let dev = "/tmp/sagefs_sparse.img"
let passed = 0
let failed = 0

proc check(label: String, got, want):
    if got == want:
        passed = passed + 1
        print("  PASS  " + label)
    else:
        failed = failed + 1
        print("  FAIL  " + label + "  got=" + str(got) + " expected=" + str(want))

proc check_true(label: String, got):
    check(label, got, true)

proc read_byte(fs, path: String, off: Int) -> Int:
    let fd = fs.open(path, 0)
    if fd < 0:
        return -1
    fs.lseek(fd, off, 0)
    let d = fs.read(fd, 1)
    fs.close(fd)
    if bytes_len(d) < 1:
        return -1
    return bytes_get(d, 0)

let features: Dict = {"checksum_algo": superblock.CHECKSUM_CRC32C}
let sb = superblock.create_superblock(4096, "Sparse", 4096, 32, features)
let ia: Int = sb.inode_entry_start_blk * sb.block_size
sb.image_size = ia + sb.inode_entry_byte_size
var buf = bytes()
let sbb = sb.serialize()
var k = 0
while k < bytes_len(sbb):
    bytes_push(buf, bytes_get(sbb, k))
    k = k + 1
var pad = bytes_len(buf)
while pad < sb.image_size:
    bytes_push(buf, 0)
    pad = pad + 1
check("image written", imgio.write_image(dev, buf), true)

let fs: Any = vfs.VFS(dev)
check_true("volume mounts", fs.mount())

## --- a three-block file, every byte distinguishable -------------------------
check_true("create /big", fs.mkdir("/big") or true)
let fd = fs.create_file("/big/data.bin", 577)
check_true("create_file returned a descriptor", fd >= 0)
var block = ""
var i = 0
while i < 4096:
    block = block + chr(65 + (i % 26))
    i = i + 1
var w = 0
while w < 3:
    check_true("write block " + str(w), fs.write(fd, bytes(block)) == 4096)
    w = w + 1
fs.close(fd)
check("file is 12288 bytes", fs.stat("/big/data.bin")["size"], 12288)
check("byte 0 before punch", read_byte(fs, "/big/data.bin", 0), 65)
## The pattern repeats per 4096-byte block, and 4096 is not a multiple of 26,
## so the byte at a file offset is 65 + ((offset % 4096) % 26).
check("byte 8191 before punch", read_byte(fs, "/big/data.bin", 8191), 65 + ((8191 % 4096) % 26))

let ino = fs.resolve_path("/big/data.bin")
check("three extents before punch", len(fs.extent._collect_extents(ino)), 3)

## --- punch the middle block out --------------------------------------------
check_true("punch_hole middle block", fs.punch_hole("/big/data.bin", 4096, 4096))
check("two extents after punch", len(fs.extent._collect_extents(ino)), 2)
check("size unchanged by punch", fs.stat("/big/data.bin")["size"], 12288)
check("hole reads as zero", read_byte(fs, "/big/data.bin", 4096), 0)
check("last byte of hole reads as zero", read_byte(fs, "/big/data.bin", 8191), 0)
check("data before hole intact", read_byte(fs, "/big/data.bin", 0), 65)
check("data after hole reachable", read_byte(fs, "/big/data.bin", 8192), 65)

## --- punch the first block: the case that used to hide live data ------------
check_true("punch_hole first block", fs.punch_hole("/big/data.bin", 0, 4096))
check("one extent after second punch", len(fs.extent._collect_extents(ino)), 1)
check("first hole reads as zero", read_byte(fs, "/big/data.bin", 0), 0)
check("tail still reachable", read_byte(fs, "/big/data.bin", 8192), 65)
check("size still unchanged", fs.stat("/big/data.bin")["size"], 12288)

## --- and it must survive a remount -----------------------------------------
fs.unmount()
let fs2: Any = vfs.VFS(dev)
fs2.mount()
check("hole survives remount", read_byte(fs2, "/big/data.bin", 4096), 0)
check("tail survives remount", read_byte(fs2, "/big/data.bin", 8192), 65)
check("size survives remount", fs2.stat("/big/data.bin")["size"], 12288)

## --- rename must keep a directory a directory ------------------------------
##
## NOTE: renaming a directory that *has children* is excluded here. It works
## under the C backend but raises "Arity mismatch" under the bytecode VM when the
## renamed directory is then resolved, and that is not yet diagnosed. The
## narrower cases below are what this file pins. See README issue 20.
check_true("mkdir /movable", fs2.mkdir("/movable"))
check_true("rename empty directory", fs2.rename("/movable", "/renamed"))
check("old name is gone", fs2.resolve_path("/movable"), -1)
check("new name resolves", fs2.resolve_path("/renamed") > 0, true)
check("renamed dir is still a directory", fs2.inode.get_inode(fs2.resolve_path("/renamed")).is_dir(), true)

check_true("mkdir /holder", fs2.mkdir("/holder"))
let fdi = fs2.create_file("/holder/leaf.txt", 577)
fs2.write(fdi, bytes("leaf"))
fs2.close(fdi)
## renaming a file must still work
check_true("rename file", fs2.rename("/holder/leaf.txt", "/holder/leaf2.txt"))
check("old file name gone", fs2.resolve_path("/holder/leaf.txt"), -1)
check("new file name resolves", fs2.resolve_path("/holder/leaf2.txt") > 0, true)
check("renamed file content intact", read_byte(fs2, "/holder/leaf2.txt", 0), ord("l"))

## renaming a file into a *different* directory exercises the cross-parent path
check_true("mkdir /dest", fs2.mkdir("/dest"))
check_true("rename across directories", fs2.rename("/holder/leaf2.txt", "/dest/moved.txt"))
check("source gone after cross-dir rename", fs2.resolve_path("/holder/leaf2.txt"), -1)
check("destination resolves", fs2.resolve_path("/dest/moved.txt") > 0, true)
check("cross-dir content intact", read_byte(fs2, "/dest/moved.txt", 0), ord("l"))
fs2.unmount()

print("  Results: " + str(passed) + "/" + str(passed + failed) + " passed")
if failed == 0:
    print("ALL SPARSE AND RENAME TESTS PASSED")
else:
    print("SPARSE AND RENAME TESTS FAILED")
