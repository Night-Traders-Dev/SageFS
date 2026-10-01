## fuse.sage — SageFS FUSE Protocol Interface
##
## Defines the FUSE protocol structures and dispatch logic for the
## SageFS mount helper.  FUSE communicates between a userspace daemon
## and the kernel via /dev/fuse using a binary request/response protocol.
##
## This module supports two modes:
##
## 1. **FFI mode (native)**: When SageVM FFI is available, the handlers
##    are registered directly with libfuse3 via fuse_session_loop().
##    This requires SageLang FFI support for libfuse3 calls.
##
## 2. **Python bridge mode (fallback)**: When FFI is unavailable, the
##    handlers are exported for the Python FUSE bridge (build/sagefs-fuse).
##
## Integration with mount.sage:
##   1. VFS opens the image, mounts (replays journal, etc.)
##   2. mount.sage passes vfs -> fuse_run(vfs)
##   3. fuse_run reads FUSE requests, dispatches to on_op_*, writes replies
##
## FFI Integration:
##   When FFI is enabled, fuse_run() uses ffi.open("libfuse3.so.4") to
##   obtain the FUSE session, then registers handlers via fuse_session_new()
##   and enters fuse_session_loop() for native FUSE protocol processing.

import ffi
import fileio
import vfs

let FUSE_ROOT_ID: Int = 1

## Opcodes, from linux/fuse.h.  The kernel dispatches on these numbers, so they
## are not ours to renumber.  The previous set had six wrong: MKDIR, UNLINK,
## RMDIR and RENAME were all off (it looked like OPENDIR/FSYNCDIR/RELEASEDIR/
## IOCTL), INTERRUPT was LISTXATTR, and DESTROY does not exist in the protocol
## at all -- the session is torn down by read() returning ENODEV.
let FUSE_LOOKUP: Int = 1
let FUSE_FORGET: Int = 2
let FUSE_GETATTR: Int = 3
let FUSE_SETATTR: Int = 4
let FUSE_READLINK: Int = 5
let FUSE_MKDIR: Int = 9
let FUSE_UNLINK: Int = 10
let FUSE_RMDIR: Int = 11
let FUSE_RENAME: Int = 12
let FUSE_OPEN: Int = 14
let FUSE_READ: Int = 15
let FUSE_WRITE: Int = 16
let FUSE_STATFS: Int = 17
let FUSE_RELEASE: Int = 18
let FUSE_FSYNC: Int = 20
let FUSE_FLUSH: Int = 25
let FUSE_INIT: Int = 26
let FUSE_OPENDIR: Int = 27
let FUSE_READDIR: Int = 28
let FUSE_RELEASEDIR: Int = 29
let FUSE_ACCESS: Int = 34
let FUSE_CREATE: Int = 35
let FUSE_INTERRUPT: Int = 36

## Error numbers, as they appear in fuse_out_header.error (negative).
let FUSE_ENOENT: Int = -2
let FUSE_EIO: Int = -5
let FUSE_EACCES: Int = -13
let FUSE_EEXIST: Int = -17
let FUSE_ENOTDIR: Int = -20
let FUSE_EISDIR: Int = -21
let FUSE_EINVAL: Int = -22
let FUSE_ENOSYS: Int = -38
let FUSE_ENOSPC: Int = -28

## fuse_attr field offsets, relative to the start of struct fuse_attr.  These
## were previously all declared as 0 and then never used; the encoders below
## wrote the fields at invented positions instead.
let FUSE_ATTR_SIZE_OFF: Int = 8
let FUSE_ATTR_BLOCKS_OFF: Int = 16
let FUSE_ATTR_MODE_OFF: Int = 60
let FUSE_ATTR_NLINK_OFF: Int = 64
let FUSE_ATTR_UID_OFF: Int = 68
let FUSE_ATTR_GID_OFF: Int = 72
let FUSE_ATTR_BLKSIZE_OFF: Int = 80
let FUSE_ATTR_INO_OFF: Int = 0

## fuse_attr is 104 bytes on the wire; fuse_entry_out adds 40 bytes of nodeid /
## generation / validity before it.
let FUSE_ATTR_LEN: Int = 88
let FUSE_ENTRY_OUT_LEN: Int = 144
let FUSE_INIT_OUT_LEN: Int = 96
let FUSE_STATFS_OUT_LEN: Int = 136

## The 40-byte request header: len(0) opcode(4) unique(8) nodeid(16) uid(24)
## gid(28) pid(32) padding(36).  This was 32, which under-read every request by
## eight bytes and shifted every parsed name and offset.
let FUSE_IN_HEADER_LEN: Int = 40

## Offset of the name within each variable-length request body.
let FUSE_MKDIR_NAME_OFF: Int = 8
let FUSE_CREATE_NAME_OFF: Int = 16
let FUSE_RENAME_NEW_DIR_OFF: Int = 0
let FUSE_RENAME_OLD_NAME_OFF: Int = 8
let FUSE_WRITE_DATA_OFF: Int = 40

## fuse_lib — Cached libfuse3 handle (set by fuse_init)
var fuse_lib: Any = nil

## libc_lib — Cached libc handle for /dev/fuse direct I/O (set by fuse_init_libc)
var libc_lib: Any = nil

## fuse_fd — File descriptor for /dev/fuse (set by fuse_run)
var fuse_fd: Int = -1

## fuse_session — Cached FUSE session (set by fuse_init)
var fuse_session: Any = nil

## fuse_init — Initialize FFI-based FUSE session
##
## Loads libfuse3 via FFI and creates a FUSE session.
## Returns true on success, false on failure.
proc fuse_init(mountpoint: String) -> Bool:
    if fuse_lib != nil:
        return true
    try:
        fuse_lib = ffi.open("libfuse3.so.4")
        if fuse_lib == nil:
            print("FUSE: libfuse3.so.4 not found")
            return false
        fuse_session = ffi.call(fuse_lib, "fuse_session_new", "int", [mountpoint])
        if fuse_session == nil:
            print("FUSE: fuse_session_new failed")
            return false
        return true
    catch e:
        print("FUSE: FFI initialization failed: " + str(e))
        return false

## fuse_init_libc — Initialize libc FFI handle for /dev/fuse direct I/O
##
## Opens libc.so.6 via FFI so we can call open/read/write/close
## on /dev/fuse directly without libfuse3.
## Returns true on success, false on failure.
proc fuse_init_libc() -> Bool:
    if libc_lib != nil:
        return true
    try:
        libc_lib = ffi.open("libc.so.6")
        if libc_lib == nil:
            print("FUSE: libc.so.6 not found")
            return false
        return true
    catch e:
        print("FUSE: libc FFI init failed: " + str(e))
        return false

## fuse_ensure_libc — Make sure the libc handle exists.
## The FFI helpers below need it, and fuse_run() normally sets it up first.
proc fuse_ensure_libc() -> Bool:
    if libc_lib == nil:
        return fuse_init_libc()
    return true

## fuse_open_rd — open(2) for reading.
proc fuse_open_rd(path: String) -> Int:
    if not fuse_ensure_libc():
        return -1
    return ffi.call(libc_lib, "open", "int", [path, 0])

