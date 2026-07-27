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

import vfs

let FUSE_ROOT_ID: Int = 1

let FUSE_LOOKUP: Int = 1
let FUSE_GETATTR: Int = 3
let FUSE_OPEN: Int = 14
let FUSE_READ: Int = 15
let FUSE_WRITE: Int = 16
let FUSE_STATFS: Int = 17
let FUSE_RELEASE: Int = 18
let FUSE_MKDIR: Int = 27
let FUSE_READDIR: Int = 28
let FUSE_RMDIR: Int = 29
let FUSE_UNLINK: Int = 30
let FUSE_CREATE: Int = 35
let FUSE_RENAME: Int = 38
let FUSE_DESTROY: Int = 39

let FUSE_ATTR_MODE: Int = 0
let FUSE_ATTR_UID: Int = 0
let FUSE_ATTR_GID: Int = 0
let FUSE_ATTR_SIZE: Int = 0
let FUSE_ATTR_ATIME: Int = 0
let FUSE_ATTR_MTIME: Int = 0
let FUSE_ATTR_CTIME: Int = 0

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
        fuse_session = ffi.call(fuse_lib, "fuse_session_new", [mountpoint])
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

## decode_u32_le — Decode a 32-bit little-endian integer from a Bytes buffer
proc decode_u32_le(buf: Bytes, off: Int) -> Int:
    return buf[off] | (buf[off + 1] << 8) | (buf[off + 2] << 16) | (buf[off + 3] << 24)

## decode_u64_le — Decode a 64-bit little-endian integer from a Bytes buffer
proc decode_u64_le(buf: Bytes, off: Int) -> Int:
    let lo: Int = buf[off] | (buf[off + 1] << 8) | (buf[off + 2] << 16) | (buf[off + 3] << 24)
    let hi: Int = buf[off + 4] | (buf[off + 5] << 8) | (buf[off + 6] << 16) | (buf[off + 7] << 24)
    return lo | (hi << 32)

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
proc encode_i32_le_to(buf: Bytes, off: Int, val: Int):
    buf[off] = val & 0xff
    buf[off + 1] = (val >> 8) & 0xff
    buf[off + 2] = (val >> 16) & 0xff
    buf[off + 3] = (val >> 24) & 0xff

## on_op_lookup — FUSE LOOKUP handler
proc on_op_lookup(fs: vfs.VFS, parent: Int, name: String) -> Int:
    if parent == FUSE_ROOT_ID:
        let path: String = "/" + name
        return fs.resolve_path(path)
    return -1

## on_op_getattr — FUSE GETATTR handler
proc on_op_getattr(fs: vfs.VFS, ino: Int) -> Dict:
    if ino == FUSE_ROOT_ID:
        return fs.stat("/")
    return fs.stat("")

## on_op_read — FUSE READ handler
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

## on_op_write — FUSE WRITE handler
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

## on_op_mkdir — FUSE MKDIR handler
proc on_op_mkdir(fs: vfs.VFS, parent: Int, name: String, mode: Int) -> Bool:
    let path: String = "/" + name
    return fs.mkdir(path, mode)

## on_op_readdir — FUSE READDIR handler
proc on_op_readdir(fs: vfs.VFS, ino: Int) -> Array[String]:
    if ino == FUSE_ROOT_ID:
        return fs.readdir("/")
    var empty: Array[String] = []
    return empty

## on_op_unlink — FUSE UNLINK handler
proc on_op_unlink(fs: vfs.VFS, parent: Int, name: String) -> Bool:
    let path: String = "/" + name
    return fs.unlink(path)

## on_op_rmdir — FUSE RMDIR handler
proc on_op_rmdir(fs: vfs.VFS, parent: Int, name: String) -> Bool:
    let path: String = "/" + name
    return fs.rmdir(path)

## on_op_rename — FUSE RENAME handler
proc on_op_rename(fs: vfs.VFS, parent: Int, name: String, newparent: Int, newname: String) -> Bool:
    let oldpath: String = "/" + name
    let newpath: String = "/" + newname
    return fs.rename(oldpath, newpath)

## on_op_create — FUSE CREATE handler
proc on_op_create(fs: vfs.VFS, parent: Int, name: String, mode: Int) -> Int:
    let path: String = "/" + name
    return fs.open(path, vfs.O_CREAT | vfs.O_RDWR)

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
    let path: String = ""
    if ino == FUSE_ROOT_ID:
        path = "/"
    return fs.open(path, flags)

