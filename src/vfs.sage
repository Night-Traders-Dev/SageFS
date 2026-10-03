## vfs.sage — SageFS Virtual Filesystem Layer
##
## Provides POSIX-like file and directory operations on top of SageFS
## on-disk structures.  This is the central orchestration layer that
## coordinates superblock, segment, allocator, NAT, inode, B+ tree,
## extent, directory, journal, cache, and async I/O modules.

import superblock
import csum
import segment as seg_module
import nat as nat_module
import allocator as alloc_module
import inode as inode_module
import dir as dir_module
import extent as extent_module
import btree as btree_module
import inodetable as it_module
import imgio
import aio as aio_module
import cache as cache_module
import transaction as txn_module
import fsgc as gc_module
import snapshot as snap_module
import compress as compress_module
import dedup as dedup_module
import encrypt as encrypt_module
import raid as raid_module
import xattr as xattr_module
from journal import Journal

let S_IFMT: Int = 0xF000
let S_IFSOCK: Int = 0xC000
let S_IFLNK: Int = 0xA000
let S_IFREG: Int = 0x8000
let S_IFBLK: Int = 0x6000
let S_IFDIR: Int = 0x4000
let S_IFCHR: Int = 0x2000
let S_IFIFO: Int = 0x1000

let O_ACCMODE: Int = 0x0003
let O_RDONLY: Int = 0x0000
let O_WRONLY: Int = 0x0001
let O_RDWR: Int = 0x0002
let O_CREAT: Int = 0x0040
let O_EXCL: Int = 0x0080
let O_TRUNC: Int = 0x0200
let O_APPEND: Int = 0x0400

let SEEK_SET: Int = 0
let SEEK_CUR: Int = 1
let SEEK_END: Int = 2

let ROOT_INO: Int = 1
let MAX_FDS: Int = 256
let MAX_PATH: Int = 4096

let DEFAULT_BLOCK_SIZE: Int = 4096
let DEFAULT_SEGMENT_SIZE: Int = 512
let DEFAULT_TOTAL_BLOCKS: Int = 65536

class FileDescriptor:
    proc init(self, ino: Int, flags: Int, pos: Int):
        self.ino = ino
        self.flags = flags
        self.pos = pos

