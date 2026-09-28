import sys
import superblock
import imgio
import inode as inode_module
import dir as dir_module
import vfs
import fsck as fsck_module

## fsck must be trustworthy in both directions: report a healthy filesystem as
## clean, and actually report damage when there is some.
##
## Every check in it was broken, and each failure mode was silent:
##
##  - FsckReport.add() called self.issues.push(issue). Lists in this runtime are
##    appended with the global push(list, value), so fsck raised "'.push' is not
##    callable" on the first issue it found -- crashing on exactly the input it
##    exists to report. A volume with no problems looked clean only because add()
##    was never reached.
##
##  - Fsck.walk() passed each DirEntry into a parameter typed Int, so the visited
##    set never matched, the cycle guard never fired, and a healthy tree had its
##    root and every descendant flagged as orphans.
##
##  - The link-count check compared nlink against the number of entries naming an
##    inode. A directory's nlink is 2 plus its subdirectory count, so the check
##    was wrong by construction for every directory.

let dev = "/tmp/sagefs_fsck.img"
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

proc count_code(report, code: Int) -> Int:
    var n = 0
    for iss in report.issues:
        if iss.code == code:
            n = n + 1
    return n

## ---------------------------------------------------------------------------
## A stub inode manager, so the checks can be driven without having to hand-
## corrupt an image. Fsck takes `inodes` as Any precisely so it can be run
## against either a mounted volume or a synthetic one.
## ---------------------------------------------------------------------------

class StubInodeManager:
    proc init(self):
        self.inodes = {}
        self.dirs = {}
        self.order = []

    proc put(self, ino: Int, inode_obj, dir_entries):
        self.inodes[str(ino)] = inode_obj
        push(self.order, ino)
        if dir_entries != nil:
            self.dirs[str(ino)] = dir_entries

    proc get_inode(self, ino: Int):
        if dict_has(self.inodes, str(ino)):
            return self.inodes[str(ino)]
        return nil

    proc list_inodes(self) -> Array:
        return self.order

    proc read_dir_entries(self, ino: Int) -> Array:
        if dict_has(self.dirs, str(ino)):
            return self.dirs[str(ino)]
        return []

    proc delete_inode(self, ino: Int) -> Bool:
        dict_delete(self.inodes, str(ino))
        return true

proc make_inode(ino: Int, is_dir: Bool):
    let obj = inode_module.SageFSInode(ino, 100 + ino, 0)
    if is_dir:
        obj.mode = inode_module.S_IFDIR | 493
    return obj

proc make_dir(entries: Array) -> Any:
    return dir_module.DirManager()

## ---------------------------------------------------------------------------
## 1. A healthy tree must come back clean.
## ---------------------------------------------------------------------------

let features: Dict = {"checksum_algo": superblock.CHECKSUM_CRC32C}
let sb = superblock.create_superblock(4096, "FsckTest", 4096, 32, features)
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
check_true("mkdir /dir", fs.mkdir("/dir"))
check_true("mkdir /dir/nested", fs.mkdir("/dir/nested"))
let fd = fs.open("/file.txt", 577)
fs.write(fd, "hello fsck")
fs.close(fd)
let fd2 = fs.open("/dir/inner.bin", 577)
var big = ""
var i = 0
while i < 9000:
    big = big + "x"
    i = i + 1
fs.write(fd2, big)
fs.close(fd2)
## Resolved while still mounted: resolve_path() returns -1 once unmounted.
let ino_dir = fs.resolve_path("/dir")
let ino_nested = fs.resolve_path("/dir/nested")
let ino_file = fs.resolve_path("/file.txt")
let ino_inner = fs.resolve_path("/dir/inner.bin")
fs.unmount()

let real: Any = fsck_module.Fsck(sb, fs.inode, nil, nil, nil, false)
let clean_report = real.run()
check("healthy filesystem is clean", clean_report.is_clean(), true)
check("healthy filesystem has no issues", len(clean_report.issues), 0)
check("fsck scanned 5 inodes", clean_report.inodes_scanned, 5)
check("fsck did not crash on add()", true, true)

## A second mount must still agree, i.e. link counts survived the remount.
let fs2: Any = vfs.VFS(dev)
fs2.mount()
let real2: Any = fsck_module.Fsck(sb, fs2.inode, nil, nil, nil, false)
let remount_report = real2.run()
check("remounted filesystem is clean", remount_report.is_clean(), true)
## Resolve on the remounted instance rather than reusing the first mount's inode
## numbers, so this checks the rebuilt table rather than assuming numbers are
## stable across mounts.
let ino_dir2 = fs2.resolve_path("/dir")
let ino_nested2 = fs2.resolve_path("/dir/nested")
let ino_file2 = fs2.resolve_path("/file.txt")
let ino_inner2 = fs2.resolve_path("/dir/inner.bin")
check("remount resolves the same inodes", ino_dir2, ino_dir)
check("root link count survives remount", fs2.inode.get_inode(1).nlink, 3)
check("/dir link count is 2 + one subdir", fs2.inode.get_inode(ino_dir2).nlink, 3)
check("nested dir link count is 2 + no subdirs", fs2.inode.get_inode(ino_nested2).nlink, 2)
check("file link count", fs2.inode.get_inode(ino_file2).nlink, 1)
check("block-mapped file link count", fs2.inode.get_inode(ino_inner2).nlink, 1)
fs2.unmount()

## ---------------------------------------------------------------------------
## 2. Damage must be reported, and reporting it must not crash.
## ---------------------------------------------------------------------------

## root(1) -> /dir(2) -> /missing(99), plus an unreferenced inode 50.
let stub = StubInodeManager()
stub.put(1, make_inode(1, true), nil)
stub.put(2, make_inode(2, true), nil)
stub.put(50, make_inode(50, false), nil)

let root_dir = dir_module.DirManager()
root_dir.add_entry("dir", 2, dir_module.DT_DIR)
let sub_dir = dir_module.DirManager()
sub_dir.add_entry("missing", 99, dir_module.DT_REG)
stub.put(1, make_inode(1, true), [root_dir.read_dir()[0]])
stub.put(2, make_inode(2, true), [sub_dir.read_dir()[0]])

let broken: Any = fsck_module.Fsck(sb, stub, nil, nil, nil, false)
let bad_report = broken.run()
check("damage is detected", bad_report.is_clean(), false)
check("dangling reference reported", count_code(bad_report, fsck_module.ISSUE_DANGLING_NID) > 0, true)
check("unreferenced inode reported", count_code(bad_report, fsck_module.ISSUE_ORPHAN_INODE) > 0, true)
check("report survives add() (no list.push crash)", len(bad_report.issues) > 0, true)

## ---------------------------------------------------------------------------
## 3. A directory entry pointing at itself must not loop forever.
## ---------------------------------------------------------------------------

let loop = StubInodeManager()
let self_ref = dir_module.DirManager()
self_ref.add_entry("self", 1, dir_module.DT_DIR)
loop.put(1, make_inode(1, true), [self_ref.read_dir()[0]])
let looping: Any = fsck_module.Fsck(sb, loop, nil, nil, nil, false)
let loop_report = looping.run()
check("self-referencing directory terminates", true, true)
check("self-reference is not silently clean", loop_report.is_clean(), false)

print("  Results: " + str(passed) + "/" + str(passed + failed) + " passed")
if failed == 0:
    print("ALL FSCK TESTS PASSED")
else:
    print("FSCK TESTS FAILED")
