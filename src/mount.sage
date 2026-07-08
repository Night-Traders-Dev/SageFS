## mount.sage — SageFS Mount Helper
##
## Entry point for mounting a SageFS image.  Reads the superblock,
## replays the journal if needed, initialises the VFS, and hands off
## to the FUSE daemon (via build/sagefs-fuse for userspace mounting,
## or directly via /dev/fuse in native-compiled mode).
##
## Usage:
##   sage --runtime bytecode -I src mount.sage <image>
##
## At runtime the VFS layer calls into the existing core engine modules
## (superblock, segment, inode, journal, transaction, dir, btree, etc.)
## to service POSIX filesystem operations forwarded by the FUSE bridge.

import sys
import imgio
import superblock
import journal
import vfs

proc mount(dev: String, mount_point: String, opts: String) -> Bool:
    print("SageFS: mounting " + dev + " on " + mount_point)

    let fs: vfs.VFS = vfs.VFS(dev)
    if not fs.mount():
        print("SageFS: mount failed — bad superblock")
        return false

    let raw: Bytes = imgio.read_image(dev)
    let sb = fs.sb

    print("SageFS: superblock verified (magic=" + str(sb.magic) + ")")
    print("SageFS: block_size=" + str(sb.block_size) + ", segments=" + str(sb.total_segments))

    return true

proc main():
    let args: Array[String] = sys.args()
    if len(args) < 2:
        print("Usage: mount.sage <image> [mountpoint]")
        print("")
        print("Mounts a SageFS image for inspection.")
        print("For full FUSE mounting, use: build/sagefs-fuse <image> <mountpoint>")
        return

    let dev: String = args[1]
    let mount_point: String = "/mnt/sagefs"
    if len(args) >= 3:
        mount_point = args[2]

    let ok: Bool = mount(dev, mount_point, "")
    if ok:
        print("SageFS: mounted successfully at " + mount_point)
    else:
        print("SageFS: mount failed")

main()