class VFS:
    proc init(self, image_path: String,
              seg_mgr: Any = nil, allocator: Any = nil,
              nat_table: Any = nil, inode_mgr: Any = nil,
              btree_eng: Any = nil, extent_tree: Any = nil,
              dir_mgr: Any = nil,
              aio_eng: Any = nil, cache_mgr: Any = nil,
              journal_eng: Any = nil, txn_mgr: Any = nil,
              gc_eng: Any = nil, snapshot_eng: Any = nil,
              compress_eng: Any = nil, dedup_eng: Any = nil,
              encrypt_layer: Any = nil, raid_eng: Any = nil,
              xattr_mgr: Any = nil):
        self.image_path = image_path
        self.mounted = false
        self.sb = nil
        ## Lazily built; nil means the volume has no checksum region.
        self.csum_region_cache = nil
        self.fds = []
        self.next_fd = 0
        self.image_buf = bytes()
        self.blocks_growable = false
        self.ino_path_cache = {}

        self.segment = seg_mgr
        self.allocator = allocator
        self.nat = nat_table
        self.inode = inode_mgr
        self.btree = btree_eng
        self.extent = extent_tree
        self.dir = dir_mgr
        self.aio = aio_eng
        self.cache = cache_mgr
        self.journal = journal_eng
        self.txmgr = txn_mgr
        self.gc = gc_eng
        self.snapshot = snapshot_eng
        self.compress = compress_eng
        self.dedup = dedup_eng
        self.encrypt = encrypt_layer
        self.raid = raid_eng
        self.xattr = xattr_mgr
        ## Whether the on-disk segment information table has been read into the
        ## segment manager this mount, and how many entries came back.
        self.sit_loaded = false
        self.sit_entries_loaded = 0
        ## Whether the "directory no longer fits inline" warning has been printed,
        ## so a large directory reports once rather than on every save.
        self.dir_overflow_reported = false
        ## Inode metadata index (format v1.5). A separate B+ tree from the
        ## extent map, with its own root and generation, so writing an inode
        ## does not copy the extent map along with it.
        self.itable = nil
        ## True when this volume was read out of the pre-v1.5 fixed inode area
        ## and has not yet been rewritten into the tree. Set at mount, cleared by
        ## the first _persist_all() that gets far enough to write the tree.
        self.inode_area_migration = false

    proc _init_block_size(self) -> Int:
        if self.sb.block_size > 0:
            return self.sb.block_size
        return DEFAULT_BLOCK_SIZE

    proc _init_total_blocks(self) -> Int:
        if self.sb.total_blocks > 0:
            return self.sb.total_blocks
        return DEFAULT_TOTAL_BLOCKS

    proc _init_segment_size(self) -> Int:
        if self.sb.segment_size > 0:
            return self.sb.segment_size
        return DEFAULT_SEGMENT_SIZE

    proc _ensure_image_size(self, needed_bytes: Int):
        let current = bytes_len(self.image_buf)
        if needed_bytes > current:
            var i = current
            while i < needed_bytes:
                bytes_push(self.image_buf, 0)
                i = i + 1

    proc _read_block(self, blk_addr: Int) -> Bytes:
        let bs = self._init_block_size()
        let offset = blk_addr * bs
        let needed = offset + bs
        self._ensure_image_size(needed)
        let result = bytes()
        var i = 0
        while i < bs:
            bytes_push(result, bytes_get(self.image_buf, offset + i))
            i = i + 1
        return result

    proc _write_block(self, blk_addr: Int, data: Bytes):
        let bs = self._init_block_size()
        let offset = blk_addr * bs
        self._ensure_image_size(offset + bs)
        var i = 0
        while i < bs and i < bytes_len(data):
            bytes_set(self.image_buf, offset + i, bytes_get(data, i))
            i = i + 1
        ## Record the checksum after the bytes are in place, from the buffer
        ## rather than from `data`.
        ##
        ## `data` may be shorter than a block (a tail write) or longer than the
        ## region covers, so hashing it would describe a block the volume does
        ## not actually hold -- and scrub would then report a mismatch on a
        ## block that was never wrong. Reading back what was really written
        ## costs one block copy and cannot disagree with the disk.
        self._record_csum(blk_addr)

    ## _csum_region — The checksum region for this volume, or nil if it has none.
    ## Built once and cached; a volume formatted before the region existed has
    ## csum_start_blk == 0 and never gets one.
    proc _csum_region(self):
        if self.csum_region_cache != nil:
            return self.csum_region_cache
        if self.sb == nil:
            return nil
        if self.sb.csum_start_blk <= 0 or self.sb.csum_block_count <= 0:
            return nil
        self.csum_region_cache = csum.CsumRegion(self.image_buf, self._init_block_size(),
                                                self.sb.csum_start_blk, self.sb.csum_block_count)
        return self.csum_region_cache

    ## _record_csum — Store the checksum of one block. Silent no-op without a region.
    proc _record_csum(self, blk_addr: Int):
        let r = self._csum_region()
        if r == nil:
            return
        ## Never checksum the region itself: writing an entry changes the block
        ## that holds it, so its own recorded checksum would be stale the moment
        ## it was stored, and every scrub would flag the region as corrupt.
        if blk_addr >= self.sb.csum_start_blk:
            return
        r.record(blk_addr, self.sb.checksum_algo)

    proc _alloc_block_addr(self, temperature: String) -> Dict:
        let result = self.allocator.allocate_data_block(temperature)
        if not result.is_success():
            return nil
        let info = {}
        info["nid"] = result.nid
        info["physical_blk"] = result.physical_blk
        info["segno"] = result.segno
        info["block_offset"] = result.block_offset
        return info

    proc _alloc_node_block_addr(self, temperature: String) -> Dict:
        let result = self.allocator.allocate_node_block(temperature)
        if not result.is_success():
            return nil
        let info = {}
        info["nid"] = result.nid
        info["physical_blk"] = result.physical_blk
        info["segno"] = result.segno
        info["block_offset"] = result.block_offset
        return info

    proc mount(self) -> Bool:
        var raw: Bytes = bytes()

        if imgio._is_block_device(self.image_path):
            let header = imgio.read_image_exact(self.image_path, superblock.SUPERBLOCK_HEADER_SIZE)
            if bytes_len(header) < 428:
                print("VFS: image too small (" + str(bytes_len(header)) + " bytes)")
                return false
            self.sb = superblock.deserialize_superblock(header)
            if self.sb.magic != superblock.SAGEFS_MAGIC:
                print("VFS: bad magic 0x" + str(self.sb.magic) + " (expected 0x" + str(superblock.SAGEFS_MAGIC) + ")")
                return false
            let needed = self.sb.image_size
            let bs = self._init_block_size()
            let area_end = self.sb.inode_entry_start_blk * bs + self.sb.inode_entry_byte_size
            if area_end > needed:
                needed = area_end
            if needed < superblock.SUPERBLOCK_HEADER_SIZE:
                needed = superblock.SUPERBLOCK_HEADER_SIZE
            raw = imgio.read_image_exact(self.image_path, needed)
        else:
            ## Read the metadata area, not the whole image.
            ##
            ## A whole-file read returns nil past 100 MiB, with no error, so a
            ## full-volume image opens as length 0 and the mount reports a bad
            ## superblock magic on a perfectly good volume. The metadata area is
            ## the superblock plus the reserved inode-entry region, which is what
            ## everything below indexes into -- so read that much, as a range, and
            ## leave the data blocks alone.
            ##
            ## The superblock has to be parsed off the header before the size is
            ## known, so that read comes first and the rest is sized from it.
            let header = imgio.read_image_range(self.image_path, 0, superblock.SUPERBLOCK_HEADER_SIZE)
            if bytes_len(header) < 428:
                print("VFS: image too small (" + str(bytes_len(header)) + " bytes)")
                return false
            self.sb = superblock.deserialize_superblock(header)
            if self.sb.magic != superblock.SAGEFS_MAGIC:
                print("VFS: bad magic 0x" + str(self.sb.magic) + " (expected 0x" + str(superblock.SAGEFS_MAGIC) + ")")
                return false
            let rneeded = self.sb.inode_entry_start_blk * self.sb.block_size + self.sb.inode_entry_byte_size
            if self.sb.image_size > rneeded:
                rneeded = self.sb.image_size
            if rneeded < superblock.SUPERBLOCK_HEADER_SIZE:
                rneeded = superblock.SUPERBLOCK_HEADER_SIZE
            raw = imgio.read_image_range(self.image_path, 0, rneeded)

        if bytes_len(raw) < 428:
            print("VFS: image too small (" + str(bytes_len(raw)) + " bytes)")
            return false
        self.sb = superblock.deserialize_superblock(raw)
        if self.sb.magic != superblock.SAGEFS_MAGIC:
            print("VFS: bad magic 0x" + str(self.sb.magic) + " (expected 0x" + str(superblock.SAGEFS_MAGIC) + ")")
            return false

        self.image_buf = raw
        self.blocks_growable = true

        let bs = self._init_block_size()
        let total_blks = self._init_total_blocks()
        let seg_sz = self._init_segment_size()
        let main_start = self.sb.main_start_blk
        let nat_start = self.sb.nat_start_blk
        let sit_start = self.sb.sit_start_blk
        let total_segs = int(total_blks / seg_sz)
        let nat_blocks = 64
        let total_nat_blocks_val = nat_blocks

        if self.segment == nil:
            let main_start_blk_val = main_start
            if main_start_blk_val <= 0:
                main_start_blk_val = 8
            self.segment = seg_module.SegmentManager(total_segs, bs, main_start_blk_val)

        if self.nat == nil:
            let nat_start_blk_val = nat_start
            if nat_start_blk_val <= 0:
                nat_start_blk_val = 2
            self.nat = nat_module.NodeAddressTable(nat_start_blk_val, total_nat_blocks_val)

        if self.allocator == nil:
            self.allocator = alloc_module.BlockAllocator(self.segment, self.nat, bs, total_blks)

        ## Load the segment information table before anything can allocate.
        ##
        ## The segment manager keeps a per-block validity bitmap and
        ## allocate_block() maintains it correctly, but nothing wrote it out, so
        ## every segment came back with an empty bitmap on the next mount and the
        ## first allocation after a remount could return a block the previous
        ## session was still using for live data. The overwrite is silent -- the
        ## file's extents and inode entry are untouched, so it keeps its length
        ## and reads back whatever now occupies its blocks. Without this the
        ## inode table's per-mount CoW allocates enough to hit that collision, and
        ## a file loses its contents while still reporting the right size.
        if not self.sit_loaded:
            self.sit_loaded = true
            self.sit_entries_loaded = self.segment.load_sit(self.image_buf, self.sb.sit_start_blk, bs)

        if self.inode == nil:
            self.inode = inode_module.InodeManager(self.nat)
            let root_inode_val = self.inode.create_root()
            if root_inode_val != nil:
                let rkey = inode_module.INODE_FLAG_INLINE_DENTRY
                root_inode_val.set_flag(rkey)

        if self.btree == nil:
            ## Use the root recorded at unmount. This used to be hardcoded to
            ## BTreeEngine(self, 0, 1) -- root block 0, which the tree itself
            ## treats as "empty" -- so every remount began with an empty extent
            ## map and every block-mapped file read back as zero bytes. The root
            ## is written back in unmount() below.
            self.btree = btree_module.BTreeEngine(self, self.sb.extent_root_blk,
                                                  self.sb.extent_generation + 1)

        if self.extent == nil:
            self.extent = extent_module.ExtentTree(self.btree, self._init_block_size())

        if self.itable == nil:
            ## Separate root and generation from the extent map -- see the note on
            ## self.itable in init(). Generation is advanced on every mount, the
            ## same way the extent tree's is, so that a mount never mutates nodes
            ## a previous generation may still be referenced by. Inode
            ## availability at mount is decided by reading the tree, not by
            ## trusting the recorded root: a volume whose root block reads back
            ## as a valid node is read from the tree, and anything else falls
            ## back to the legacy area.
            ## Opened at the recorded generation, not recorded + 1: the table
            ## advances its own CoW generation when it is first written, so a
            ## mount that changes nothing allocates nothing. See
            ## InodeTable.ensure_writable().
            let inode_engine = btree_module.BTreeEngine(self, self.sb.inode_root_blk,
                                                       self.sb.inode_root_generation)
            self.itable = it_module.InodeTable(inode_engine)

        if self.dir == nil:
            self.dir = dir_module.DirManager()

        if self.aio == nil:
            self.aio = aio_module.AsyncIOEngine()

        if self.cache == nil:
            self.cache = cache_module.CacheManager(1024, 1024, 512)

        if self.journal == nil:
            ## Use the region the layout reserved, not blocks 0-15. Those are the
            ## superblock, its mirror, both checkpoint packs and the whole
            ## inode-entry area, and Journal.sync() rewrites its buffer from
            ## start_blk -- so every commit after a non-inline write stamped the
            ## journal's magic over the superblock. It went unnoticed because
            ## unmount() re-serialises the superblock afterwards; a crash in
            ## between left an unreadable volume. A volume with no reserved
            ## region (written before format v1.3) gets a disabled journal.
            self.journal = Journal(self, self.sb.journal_start_blk,
                                   self.sb.journal_block_count, bs)

        if self.txmgr == nil:
            self.txmgr = txn_module.TransactionManager(self.journal, self)

        if self.gc == nil:
            self.gc = gc_module.GarbageCollector(self.segment, self.allocator)

        if self.snapshot == nil:
            self.snapshot = snap_module.SnapshotEngine()

        if self.compress == nil:
            self.compress = compress_module.CompressionEngine()

        if self.dedup == nil:
            self.dedup = dedup_module.DedupEngine()

        if self.encrypt == nil:
            self.encrypt = encrypt_module.EncryptionLayer("")

        if self.raid == nil:
            self.raid = raid_module.RaidEngine(0)

        if self.xattr == nil:
            self.xattr = xattr_module.XAttrManager()

        self.nat.prefill_free_nids(128)

        ## Inode metadata (format v1.5).
        ##
        ## Read the tree when it has a root that really holds a node. A volume
        ## formatted before v1.5 has inode_root_blk == 0 and its metadata in the
        ## fixed area, so it is read from there and rewritten into the tree by the
        ## first _persist_all(). A volume with a non-zero root whose block is not
        ## a node has lost its metadata index; that is reported rather than
        ## silently mounting empty, and the area is tried as a last resort.
        let area_start = self.sb.inode_entry_start_blk * bs
        let area_size = self.sb.inode_entry_byte_size
        ## Grow the image so the reserved area is actually present before reading
        ## it. mkfs pads the image out to image_size, but a caller can hand us a
        ## bare superblock, and the area then starts past the end of the buffer.
        ## bytes_get() answers an out-of-range index with nil rather than
        ## failing, so that surfaced much later as "number + nil" from inside
        ## read_inode_entries_from_area() with nothing pointing at the real
        ## cause. A short image should read as an empty reserved area.
        self._ensure_image_size(area_start + area_size)

        var use_tree = self.itable.is_readable()
        var named_entries: Array = []
        var inline_entries: Array = []
        if use_tree:
            let tree_entries = self.itable.scan()
            ## A readable root with no entries means the index was damaged after
            ## all -- a node with the right magic is always the result of at least
            ## one insert, so an empty walk is not a legitimate state. Fall back
            ## to the area rather than coming up with no inodes at all.
            if len(tree_entries) == 0:
                print("SageFS: inode tree at block " + str(self.itable.root_block()) +
                      " is readable but empty; falling back to the legacy inode area.")
                use_tree = false
            else:
                var ti = 0
                while ti < len(tree_entries):
                    let te = tree_entries[ti]
                    push(inline_entries, te)
                    push(named_entries, te)
                    ti = ti + 1
        else:
            if self.itable.root_block() != 0:
                print("SageFS: inode tree root at block " + str(self.itable.root_block()) +
                      " does not hold a B-tree node; inode metadata is damaged.")
            if area_size > 0:
                let legacy_entries = imgio.read_inode_entries_from_area(self.image_buf, area_start, area_size)
                var li = 0
                while li < len(legacy_entries):
                    let le = legacy_entries[li]
                    ## Name-carrying entries are directory records rather than
                    ## inode metadata; the two passes below kept them apart, and
                    ## the tree only ever stores the nameless ones.
                    if len(le["name"]) == 0:
                        push(inline_entries, le)
                    else:
                        push(named_entries, le)
                    li = li + 1
                ## Everything read out of the area has to be rewritten into the
                ## tree, so mark the whole in-memory set dirty rather than relying
                ## on the loader below to have noted each one. A partial migration
                ## would leave a volume whose superblock advertises a tree that is
                ## missing inodes, with nothing to indicate which.
                self.inode_area_migration = true
                self.inode.mark_all_dirty()

        var i = 0
        while i < len(inline_entries):
            let le = inline_entries[i]
            let l_name: String = le["name"]
            let l_ino: Int = le["ino"]
            let l_mode: Int = le["mode"]
            let l_size: Int = le["size"]
            let l_data: String = le["data"]
            if len(l_name) == 0:
                let target = self.inode.get_inode(l_ino)
                if target == nil:
                    self._ensure_stub_inode(l_ino, l_mode, l_data, l_size)
                else:
                    ## Loading persisted state is not a modification, so the inode
                    ## is deliberately left clean. Marking it dirty here made every
                    ## inode in the table dirty on every mount, which defeated the
                    ## whole point of the tree: unmount has to write only what
                    ## changed, and with the whole table dirty it wrote the whole
                    ## table -- exactly what the fixed area always did. The area
                    ## path gets its dirty set separately, via mark_all_dirty().
                    target.set_inline_data(l_data)
                    target.size = l_size
            i = i + 1

        i = 0
        while i < len(named_entries):
            let le = named_entries[i]
            let l_name: String = le["name"]
            let l_ino: Int = le["ino"]
            let l_mode: Int = le["mode"]
            let l_size: Int = le["size"]
            let l_data: String = le["data"]
            if len(l_name) > 0:
                if self.dir.lookup(l_name) == -1:
                    self.dir.add_entry(l_name, l_ino, dir_module.DT_REG)
                if self.inode.get_inode(l_ino) == nil:
                    self._ensure_stub_inode(l_ino, l_mode, l_data, l_size)
            i = i + 1

        let root_inode = self.inode.get_inode(ROOT_INO)
        if root_inode != nil and len(root_inode.get_inline_data()) > 0:
            let loaded_dir = self._decode_dir_data(root_inode.get_inline_data())
            let dir_entries = loaded_dir.read_dir()
            for de in dir_entries:
                if self.dir.lookup(de.name) == -1:
                    let ftype: Int = dir_module.DT_DIR
                    if de.file_type == dir_module.DT_REG or de.file_type == dir_module.DT_DIR:
                        ftype = de.file_type
                    self.dir.add_entry(de.name, de.ino, ftype)

        ## Rebuild link counts from the directory tree.
        self._recompute_link_counts()

        ## Everything now in memory came off stable storage, so nothing is dirty.
        ##
        ## The in-memory table starts empty on every mount, so the loader has to
        ## create an inode for each entry it reads -- through _ensure_stub_inode,
        ## which correctly marks what it creates as dirty. But reading the table
        ## is not modifying it, and leaving the whole table dirty meant unmount
        ## rewrote every inode on every mount: the one property the inode table
        ## exists to provide. Migration does not depend on this -- it writes the
        ## full in-memory set, not the dirty set, and sets its own flag above.
        self.inode.checkpoint()

        self.mounted = true
        self.ino_path_cache = {}
        self.cache_ino_path(ROOT_INO, "/")
        ## Inode content cache, keyed by inode number.
        ##
        ## read_inode_data() used to borrow CacheManager.get_node()/put_node(),
        ## which is a *block address* cache -- so file content was filed under an
        ## inode number in the same map that invalidate_node() treats as block
        ## addresses. Worse, nothing ever invalidated it, so a read after a write
        ## returned the content from before that write. Verified: rewriting a file
        ## and reading it back still returned the original bytes.
        ##
        ## Keeping it separate removes the stale read and the conflated key space.
        ## Every path that changes an inode's content must call
        ## _invalidate_content().
        self.content_cache = {}
        return true

    ## ino_path_cache — reverse map ino → cached path for FUSE operations

    proc cache_ino_path(self, ino: Int, path: String):
        self.ino_path_cache[str(ino)] = path

    proc resolve_ino(self, ino: Int) -> String:
        let key: String = str(ino)
        if dict_has(self.ino_path_cache, key):
            return self.ino_path_cache[key]
        return ""

    proc _ensure_stub_inode(self, ino: Int, mode: Int, inline_data: String, size: Int):
        if self.inode.get_inode(ino) != nil:
            return
        let nid: Int = self.inode.nat_table.allocate_nid()
        let stub = inode_module.SageFSInode(ino, nid, mode)
        stub.uid = 0
        stub.gid = 0
        let S_IFDIR_VAL: Int = 0x4000
        let S_IFMT_VAL: Int = 0xF000
        if (mode & S_IFMT_VAL) == S_IFDIR_VAL:
            stub.nlink = 2
            stub.set_flag(inode_module.INODE_FLAG_INLINE_DENTRY)
        if len(inline_data) > 0:
            stub.set_inline_data(inline_data)
        ## Size must be restored whether or not there is inline data. A
        ## block-mapped file has an empty inline payload and a non-zero size, so
        ## gating this on the payload left every such file reporting size 0
        ## after a remount even though the correct size was sitting in the
        ## inode-entry area on disk.
        stub.size = size
        self.inode.inodes[str(ino)] = stub
        self.inode.dirty_inodes[str(ino)] = true
        ## Keep the allocator ahead of the inode we just restored.
        self.inode.note_inode(ino)

    proc _recompute_link_counts(self):
        ## Recompute every inode's nlink from the directory tree.
        ##
        ## nlink is not on disk. The on-disk inode entry is a 16-byte header of
        ## ino/mode/size/name_len/data_len followed by the name and the payload,
        ## so there is nowhere to store a link count -- write_inode_entry_at()
        ## takes no nlink argument and the reader has nothing to restore it from.
        ## A remount therefore reset every count to whatever the loader defaults
        ## to, and a directory's count never came back.
        ##
        ## Rather than widen the entry format for a value that is entirely
        ## derivable, mount() recomputes it: a file's count is the number of
        ## directory entries naming it, and a directory's is 2 ("." plus its
        ## parent's entry) plus its subdirectory count. This is the same rule
        ## fsck checks, so the two agree by construction rather than by luck.
        let refs: Dict[Int, Int] = {}
        let subdirs: Dict[Int, Int] = {}
        let visited: Dict[Int, Bool] = {}
        self._walk_link_counts(ROOT_INO, refs, subdirs, visited)

        let all_inos: Array = self.inode.list_inodes()
        for ino in all_inos:
            let inode_obj = self.inode.get_inode(ino)
            if inode_obj == nil:
                continue
            var want: Int = 0
            if inode_obj.is_dir():
                want = 2
                if dict_has(subdirs, ino):
                    want = want + subdirs[ino]
            elif dict_has(refs, ino):
                want = refs[ino]
            if inode_obj.nlink != want:
                inode_obj.nlink = want
                ## Deliberately not marked dirty. A link count is derived from
                ## the directory tree, and the on-disk inode entry has no field
                ## for it -- encode_inode_entry() stores ino, mode, size and data
                ## and nothing else. So there is no nlink on disk to bring up to
                ## date, and writing the inode because the derived value changed
                ## would dirty every inode on every mount: recomputation always
                ## differs from the default a freshly loaded inode carries, so
                ## the whole table looked modified and unmount rewrote all of it.
                ## That is precisely the cost the inode table exists to remove.

    proc _walk_link_counts(self, ino: Int, refs: Dict[Int, Int], subdirs: Dict[Int, Int],
                           visited: Dict[Int, Bool]):
        if dict_has(visited, ino):
            return
        visited[ino] = true
        subdirs[ino] = 0
        let inode_obj = self.inode.get_inode(ino)
        if inode_obj == nil or not inode_obj.is_dir():
            return
        let children: Array = self.inode.read_dir_entries(ino)
        for entry in children:
            if dict_has(refs, entry.ino):
                refs[entry.ino] = refs[entry.ino] + 1
            else:
                refs[entry.ino] = 1
            if entry.file_type == dir_module.DT_DIR:
                subdirs[ino] = subdirs[ino] + 1
            self._walk_link_counts(entry.ino, refs, subdirs, visited)

    proc _persist_all(self):
        ## Write dirty inode metadata into the inode B+ tree (format v1.5).
        ##
        ## This replaces the fixed-area writer, which packed every inode's
        ## metadata as hex text into 32 KiB of reserved blocks and dropped
        ## whatever did not fit -- reporting how many it dropped on stdout, which
        ## is not something a filesystem should do silently or at all. The ceiling
        ## was architectural rather than a matter of tuning: it could not be
        ## raised without another on-disk format change, and a volume with
        ## metadata past 32 KiB simply could not be represented.
        ##
        ## Only dirty inodes are written, which is what makes the tree worth
        ## having: mount does not have to rewrite the whole table to change one
        ## file, so unmount cost tracks what changed rather than how much exists.
        if self.itable == nil:
            return
        ## Migrating from the area: the tree has to end up holding every inode, not
        ## just the ones that happen to be dirty, or the next mount reads a
        ## complete-looking tree that is quietly missing the rest.
        let full_set = self.inode_area_migration
        let candidates = self.inode.list_inodes()

        ## Inodes that exist in memory right now. Used to find tree entries whose
        ## inode has been deleted.
        ##
        ## Deletions have to be found by diffing, not by iterating the in-memory
        ## set: a deleted inode is *absent* from list_inodes(), so a loop over it
        ## never visits the number and the stale entry stays in the tree. The area
        ## writer did not have this problem only because it rewrote the whole
        ## area and zeroed the remainder, so absence was implicit.
        let live: Dict = {}
        for ino in candidates:
            live[str(ino)] = true

        var removed = 0
        if not full_set:
            ## Read the tree's keys and drop any that no longer have an inode.
            ## A scan, not a write, so it costs far less than the fixed area
            ## writer did -- but it is still O(inodes) at unmount, and the honest
            ## way to avoid even that is for the deletion paths to remove from the
            ## table as they unlink, which is not wired up yet.
            let existing = self.itable.scan()
            for e in existing:
                let eino: Int = e["ino"]
                if not dict_has(live, str(eino)):
                    self.itable.remove(eino)
                    removed = removed + 1

        ## What to write. Normally only the dirty set, which is the whole reason
        ## the tree is worth having: the fixed area had to rewrite every inode on
        ## every unmount because there was nowhere else to put them. During a
        ## migration from the area the set has to be the whole table, since the
        ## tree starts empty and a partial copy would look like a complete one.
        ##
        ## Both lists are inode objects. list_inodes() returns inode *numbers*,
        ## so a migration cannot reuse it directly -- doing so fed integers into a
        ## loop that calls get_inline_data() on each element.
        let to_write: Array = self.inode.get_dirty_inodes()
        if full_set:
            to_write = []
            for ino in candidates:
                let obj = self.inode.get_inode(ino)
                if obj != nil:
                    push(to_write, obj)

        var written = 0
        for inode_obj in to_write:
            if inode_obj == nil:
                continue
            self.itable.put(inode_obj.ino, inode_obj.mode, inode_obj.size, "",
                            inode_obj.get_inline_data())
            written = written + 1
        if full_set:
            self.inode_area_migration = false
        self.inode.checkpoint()
        self.inode_entries_written = written
        self.inodes_removed = removed

    proc unmount(self) -> Bool:
        if not self.mounted:
            return false
        self._persist_all()
        self.sb.image_size = bytes_len(self.image_buf)

        ## Record where the extent tree lives, so the next mount can find it.
        ## Done before serialize() below, since that is what lands on disk.
        if self.extent != nil and self.extent.btree != nil:
            self.sb.extent_root_blk = self.extent.btree.root_block
            self.sb.extent_generation = self.extent.btree.current_generation

        ## Same for the inode tree, which has its own root and generation and is
        ## written independently of the extent map.
        ##
        ## A volume that has an inode tree is a v1.5 volume, so the version is
        ## recorded as one. It has to be written here rather than left at whatever
        ## was read: deserialize gates the root fields on version_minor >= 5, so a
        ## volume migrated from the area but still stamped 1.4 would have its root
        ## zeroed again on the next mount, hiding the tree it had just built and
        ## sending it back to the area -- which by then no longer holds the file
        ## that had been migrated out of it.
        if self.itable != nil:
            self.itable.save_root(self.sb)
            if self.itable.root_block() != 0:
                self.sb.version_minor = superblock.SAGEFS_VERSION_MINOR

        ## Write the segment validity bitmap back out, after all allocation has
        ## finished for this mount. The next mount reads it in mount() and will
        ## not hand these blocks to anything else. A bitmap that cannot be
        ## written leaves the previous one in place, which is stale rather than
        ## correct -- so say so rather than failing the unmount over it.
        if self.sit_loaded and self.segment != nil:
            let bs_u = self._init_block_size()
            let sit_written = self.segment.save_sit(self.image_buf, self.sb.sit_start_blk, bs_u)
            if sit_written == 0:
                print("SageFS: segment validity table could not be written; the next mount may " +
                      "reuse blocks this session allocated.")

        let sb_bytes = self.sb.serialize()
        let bs = self._init_block_size()
        var i = 0
        while i < bytes_len(sb_bytes) and i < bs:
            bytes_set(self.image_buf, i, bytes_get(sb_bytes, i))
            i = i + 1
        self.mounted = false
        self.fds = []
        self.next_fd = 0
        imgio.write_image(self.image_path, self.image_buf)
        return true

    proc _bytes_to_hex(self, buf: Bytes) -> String:
        var hex: String = ""
        var i: Int = 0
        let hex_chars: String = "0123456789abcdef"
        while i < bytes_len(buf):
            let b: Int = bytes_get(buf, i)
            hex = hex + hex_chars[(b >> 4) & 0xF]
            hex = hex + hex_chars[b & 0xF]
            i = i + 1
        return hex

    proc _hex_to_bytes(self, hex: String) -> Bytes:
        let result: Bytes = bytes()
        var i: Int = 0
        let hlen: Int = len(hex)
        while i + 1 < hlen:
            var hi: Int = 0
            var lo: Int = 0
            let c1: Int = ord(hex[i])
            if c1 >= 48 and c1 <= 57:
                hi = c1 - 48
            elif c1 >= 97 and c1 <= 102:
                hi = c1 - 97 + 10
            let c2: Int = ord(hex[i + 1])
            if c2 >= 48 and c2 <= 57:
                lo = c2 - 48
            elif c2 >= 97 and c2 <= 102:
                lo = c2 - 97 + 10
            bytes_push(result, (hi << 4) | lo)
            i = i + 2
        return result

    proc _decode_dir_data(self, inline_data: String) -> Any:
        ## Decoding now lives in DirManager.deserialize(), next to the format
        ## definition, rather than being inlined here. This loop also used to
        ## guard with `off + 8 <= bytes_len` against a 7-byte header, so it
        ## silently dropped a final zero-name entry instead of reporting damage.
        let dir_mgr = dir_module.DirManager()
        dir_mgr.deserialize(self._hex_to_bytes(inline_data))
        return dir_mgr

    proc _get_dir(self, ino: Int) -> Any:
        if ino == ROOT_INO:
            return self.dir
        let inode_obj = self.inode.get_inode(ino)
        if inode_obj == nil:
            return nil
        if not inode_obj.is_dir():
            return nil
        let inline_data = inode_obj.get_inline_data()
        return self._decode_dir_data(inline_data)

    proc _dir_has_room(self, parent_ino: Int, name: String) -> Bool:
        ## Whether one more entry of this size can still be recorded in a directory.
        ##
        ## A directory is stored as one hex blob in its own inode, capped by
        ## INLINE_DATA_MAX, and _save_dir() cannot record anything past that --
        ## set_inline_data() refuses and changes nothing, so the directory stops
        ## being saved altogether. That made this a lie: create_file() would
        ## accept the 95th name, hand back a working descriptor, write to it, and
        ## then lose the name on unmount, leaving a file in the inode table that
        ## nothing could reach.
        ##
        ## Checking before the entry is added turns that into an early, visible
        ## refusal. It does not lift the ceiling -- directory entries need their
        ## own index for that -- but a caller that is told "no" still has its
        ## file, whereas one that is told "yes" and loses the name does not.
        let entries = self.dir.read_dir()
        ## Same 2-byte header and per-entry encoding _save_dir() writes:
        ## 4 bytes of ino, 2 of name length, 1 of file type, then the name.
        let need = 2 + len(entries) * (7 + len(name)) + 2
        let hex_len = 2 * need
        return hex_len <= inode_module.INLINE_DATA_MAX

    proc _save_dir(self, ino: Int, dir_mgr: Any):
        let inode_obj = self.inode.get_inode(ino)
        if inode_obj == nil:
            return
        let entries = dir_mgr.read_dir()
        let data_bytes = bytes()
        let entry_count = len(entries)
        bytes_push(data_bytes, entry_count & 0xFF)
        bytes_push(data_bytes, (entry_count >> 8) & 0xFF)
        for entry in entries:
            let name_bytes = bytes(entry.name)
            let name_len = bytes_len(name_bytes)
            bytes_push(data_bytes, entry.ino & 0xFF)
            bytes_push(data_bytes, (entry.ino >> 8) & 0xFF)
            bytes_push(data_bytes, (entry.ino >> 16) & 0xFF)
            bytes_push(data_bytes, (entry.ino >> 24) & 0xFF)
            bytes_push(data_bytes, name_len & 0xFF)
            bytes_push(data_bytes, (name_len >> 8) & 0xFF)
            bytes_push(data_bytes, entry.file_type & 0xFF)
            var j = 0
            while j < name_len:
                bytes_push(data_bytes, bytes_get(name_bytes, j))
                j = j + 1
        let hex_data: String = self._bytes_to_hex(data_bytes)
        ## A directory that no longer fits inline must not be dropped in silence.
        ##
        ## set_inline_data() refuses anything over INLINE_DATA_MAX (3400) and
        ## returns false having changed nothing, so the inode kept whatever it
        ## already had and the directory stopped being recorded at all. The
        ## inodes were still written to the inode table, so the files existed and
        ## were unreachable by name: a "fileNNN.txt" entry costs 36 hex
        ## characters, so 3400 / 36 puts the ceiling at 94 entries in one
        ## directory. Anything past that was accepted, handed a file descriptor,
        ## and then lost on unmount with no error anywhere.
        if not inode_obj.set_inline_data(hex_data):
            if not self.dir_overflow_reported:
                self.dir_overflow_reported = true
                print("SageFS: directory for inode " + str(ino) + " no longer fits inline (" +
                      str(len(hex_data)) + " > " + str(inode_module.INLINE_DATA_MAX) +
                      " chars of hex). Its entries are NOT being saved, and files created in it " +
                      "will not survive a remount. Directory entries need their own index.")
        self.inode.update_inode(ino)
        ## No direct write to the image here.
        ##
        ## This used to write the entry at the fixed offset inode_entry_start_blk,
        ## ignoring `ino`, so every directory saved over the same first slot --
        ## and with no bounds check in write_inode_entry_at, a large listing would
        ## have run off the end of the reserved area. It was also redundant:
        ## set_inline_data() puts the listing on the inode, and _persist_all()
        ## writes every inode's inline data sequentially at unmount. Nested
        ## directories persisted correctly throughout, which is why removing the
        ## write changes no behaviour -- the stray write was being overwritten
        ## moments later regardless.

    proc split_path(self, path: String) -> Array[String]:
        var result: Array[String] = []
        var i: Int = 0
        var seg: String = ""
        while i < len(path):
            if path[i] == "/":
                if len(seg) > 0:
                    push(result, seg)
                    seg = ""
            else:
                seg = seg + path[i]
            i = i + 1
        if len(seg) > 0:
            push(result, seg)
        return result

    proc resolve_path(self, path: String) -> Int:
        if not self.mounted:
            return -1
        if path == "/" or path == "":
            return ROOT_INO
        let parts = self.split_path(path)
        var current_ino = ROOT_INO
        var current_dir = self.dir
        for part in parts:
            if current_dir == nil:
                return -1
            let entry_ino = current_dir.lookup(part)
            if entry_ino == -1:
                return -1
            current_ino = entry_ino
            let entry_inode = self.inode.get_inode(current_ino)
            if entry_inode != nil and entry_inode.is_dir():
                current_dir = self._get_dir(current_ino)
            else:
                current_dir = nil
        return current_ino

    proc _lookup_in_parent(self, path: String) -> Dict:
        let result = {}
        result["parent_ino"] = ROOT_INO
        result["name"] = path
        let parts = self.split_path(path)
        if len(parts) == 0:
            result["parent_ino"] = ROOT_INO
            result["name"] = ""
            return result
        let name = parts[len(parts) - 1]
        result["name"] = name
        if len(parts) == 1:
            result["parent_ino"] = ROOT_INO
        else:
            var parent_path = ""
            var i = 0
            while i < len(parts) - 1:
                parent_path = parent_path + "/" + parts[i]
                i = i + 1
            if parent_path == "":
                parent_path = "/"
            result["parent_ino"] = self.resolve_path(parent_path)
        return result

    proc open(self, path: String, flags: Int) -> Int:
        if not self.mounted:
            return -1
        let ino: Int = self.resolve_path(path)
        if ino == -1:
            if (flags & O_CREAT) != 0:
                return self.create_file(path, flags)
            return -1
        if self.next_fd >= MAX_FDS:
            return -1
        ## O_TRUNC is only honoured for a descriptor that may write.
        ##
        ## Linux ignores O_TRUNC on a read-only descriptor, and so should we.
        ## This is not a theoretical guard: a caller that references an O_*
        ## constant off an instance (`fs.O_RDONLY`) rather than off the module
        ## (`vfs.O_RDONLY`) ends up passing unusable flags, and those satisfied
        ## `(flags & O_TRUNC) != 0` while still looking read-only. That truncated
        ## a file to zero bytes on a read-only open, and _persist_all() then
        ## skipped the inode for having no size, so the file's entry was dropped
        ## from the superblock entirely. Requiring write access first means a
        ## read-only open can never destroy data.
        if (flags & O_TRUNC) != 0 and (flags & O_ACCMODE) != O_RDONLY:
            let inode_obj = self.inode.get_inode(ino)
            if inode_obj != nil:
                inode_obj.size = 0
                self.inode.update_inode(ino)
        let fd: Int = self.next_fd
        self.next_fd = self.next_fd + 1
        push(self.fds, FileDescriptor(ino, flags, 0))
        return fd

    proc close(self, fd: Int) -> Bool:
        if fd < 0 or fd >= len(self.fds) or self.fds[fd] == nil:
            return false
        self.fds[fd] = nil
        return true

    proc read(self, fd: Int, size: Int) -> Bytes:
        if fd < 0 or fd >= len(self.fds) or self.fds[fd] == nil:
            return bytes()
        let f: FileDescriptor = self.fds[fd]
        if (f.flags & O_ACCMODE) == O_WRONLY:
            return bytes()
        let data: Bytes = self.read_inode_data(f.ino)
        let n: Int = bytes_len(data)
        if f.pos >= n:
            return bytes()
        let avail: Int = n - f.pos
        let to_read: Int = size
        if to_read > avail:
            to_read = avail
        let result: Bytes = bytes()
        var i: Int = 0
        while i < to_read:
            bytes_push(result, bytes_get(data, f.pos + i))
            i = i + 1
        f.pos = f.pos + to_read
        return result

    ## Move an inline file's contents into data blocks.
    ##
    ## Called when a file stored inline outgrows INLINE_DATA_MAX. Bytes written
    ## while inline live in the inode, not in any block, so falling straight
    ## through to the block path would strand them and the file would read back
    ## with a hole at the front.
    ##
    ## Deliberately does not open a transaction: the block path in write() opens
    ## one immediately afterwards, and nesting them is not something I have
    ## verified. A failure part-way leaves the blocks already written with their
    ## extents recorded, so the file stays self-consistent and shorter than
    ## intended rather than corrupt; the caller turns it into -1.
    proc _migrate_inline_to_blocks(self, ino: Int, inode_obj) -> Bool:
        let content: Bytes = self._hex_to_bytes(inode_obj.get_inline_data())
        inode_obj.clear_inline_data()
        self._invalidate_content(ino)
        let total: Int = bytes_len(content)
        if total <= 0:
            return true
        let bs = self._init_block_size()
        var placed: Int = 0
        while placed < total:
            let chunk_len: Int = bs
            if total - placed < bs:
                chunk_len = total - placed
            let alloc_info = self._alloc_block_addr("warm")
            if alloc_info == nil:
                return false
            let phys_blk: Int = alloc_info["physical_blk"]
            var chunk: Bytes = bytes(chunk_len)
            var c: Int = 0
            while c < chunk_len:
                bytes_set(chunk, c, bytes_get(content, placed + c))
                c = c + 1
            self._write_block(phys_blk, chunk)
            self.extent.insert_extent(ino, placed, phys_blk, chunk_len)
            placed = placed + chunk_len
        return true

    proc write(self, fd: Int, data: Bytes) -> Int:
        if fd < 0 or fd >= len(self.fds) or self.fds[fd] == nil:
            return -1
        let f: FileDescriptor = self.fds[fd]
        if (f.flags & O_ACCMODE) == O_RDONLY:
            return -1
        let inode_obj = self.inode.get_inode(f.ino)
        if inode_obj == nil:
            return -1
        let written: Int = bytes_len(data)
        if written == 0:
            return 0
        let new_size = f.pos + written
        ## Storage class is decided by the file's current state, not by the size of
        ## this particular write.
        ##
        ## The test used to be `is_inline() or new_size <= INLINE_DATA_MAX`, so a
        ## 16-byte write at offset 0 of an 8192-byte block-mapped file took the
        ## inline path: the file was rewritten as inline data and its size was
        ## set to len(new_data) == 16. The other 8178 bytes were gone, and
        ## read_inode_data() afterwards returned 16 bytes. Any small edit to a
        ## large file destroyed it.
        ##
        ## A file that already has extents stays block-mapped; a file with no
        ## extents yet may still become inline if it is small.
        var has_extents = false
        if self.extent != nil:
            has_extents = len(self.extent._collect_extents(f.ino)) > 0
        ## Inline payloads are hex, so N bytes occupy 2N characters and
        ## INLINE_DATA_MAX bounds N at half that. Testing the byte count instead
        ## meant set_inline_data() refused anything past 3400 bytes -- and its
        ## return value was ignored here. Writing 3000 bytes and then 1000 more
        ## reported 3000 and 1000 written, then read back 3000. A file that
        ## outgrew the inline limit lost everything past it, silently.
        let fits_inline: Bool = (new_size * 2) <= inode_module.INLINE_DATA_MAX
        ## A file that already has extents stays block-mapped: its bytes live in
        ## blocks, and routing it through the inline path would mean reassembling
        ## the whole file only to re-encode it.
        if fits_inline and not has_extents:
            let current: Bytes = self._hex_to_bytes(inode_obj.get_inline_data())
            ## Merge in bytes, not characters.
            ##
            ## This built the payload with `new_data + chr(byte)`. chr(0) is an
            ## empty String because Strings are NUL-terminated, so a zero byte in
            ## the written data vanished, and size was then set from the truncated
            ## string. Writing [65,0,66,67] reported 4 written and read back 3.
            var merged: Bytes = bytes(new_size)
            var i = 0
            while i < f.pos and i < bytes_len(current):
                bytes_set(merged, i, bytes_get(current, i))
                i = i + 1
            ## Bytes beyond the old end stay zero, which is what the chr(0) padding
            ## loop was trying to express.
            i = 0
            while i < written:
                bytes_set(merged, f.pos + i, bytes_get(data, i))
                i = i + 1
            let hex_data: String = self._bytes_to_hex(merged)
            if not inode_obj.set_inline_data(hex_data):
                ## fits_inline makes this unreachable, but a silent refusal would
                ## drop the write entirely, so fail loudly instead.
                return -1
            ## size is a byte count. set_inline_data() assigns len(data), which is
            ## twice the truth for hex.
            inode_obj.size = new_size
            self._invalidate_content(f.ino)
        else:
            if inode_obj.is_inline() and not has_extents:
                if not self._migrate_inline_to_blocks(f.ino, inode_obj):
                    return -1
            ## Spread the write across as many blocks as it needs.
            ##
            ## This used to allocate a single block, hand the whole buffer to
            ## _write_block() -- which copies at most one block's worth -- and
            ## record an extent of length 1. So a write larger than the block
            ## size kept only its first 4 KiB and still reported the full byte
            ## count as written, and the inode's size was set to the full length.
            ## Nothing reported an error: the data was simply gone, and a
            ## subsequent read returned a short file.
            self.txmgr.begin()
            let bs = self._init_block_size()
            var placed = 0
            var failed = false
            while placed < written:
                let chunk_len = bs
                if written - placed < bs:
                    chunk_len = written - placed
                ## Overwrite in place when the target offset is already mapped.
                ##
                ## This loop used to allocate a fresh block for every chunk of
                ## every write, including writes wholly inside existing data. A
                ## 16-byte edit at offset 0 of an 8192-byte file therefore
                ## allocated a new block, wrote 16 bytes into it, and recorded an
                ## extent of 16 -- orphaning the block that held the other 8178
                ## bytes, which were then gone. Any in-place modification of a
                ## block-mapped file silently destroyed the rest of it.
                ##
                ## Now the extent covering this offset is consulted first, and the
                ## chunk is written into the block that already holds those bytes.
                ## A block is only allocated when the write extends past the last
                ## mapped byte.
                let target_off = f.pos + placed
                var phys_blk = -1
                var allocated_new = false
                let existing = self.extent.lookup_extent(f.ino, target_off)
                if existing != nil:
                    ## Which block inside that extent does this offset land in?
                    let off_in_ext = target_off - existing.file_offset
                    phys_blk = existing.block_addr + int(off_in_ext / bs)
                    ## Only the first `bs - (off_in_ext % bs)` bytes of that block
                    ## belong to the extent, so cap the chunk there.
                    let room = bs - (off_in_ext % bs)
                    if room < chunk_len:
                        chunk_len = room
                if phys_blk < 0:
                    let alloc_info = self._alloc_block_addr("warm")
                    if alloc_info == nil:
                        failed = true
                        break
                    phys_blk = alloc_info["physical_blk"]
                    allocated_new = true
                let chunk = bytes()
                var c = 0
                while c < chunk_len:
                    bytes_push(chunk, bytes_get(data, placed + c))
                    c = c + 1
                self._write_block(phys_blk, chunk)
                ## Only a freshly allocated block needs an extent. Writing in
                ## place leaves the existing extent, which still describes the
                ## whole block correctly -- re-inserting it with this chunk's
                ## length replaced a 4096-byte extent with a 16-byte one, so the
                ## rest of that block stopped being covered and the file lost the
                ## bytes beyond the edit as soon as it was remounted.
                if allocated_new:
                    ## Length is in bytes, not blocks: end_offset() is
                    ## file_offset + length, so passing 1 described every extent as
                    ## covering a single byte. An 8192-byte file came out as two
                    ## extents of length 1 rather than one of 8192, which left the
                    ## extent map -- the authoritative description of a file's
                    ## block layout -- wrong for every block-mapped file.
                    self.extent.insert_extent(f.ino, f.pos + placed, phys_blk, chunk_len)
                placed = placed + chunk_len
            if failed:
                self.txmgr.abort()
                return -1
            ## A write can only extend a file, never shrink it. `new_size` is
            ## f.pos + written, so assigning it directly truncated the file
            ## whenever a write was wholly inside existing data -- a 16-byte edit
            ## at offset 0 of an 8192-byte file left it 16 bytes long even though
            ## the underlying blocks still held the other 8178.
            if new_size > inode_obj.size:
                inode_obj.size = new_size
            self.txmgr.commit()
        self.inode.update_inode(f.ino)
        ## The cached copy of this inode's content is now wrong.
        self._invalidate_content(f.ino)
        f.pos = f.pos + written
        return written

    proc lseek(self, fd: Int, offset: Int, whence: Int) -> Int:
        if fd < 0 or fd >= len(self.fds) or self.fds[fd] == nil:
            return -1
        let f: FileDescriptor = self.fds[fd]
        if whence == SEEK_SET:
            f.pos = offset
        elif whence == SEEK_CUR:
            f.pos = f.pos + offset
        elif whence == SEEK_END:
            let data: Bytes = self.read_inode_data(f.ino)
            f.pos = bytes_len(data) + offset
        if f.pos < 0:
            f.pos = 0
        return f.pos

    proc stat(self, path: String) -> Dict:
        let info: Dict = {}
        let ino: Int = self.resolve_path(path)
        if ino == -1:
            info["exists"] = false
            return info
        info["exists"] = true
        info["ino"] = ino
        if ino == ROOT_INO:
            info["mode"] = S_IFDIR | 0x1ED
            info["size"] = 4096
            info["isdir"] = true
            info["blocks"] = 0
            info["nlink"] = 2
        else:
            let inode_obj = self.inode.get_inode(ino)
            if inode_obj != nil:
                info["mode"] = inode_obj.mode
                info["size"] = inode_obj.size
                info["isdir"] = inode_obj.is_dir()
                info["blocks"] = inode_obj.blocks
                info["nlink"] = inode_obj.nlink
                info["uid"] = inode_obj.uid
                info["gid"] = inode_obj.gid
                info["atime"] = inode_obj.atime
                info["mtime"] = inode_obj.mtime
                info["ctime"] = inode_obj.ctime
            else:
                info["mode"] = S_IFREG | 0x1A4
                let data: Bytes = self.read_inode_data(ino)
                info["size"] = bytes_len(data)
                info["isdir"] = false
                info["blocks"] = 0
                info["nlink"] = 1
        return info

    proc readdir(self, path: String) -> Array[String]:
        var entries: Array[String] = []
        push(entries, ".")
        push(entries, "..")
        let ino = self.resolve_path(path)
        if ino == -1:
            return entries
        let dir_mgr = self._get_dir(ino)
        if dir_mgr == nil:
            return entries
        let dentries = dir_mgr.read_dir()
        for d in dentries:
            push(entries, d.name)
        return entries

    proc mkdir(self, path: String, mode: Int = 493) -> Bool:
        ## 493 == 0o755, the mode create_root() uses for the root directory.
        let pinfo = self._lookup_in_parent(path)
        let parent_ino = pinfo["parent_ino"]
        let name = pinfo["name"]
        if parent_ino == -1 or len(name) == 0:
            return false
        let parent_dir = self._get_dir(parent_ino)
        if parent_dir == nil:
            return false
        if parent_dir.lookup(name) != -1:
            return false
        ## Guard the mode explicitly. With no default this runtime passes nil for
        ## a missing argument instead of raising, so mkdir("/dir") built an inode
        ## with mode = nil: is_dir() was false, _get_dir() returned nil, and
        ## everything downstream failed obscurely -- mkdir("/dir/nested") simply
        ## returned false, and fsck reported a healthy-looking tree as broken.
        if mode == nil:
            mode = 493
        ## Before the inode exists, so a refusal does not leak one.
        if not self._dir_has_room(parent_ino, name):
            return false
        let new_inode = self.inode.create_inode(S_IFDIR | (mode & 0xFFF), 0, 0)
        if new_inode == nil:
            return false
        parent_dir.add_entry(name, new_inode.ino, dir_module.DT_DIR)
        ## A directory's link count is 2 ("." plus its parent's entry) plus one
        ## per subdirectory. create_inode() sets the new directory's own nlink
        ## to 2, but nothing ever raised the *parent's* count, so every directory
        ## carried a stale nlink and `fsck` flagged the link count as an error on
        ## a perfectly healthy filesystem.
        let parent_inode = self.inode.get_inode(parent_ino)
        if parent_inode != nil:
            parent_inode.nlink = parent_inode.nlink + 1
            ## Mutating an inode in place does not mark it dirty. Without this the
            ## new count lives only in memory: unmount persists the dirty set, so
            ## the change was silently lost and the count reverted on remount.
            self.inode.update_inode(parent_ino)
        self._save_dir(parent_ino, parent_dir)
        return true

    proc create_file(self, path: String, flags: Int = 577) -> Int:
        ## 577 == O_WRONLY|O_CREAT|O_TRUNC, the mode a caller opening a new file
        ## for writing would use.
        ##
        ## flags had no default, and this runtime passes nil for a missing
        ## argument rather than raising, so create_file("/x") stored a nil flags
        ## on the FileDescriptor. Every later flag test on that descriptor then
        ## compared against nil.
        let pinfo = self._lookup_in_parent(path)
        let parent_ino = pinfo["parent_ino"]
        let name = pinfo["name"]
        if parent_ino == -1 or len(name) == 0:
            return -1
        let parent_dir = self._get_dir(parent_ino)
        if parent_dir == nil:
            return -1
        if parent_dir.lookup(name) != -1:
            return -1
        ## Check before the inode is created, not after. Refusing once the inode
        ## exists leaves an inode in the table that nothing points at: it is
        ## written to the inode tree on unmount and nothing ever removes it, so a
        ## caller that keeps retrying would grow the table forever.
        if not self._dir_has_room(parent_ino, name):
            return -1
        ## Check for a free descriptor *before* creating anything. This used to
        ## run after the inode was created and the directory entry was saved, so
        ## a full descriptor table returned -1 having already made the file: the
        ## caller saw a failure and retried, and got a second file on the retry
        ## because the first was already there.
        if self.next_fd >= MAX_FDS:
            return -1
        let file_inode = self.inode.create_inode(S_IFREG | 0x1A4, 0, 0)
        if file_inode == nil:
            return -1
        parent_dir.add_entry(name, file_inode.ino, dir_module.DT_REG)
        self._save_dir(parent_ino, parent_dir)
        let fd: Int = self.next_fd
        self.next_fd = self.next_fd + 1
        push(self.fds, FileDescriptor(file_inode.ino, flags, 0))
        return fd

    ## Truncate a file to `size` bytes, updating both the extent map and the
    ## inode. ExtentTree.truncate() fixes the block map; on its own the inode size
    ## still claimed the old length, so stat() and the read path disagreed with
    ## the data actually on disk.
    proc truncate(self, path: String, size: Int) -> Bool:
        let ino: Int = self.resolve_path(path)
        if ino == -1:
            return false
        if size < 0:
            return false
        let inode_obj = self.inode.get_inode(ino)
        if inode_obj == nil:
            return false
        if size > inode_obj.size:
            ## Growing is not supported: there is no block to grow into, and
            ## silently zero-filling would hand the caller data that was never
            ## written. Refuse rather than pretend.
            return false
        if self.extent != nil:
            self.extent.truncate(ino, size)
        inode_obj.size = size
        self.inode.update_inode(ino)
        self._invalidate_content(ino)
        return true

    ## Release the blocks backing a byte range, so a sparse region stops
    ## occupying storage. ExtentTree.punch_hole() already did the block-map half;
    ## nothing on the filesystem API reached it, so blocks could not be freed
    ## through the VFS at all.
    ##
    ## Extents are block-granular, so the range is snapped outward to block
    ## boundaries: a caller asking to release bytes 100..200 cannot keep
    ## block 0 allocated without keeping the bytes 100..200 alive, so a partial
    ## block is freed whole and reads through the hole return zeroes.
    proc punch_hole(self, path: String, offset: Int, length: Int) -> Bool:
        if offset < 0 or length <= 0:
            return false
        let ino: Int = self.resolve_path(path)
        if ino == -1:
            return false
        let inode_obj = self.inode.get_inode(ino)
        if inode_obj == nil:
            return false
        if inode_obj.is_dir():
            return false
        if self.extent == nil:
            return false
        if offset >= inode_obj.size:
            ## Entirely past end of file: nothing is allocated there to release.
            return true
        let bs = self._init_block_size()
        if bs <= 0:
            return false
        ## Do not punch past end of file; the request is clamped, not rejected.
        var end = offset + length
        if end > inode_obj.size:
            end = inode_obj.size
        self.txmgr.begin()
        self.extent.punch_hole(ino, int(offset / bs) * bs,
                               int((end - 1) / bs) * bs + bs - int(offset / bs) * bs)
        self.txmgr.commit()
        ## The inode's size is unchanged -- punching a hole leaves a sparse file,
        ## not a shorter one -- but the blocks behind the range are now gone, so
        ## anything cached for this inode is stale.
        self._invalidate_content(ino)
        return true

    proc unlink(self, path: String) -> Bool:
        let pinfo = self._lookup_in_parent(path)
        let parent_ino = pinfo["parent_ino"]
        let name = pinfo["name"]
        if parent_ino == -1 or len(name) == 0:
            return false
        let parent_dir = self._get_dir(parent_ino)
        if parent_dir == nil:
            return false
        let target_ino = parent_dir.lookup(name)
        if target_ino == -1:
            return false
        if not parent_dir.remove_entry(name):
            return false
        ## Removing a subdirectory lowers its parent's count too, for the same
        ## reason mkdir raises it.
        let target_obj = self.inode.get_inode(target_ino)
        let was_dir: Bool = target_obj != nil and target_obj.is_dir()
        self.inode.unlink(target_ino)
        if was_dir:
            let parent_inode = self.inode.get_inode(parent_ino)
            if parent_inode != nil and parent_inode.nlink > 2:
                parent_inode.nlink = parent_inode.nlink - 1
                self.inode.update_inode(parent_ino)
        ## The inode is gone; any cached content for it must not survive, and the
        ## number can be reused for a new file.
        self._invalidate_content(target_ino)
        self._save_dir(parent_ino, parent_dir)
        return true

    proc rmdir(self, path: String) -> Bool:
        let ino = self.resolve_path(path)
        if ino == -1:
            return false
        let dir_mgr = self._get_dir(ino)
        if dir_mgr == nil:
            return false
        if not dir_mgr.is_empty():
            return false
        return self.unlink(path)

    proc rename(self, oldpath: String, newpath: String) -> Bool:
        let old_pinfo = self._lookup_in_parent(oldpath)
        let new_pinfo = self._lookup_in_parent(newpath)
        let old_parent = old_pinfo["parent_ino"]
        let new_parent = new_pinfo["parent_ino"]
        let old_name = old_pinfo["name"]
        let new_name = new_pinfo["name"]
        if old_parent == -1 or new_parent == -1 or len(old_name) == 0 or len(new_name) == 0:
            return false
        let old_dir = self._get_dir(old_parent)
        if old_dir == nil:
            return false
        let target_ino: Int = old_dir.lookup(old_name)
        if target_ino == -1:
            return false

        ## Preserve the entry's type. This hardcoded DT_REG, so renaming a
        ## directory re-inserted it as a regular file: is_dir() went false, its
        ## dentries became unreachable, and fsck reported the subtree below it as
        ## orphans. Resolve the type from the inode itself.
        var entry_type: Int = dir_module.DT_REG
        let target_obj = self.inode.get_inode(target_ino)
        if target_obj != nil and target_obj.is_dir():
            entry_type = dir_module.DT_DIR

        ## Same-parent rename, handled without a second directory object.
        ##
        ## _get_dir() decodes a *fresh* DirManager from the inode's inline data on
        ## every call, so the original code -- which called it once for the source
        ## parent and once for the destination -- held two independent copies of
        ## the same directory whenever the parents matched. The removal went to one
        ## copy and the insertion to the other, and the save wrote whichever copy
        ## had only had the removal applied, so a rename within a directory lost
        ## the file.
        if old_parent == new_parent:
            if not old_dir.remove_entry(old_name):
                return false
            ## Same ceiling as create_file() and mkdir(): a rename that would push
            ## the destination directory past what _save_dir() can record has to
            ## be refused for the same reason, or it moves a file into a directory
            ## that has silently stopped being saved.
            if not self._dir_has_room(old_parent, new_name):
                return false
            old_dir.add_entry(new_name, target_ino, entry_type)
            self._save_dir(old_parent, old_dir)
            return true

        let new_dir = self._get_dir(new_parent)
        if new_dir == nil:
            return false
        if not old_dir.remove_entry(old_name):
            return false
        if new_dir.lookup(new_name) != -1:
            new_dir.remove_entry(new_name)
        if not self._dir_has_room(new_parent, new_name):
            return false
        new_dir.add_entry(new_name, target_ino, entry_type)
        self._save_dir(old_parent, old_dir)
        if old_parent != new_parent:
            self._save_dir(new_parent, new_dir)
        return true

    ## Drop a cached copy of an inode's content. Called by every path that
    ## changes what read_inode_data() would return.
    proc _invalidate_content(self, ino: Int):
        if self.content_cache == nil:
            return
        if dict_has(self.content_cache, str(ino)):
            dict_delete(self.content_cache, str(ino))

    proc read_inode_data(self, ino: Int) -> Bytes:
        let inode_obj = self.inode.get_inode(ino)
        if inode_obj == nil:
            return bytes()
        if inode_obj.is_inline():
            ## Inline payloads are hex. Directories always were (_save_dir /
            ## _decode_dir_data); regular files were not, and chr(0) is an empty
            ## String, so a zero byte in a small file was dropped on the way in and
            ## the file came back short. One persisted field, two conventions.
            return self._hex_to_bytes(inode_obj.get_inline_data())
        if self.content_cache != nil and dict_has(self.content_cache, str(ino)):
            let hit = self.content_cache[str(ino)]
            if bytes_len(hit) > 0:
                return hit
        let extents = self.extent._collect_extents(ino)
        let size: Int = inode_obj.size
        if len(extents) == 0:
            return bytes()
        let bs = self._init_block_size()
        ## Lay the result out by file offset, not by arrival order.
        ##
        ## The old loop appended each extent's bytes to the end of the buffer and
        ## ignored ext.file_offset entirely. That is only correct when the extents
        ## happen to be contiguous and sorted, which a file's first hole breaks.
        ## Punching block 0 out of a 12288-byte file left two extents at 4096 and
        ## 8192; their data was concatenated into offsets 0 and 4096, so a read at
        ## offset 0 returned what should have been at 4096, and a read at 8192 fell
        ## off the end of an 8192-byte buffer and returned nothing at all. The
        ## surviving data was not merely misplaced, it was unreachable.
        ##
        ## Sparse regions read as zeroes, which is what a hole means.
        var result = bytes()
        var pre = 0
        while pre < size:
            bytes_push(result, 0)
            pre = pre + 1
        for ext in extents:
            ## Walk whole blocks, taking only the bytes this extent covers.
            ##
            ## ext.length is a byte count, not a block count. This loop used to
            ## iterate ext.length times and step the *block number* by one each
            ## time, so an extent of 4096 bytes read 4096 consecutive blocks --
            ## straight off the end of the volume. _read_block() materialises the
            ## whole prefix for any address, so the image buffer grew to cover
            ## block 4096 (one past total_blocks) and ran on past it, reaching
            ## 17 MB. unmount() then persisted that length, and the next mount
            ## read the oversized file back and the VM died copying it.
            var remaining = ext.length
            var blk = ext.block_addr
            var dst: Int = ext.file_offset
            while remaining > 0:
                if dst >= size:
                    break
                var take = bs
                if remaining < take:
                    take = remaining
                ## Never write past the inode's size.
                if dst + take > size:
                    take = size - dst
                let blk_data = self._read_block(blk)
                var i = 0
                while i < take and i < bytes_len(blk_data):
                    bytes_set(result, dst + i, bytes_get(blk_data, i))
                    i = i + 1
                remaining = remaining - take
                dst = dst + take
                blk = blk + 1
        if self.content_cache != nil:
            ## Bound it, so a workload touching many inodes cannot grow it without
            ## limit. Evicting the oldest key is crude but correct: correctness
            ## does not depend on what stays cached, only on _invalidate_content()
            ## being called on every write.
            if len(dict_keys(self.content_cache)) >= 256:
                dict_delete(self.content_cache, dict_keys(self.content_cache)[0])
            self.content_cache[str(ino)] = result
        return result

    proc write_block(self, blk: Int, data: Bytes):
        self._write_block(blk, data)

    proc read_block(self, blk: Int) -> Bytes:
        return self._read_block(blk)

    proc alloc_block(self) -> Int:
        let alloc = self.allocator.allocate_node_block("warm")
        if alloc == nil or not alloc.is_success():
            return 0
        return alloc.physical_blk
