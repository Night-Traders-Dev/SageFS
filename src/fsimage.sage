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
import aio as aio_module
import cache as cache_module
import fsgc as gc_module
import snapshot as snap_module
import compress as compress_module
import dedup as dedup_module
import encrypt as encrypt_module
import raid as raid_module
import xattr as xattr_module
import vfs

proc mount(dev: String) -> vfs.VFS:
    ## Validate the volume, then hand off to VFS.mount(), which is the same path
    ## every test in testing/ uses and which does the real work: it validates the
    ## magic, sizes the read from sb.image_size, and builds the segment manager,
    ## NAT, allocator, inode manager, B+ tree, extent tree, dir manager, cache,
    ## journal and transaction manager from the superblock.
    ##
    ## This function used to do all of that itself and then pass the result to the
    ## VFS constructor by keyword. That call is broken in this runtime: the
    ## constructor's `allocator` parameter resolves as an undefined variable, so
    ## VFS.init() aborts partway, fs.journal is left nil, the journal replay
    ## raises on it, and the mount ends with a single inode. The hand-built
    ## graph bought nothing that VFS.mount() does not already do correctly.
    ## Read the metadata area as a range rather than the whole image.
    ##
    ## io.readbytes() refuses a whole-file read over 100 MiB and returns nil
    ## with no error, so a full-volume image read this way comes back as length
    ## 0 and the mount reports "image too small" about an image that is exactly
    ## the right size. The header comes first, because the size of the rest of
    ## the metadata depends on it.
    let raw: Bytes = imgio.read_image_range(dev, 0, superblock.SUPERBLOCK_HEADER_SIZE)
    if bytes_len(raw) < 428:
        print("SageFS: image too small (" + str(bytes_len(raw)) + " bytes)")
        return nil
    let sb = superblock.deserialize_superblock(raw)
    if sb.magic != superblock.SAGEFS_MAGIC:
        print("SageFS: bad magic 0x" + str(sb.magic) + " (expected 0x" + str(superblock.SAGEFS_MAGIC) + ")")
        return nil
    ## Superblock plus the reserved inode-entry area: everything the mount
    ## indexes into. The data blocks stay on disk.
    let meta_end: Int = sb.inode_entry_start_blk * sb.block_size + sb.inode_entry_byte_size
    if meta_end > sb.image_size:
        meta_end = sb.image_size
    if meta_end > bytes_len(raw):
        raw = imgio.read_image_range(dev, 0, meta_end)

    let fs: Any = vfs.VFS(dev)
    if not fs.mount():
        print("SageFS: mount failed")
        return nil

    let applied: Int = fs.journal.replay()
    if applied > 0:
        print("SageFS: journal replayed " + str(applied) + " updates")

    ## The previous version also swept the inode table on every mount, deleting
    ## every inode whose nlink was <= 0. Nothing in the write path maintains
    ## nlink, so this was not a recovery step -- it was a data-destroying one:
    ## mounting a filesystem was enough to delete its inodes, and the freshly
    ## created root was itself a candidate. Reclaim is fsck's job, and fsck
    ## reaches unreferenced inodes by walking from the root rather than by
    ## trusting a link count that is never written.
    return fs


## main — CLI entry point
##
## Reads the device path from command-line arguments, mounts the
## filesystem, and hands control to the FUSE event loop.
