import superblock
import imgio
import inode as inode_module
import vfs

## The superblock's root_inode must be the inode the filesystem actually creates
## the root with.
##
## These were three different numbers: inode.ROOT_INO was 1, the superblock
## recorded 3 ("inode 3 is traditionally the root dir"), and the kernel driver
## compiled in SAGEFS_ROOT_INO 3. Nothing in the VFS honoured the superblock
## field -- create_root() used inode.ROOT_INO, and a remount resolved "/" to
## that.
##
## That made fsck.sage dangerous rather than merely wrong. It walks inode
## reachability starting from sb.root_inode, so it began at an unrelated inode,
## found the real root unreachable, and reported the root and everything beneath
## it as orphans. With --repair it deletes exactly those inodes.

let dev = "/tmp/sagefs_root_ino.img"
let passed = 0
let failed = 0

proc check(label: String, got, want):
    if got == want:
        passed = passed + 1
        print("  PASS  " + label)
    else:
        failed = failed + 1
        print("  FAIL  " + label + "  got=" + str(got) + " expected=" + str(want))

let features: Dict = {"checksum_algo": superblock.CHECKSUM_CRC32C}
let sb = superblock.create_superblock(4096, "Root", 4096, 32, features)

check("fresh superblock root_inode == inode.ROOT_INO",
      sb.root_inode, inode_module.ROOT_INO)

## And it must survive the round trip to disk, since that is what fsck reads.
imgio.write_image(dev, sb.serialize())
let on_disk = superblock.deserialize_superblock(imgio.read_image(dev))
check("on-disk root_inode == inode.ROOT_INO",
      on_disk.root_inode, inode_module.ROOT_INO)

## The decisive check: the number the filesystem resolves "/" to must be the
## number the superblock advertises, because that is the number fsck walks from.
let fs = vfs.VFS(dev)
check("mount", fs.mount(), true)
fs.mkdir("/subdir", 0o755)
let fd = fs.open("/subdir/file.txt", vfs.O_CREAT | vfs.O_RDWR)
fs.write(fd, bytes("payload"))
fs.close(fd)
let live_root = fs.resolve_path("/")
check("resolve(\"/\") == inode.ROOT_INO", live_root, inode_module.ROOT_INO)
check("resolve(\"/\") == superblock root_inode", live_root, sb.root_inode)
fs.unmount()

## After a remount, so the value is the persisted one rather than fresh state.
let fs2 = vfs.VFS(dev)
check("remount", fs2.mount(), true)
check("resolve(\"/\") after remount == superblock root_inode",
      fs2.resolve_path("/"), on_disk.root_inode)
check("content reachable under the advertised root",
      fs2.resolve_path("/subdir/file.txt") >= 0, true)
fs2.unmount()

print("  Results: " + str(passed) + "/" + str(passed + failed) + " passed")
if failed > 0:
    print("  ROOT INODE TESTS FAILED")
else:
    print("  ALL ROOT INODE TESTS PASSED")
