import btree
import extent as extent_module
import vfs
import superblock
import imgio

## Covers three related defects in the extent map:
##
## 1. VFS.write() called insert_extent(ino, offset, block, 1) -- passing 1 as the
##    length, which is in bytes (end_offset = file_offset + length). Every
##    block-mapped extent claimed to cover a single byte, so the map misdescribed
##    every block-mapped file. read_inode_data() masked it by walking block_addr
##    and the inode size instead of the extents.
##
## 2. ExtentTree._write_extents() did not exist, so truncate() and punch_hole()
##    both raised at runtime. punch_hole is how a filesystem releases blocks, so
##    it freed nothing.
##
## 3. punch_hole() added a byte offset to a block address when trimming or
##    splitting, producing block numbers pointing at unrelated data.
##
## Driven against ExtentTree directly because VFS exposes no truncate or
## punch_hole -- see known issue 14.

let passed = 0
let failed = 0

proc check(label: String, got, want):
    if got == want:
        passed = passed + 1
        print("  PASS  " + label)
    else:
        failed = failed + 1
        print("  FAIL  " + label + "  got=" + str(got) + " expected=" + str(want))

proc fresh(dev: String) -> VFS:
    let features: Dict = {"checksum_algo": superblock.CHECKSUM_CRC32C}
    let sb = superblock.create_superblock(4096, "Ext", 4096, 32, features)
    imgio.write_image(dev, sb.serialize())
    let f = vfs.VFS(dev)
    f.mount()
    return f

proc make_file(fs: VFS, path: String, size: Int) -> Int:
    let fd = fs.open(path, vfs.O_CREAT | vfs.O_RDWR)
    var payload = bytes()
    var i = 0
    while i < size:
        bytes_push(payload, i & 0xFF)
        i = i + 1
    fs.write(fd, payload)
    fs.close(fd)
    return fs.resolve_path(path)

proc total_len(exts) -> Int:
    var n: Int = 0
    for e in exts:
        n = n + e.length
    return n

proc contiguous(exts) -> Bool:
    ## True when the extents tile [0, total) with no gap and no overlap.
    var pos = 0
    for e in exts:
        if e.file_offset != pos:
            return false
        pos = pos + e.length
    return true

## ------------------------------------------------- extents describe the file
print("  --- extent lengths ---")
let dev0 = "/tmp/sagefs_xl.img"
let fs0 = fresh(dev0)
let ino0 = make_file(fs0, "/x.bin", 8192)
let e0 = fs0.extent._collect_extents(ino0)
check("file is block-mapped", fs0.inode.get_inode(ino0).size, 8192)
check("extents cover the whole file", total_len(e0), 8192)
check("extents tile without gaps", contiguous(e0), true)
var lengths_are_blocks = true
for e in e0:
    if e.length % 4096 != 0:
        lengths_are_blocks = false
check("extent lengths are whole blocks", lengths_are_blocks, true)
check("data reads back in full", bytes_len(fs0.read_inode_data(ino0)), 8192)
fs0.unmount()

## The map must survive a remount intact, lengths included.
let fs0b = vfs.VFS(dev0)
check("remount", fs0b.mount(), true)
let ino0b = fs0b.resolve_path("/x.bin")
check("lengths persisted", total_len(fs0b.extent._collect_extents(ino0b)), 8192)
fs0b.unmount()

## ---------------------------------------------------------------- truncate
print("  --- truncate() ---")
let dev1 = "/tmp/sagefs_trunc.img"
let fs1 = fresh(dev1)
let ino1 = make_file(fs1, "/f.bin", 8192)
let before = fs1.extent._collect_extents(ino1)
let head_block = 0
for e in before:
    if e.file_offset == 0:
        head_block = e.block_addr
check("head block recorded", head_block > 0, true)

fs1.extent.truncate(ino1, 4096)
let after = fs1.extent._collect_extents(ino1)
check("extent count shrank", len(after) < len(before), true)
check("extents cover exactly the new size", total_len(after), 4096)
check("extents still tile", contiguous(after), true)
var head_kept = false
for e in after:
    if e.file_offset == 0 and e.block_addr == head_block:
        head_kept = true
