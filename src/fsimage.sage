## ============================================================================
## SageFS image mounting (shared by the mount and fsck front-ends)
## ============================================================================
##
## This lived in mount.sage, which made it impossible for fsck to reuse: mount.sage
## calls main() at module level, so importing it to get mount() ran the FUSE
## mount command as a side effect of importing the library function. Moving it
## into vfs.sage instead does not work either -- vfs.mount() calling VFS() in its
## own defining module makes the constructor's `allocator` parameter resolve as
## an undefined variable, so VFS.init() aborted partway and left fs.journal nil.
## A separate module sidesteps both problems: it imports vfs the same way any
## other consumer does.
##
import sys
import io
import imgio
import superblock
import segment as seg_module
import nat as nat_module
import allocator as alloc_module
import inode as inode_module
import btree as btree_module
import extent as extent_module
import dir as dir_module
import vfs

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
    let extent_tree = extent_module.ExtentTree(btree_eng, sb.block_size)
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