## dispatch — Central FUSE opcode dispatcher
##
## Routes a FUSE opcode to the corresponding handler function,
## extracting arguments from the args Dict.  Returns the handler's
## result (nil for void handlers).
proc dispatch(fs: vfs.VFS, opcode: Int, args: Dict) -> Any:
    match opcode:
        case FUSE_LOOKUP:
            return on_op_lookup(fs, args["parent"], args["name"])
        case FUSE_GETATTR:
            return on_op_getattr(fs, args["ino"])
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
        case FUSE_DESTROY:
            on_op_destroy(fs)
            return nil
        default:
            return nil

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

## build_lookup_response — Build a FUSE lookup response (entry_out, 72 bytes)
proc build_lookup_response(unique: Int, ino: Int) -> Bytes:
    var resp: Bytes = bytes(72)
    encode_u32_le_to(resp, 0, 72)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    encode_u64_le_to(resp, 24, ino)
    return resp

## build_open_response — Build a FUSE open response (open_out, 24 bytes)
proc build_open_response(unique: Int, fh: Int) -> Bytes:
    var resp: Bytes = bytes(24)
    encode_u32_le_to(resp, 0, 24)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    encode_u64_le_to(resp, 24, fh)
    return resp

## build_read_response — Build a FUSE read response (header + data)
proc build_read_response(unique: Int, data: Bytes) -> Bytes:
    let data_len: Int = bytes_len(data)
    var resp: Bytes = bytes(16 + data_len)
    encode_u32_le_to(resp, 0, 16 + data_len)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    var j: Int = 0
    while j < data_len:
        resp[16 + j] = data[j]
        j = j + 1
    return resp

## build_write_response — Build a FUSE write response (write_out, 24 bytes)
proc build_write_response(unique: Int, size: Int) -> Bytes:
    var resp: Bytes = bytes(24)
    encode_u32_le_to(resp, 0, 24)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    encode_u64_le_to(resp, 24, size)
    return resp

## build_bool_response — Build a FUSE bool response (16 bytes, ok or error)
proc build_bool_response(unique: Int, success: Bool, unused: Int) -> Bytes:
    if success:
        return build_ok_response(unique)
    return build_error_response(unique, -1)

## build_readdir_response — Build a FUSE readdir response with dentries
proc build_readdir_response(unique: Int, entries: Array[String]) -> Bytes:
    let count: Int = len(entries)
    var resp: Bytes = bytes(16 + 12 * count)
    encode_u32_le_to(resp, 0, 16 + 12 * count)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    var j: Int = 0
    while j < count:
        encode_u64_le_to(resp, 16 + j * 12, 0)
        encode_u64_le_to(resp, 24 + j * 12, 0)
        encode_u32_le_to(resp, 32 + j * 12, len(entries[j]))
        j = j + 1
    return resp

