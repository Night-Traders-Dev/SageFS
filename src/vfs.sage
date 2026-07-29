## vfs.sage — SageFS Virtual Filesystem Layer
##
## Provides POSIX-like file and directory operations on top of SageFS
## on-disk structures.  This is the central orchestration layer that
## coordinates superblock, segment, allocator, NAT, inode, B+ tree,
## extent, directory, journal, cache, and async I/O modules.

import superblock
import segment as seg_module
import nat as nat_module
import allocator as alloc_module
import inode as inode_module
import dir as dir_module
import extent as extent_module
import btree as btree_module
import imgio
import aio as aio_module
import cache as cache_module
import transaction as txn_module
import gc as gc_module
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
        self.fds = []
        self.next_fd = 0
        self.image_buf = bytes()
        self.blocks_growable = false

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
        let raw: Bytes = imgio.read_image(self.image_path)
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

        if self.inode == nil:
            self.inode = inode_module.InodeManager(self.nat)
            let root_inode_val = self.inode.create_root()
            if root_inode_val != nil:
                let rkey = inode_module.INODE_FLAG_INLINE_DENTRY
                root_inode_val.set_flag(rkey)

        if self.btree == nil:
            self.btree = btree_module.BTreeEngine(self, 0, 1)

        if self.extent == nil:
            self.extent = extent_module.ExtentTree(self.btree)

        if self.dir == nil:
            self.dir = dir_module.DirManager()

        if self.aio == nil:
            self.aio = aio_module.AsyncIOEngine()

        if self.cache == nil:
            self.cache = cache_module.CacheManager(1024, 1024, 512)

        if self.journal == nil:
            self.journal = Journal(self, 0, 16, bs)

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

        if bytes_len(raw) > 428:
            var tail_bytes = bytes()
            var ti: Int = 428
            while ti < bytes_len(raw):
                bytes_push(tail_bytes, bytes_get(raw, ti))
                ti = ti + 1
            if bytes_len(tail_bytes) > 0:
                let legacy_entries = imgio.read_inode_entries(tail_bytes)

                var i = 0
                while i < len(legacy_entries):
                    let le = legacy_entries[i]
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
                            target.set_inline_data(l_data)
                            target.size = l_size
                    i = i + 1

                i = 0
                while i < len(legacy_entries):
                    let le = legacy_entries[i]
                    let l_name: String = le["name"]
                    let l_ino: Int = le["ino"]
                    let l_mode: Int = le["mode"]
                    let l_data: String = le["data"]
                    let l_size: Int = le["size"]
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

        self.mounted = true
        return true

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
            stub.size = size
        self.inode.inodes[str(ino)] = stub
        self.inode.dirty_inodes[str(ino)] = true

    proc _persist_all(self):
        let all_inos = self.inode.list_inodes()
        for ino in all_inos:
            let inode_obj = self.inode.get_inode(ino)
            if inode_obj == nil:
                continue
            let data_str: String = inode_obj.get_inline_data()
            if len(data_str) > 0 or inode_obj.size > 0:
                imgio.write_inode_entry(self.image_buf, ino, inode_obj.mode, inode_obj.size, "", data_str)

    proc unmount(self) -> Bool:
        if not self.mounted:
            return false
        self._persist_all()
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
        let dir_mgr = dir_module.DirManager()
        if len(inline_data) < 2:
            return dir_mgr
        let data_bytes: Bytes = self._hex_to_bytes(inline_data)
        if bytes_len(data_bytes) < 8:
            return dir_mgr
        let count: Int = bytes_get(data_bytes, 0) | (bytes_get(data_bytes, 1) << 8)
        var off: Int = 2
        var i: Int = 0
        while i < count and off + 8 <= bytes_len(data_bytes):
            let entry_ino: Int = bytes_get(data_bytes, off) | (bytes_get(data_bytes, off + 1) << 8) | (bytes_get(data_bytes, off + 2) << 16) | (bytes_get(data_bytes, off + 3) << 24)
            let name_len: Int = bytes_get(data_bytes, off + 4) | (bytes_get(data_bytes, off + 5) << 8)
            let ftype: Int = bytes_get(data_bytes, off + 6)
            off = off + 7
            if off + name_len <= bytes_len(data_bytes):
                var name_str: String = ""
                var j: Int = 0
                while j < name_len:
                    name_str = name_str + chr(bytes_get(data_bytes, off + j))
                    j = j + 1
                dir_mgr.add_entry(name_str, entry_ino, ftype)
                off = off + name_len
            i = i + 1
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
        inode_obj.set_inline_data(hex_data)
        self.inode.update_inode(ino)
        imgio.write_inode_entry(self.image_buf, ino, inode_obj.mode, inode_obj.size, "", hex_data)

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
        if (flags & O_TRUNC) != 0:
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
        if inode_obj.is_inline() or new_size <= inode_module.INLINE_DATA_MAX:
            let current = inode_obj.get_inline_data()
            var new_data = ""
            var i = 0
            while i < f.pos and i < len(current):
                new_data = new_data + current[i]
                i = i + 1
            while i < f.pos:
                new_data = new_data + chr(0)
                i = i + 1
            i = 0
            while i < written:
                new_data = new_data + chr(bytes_get(data, i))
                i = i + 1
            inode_obj.set_inline_data(new_data)
            inode_obj.size = len(new_data)
        else:
            self.txmgr.begin()
            let alloc_info = self._alloc_block_addr("warm")
            if alloc_info == nil:
                self.txmgr.abort()
                return -1
            let phys_blk = alloc_info["physical_blk"]
            self._write_block(phys_blk, data)
            self.extent.insert_extent(f.ino, f.pos, phys_blk, 1)
            inode_obj.size = new_size
            self.txmgr.commit()
        self.inode.update_inode(f.ino)
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

    proc mkdir(self, path: String, mode: Int) -> Bool:
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
        let new_inode = self.inode.create_inode(S_IFDIR | (mode & 0xFFF), 0, 0)
        if new_inode == nil:
            return false
        parent_dir.add_entry(name, new_inode.ino, dir_module.DT_DIR)
        self._save_dir(parent_ino, parent_dir)
        return true

    proc create_file(self, path: String, flags: Int) -> Int:
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
        let file_inode = self.inode.create_inode(S_IFREG | 0x1A4, 0, 0)
        if file_inode == nil:
            return -1
        parent_dir.add_entry(name, file_inode.ino, dir_module.DT_REG)
        self._save_dir(parent_ino, parent_dir)
        if self.next_fd >= MAX_FDS:
            return -1
        let fd: Int = self.next_fd
        self.next_fd = self.next_fd + 1
        push(self.fds, FileDescriptor(file_inode.ino, flags, 0))
        return fd

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
        self.inode.unlink(target_ino)
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
        let new_dir = self._get_dir(new_parent)
        if old_dir == nil or new_dir == nil:
            return false
        let target_ino = old_dir.lookup(old_name)
        if target_ino == -1:
            return false
        if not old_dir.remove_entry(old_name):
            return false
        if new_dir.lookup(new_name) != -1:
            new_dir.remove_entry(new_name)
        new_dir.add_entry(new_name, target_ino, dir_module.DT_REG)
        self._save_dir(old_parent, old_dir)
        if old_parent != new_parent:
            self._save_dir(new_parent, new_dir)
        return true

    proc read_inode_data(self, ino: Int) -> Bytes:
        let inode_obj = self.inode.get_inode(ino)
        if inode_obj == nil:
            return bytes()
        if inode_obj.is_inline():
            return bytes(inode_obj.get_inline_data())
        let cached = self.cache.get_node(ino)
        if bytes_len(cached) > 0:
            return cached
        let extents = self.extent._collect_extents(ino)
        if len(extents) == 0:
            return bytes()
        let bs = self._init_block_size()
        var result = bytes()
        for ext in extents:
            var bi = 0
            while bi < ext.length:
                let blk_data = self._read_block(ext.block_addr + bi)
                var i = 0
                while i < bytes_len(blk_data):
                    bytes_push(result, bytes_get(blk_data, i))
                    i = i + 1
                bi = bi + 1
        let end = inode_obj.size
        if bytes_len(result) > end:
            let trimmed = bytes()
            var i = 0
            while i < end:
                bytes_push(trimmed, bytes_get(result, i))
                i = i + 1
            result = trimmed
        self.cache.put_node(ino, result)
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