## fuse_open_rw — open(2) for writing, creating and truncating.
proc fuse_open_rw(path: String) -> Int:
    if not fuse_ensure_libc():
        return -1
    ## O_WRONLY|O_CREAT|O_TRUNC = 1|64|512 = 577, mode 0644 = 420.
    return ffi.call(libc_lib, "open", "int", [path, 577, 420])

## fuse_close_fd — close(2).
proc fuse_close_fd(fd: Int):
    if fd >= 0:
        ffi.call(libc_lib, "close", "int", [fd])

## fuse_lseek — lseek(2).
proc fuse_lseek(fd: Int, off: Int) -> Int:
    if not fuse_ensure_libc():
        return -1
    return ffi.call(libc_lib, "lseek", "int", [fd, off, 0])

## fuse_read_fd — read(2) from fd into buf, via an FFI pointer.
##
## The FFI takes a mem_alloc pointer for a buffer argument, not a Bytes. Passing
## a Bytes matches no specialisation, so the call returns nil and the byte count
## is lost -- which is what every read() in the event loop used to do, on a host
## where the mount itself worked.
proc fuse_read_fd(fd: Int, buf: Bytes, n: Int) -> Int:
    if n <= 0:
        return 0
    let want: Int = n
    if want > bytes_len(buf):
        want = bytes_len(buf)
    let ptr = mem_alloc(want)
    if ptr == nil:
        return 0
    let got: Int = ffi.call(libc_lib, "read", "int", [fd, ptr, want])
    var copied: Int = 0
    if got > 0:
        if got > bytes_len(buf):
            copied = bytes_len(buf)
        else:
            copied = got
        var i: Int = 0
        while i < copied:
            buf[i] = mem_read(ptr, i, "byte")
            i = i + 1
    mem_free(ptr)
    if got < 0:
        return got
    return copied

## fuse_write_fd — write(2) buf to fd, via an FFI pointer. Same shape as above.
proc fuse_write_fd(fd: Int, buf: Bytes) -> Int:
    let n: Int = bytes_len(buf)
    if n == 0:
        return 0
    let ptr = mem_alloc(n)
    if ptr == nil:
        return 0
    var i: Int = 0
    while i < n:
        mem_write(ptr, i, "byte", buf[i])
        i = i + 1
    let put: Int = ffi.call(libc_lib, "write", "int", [fd, ptr, n])
    mem_free(ptr)
    return put

## fuse_mountpoint — The directory the filesystem is mounted on, for unmount.
var fuse_mountpoint: String = ""

## fuse_cmd_argc / fuse_cmd_argv — State for an execv() call.
##
## The SageLang FFI passes at most three arguments to a C function, so argv has
## to be built in memory and handed over as a pointer. That needs somewhere to
## live for the duration of the call, which is what these are.
var fuse_cmd_argc: Int = 0
var fuse_cmd_argv: Any = nil

## fuse_quote — Single-quote a string for /bin/sh.
##
## The mountpoint and the uid/gid are interpolated into a shell command, so they
## are quoted rather than trusted. A mountpoint containing a quote or a
## semicolon would otherwise be a command injection into a program that is about
## to run as root.
proc fuse_quote(s: String) -> String:
    var out: String = "'"
    var i: Int = 0
    while i < len(s):
        let c: String = s[i]
        if c == "'":
            ## Close, emit an escaped quote, reopen.
            out = out + "'\\''"
        else:
            out = out + c
        i = i + 1
    return out + "'"

## fuse_geteuid — Effective uid, or 0 if it cannot be read.
proc fuse_geteuid() -> Int:
    if libc_lib == nil and not fuse_init_libc():
        return 0
    let uid: Int = ffi.call(libc_lib, "geteuid", "int", [])
    return uid

## fuse_mount — Mount the FUSE filesystem on `mountpoint`.
##
## Two paths, because they need different privileges:
##
##   * root calls mount(2) directly, via fusermount3 which is setuid-root and
##     therefore does not need a shell at all.
##   * an unprivileged user goes through fusermount3 too, which is the
##     supported route and is what libfuse itself does.
##
## `fd` must already be an open descriptor on /dev/fuse. The kernel keeps using
## that descriptor for the whole session, so it must not be closed here.
##
## Returns true if the filesystem is mounted.
proc fuse_mount(mountpoint: String, fd: Int) -> Bool:
    fuse_mountpoint = mountpoint
    let uid: Int = fuse_geteuid()
    ## rootmode=40000 is S_IFDIR, which the kernel requires for a mount root.
    let opts: String = "fd=" + str(fd) + ",rootmode=40000,user_id=" + str(uid) + ",group_id=" + str(uid)

    ## fusermount3 -o <opts> -- <mountpoint>. Prefer the explicit -- so a
    ## mountpoint beginning with a dash is not read as an option.
    let cmd: String = "fusermount3 -o " + fuse_quote(opts) + " -- " + fuse_quote(mountpoint)
    let rc: Int = ffi.call(libc_lib, "system", "int", [cmd])
    if rc == 0:
        return true

    ## Fall back to mount(2). The filesystem type is "fuse"; naming a private
    ## type like fuse.sagefs needs a /etc/filesystems entry and a matching
    ## mount.fuse.sagefs helper, and without them mount(2) fails outright. The
    ## source string is ignored by the FUSE driver but must still be a single
    ## word, or the shell tries to execute it.
    let mcmd: String = "mount -t fuse -o " + fuse_quote(opts) + " sagefs " + fuse_quote(mountpoint)
    let rc2: Int = ffi.call(libc_lib, "system", "int", [mcmd])
    if rc2 == 0:
        return true

    ## Report what actually happened. "mount failed" on its own is not
    ## actionable, and the usual cause is not a bug here: fusermount3 refuses
    ## the fd= handoff ("old style mounting not supported") on hosts where the
    ## setuid helper is configured that way, and unprivileged mounting then needs
    ## user namespaces.
    print("FUSE: could not mount on " + mountpoint)
    print("FUSE:   fusermount3 rc=" + str(rc) + ", mount(2) rc=" + str(rc2))
    print("FUSE:   if fusermount3 reports 'old style mounting not supported', this host")
    print("FUSE:   does not allow unprivileged FUSE; try running as root, or in a")
    print("FUSE:   user namespace with fusermount3 available.")
    return false

## fuse_unmount — Unmount and release the mountpoint.
proc fuse_unmount() -> Bool:
    if fuse_mountpoint == "":
        return true
    let cmd: String = "fusermount3 -u -- " + fuse_quote(fuse_mountpoint)
    let rc: Int = ffi.call(libc_lib, "system", "int", [cmd])
    if rc != 0:
        let mcmd: String = "umount " + fuse_quote(fuse_mountpoint)
        ffi.call(libc_lib, "system", "int", [mcmd])
    fuse_mountpoint = ""
    return true

## decode_u32_le — Decode a 32-bit little-endian integer from a Bytes buffer
proc decode_u32_le(buf: Bytes, off: Int) -> Int:
    return buf[off] | (buf[off + 1] << 8) | (buf[off + 2] << 16) | (buf[off + 3] << 24)