## build_statfs_response — Build a FUSE statfs response (120 bytes)
proc build_statfs_response(unique: Int, st: Dict) -> Bytes:
    var resp: Bytes = bytes(120)
    encode_u32_le_to(resp, 0, 120)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    encode_u64_le_to(resp, 24, st["bsize"])
    encode_u64_le_to(resp, 32, st["frsize"])
    encode_u64_le_to(resp, 40, st["blocks"])
    encode_u64_le_to(resp, 48, st["bfree"])
    encode_u64_le_to(resp, 56, st["bavail"])
    encode_u64_le_to(resp, 64, st["files"])
    encode_u64_le_to(resp, 72, st["ffree"])
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
proc fuse_run(fs: vfs.VFS):
    if libc_lib == nil and not fuse_init_libc():
        print("FUSE: libc unavailable, falling back to Python bridge")
        return

    fuse_fd = ffi.call(libc_lib, "open", ["/dev/fuse", 2, 0])
    if fuse_fd < 0:
        print("FUSE: cannot open /dev/fuse")
        return

    print("FUSE: opened /dev/fuse (fd=" + str(fuse_fd) + ")")

    let HEADER_SIZE: Int = 32
    let buf_size: Int = 65536

    var running: Bool = true
    while running:
        var hdr_buf: Bytes = bytes(HEADER_SIZE)
        let nread: Int = ffi.call(libc_lib, "read", [fuse_fd, hdr_buf, HEADER_SIZE])
        if nread <= 0:
            break

        let req_len: Int = decode_u32_le(hdr_buf, 0)
        let opcode: Int = decode_u32_le(hdr_buf, 4)
        let unique: Int = decode_u64_le(hdr_buf, 8)
        let nodeid: Int = decode_u64_le(hdr_buf, 16)
        let pid: Int = decode_u32_le(hdr_buf, 24)

        var body: Bytes = bytes(0)
        let body_len: Int = req_len - HEADER_SIZE
        if body_len > 0 and body_len <= buf_size:
            body = bytes(body_len)
            let nbody: Int = ffi.call(libc_lib, "read", [fuse_fd, body, body_len])
            if nbody < body_len:
                body = slice(body, 0, nbody)

        var args: Dict = {}
        args["parent"] = nodeid
        args["ino"] = nodeid
        args["pid"] = pid

        match opcode:
            case FUSE_LOOKUP:
                let name_end: Int = find_in_bytes(body, 0)
                args["name"] = body_to_string(slice(body, 0, name_end))
            case FUSE_GETATTR:
                args["ino"] = nodeid
            case FUSE_OPEN:
                args["ino"] = nodeid
                args["flags"] = decode_u32_le(body, 0)
            case FUSE_READ:
                args["ino"] = nodeid
                args["offset"] = decode_u64_le(body, 0)
                args["size"] = decode_u32_le(body, 8)
            case FUSE_WRITE:
                args["ino"] = nodeid
                args["offset"] = decode_u64_le(body, 0)
                args["size"] = decode_u32_le(body, 8)
                args["data"] = slice(body, 16, req_len)
            case FUSE_MKDIR:
                let name_end: Int = find_in_bytes(body, 0)
                args["parent"] = nodeid
                args["name"] = body_to_string(slice(body, 0, name_end))
                args["mode"] = decode_u32_le(body, name_end + 1)
            case FUSE_READDIR:
                args["ino"] = nodeid
            case FUSE_RMDIR:
                let name_end: Int = find_in_bytes(body, 0)
                args["parent"] = nodeid
                args["name"] = body_to_string(slice(body, 0, name_end))
            case FUSE_UNLINK:
                let name_end: Int = find_in_bytes(body, 0)
                args["parent"] = nodeid
                args["name"] = body_to_string(slice(body, 0, name_end))
            case FUSE_CREATE:
                let name_end: Int = find_in_bytes(body, 0)
                args["parent"] = nodeid
                args["name"] = body_to_string(slice(body, 0, name_end))
                args["mode"] = decode_u32_le(body, name_end + 1)
            case FUSE_RENAME:
                let old_end: Int = find_in_bytes(body, 0)
                let new_start: Int = old_end + 1
                let new_end: Int = find_in_bytes(body, new_start)
                args["parent"] = nodeid
                args["name"] = body_to_string(slice(body, 0, old_end))
                args["newparent"] = nodeid
                args["newname"] = body_to_string(slice(body, new_start, new_end))
            case FUSE_DESTROY:
                on_op_destroy(fs)
                running = false
                continue
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
            case FUSE_LOOKUP:
                if result != nil and result >= 0:
                    resp = build_lookup_response(unique, result)
                else:
                    resp = build_error_response(unique, -2)
    ## build_attr_response — Build a FUSE getattr response (attr_out + entry_out, 88 bytes)
proc build_attr_response(unique: Int, st: Dict) -> Bytes:
    var resp: Bytes = bytes(88)
    encode_u32_le_to(resp, 0, 88)
    encode_i32_le_to(resp, 4, 0)
    encode_u64_le_to(resp, 8, unique)
    encode_u64_le_to(resp, 24, 0)
    return resp
                else:
                    resp = build_error_response(unique, -2)
            case FUSE_OPEN:
                if result >= 0:
                    resp = build_open_response(unique, result)
                else:
                    resp = build_error_response(unique, -result)
            case FUSE_READ:
                if result != nil:
                    resp = build_read_response(unique, result)
                else:
                    resp = build_error_response(unique, -5)
            case FUSE_WRITE:
                if result >= 0:
                    resp = build_write_response(unique, result)
                else:
                    resp = build_error_response(unique, -result)
            case FUSE_STATFS:
                resp = build_statfs_response(unique, result)
            case FUSE_MKDIR:
                resp = build_bool_response(unique, result, 0)
            case FUSE_READDIR:
                resp = build_readdir_response(unique, result)
            case FUSE_RMDIR:
                resp = build_bool_response(unique, result, 0)
            case FUSE_UNLINK:
                resp = build_bool_response(unique, result, 0)
            case FUSE_CREATE:
                if result >= 0:
                    resp = build_open_response(unique, result)
                else:
                    resp = build_error_response(unique, -result)
            case FUSE_RENAME:
                resp = build_bool_response(unique, result, 0)
            default:
                resp = build_ok_response(unique)

        let nwrote: Int = ffi.call(libc_lib, "write", [fuse_fd, resp, bytes_len(resp)])
        if nwrote < bytes_len(resp):
            print("FUSE: short write (" + str(nwrote) + "/" + str(bytes_len(resp)) + ")")
            break

    ffi.call(libc_lib, "close", [fuse_fd])
    fuse_fd = -1
    print("FUSE: event loop exited")