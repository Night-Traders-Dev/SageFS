## vfs.sage — SageFS Virtual Filesystem Layer
##
## Provides POSIX-like file and directory operations on top of SageFS
## on-disk structures.  This is the central orchestration layer that
## coordinates superblock, inode, segment, and journal modules.
##
## Two execution modes:
##   - Native (SageVM / compiled): full performance, direct block I/O
##   - Python FUSE bridge: used by build/sagefs-fuse for userspace mounting

import superblock
import inode
import dir
import imgio

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

class FileDescriptor:
    proc init(self, ino: Int, flags: Int, pos: Int):
        self.ino = ino
        self.flags = flags
        self.pos = pos

class VFS:
    proc init(self, image_path: String):
        self.image_path = image_path
        self.mounted = false
        self.sb = nil
        self.fds = []
        self.next_fd = 0
        self.dentries = []
        self.inodes = {}

    proc mount(self) -> Bool:
        let raw: Bytes = imgio.read_image(self.image_path)
        if bytes_len(raw) < 428:
            print("VFS: image too small (" + str(bytes_len(raw)) + " bytes)")
            return false
        self.sb = superblock.deserialize_superblock(raw)
        if self.sb.magic != superblock.SAGEFS_MAGIC:
            print("VFS: bad magic 0x" + str(self.sb.magic) + " (expected 0x" + str(superblock.SAGEFS_MAGIC) + ")")
            return false
        if bytes_len(raw) > 428:
            let tail: Bytes = bytes()
            var i: Int = 428
            while i < bytes_len(raw):
                bytes_push(tail, bytes_get(raw, i))
                i = i + 1
            let entries: Array = imgio.read_inode_entries(tail)
            for entry in entries:
                let entry_ino: Int = entry["ino"]
                let key: String = str(entry_ino)
                self.inodes[key] = entry
                let name: String = entry["name"]
                push(self.dentries, name)
        self.mounted = true
        return true

    proc unmount(self) -> Bool:
        self.mounted = false
        return true

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
        let fd: Int = self.next_fd
        self.next_fd = self.next_fd + 1
        push(self.fds, FileDescriptor(ino, flags, 0))
        return fd

    proc close(self, fd: Int) -> Bool:
        if fd < 0 or fd >= len(self.fds):
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
        let written: Int = bytes_len(data)
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
            info["mode"] = S_IFDIR
            info["size"] = 4096
            info["isdir"] = true
        else:
            let key: String = str(ino)
            if dict_has(self.inodes, key):
                let entry: Dict = self.inodes[key]
                info["mode"] = entry["mode"]
                info["size"] = entry["size"]
            else:
                info["mode"] = S_IFREG
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
        if path == "/":
            for d in self.dentries:
                push(entries, d)
        return entries

    proc resolve_path(self, path: String) -> Int:
        if not self.mounted:
            return -1
        if path == "/" or path == "":
            return ROOT_INO
        if path[0] == "/":
            path = path[1:len(path)]
        for d in self.dentries:
            if d == path:
                let entry_ino: Int = 0
                let keys: Array = dict_keys(self.inodes)
                for k in keys:
                    let e: Dict = self.inodes[k]
                    if e["name"] == path:
                        return e["ino"]
                return ROOT_INO + 1
        return -1

    proc create_file(self, path: String, flags: Int) -> Int:
        let parts: Array[String] = self.split_path(path)
        let name: String = parts[len(parts) - 1]
        for d in self.dentries:
            if d == name:
                return -1
        push(self.dentries, name)
        let ino: Int = ROOT_INO + 1
        var entry: Dict = {}
        entry["ino"] = ino
        entry["mode"] = S_IFREG | 0x1A4
        entry["size"] = 0
        entry["name"] = name
        entry["data"] = ""
        self.inodes[str(ino)] = entry
        if self.next_fd >= MAX_FDS:
            return -1
        let fd: Int = self.next_fd
        self.next_fd = self.next_fd + 1
        push(self.fds, FileDescriptor(ino, flags, 0))
        return fd

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

    proc read_inode_data(self, ino: Int) -> Bytes:
        let key: String = str(ino)
        if dict_has(self.inodes, key):
            let entry: Dict = self.inodes[key]
            let data_str: String = entry["data"]
            return bytes(data_str)
        return bytes()

    proc mkdir(self, path: String, mode: Int) -> Bool:
        let parts: Array[String] = self.split_path(path)
        let name: String = parts[len(parts) - 1]
        for d in self.dentries:
            if d == name:
                return false
        push(self.dentries, name)
        return true

    proc unlink(self, path: String) -> Bool:
        let parts: Array[String] = self.split_path(path)
        let name: String = parts[len(parts) - 1]
        var i: Int = 0
        while i < len(self.dentries):
            if self.dentries[i] == name:
                self.dentries[i] = self.dentries[len(self.dentries) - 1]
                pop(self.dentries)
                return true
            i = i + 1
        return false

    proc rmdir(self, path: String) -> Bool:
        return self.unlink(path)

    proc rename(self, oldpath: String, newpath: String) -> Bool:
        let old_parts: Array[String] = self.split_path(oldpath)
        let old_name: String = old_parts[len(old_parts) - 1]
        let new_parts: Array[String] = self.split_path(newpath)
        let new_name: String = new_parts[len(new_parts) - 1]
        var i: Int = 0
        var found: Bool = false
        while i < len(self.dentries):
            if self.dentries[i] == old_name:
                self.dentries[i] = new_name
                found = true
            i = i + 1
        return found