## decode_u64_le — Decode a 64-bit little-endian integer from a Bytes buffer
proc decode_u64_le(buf: Bytes, off: Int) -> Int:
    let lo: Int = buf[off] | (buf[off + 1] << 8) | (buf[off + 2] << 16) | (buf[off + 3] << 24)
    let hi: Int = buf[off + 4] | (buf[off + 5] << 8) | (buf[off + 6] << 16) | (buf[off + 7] << 24)
    return lo | (hi << 32)

## decode_i32_le — Decode a signed 32-bit little-endian integer.
## The sign is taken from the top byte, not by comparing the assembled value
## against 0x80000000. decode_u32_le() shifts into the sign bit of a 32-bit int,
## so a word like 0xFFFFFFFE comes back already negative and that comparison
## never fires -- every negative errno decoded as a large negative number
## instead of -2, which the kernel then rejects as an unknown error.
proc decode_i32_le(buf: Bytes, off: Int) -> Int:
    let v: Int = decode_u32_le(buf, off)
    if buf[off + 3] >= 128:
        return v - 0x100000000
    return v

## encode_u32_le_to — Encode a 32-bit unsigned integer as little-endian into buf at offset off
proc encode_u32_le_to(buf: Bytes, off: Int, val: Int):
    buf[off] = val & 0xff
    buf[off + 1] = (val >> 8) & 0xff
    buf[off + 2] = (val >> 16) & 0xff
    buf[off + 3] = (val >> 24) & 0xff

## encode_u64_le_to — Encode a 64-bit unsigned integer as little-endian into buf at offset off
proc encode_u64_le_to(buf: Bytes, off: Int, val: Int):
    buf[off] = val & 0xff
    buf[off + 1] = (val >> 8) & 0xff
    buf[off + 2] = (val >> 16) & 0xff
    buf[off + 3] = (val >> 24) & 0xff
    buf[off + 4] = (val >> 32) & 0xff
    buf[off + 5] = (val >> 40) & 0xff
    buf[off + 6] = (val >> 48) & 0xff
    buf[off + 7] = (val >> 56) & 0xff

## encode_i32_le_to — Encode a 32-bit signed integer as little-endian into buf at offset off
##
## The value is reduced to its unsigned 32-bit pattern first. Shifting a negative
## integer right in SageLang does not do an arithmetic shift -- `-2 >> 8` yields
## 7.2e16, not -1 -- so `(val >> 8) & 0xff` on a negative produced 0 instead of
## 0xFF. Every negative errno was therefore encoded as a positive number, and
## the kernel read a success with a garbage code.
proc encode_i32_le_to(buf: Bytes, off: Int, val: Int):
    let v: Int = val & 0xFFFFFFFF
    buf[off] = v & 0xff
    buf[off + 1] = (v >> 8) & 0xff
    buf[off + 2] = (v >> 16) & 0xff
    buf[off + 3] = (v >> 24) & 0xff

## on_op_lookup — FUSE LOOKUP handler
proc on_op_lookup(fs: vfs.VFS, parent: Int, name: String) -> Int:
    if name == "/" or name == "" or name == ".":
        fs.cache_ino_path(1, "/")
        return 1
    if parent == FUSE_ROOT_ID:
        let path: String = "/" + name
        let ino: Int = fs.resolve_path(path)
        if ino >= 0:
            fs.cache_ino_path(ino, path)
        return ino
    let parent_path: String = fs.resolve_ino(parent)
    if len(parent_path) == 0:
        return -1
    let path: String = parent_path + "/" + name
    let ino: Int = fs.resolve_path(path)
    if ino >= 0:
        fs.cache_ino_path(ino, path)
    return ino

## on_op_getattr — FUSE GETATTR handler
proc on_op_getattr(fs: vfs.VFS, ino: Int) -> Dict:
    let path: String = fs.resolve_ino(ino)
    if len(path) == 0:
        if ino == FUSE_ROOT_ID:
            path = "/"
        else:
            return {"exists": false}
    return fs.stat(path)

## The FUSE dispatcher referenced on_op_setattr, on_op_access, on_op_flush and
## on_op_fsync, and none of the four were ever defined. The interpreter resolves
## a missing proc to nil at run time, so the FUSE paths that reach them never
## worked; the C backend rejects the name outright, which is why
## `sage-c --emit-c src/fuse.sage` failed and took mount.sage and all.sage with
## it. They are defined here rather than removed, because the operations are
## real and the dispatcher is the one place that knows their shapes.
##
## FUSE_SETATTR mask bits, from linux/fuse.h.
let FUSE_SET_ATTR_MODE: Int = 1
let FUSE_SET_ATTR_SIZE: Int = 8

## on_op_setattr — FUSE SETATTR handler. Applies the mode and size the kernel
## asked for; other mask bits (uid, gid, times) have no backing field on
## SageFSInode beyond ctime/mtime, which write() already maintains, so they are
## accepted and ignored rather than reported as an error the kernel would retry.
proc on_op_setattr(fs: vfs.VFS, ino: Int, args: Dict) -> Dict:
    let st: Dict = on_op_getattr(fs, ino)
    if not dict_has(st, "exists"):
        return {"exists": false}
    let mask: Int = args["mask"]
    let obj = fs.inode.get_inode(ino)
    if (mask & FUSE_SET_ATTR_MODE) != 0:
        obj.mode = args["mode"]
    if (mask & FUSE_SET_ATTR_SIZE) != 0:
        let fd: Int = fs.open(fs.resolve_ino(ino), vfs.O_WRONLY)
        if fd != -1:
            fs.truncate(fd, args["size"])
            fs.close(fd)
    fs.inode.update_inode(ino)
    return on_op_getattr(fs, ino)

## on_op_access — FUSE ACCESS handler. SageFS is single-user and stores no
## permission bits beyond the mode, and the VFS layer does not enforce an access
## policy, so the honest answer is that everything that resolves is accessible.
## Returning -EACCES here would break mounts that currently work.
proc on_op_access(fs: vfs.VFS, ino: Int, args: Dict) -> Int:
    let path: String = fs.resolve_ino(ino)
    if len(path) == 0 and ino != FUSE_ROOT_ID:
        return -9
    return 0

## on_op_flush — FUSE FLUSH handler. Called on every close(2), and the kernel may
## call it more than once for a single fd, so it must be idempotent. fsync is the
## call that has to persist; flush just needs to not fail.
proc on_op_flush(fs: vfs.VFS, ino: Int) -> Int:
    return 0

## on_op_fsync — FUSE FSYNC handler. _persist_all writes the dirty inodes and
## directories back to the image, which is what fsync has to mean here.
proc on_op_fsync(fs: vfs.VFS, ino: Int) -> Int:
    fs._persist_all()
    return 0