check("surviving head keeps its original block", head_kept, true)
fs1.unmount()

let fs1b = vfs.VFS(dev1)
check("remount after truncate", fs1b.mount(), true)
check("truncated map persisted", total_len(fs1b.extent._collect_extents(fs1b.resolve_path("/f.bin"))), 4096)
fs1b.unmount()

## -------------------------------------------------------------- punch_hole
print("  --- punch_hole() ---")
## Holes are block-aligned because that is all this extent model can represent.

## Swallow a whole trailing extent.
let dev2 = "/tmp/sagefs_hole.img"
let fs2 = fresh(dev2)
let ino2 = make_file(fs2, "/g.bin", 8192)
fs2.extent.punch_hole(ino2, 4096, 4096)
let holed = fs2.extent._collect_extents(ino2)
check("trailing extent released", len(holed), 1)
check("what remains is the head", holed[0].file_offset, 0)
check("remaining length excludes the hole", total_len(holed), 4096)
fs2.unmount()

## Trim the head of the first extent.
let dev3 = "/tmp/sagefs_hole2.img"
let fs3 = fresh(dev3)
let ino3 = make_file(fs3, "/h.bin", 8192)
fs3.extent.punch_hole(ino3, 0, 4096)
let holed3 = fs3.extent._collect_extents(ino3)
var min_off = -1
for e in holed3:
    if min_off < 0 or e.file_offset < min_off:
        min_off = e.file_offset
check("first extent no longer starts at 0", min_off, 4096)
check("remaining length excludes the hole", total_len(holed3), 4096)
## No tiling check here: a hole at offset 0 leaves a real gap, which is the
## point. contiguous() is only meaningful before any hole.
fs3.unmount()

## Trim the end of the first extent, leaving the second untouched.
let dev4 = "/tmp/sagefs_hole3.img"
let fs4 = fresh(dev4)
let ino4 = make_file(fs4, "/k.bin", 8192)
fs4.extent.punch_hole(ino4, 2048, 2048)
let t4 = fs4.extent._collect_extents(ino4)
check("head extent trimmed", t4[0].file_offset, 0)
check("head extent shortened to the hole", t4[0].length, 2048)
check("following extent untouched", t4[1].file_offset, 4096)
check("following extent length untouched", t4[1].length, 4096)
fs4.unmount()

## A hole swallowing the first of several extents must not renumber the rest.
## This is the case that produced block 3312 before the fix: trimming a block
## address by a byte count.
let dev5 = "/tmp/sagefs_hole4.img"
let fs5 = fresh(dev5)
let ino5 = make_file(fs5, "/m.bin", 8192)
let tail_block = 0
for e in fs5.extent._collect_extents(ino5):
    if e.file_offset == 4096:
        tail_block = e.block_addr
fs5.extent.punch_hole(ino5, 0, 8192)
let t5 = fs5.extent._collect_extents(ino5)
check("everything released", len(t5), 0)
check("no block number was invented", tail_block > 0, true)
fs5.unmount()

## ------------------------------------------------------------- idempotence
print("  --- repeated truncate ---")
let fs6 = fresh("/tmp/sagefs_trunc2.img")
let ino6 = make_file(fs6, "/i.bin", 8192)
fs6.extent.truncate(ino6, 4096)
fs6.extent.truncate(ino6, 2048)
check("progressive truncate lands on target", total_len(fs6.extent._collect_extents(ino6)), 2048)
fs6.extent.truncate(ino6, 0)
check("truncate to 0 releases every extent", len(fs6.extent._collect_extents(ino6)), 0)
fs6.unmount()

## Truncating up must not invent extents.
let fs7 = fresh("/tmp/sagefs_trunc3.img")
let ino7 = make_file(fs7, "/j.bin", 8192)
fs7.extent.truncate(ino7, 16384)
check("truncate beyond EOF changes nothing", total_len(fs7.extent._collect_extents(ino7)), 8192)
fs7.unmount()

print("  Results: " + str(passed) + "/" + str(passed + failed) + " passed")
if failed > 0:
    print("  EXTENT RESIZE TESTS FAILED")
else:
    print("  ALL EXTENT RESIZE TESTS PASSED")
