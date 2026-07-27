## mount.sage — SageFS Mount Helper with Journal Replay
##
## Entry point for mounting a SageFS image.  Reads the superblock,
## initialises all subsystems, replays the journal, cleans orphans,
## wires everything into the VFS, and hands off to the FUSE daemon.
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
import segment as seg_module
import nat as nat_module
import allocator as alloc_module
import inode as inode_module
import btree as btree_module
import extent as extent_module
import dir as dir_module
import aio as aio_module
import cache as cache_module
import journal as journal_module
import transaction as txn_module
import gc as gc_module
import snapshot as snap_module
import compress as compress_module
import dedup as dedup_module
import encrypt as encrypt_module
import raid as raid_module
import xattr as xattr_module
import vfs
import fuse

## mount — Full mount flow
##
## Reads the image, deserializes the superblock, initializes every
## subsystem, replays the journal, detects and cleans orphan inodes,
## and returns a fully-wired vfs.VFS instance.
proc mount(dev: String) -> vfs.VFS:
    let raw: Bytes = imgio.read_image(dev)
    if bytes_len(raw) < 428:
        print("SageFS: image too small (" + str(bytes_len(raw)) + " bytes)")
        return nil

    let sb = superblock.deserialize_superblock(raw)
    if sb.magic != superblock.SAGEFS_MAGIC:
        print("SageFS: bad magic 0x" + str(sb.magic) + " (expected 0x" + str(superblock.SAGEFS_MAGIC) + ")")
        return nil

    print("SageFS: superblock verified (magic=0x" + str(sb.magic) + ")")
    print("SageFS: block_size=" + str(sb.block_size) + ", segments=" + str(sb.total_segments))

    let bs: Int = sb.block_size
    if bs <= 0:
        bs = 4096
    let total_blks: Int = sb.total_blocks
    if total_blks <= 0:
        total_blks = 65536
    let seg_sz: Int = sb.segment_size
    if seg_sz <= 0:
        seg_sz = 512
    let main_start: Int = sb.main_start_blk
    if main_start <= 0:
        main_start = 8
    let nat_start: Int = sb.nat_start_blk
    if nat_start <= 0:
        nat_start = 2
    let total_segs: Int = int(total_blks / seg_sz)
    let nat_blocks: Int = 64

    let seg_mgr = seg_module.SegmentManager(total_segs, bs, main_start)
    let nat_table = nat_module.NodeAddressTable(nat_start, nat_blocks)
    let alloc = alloc_module.BlockAllocator(seg_mgr, nat_table, bs, total_blks)
    let inode_mgr = inode_module.InodeManager(nat_table)
    let root_inode = inode_mgr.create_root()
    if root_inode != nil:
        root_inode.set_flag(inode_module.INODE_FLAG_INLINE_DENTRY)
    nat_table.prefill_free_nids(128)

    let btree_eng = btree_module.BTreeEngine(alloc, 0, 1)
    let extent_tree = extent_module.ExtentTree(btree_eng)
    let dir_mgr = dir_module.DirManager()
    let aio_eng = aio_module.AsyncIOEngine()
    let cache_mgr = cache_module.CacheManager(1024, 1024, 512)
    let gc_eng = gc_module.GarbageCollector(seg_mgr, alloc)
    let snapshot_eng = snap_module.SnapshotEngine()
    let compress_eng = compress_module.CompressionEngine()
    let dedup_eng = dedup_module.DedupEngine()
    let encrypt_layer = encrypt_module.EncryptionLayer("")
    let raid_eng = raid_module.RaidEngine(0)
    let xattr_mgr = xattr_module.XAttrManager()

    let fs = vfs.VFS(dev,
                     seg_mgr=seg_mgr,
                     allocator=alloc,
                     nat_table=nat_table,
                     inode_mgr=inode_mgr,
                     btree_eng=btree_eng,
                     extent_tree=extent_tree,
                     dir_mgr=dir_mgr,
                     aio_eng=aio_eng,
                     cache_mgr=cache_mgr,
                     gc_eng=gc_eng,
                     snapshot_eng=snapshot_eng,
                     compress_eng=compress_eng,
                     dedup_eng=dedup_eng,
                     encrypt_layer=encrypt_layer,
                     raid_eng=raid_eng,
                     xattr_mgr=xattr_mgr)

    if not fs.mount():
        print("SageFS: mount failed")
        return nil

    let applied: Int = fs.journal.replay()
    if applied > 0:
        print("SageFS: journal replayed " + str(applied) + " updates")

    let all_inos = fs.inode.list_inodes()
    var cleaned: Int = 0
    for ino in all_inos:
        let inode_obj = fs.inode.get_inode(ino)
        if inode_obj != nil and inode_obj.nlink <= 0:
            fs.inode.delete_inode(ino)
            cleaned = cleaned + 1
    if cleaned > 0:
        print("SageFS: cleaned " + str(cleaned) + " orphan inodes")

    return fs


## main — CLI entry point
##
## Reads the device path from command-line arguments, mounts the
## filesystem, and hands control to the FUSE event loop.
proc main():
    let args: Array[String] = sys.args()
    if len(args) < 2:
        print("Usage: mount.sage <image>")
        return

    let dev: String = args[1]
    let fs: vfs.VFS = mount(dev)
    if fs == nil:
        print("SageFS: mount failed")
        return

    print("SageFS: mounted " + dev + " — entering FUSE loop")
    fuse.fuse_run(fs)

main()