## on_op_read — FUSE READ handler
proc on_op_read(fs: vfs.VFS, ino: Int, offset: Int, size: Int) -> Bytes:
    let path: String = fs.resolve_ino(ino)
    if len(path) == 0:
        return bytes()
    let fd: Int = fs.open(path, vfs.O_RDONLY)
    if fd == -1:
        return bytes()
    fs.lseek(fd, offset, vfs.SEEK_SET)
    let data: Bytes = fs.read(fd, size)
    fs.close(fd)
    return data

## on_op_write — FUSE WRITE handler
proc on_op_write(fs: vfs.VFS, ino: Int, offset: Int, data: Bytes) -> Int:
    let path: String = fs.resolve_ino(ino)
    if len(path) == 0:
        return -1
    let fd: Int = fs.open(path, vfs.O_WRONLY)
    if fd == -1:
        return -1
    fs.lseek(fd, offset, vfs.SEEK_SET)
    let written: Int = fs.write(fd, data)
    fs.close(fd)
    return written

## on_op_mkdir — FUSE MKDIR handler
proc on_op_mkdir(fs: vfs.VFS, parent: Int, name: String, mode: Int) -> Bool:
    let path: String = ""
    if parent == FUSE_ROOT_ID:
        path = "/" + name
    else:
        let pp: String = fs.resolve_ino(parent)
        if len(pp) == 0:
            return false
        path = pp + "/" + name
    return fs.mkdir(path, mode)

## on_op_readdir — FUSE READDIR handler
proc on_op_readdir(fs: vfs.VFS, ino: Int) -> Array[String]:
    ## Returns "ino name type" triples rather than bare names. A fuse_dirent
    ## needs the inode number and the DT_ type; reporting every entry as inode 1
    ## and DT_DIR makes subdirectories unreachable and files unopenable.
    let path: String = fs.resolve_ino(ino)
    if len(path) == 0:
        if ino == FUSE_ROOT_ID:
            path = "/"
        else:
            return []
    let names: Array[String] = fs.readdir(path)
    var out: Array[String] = []
    ## "." and ".." are mandatory, and refer to this directory and its parent.
    push(out, str(ino) + " . 4")
    var parent_ino: Int = FUSE_ROOT_ID
    if ino != FUSE_ROOT_ID:
        let cut: Int = fuse_last_slash(path)
        if cut > 0:
            let resolved: Int = fs.resolve_path(path[0:cut])
            if resolved > 0:
                parent_ino = resolved
    push(out, str(parent_ino) + " .. 4")
    var i: Int = 0
    while i < len(names):
        let name: String = names[i]
        if name == "." or name == "..":
            i = i + 1
            continue
        let child_path: String = path + "/" + name
        let child: Int = fs.resolve_path(child_path)
        if child < 0:
            i = i + 1
            continue
        let cst: Dict = fs.stat(child_path)
        var dtype: Int = 8
        if dict_has(cst, "mode"):
            let m: Int = cst["mode"]
            if (m & 0xF000) == vfs.S_IFDIR:
                dtype = 4
        push(out, str(child) + " " + name + " " + str(dtype))
        i = i + 1
    return out

## on_op_unlink — FUSE UNLINK handler
proc on_op_unlink(fs: vfs.VFS, parent: Int, name: String) -> Bool:
    let path: String = ""
    if parent == FUSE_ROOT_ID:
        path = "/" + name
    else:
        let pp: String = fs.resolve_ino(parent)
        if len(pp) == 0:
            return false
        path = pp + "/" + name
    return fs.unlink(path)

## on_op_rmdir — FUSE RMDIR handler
proc on_op_rmdir(fs: vfs.VFS, parent: Int, name: String) -> Bool:
    let path: String = ""
    if parent == FUSE_ROOT_ID:
        path = "/" + name
    else:
        let pp: String = fs.resolve_ino(parent)
        if len(pp) == 0:
            return false
        path = pp + "/" + name
    return fs.rmdir(path)

## on_op_rename — FUSE RENAME handler
proc on_op_rename(fs: vfs.VFS, parent: Int, name: String, newparent: Int, newname: String) -> Bool:
    let oldpath: String = ""
    if parent == FUSE_ROOT_ID:
        oldpath = "/" + name
    else:
        let pp: String = fs.resolve_ino(parent)
        if len(pp) == 0:
            return false
        oldpath = pp + "/" + name
    let newpath: String = ""
    if newparent == FUSE_ROOT_ID:
        newpath = "/" + newname
    else:
        let np: String = fs.resolve_ino(newparent)
        if len(np) == 0:
            return false
        newpath = np + "/" + newname
    return fs.rename(oldpath, newpath)

## on_op_create — FUSE CREATE handler
proc on_op_create(fs: vfs.VFS, parent: Int, name: String, mode: Int) -> Int:
    let path: String = ""
    if parent == FUSE_ROOT_ID:
        path = "/" + name
    else:
        let pp: String = fs.resolve_ino(parent)
        if len(pp) == 0:
            return -1
        path = pp + "/" + name
    let fd: Int = fs.open(path, vfs.O_CREAT | vfs.O_RDWR)
    if fd >= 0:
        let ino: Int = fs.resolve_path(path)
        if ino >= 0:
            fs.cache_ino_path(ino, path)
    return fd

## on_op_statfs — FUSE STATFS handler
proc on_op_statfs(fs: vfs.VFS) -> Dict:
    var info: Dict = {}
    info["blocks"] = 0
    info["bfree"] = 0
    info["bavail"] = 0
    info["files"] = 0
    info["ffree"] = 0
    info["bsize"] = 4096
    return info

## on_op_destroy — FUSE DESTROY handler
proc on_op_destroy(fs: vfs.VFS):
    fs.unmount()

## on_op_release — FUSE RELEASE handler
proc on_op_release(fs: vfs.VFS, ino: Int):
    return

## on_op_open — FUSE OPEN handler
proc on_op_open(fs: vfs.VFS, ino: Int, flags: Int) -> Int:
    let path: String = fs.resolve_ino(ino)
    if len(path) == 0:
        if ino == FUSE_ROOT_ID:
            path = "/"
        else:
            return -1
    return fs.open(path, flags)

