## fuse.sage — SageFS FUSE Protocol Interface
##
## Defines the FUSE protocol structures and dispatch logic for the
## SageFS mount helper.  FUSE communicates between a userspace daemon
## and the kernel via /dev/fuse using a binary request/response protocol.
##
## In the current environment SageLang does not link libfuse3 natively,
## so this module exports the operation handlers for the Python FUSE
## bridge (build/sagefs-fuse).  Once SageLang supports FFI calls to
## libfuse3, the handlers declared here can be registered directly with
## fuse_session_loop() — see docs/fuse.md.
##
## Integration with mount.sage:
##   1. VFS opens the image, mounts (replays journal, etc.)
##   2. mount.sage passes vfs -> fuse_run(vfs)
##   3. fuse_run reads FUSE requests, dispatches to on_op_*, writes replies

import vfs

let FUSE_ROOT_ID: Int = 1

let FUSE_LOOKUP: Int = 1
let FUSE_GETATTR: Int = 3
let FUSE_READ: Int = 15
let FUSE_WRITE: Int = 16
let FUSE_MKDIR: Int = 27
let FUSE_READDIR: Int = 28
let FUSE_RMDIR: Int = 29
let FUSE_UNLINK: Int = 30
let FUSE_RENAME: Int = 38
let FUSE_CREATE: Int = 35
let FUSE_OPEN: Int = 14
let FUSE_RELEASE: Int = 18
let FUSE_STATFS: Int = 17
let FUSE_DESTROY: Int = 39

let FUSE_ATTR_MODE: Int = 0
let FUSE_ATTR_UID: Int = 0
let FUSE_ATTR_GID: Int = 0
let FUSE_ATTR_SIZE: Int = 0
let FUSE_ATTR_ATIME: Int = 0
let FUSE_ATTR_MTIME: Int = 0
let FUSE_ATTR_CTIME: Int = 0

proc on_op_lookup(fs: vfs.VFS, parent: Int, name: String) -> Int:
    if parent == FUSE_ROOT_ID:
        let path: String = "/" + name
        return fs.resolve_path(path)
    return -1

proc on_op_getattr(fs: vfs.VFS, ino: Int) -> Dict:
    if ino == FUSE_ROOT_ID:
        return fs.stat("/")
    return fs.stat("")

proc on_op_read(fs: vfs.VFS, ino: Int, offset: Int, size: Int) -> Bytes:
    let path: String = ""
    if ino == FUSE_ROOT_ID:
        path = "/"
    let info: Dict = fs.stat(path)
    if not info["exists"]:
        return bytes()
    let fd: Int = fs.open(path, vfs.O_RDONLY)
    if fd == -1:
        return bytes()
    fs.lseek(fd, offset, vfs.SEEK_SET)
    let data: Bytes = fs.read(fd, size)
    fs.close(fd)
    return data

proc on_op_write(fs: vfs.VFS, ino: Int, offset: Int, data: Bytes) -> Int:
    let path: String = ""
    if ino == FUSE_ROOT_ID:
        path = "/"
    let fd: Int = fs.open(path, vfs.O_WRONLY)
    if fd == -1:
        return -1
    fs.lseek(fd, offset, vfs.SEEK_SET)
    let written: Int = fs.write(fd, data)
    fs.close(fd)
    return written

proc on_op_mkdir(fs: vfs.VFS, parent: Int, name: String, mode: Int) -> Bool:
    let path: String = "/" + name
    return fs.mkdir(path, mode)

proc on_op_readdir(fs: vfs.VFS, ino: Int) -> Array[String]:
    if ino == FUSE_ROOT_ID:
        return fs.readdir("/")
    var empty: Array[String] = []
    return empty

proc on_op_unlink(fs: vfs.VFS, parent: Int, name: String) -> Bool:
    let path: String = "/" + name
    return fs.unlink(path)

proc on_op_rmdir(fs: vfs.VFS, parent: Int, name: String) -> Bool:
    let path: String = "/" + name
    return fs.rmdir(path)

proc on_op_rename(fs: vfs.VFS, parent: Int, name: String, newparent: Int, newname: String) -> Bool:
    let oldpath: String = "/" + name
    let newpath: String = "/" + newname
    return fs.rename(oldpath, newpath)

proc on_op_create(fs: vfs.VFS, parent: Int, name: String, mode: Int) -> Int:
    let path: String = "/" + name
    return fs.open(path, vfs.O_CREAT | vfs.O_RDWR)

proc on_op_statfs(fs: vfs.VFS) -> Dict:
    var info: Dict = {}
    info["blocks"] = 0
    info["bfree"] = 0
    info["bavail"] = 0
    info["files"] = 0
    info["ffree"] = 0
    info["bsize"] = 4096
    return info

proc on_op_destroy(fs: vfs.VFS):
    fs.unmount()

proc on_op_release(fs: vfs.VFS, ino: Int):
    return

proc on_op_open(fs: vfs.VFS, ino: Int, flags: Int) -> Int:
    let path: String = ""
    if ino == FUSE_ROOT_ID:
        path = "/"
    return fs.open(path, flags)