## dispatch — Central FUSE opcode dispatcher
##
## Routes a FUSE opcode to the corresponding handler function,
## extracting arguments from the args Dict.  Returns the handler's
## result (nil for void handlers).
proc dispatch(fs: vfs.VFS, opcode: Int, args: Dict) -> Any:
    match opcode:
        case FUSE_INIT:
            return {"max_readahead": 131072, "flags": 0, "max_write": 65536}
        case FUSE_LOOKUP:
            ## Resolve the name, then stat it: the kernel needs the attributes
            ## with the entry, not just a nodeid.
            let lino: Int = on_op_lookup(fs, args["parent"], args["name"])
            if lino < 0:
                return nil
            let lst: Dict = on_op_getattr(fs, lino)
            if not dict_has(lst, "exists"):
                return nil
            return lst
        case FUSE_GETATTR:
            return on_op_getattr(fs, args["ino"])
        case FUSE_SETATTR:
            return on_op_setattr(fs, args["ino"], args)
        case FUSE_ACCESS:
            return on_op_access(fs, args["ino"], args)
        case FUSE_FLUSH:
            return on_op_flush(fs, args["ino"])
        case FUSE_FSYNC:
            return on_op_fsync(fs, args["ino"])
        case FUSE_OPENDIR:
            return on_op_open(fs, args["ino"], args["flags"])
        case FUSE_RELEASEDIR:
            on_op_release(fs, args["ino"])
            return nil
        case FUSE_OPEN:
            return on_op_open(fs, args["ino"], args["flags"])
        case FUSE_READ:
            return on_op_read(fs, args["ino"], args["offset"], args["size"])
        case FUSE_WRITE:
            return on_op_write(fs, args["ino"], args["offset"], args["data"])
        case FUSE_STATFS:
            return on_op_statfs(fs)
        case FUSE_RELEASE:
            on_op_release(fs, args["ino"])
            return nil
        case FUSE_MKDIR:
            return on_op_mkdir(fs, args["parent"], args["name"], args["mode"])
        case FUSE_READDIR:
            return on_op_readdir(fs, args["ino"])
        case FUSE_RMDIR:
            return on_op_rmdir(fs, args["parent"], args["name"])
        case FUSE_UNLINK:
            return on_op_unlink(fs, args["parent"], args["name"])
        case FUSE_CREATE:
            return on_op_create(fs, args["parent"], args["name"], args["mode"])
        case FUSE_RENAME:
            return on_op_rename(fs, args["parent"], args["name"], args["newparent"], args["newname"])
        default:
            return nil

## dict_get_int — Read an integer key from a Dict, or a default when absent.
## Every encoder below needs this, and guessing at st["x"] on a missing key is
## how a partial stat() turns into a reply full of zeroes.
proc dict_get_int(d: Dict, key: String, dflt: Int) -> Int:
    if d == nil:
        return dflt
    if not dict_has(d, key):
        return dflt
    return d[key]

## fuse_last_slash — Index of the last '/' in s, or -1.
proc fuse_last_slash(s: String) -> Int:
    var i: Int = len(s) - 1
    while i >= 0:
        if s[i] == "/":
            return i
        i = i - 1
    return -1

## find_char — Index of the first `c` in s, or -1.
proc find_char(s: String, c: String) -> Int:
    var i: Int = 0
    while i < len(s):
        if s[i] == c:
            return i
        i = i + 1
    return -1

## str_to_int — Parse a decimal integer, 0 on anything unparseable.
proc str_to_int(s: String) -> Int:
    if len(s) == 0:
        return 0
    var out: Int = 0
    var i: Int = 0
    var seen: Bool = false
    while i < len(s):
        let c: Int = ord(s[i])
        if c >= 48 and c <= 57:
            out = out * 10 + (c - 48)
            seen = true
        else:
            return 0
        i = i + 1
    if not seen:
        return 0
    return out

## find_in_bytes — Find null terminator position in a Bytes buffer
## Returns the index of the first null byte, or len(buf) if not found.
proc find_in_bytes(buf: Bytes, start: Int) -> Int:
    let n: Int = bytes_len(buf)
    var i: Int = start
    while i < n:
        if buf[i] == 0:
            return i
        i = i + 1
    return n

## body_to_string — Extract a null-terminated string from a Bytes body
## Uses chr() builtin to convert bytes to characters.
proc body_to_string(body: Bytes) -> String:
    let end: Int = find_in_bytes(body, 0)
    var result: String = ""
    var i: Int = 0
    while i < end:
        result = result + chr(body[i])
        i = i + 1
    return result

## write_attr — Encode a struct fuse_attr at `off` in a reply buffer.
##
## One writer, used by both getattr and lookup, because these are the same
## struct at two different offsets and they had drifted apart.
proc write_attr(resp: Bytes, off: Int, st: Dict):
    encode_u64_le_to(resp, off + FUSE_ATTR_INO_OFF, dict_get_int(st, "ino", 0))
    encode_u64_le_to(resp, off + FUSE_ATTR_SIZE_OFF, dict_get_int(st, "size", 0))
    encode_u64_le_to(resp, off + FUSE_ATTR_BLOCKS_OFF, dict_get_int(st, "blocks", 0))
    encode_u64_le_to(resp, off + 24, dict_get_int(st, "atime", 0))
    encode_u64_le_to(resp, off + 32, dict_get_int(st, "mtime", 0))
    encode_u64_le_to(resp, off + 40, dict_get_int(st, "ctime", 0))
    encode_u32_le_to(resp, off + 48, dict_get_int(st, "atime_nsec", 0))
    encode_u32_le_to(resp, off + 52, dict_get_int(st, "mtime_nsec", 0))
    encode_u32_le_to(resp, off + 56, dict_get_int(st, "ctime_nsec", 0))
    encode_u32_le_to(resp, off + FUSE_ATTR_MODE_OFF, dict_get_int(st, "mode", 0))
    encode_u32_le_to(resp, off + FUSE_ATTR_NLINK_OFF, dict_get_int(st, "nlink", 1))
    encode_u32_le_to(resp, off + FUSE_ATTR_UID_OFF, dict_get_int(st, "uid", 0))
    encode_u32_le_to(resp, off + FUSE_ATTR_GID_OFF, dict_get_int(st, "gid", 0))
    encode_u32_le_to(resp, off + 76, 0)
    encode_u32_le_to(resp, off + 84, 0)
    encode_u32_le_to(resp, off + FUSE_ATTR_BLKSIZE_OFF, dict_get_int(st, "blksize", 4096))

## build_ok_response — Build a minimal success FUSE response header (16 bytes)
proc build_ok_response(unique: Int) -> Bytes:
    var resp: Bytes = bytes(16)
    encode_u32_le_to(resp, 0, 16)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    return resp

## build_error_response — Build a FUSE error response with given errno (16 bytes)
proc build_error_response(unique: Int, errno: Int) -> Bytes:
    var resp: Bytes = bytes(16)
    encode_u32_le_to(resp, 0, 16)
    encode_i32_le_to(resp, 4, errno)
    encode_u64_le_to(resp, 8, unique)
    return resp

## build_init_response — Build a FUSE INIT response (fuse_init_out, 104 bytes)
proc build_init_response(unique: Int, max_readahead: Int, flags: Int, max_write: Int) -> Bytes:
    ## fuse_init_out is 80 bytes, so 16 + 80 = 96. The old reply was 104 bytes
    ## and had major/minor at 24/28 and max_readahead at 32, which is the
    ## fuse_init_out of a different ABI generation entirely.
    var resp: Bytes = bytes(FUSE_INIT_OUT_LEN)
    encode_u32_le_to(resp, 0, FUSE_INIT_OUT_LEN)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    encode_u32_le_to(resp, 16, 7)
    encode_u32_le_to(resp, 20, 26)
    encode_u32_le_to(resp, 24, max_readahead)
    encode_u32_le_to(resp, 28, flags)
    ## max_background(32) congestion_threshold(34)
    encode_u32_le_to(resp, 32, 16)
    encode_u32_le_to(resp, 36, max_write)
    encode_u32_le_to(resp, 40, 1)
    return resp

## build_lookup_response — Build a FUSE lookup response (fuse_entry_out, 112 bytes)
proc build_lookup_response(unique: Int, st: Dict) -> Bytes:
    var resp: Bytes = bytes(FUSE_ENTRY_OUT_LEN)
    encode_u32_le_to(resp, 0, FUSE_ENTRY_OUT_LEN)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    encode_u64_le_to(resp, 16, dict_get_int(st, "ino", 0))
    encode_u64_le_to(resp, 24, dict_get_int(st, "generation", 0))
    encode_u64_le_to(resp, 32, 1)
    encode_u64_le_to(resp, 40, 1)
    encode_u32_le_to(resp, 48, 0)
    encode_u32_le_to(resp, 52, 0)
    write_attr(resp, 56, st)
    return resp

## build_open_response — Build a FUSE open response (fuse_open_out, 32 bytes)
proc build_open_response(unique: Int, fh: Int) -> Bytes:
    ## fuse_open_out is fh(8) + open_flags(4) + padding(4) on top of the
    ## 16-byte out_header, so fh belongs at 16 and the whole reply is 32 bytes.
    ## This wrote fh at 24, which put it in open_flags and left the real fh slot
    ## zeroed: every file the kernel opened came back with fh 0, so the first
    ## process to READ or WRITE a file used descriptor 0 regardless of what it
    ## had opened.
    var resp: Bytes = bytes(32)
    encode_u32_le_to(resp, 0, 32)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    encode_u64_le_to(resp, 16, fh)
    encode_u32_le_to(resp, 24, 0)
    return resp

## build_write_response — Build a FUSE write response (fuse_write_out, 24 bytes)
proc build_write_response(unique: Int, size: Int) -> Bytes:
    ## fuse_write_out is size(4) + padding(4), so the payload starts at 16 and
    ## the reply is 24 bytes. This wrote size at 24, which is four bytes past
    ## the end of its own buffer.
    var resp: Bytes = bytes(24)
    encode_u32_le_to(resp, 0, 24)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    encode_u32_le_to(resp, 16, size)
    encode_u32_le_to(resp, 20, 0)
    return resp

## build_read_response — Build a FUSE read response with data payload
proc build_read_response(unique: Int, data: Bytes) -> Bytes:
    let data_len: Int = bytes_len(data)
    var resp: Bytes = bytes(16 + data_len)
    encode_u32_le_to(resp, 0, 16 + data_len)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    var i: Int = 0
    while i < data_len:
        resp[16 + i] = data[i]
        i = i + 1
    return resp

## build_bool_response — Build a FUSE response for boolean-result operations (mkdir, rmdir, unlink, rename)
proc build_bool_response(unique: Int, ok: Bool, errno_default: Int) -> Bytes:
    if ok:
        return build_ok_response(unique)
    return build_error_response(unique, -errno_default)

## build_statfs_response — Build a FUSE statfs response (fuse_statfs_out, 112 bytes)
proc build_statfs_response(unique: Int, st: Dict) -> Bytes:
    var resp: Bytes = bytes(FUSE_STATFS_OUT_LEN)
    encode_u32_le_to(resp, 0, FUSE_STATFS_OUT_LEN)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    if st != nil:
        var blocks: Int = 0
        var bfree: Int = 0
        var bavail: Int = 0
        var files: Int = 0
        var ffree: Int = 0
        if dict_has(st, "blocks"): blocks = st["blocks"]
        if dict_has(st, "bfree"): bfree = st["bfree"]
        if dict_has(st, "bavail"): bavail = st["bavail"]
        if dict_has(st, "files"): files = st["files"]
        if dict_has(st, "ffree"): ffree = st["ffree"]
        encode_u64_le_to(resp, 16, blocks)
        encode_u64_le_to(resp, 24, bfree)
        encode_u64_le_to(resp, 32, bavail)
        encode_u64_le_to(resp, 40, files)
        encode_u64_le_to(resp, 48, ffree)
        encode_u64_le_to(resp, 56, dict_get_int(st, "bsize", 4096))
        encode_u64_le_to(resp, 64, 255)
        encode_u64_le_to(resp, 72, 4096)
    return resp

## build_readdir_response — Build a FUSE readdir response with dirent entries
proc build_readdir_response(unique: Int, entries: Array[String]) -> Bytes:
    ## Entries arrive as "ino name type" triples so the inode numbers and the
    ## DT_ types are the filesystem's, not a constant. Everything is reported as
    ## DT_DIR otherwise, and every entry as inode 1.
    var payload: Bytes = bytes(0)
    var i: Int = 0
    while i < len(entries):
        let spec: String = entries[i]
        let sp: Int = find_char(spec, " ")
        var ino: Int = 1
        var name: String = spec
        var dtype: Int = 0
        if sp > 0:
            ino = str_to_int(spec[0:sp])
            name = spec[sp + 1:len(spec)]
            let tp: Int = find_char(name, " ")
            if tp > 0:
                dtype = str_to_int(name[tp + 1:len(name)])
                name = name[0:tp]
        let name_bytes: Int = len(name)
        ## Round the entry up to an 8-byte boundary; fuse_dirent must be aligned.
        let ent_size: Int = 24 + name_bytes
        let padded: Int = (ent_size + 7) & ~7
        var ent: Bytes = bytes(padded)
        encode_u64_le_to(ent, 0, ino)
        encode_u64_le_to(ent, 8, padded)
        encode_u32_le_to(ent, 16, name_bytes)
        encode_u32_le_to(ent, 20, dtype)
        var j = 0
        while j < name_bytes:
            ent[24 + j] = ord(name[j])
            j = j + 1
        var k = 0
        while k < padded:
            bytes_push(payload, ent[k])
            k = k + 1
        i = i + 1
    var resp: Bytes = bytes(16 + bytes_len(payload))
    encode_u32_le_to(resp, 0, 16 + bytes_len(payload))
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    i = 0
    while i < bytes_len(payload):
        resp[16 + i] = payload[i]
        i = i + 1
    return resp

## build_attr_response — Build a FUSE getattr response (fuse_attr_out, 88 bytes)
proc build_attr_response(unique: Int, st: Dict) -> Bytes:
    ## fuse_attr_out is the 16-byte out_header plus one fuse_attr, so the
    ## attribute starts at 16 and the reply is 16 + FUSE_ATTR_LEN bytes.
    ##
    ## This allocated 16 + FUSE_ATTR_LEN and then started the attribute at 32,
    ## 16 bytes past the end, so write_attr's last field landed out of bounds.
    ## The bytecode backend silently dropped those writes and produced a
    ## plausible short reply; the C backend wrote past the buffer and later
    ## failed allocation. It also wrote an entry_out-style nlookup at 16, which
    ## fuse_attr_out does not have.
    let total: Int = 16 + FUSE_ATTR_LEN
    var resp: Bytes = bytes(total)
    encode_u32_le_to(resp, 0, total)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    write_attr(resp, 16, st)
    return resp

## fuse_run — Main FUSE event loop
##
## Loops reading FUSE request frames from /dev/fuse via FFI,
## dispatching each to the appropriate handler, and writing
## the reply back to /dev/fuse.
##
## Implements the FUSE ABI 7.26 binary protocol directly,
## accessing /dev/fuse via libc open() read() write() close()
## through the SageVM FFI layer.
##
## Protocol flow:
##   1. Open /dev/fuse with O_RDWR via libc.open()
##   2. Read 32-byte fuse_in_header (little-endian)
##   3. Read remaining payload (len - 32 bytes)
##   4. Parse opcode and payload fields
##   5. Dispatch opcode to on_op_* handler
##   6. Encode response (fuse_out_header + payload)
##   7. Write response to /dev/fuse via libc.write()
##   8. On FUSE_DESTROY, unmount and exit loop
## fuse_run — mount and serve.
##
## `fd` is -1 normally, meaning open /dev/fuse and mount as usual. Passing a
## descriptor runs the loop against an already-attached channel and skips the
## mount, which is how testing/test_fuse_loop.sage drives this loop on a host
## where mounting is not permitted. It is a parameter rather than a second entry
## point so the loop body is the same code either way -- a test that called a
## separate function would exercise a copy, and copies go stale.
proc fuse_run(fs: vfs.VFS, mountpoint: String, fd: Int = -1):
    if libc_lib == nil and not fuse_init_libc():
        print("FUSE: libc unavailable; cannot run the FUSE loop")
        return

    var mounted: Bool = true
    if fd < 0:
        ## O_RDWR on /dev/fuse, then mount. Both are required: the descriptor is
        ## what the kernel reads requests from, and the mount is what makes this
        ## process the filesystem at `mountpoint`. Opening the device alone leaves
        ## the loop reading from a device no filesystem is attached to.
        fd = ffi.call(libc_lib, "open", "int", ["/dev/fuse", 2, 0])
        if fd < 0:
            print("FUSE: cannot open /dev/fuse (is the fuse module loaded?)")
            return
        print("FUSE: opened /dev/fuse (fd=" + str(fd) + ")")
        mounted = fuse_mount(mountpoint, fd)
    else:
        print("FUSE: descriptor supplied (fd=" + str(fd) + "), skipping mount")
    fuse_fd = fd

    if not mounted:
        print("FUSE: could not mount on " + mountpoint)
        ffi.call(libc_lib, "close", "int", [fuse_fd])
        fuse_fd = -1
        return

    if mountpoint != "":
        print("FUSE: mounted on " + mountpoint)

    let HEADER_SIZE: Int = FUSE_IN_HEADER_LEN
    let buf_size: Int = 1048576

    var running: Bool = true
    ## Consecutive zero-length reads tolerated before the channel is considered
    ## finished. See the nread == 0 branch below.
    let FUSE_EMPTY_READ_LIMIT: Int = 50
    var empty_reads: Int = 0
    while running:
        var hdr_buf: Bytes = bytes(HEADER_SIZE)
        let nread: Int = fuse_read_fd(fuse_fd, hdr_buf, HEADER_SIZE)
        if nread < 0:
            ## ENODEV from read() is how the kernel says "unmount". That, not a
            ## DESTROY opcode, is the end of the session.
            on_op_destroy(fs)
            break
        if nread == 0:
            ## A short grace period for a spurious zero, then treat it as the end
            ## of the channel.
            ##
            ## The previous behaviour was to usleep(1ms) and loop forever. On
            ## /dev/fuse that is unreachable, because the kernel blocks in read
            ## and reports an unmount as ENODEV. On any other descriptor read
            ## returning 0 is end-of-stream, so the loop never exited: it burned
            ## a millisecond of CPU per iteration indefinitely, and because it
            ## inherits stdout it also held the parent's output pipe open, so
            ## anything reading that pipe waited forever. Bounding it here is
            ## what lets testing/test_fuse_loop.sage close its end cleanly.
            empty_reads = empty_reads + 1
            if empty_reads > FUSE_EMPTY_READ_LIMIT:
                break
            ffi.call(libc_lib, "usleep", "int", [1000])
            continue
        empty_reads = 0

        let req_len: Int = decode_u32_le(hdr_buf, 0)
        let opcode: Int = decode_u32_le(hdr_buf, 4)
        let unique: Int = decode_u64_le(hdr_buf, 8)
        let nodeid: Int = decode_u64_le(hdr_buf, 16)
        let uid: Int = decode_u32_le(hdr_buf, 24)
        let gid: Int = decode_u32_le(hdr_buf, 28)
        let pid: Int = decode_u32_le(hdr_buf, 32)

        var body: Bytes = bytes(0)
        let body_len: Int = req_len - HEADER_SIZE
        if body_len > buf_size:
            ## Too large to hold. Answering with a truncated body would hand the
            ## handlers a plausible-looking name or offset that is not the
            ## kernel's, which is worse than refusing.
            resp = build_error_response(unique, FUSE_EINVAL)
            fuse_write_fd(fuse_fd, resp)
            continue
        if body_len > 0:
            body = bytes(body_len)
            let nbody: Int = fuse_read_fd(fuse_fd, body, body_len)
            if nbody < body_len:
                body = fileio.slice_bytes(body, 0, nbody)

        var args: Dict = {}
        args["parent"] = nodeid
        args["ino"] = nodeid
        args["pid"] = pid
        args["uid"] = uid
        args["gid"] = gid

        match opcode:
            case FUSE_LOOKUP:
                let name_end: Int = find_in_bytes(body, 0)
                args["name"] = body_to_string(fileio.slice_bytes(body, 0, name_end))
            case FUSE_INIT:
                args["major"] = decode_u32_le(body, 0)
                args["minor"] = decode_u32_le(body, 4)
                args["max_readahead"] = decode_u32_le(body, 8)
                args["flags"] = decode_u32_le(body, 12)
            case FUSE_FORGET:
                args["ino"] = nodeid
                let nlookup: Int = decode_u64_le(body, 0)
                continue
            case FUSE_INTERRUPT:
                ## No reply: a stale interrupt has no addressee.
                continue
            case FUSE_SETATTR:
                args["ino"] = nodeid
                args["valid"] = decode_u32_le(body, 0)
                args["fh"] = decode_u64_le(body, 8)
                args["size"] = decode_u64_le(body, 16)
                args["lock_owner"] = decode_u64_le(body, 24)
                args["ctime"] = decode_u64_le(body, 56)
                args["mtime"] = decode_u64_le(body, 64)
                args["atime"] = decode_u64_le(body, 72)
            case FUSE_GETATTR:
                args["ino"] = nodeid
                if body_len >= 8:
                    args["getattr_flags"] = decode_u32_le(body, 0)
            case FUSE_OPEN:
                args["ino"] = nodeid
                ## fuse_open_in is 8 bytes: flags@0, open_flags@4. Guarded like
                ## the GETATTR case above: decode_u32_le reads four separate
                ## bytes, so an undersized body raises four separate
                ## out-of-bounds errors and leaves flags as nil, which
                ## on_op_open then treats as an unusable descriptor.
                if body_len >= 4:
                    args["flags"] = decode_u32_le(body, 0)
            case FUSE_OPENDIR:
                ## Same fuse_open_in body as FUSE_OPEN, and the same guard.
                ## Without the parse, args["flags"] stayed nil and dispatch
                ## handed on_op_open a nil flags, so OPENDIR never produced a
                ## reply and a directory listing hung the caller.
                args["ino"] = nodeid
                if body_len >= 4:
                    args["flags"] = decode_u32_le(body, 0)
            case FUSE_READ:
                args["ino"] = nodeid
                args["fh"] = decode_u64_le(body, 0)
                args["offset"] = decode_u64_le(body, 8)
                args["size"] = decode_u32_le(body, 16)
            case FUSE_WRITE:
                args["ino"] = nodeid
                args["fh"] = decode_u64_le(body, 0)
                args["offset"] = decode_u64_le(body, 8)
                args["size"] = decode_u32_le(body, 16)
                ## The payload starts after the 40-byte write header. This used
                ## to start at 16, so 24 bytes of protocol header were written
                ## into the file as if they were file data.
                if body_len > FUSE_WRITE_DATA_OFF:
                    args["data"] = fileio.slice_bytes(body, FUSE_WRITE_DATA_OFF, body_len)
                else:
                    args["data"] = bytes(0)
            case FUSE_MKDIR:
                let name_end: Int = find_in_bytes(body, FUSE_MKDIR_NAME_OFF)
                args["parent"] = nodeid
                args["mode"] = decode_u32_le(body, 0)
                args["umask"] = decode_u32_le(body, 4)
                args["name"] = body_to_string(fileio.slice_bytes(body, FUSE_MKDIR_NAME_OFF, name_end))
            case FUSE_READDIR:
                args["ino"] = nodeid
            case FUSE_RMDIR:
                let name_end: Int = find_in_bytes(body, 0)
                args["parent"] = nodeid
                args["name"] = body_to_string(fileio.slice_bytes(body, 0, name_end))
            case FUSE_UNLINK:
                let name_end: Int = find_in_bytes(body, 0)
                args["parent"] = nodeid
                args["name"] = body_to_string(fileio.slice_bytes(body, 0, name_end))
            case FUSE_CREATE:
                let name_end: Int = find_in_bytes(body, FUSE_CREATE_NAME_OFF)
                args["parent"] = nodeid
                args["flags"] = decode_u32_le(body, 0)
                args["mode"] = decode_u32_le(body, 4)
                args["umask"] = decode_u32_le(body, 8)
                args["name"] = body_to_string(fileio.slice_bytes(body, FUSE_CREATE_NAME_OFF, name_end))
            case FUSE_RENAME:
                ## newdir is a real field, not a repeat of nodeid. Treating it as
                ## nodeid made every cross-directory rename a same-directory one,
                ## silently moving the file to the wrong place.
                args["newparent"] = decode_u64_le(body, FUSE_RENAME_NEW_DIR_OFF)
                let old_end: Int = find_in_bytes(body, FUSE_RENAME_OLD_NAME_OFF)
                let new_start: Int = old_end + 1
                let new_end: Int = find_in_bytes(body, new_start)
                args["parent"] = nodeid
                args["name"] = body_to_string(fileio.slice_bytes(body, FUSE_RENAME_OLD_NAME_OFF, old_end))
                args["newname"] = body_to_string(fileio.slice_bytes(body, new_start, new_end))

            case FUSE_RELEASE:
                args["ino"] = nodeid
                on_op_release(fs, nodeid)
                continue
            default:
                print("FUSE: unhandled opcode " + str(opcode))
                continue

        let result: Any = dispatch(fs, opcode, args)

        var resp: Bytes = bytes(0)
        match opcode:
            case FUSE_INIT:
                if result != nil:
                    resp = build_init_response(unique, result["max_readahead"], result["flags"], result["max_write"])
                else:
                    resp = build_error_response(unique, FUSE_EIO)
            case FUSE_LOOKUP:
                if result != nil:
                    resp = build_lookup_response(unique, result)
                else:
                    resp = build_error_response(unique, FUSE_ENOENT)
            case FUSE_GETATTR:
                ## Was missing entirely, so it fell through to a bare OK with no
                ## attributes in it. stat(), ls -l and every path walk the kernel
                ## does first go through here.
                if result != nil and dict_has(result, "exists") and result["exists"]:
                    resp = build_attr_response(unique, result)
                else:
                    resp = build_error_response(unique, FUSE_ENOENT)
            case FUSE_SETATTR:
                if result != nil:
                    resp = build_attr_response(unique, result)
                else:
                    resp = build_error_response(unique, FUSE_ENOENT)
            case FUSE_ACCESS:
                if result != nil:
                    resp = build_ok_response(unique)
                else:
                    resp = build_error_response(unique, FUSE_EACCES)
            case FUSE_FLUSH:
                resp = build_ok_response(unique)
            case FUSE_FSYNC:
                resp = build_ok_response(unique)
            case FUSE_OPENDIR:
                if result != nil and result >= 0:
                    resp = build_ok_response(unique)
                else:
                    resp = build_error_response(unique, FUSE_EIO)
            case FUSE_RELEASEDIR:
                resp = build_ok_response(unique)
            case FUSE_OPEN:
                if result >= 0:
                    resp = build_open_response(unique, result)
                else:
                    resp = build_error_response(unique, -result)
            case FUSE_READ:
                if result != nil:
                    resp = build_read_response(unique, result)
                else:
                    resp = build_error_response(unique, FUSE_EIO)
            case FUSE_WRITE:
                if result >= 0:
                    resp = build_write_response(unique, result)
                else:
                    resp = build_error_response(unique, -result)
            case FUSE_STATFS:
                resp = build_statfs_response(unique, result)
            case FUSE_MKDIR:
                resp = build_bool_response(unique, result, FUSE_EIO)
            case FUSE_READDIR:
                resp = build_readdir_response(unique, result)
            case FUSE_RMDIR:
                resp = build_bool_response(unique, result, FUSE_EIO)
            case FUSE_UNLINK:
                resp = build_bool_response(unique, result, FUSE_EIO)
            case FUSE_CREATE:
                if result >= 0:
                    resp = build_open_response(unique, result)
                else:
                    resp = build_error_response(unique, -result)
            case FUSE_RENAME:
                resp = build_bool_response(unique, result, FUSE_EIO)
            default:
                resp = build_ok_response(unique)

        ## Through fuse_write_fd, not write(2) directly. ffi.call needs a live
        ## pointer, and resp is a Bytes value: the C backend rejects it as
        ## "unsupported argument types for int return", which made the loop
        ## answer nothing at all. fuse_write_fd allocates and copies.
        let nwrote: Int = fuse_write_fd(fuse_fd, resp)
        if nwrote < bytes_len(resp):
            print("FUSE: short write (" + str(nwrote) + "/" + str(bytes_len(resp)) + ")")
            break

    ## Leave nothing mounted: an orphaned mount would keep the image locked and
    ## the mountpoint unusable after the daemon exits.
    fuse_unmount()
    ffi.call(libc_lib, "close", "int", [fuse_fd])
    fuse_fd = -1
    print("FUSE: event loop exited")