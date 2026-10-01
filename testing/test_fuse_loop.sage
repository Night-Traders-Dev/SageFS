## test_fuse_loop.sage — drive the real FUSE event loop without a mount.
##
## This host cannot mount FUSE: fusermount3 is 3.18 and rejects the fd= handoff
## with "old style mounting not supported", mount namespaces are refused
## (unshare -m fails EPERM), and mount(2) inside a user namespace returns EPERM
## even as root-in-namespace. /dev/fuse opens fine and is mode 0666, so the
## mount syscall is the only blocked step, and it is host policy.
##
## Everything past it is testable. fuse_run() takes its descriptor as a
## parameter, so pointing that at one end of a connected socket pair and writing
## real kernel-format frames into the other exercises the code a live mount
## would run: read framing, body splitting, dispatch, the on_op_* handlers
## against a real VFS, every encoder, and fuse_write_fd.
##
## What this cannot cover is whether the kernel would accept those replies. That
## needs a host that permits mounting.
##
## All output goes through write(2) on fd 2, never print(). stdout is
## stdio-buffered and fork() hands the child a copy of the parent's unflushed
## buffer, so a child appears to repeat the parent's lines and a parent appears
## to return the child's value. An earlier version of this file was written
## with print() and produced exactly that confusion twice; the assertions below
## are only trustworthy because the log cannot be duplicated.

import sys
import io
import ffi
import superblock
import imgio
import vfs
import fuse

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0
var lib: Any = nil

## Unbuffered. See the file header for why this matters more than it looks.
proc note(s: String):
    let n: Int = len(s)
    let p = mem_alloc(n)
    var i: Int = 0
    while i < n:
        mem_write(p, i, "byte", bytes(s)[i])
        i = i + 1
    ffi.call(lib, "write", "int", [2, p, n])
    mem_free(p)

proc check(name: String, got: Any, expected: Any):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        note("  PASS  " + name + "\n")
    else:
        note("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected) + "\n")

proc put_u32(buf: Bytes, off: Int, v: Int):
    buf[off] = v & 0xFF
    buf[off + 1] = (v >> 8) & 0xFF
    buf[off + 2] = (v >> 16) & 0xFF
    buf[off + 3] = (v >> 24) & 0xFF

proc put_u64(buf: Bytes, off: Int, v: Int):
    var i: Int = 0
    while i < 8:
        buf[off + i] = (v >> (i * 8)) & 0xFF
        i = i + 1

## read(2) into a Bytes via a mem_alloc buffer. Read one call at a time rather
## than looping until want bytes arrive: these are request/reply sockets, so a
## short read means the reply has not been written yet, not that the peer is
## done. Blocking is the loop's job, and read(2) already blocks.
proc read_exact(fd: Int, want: Int) -> Bytes:
    let p = mem_alloc(want)
    let n: Int = ffi.call(lib, "read", "int", [fd, p, want])
    let out: Bytes = bytes(want)
    if n > 0:
        var i: Int = 0
        while i < n:
            out[i] = mem_read(p, i, "byte")
            i = i + 1
    mem_free(p)
    return out

## The 16-byte fuse_out_header the loop writes back.
proc recv_reply(fd: Int) -> List:
    let hdr: Bytes = read_exact(fd, 16)
    let total: Int = fuse.decode_u32_le(hdr, 0)
    let err: Int = fuse.decode_i32_le(hdr, 4)
    let unique: Int = fuse.decode_u64_le(hdr, 8)
    var body: Bytes = bytes(0)
    if total > 16:
        body = read_exact(fd, total - 16)
    return [err, unique, body]

## Hand-built fuse_in_header. Built here rather than taken from the kernel so a
## wrong offset shows up as a wrong assertion instead of a plausible reply.
proc make_req(opcode: Int, unique: Int, nodeid: Int, body: Bytes) -> Bytes:
    let total: Int = fuse.FUSE_IN_HEADER_LEN + bytes_len(body)
    let buf: Bytes = bytes(total)
    put_u32(buf, 0, total)
    put_u32(buf, 4, opcode)
    put_u64(buf, 8, unique)
    put_u64(buf, 16, nodeid)
    put_u32(buf, 24, 0)
    put_u32(buf, 28, 0)
    put_u32(buf, 32, 1234)
    var i: Int = 0
    while i < bytes_len(body):
        buf[fuse.FUSE_IN_HEADER_LEN + i] = body[i]
        i = i + 1
    return buf

proc send_frame(fd: Int, req: Bytes):
    let ptr = mem_alloc(bytes_len(req))
    var i: Int = 0
    while i < bytes_len(req):
        mem_write(ptr, i, "byte", req[i])
        i = i + 1
    ffi.call(lib, "write", "int", [fd, ptr, bytes_len(req)])
    mem_free(ptr)

proc strbytes(s: String) -> Bytes:
    let b: Bytes = bytes(0)
    let src: Bytes = bytes(s)
    var i: Int = 0
    while i < bytes_len(src):
        bytes_push(b, src[i])
        i = i + 1
    return b

proc make_image(path: String) -> Bool:
    io.remove(path)
    let sb = superblock.create_superblock(32768, "SageFS", 4096, 512,
                                          {"checksum_algo": superblock.CHECKSUM_CRC32C})
    imgio.write_image(path, sb.serialize())
    imgio.truncate_to(path,
                      sb.inode_entry_start_blk * sb.block_size + sb.inode_entry_byte_size)
    let setup: Any = vfs.VFS(path)
    if not setup.mount():
        return false
    let payload: Bytes = bytes(0)
    var k: Int = 0
    while k < 5:
        bytes_push(payload, 65 + k)
        k = k + 1
    let wfd = setup.create_file("/hello.txt", 577)
    setup.write(wfd, payload)
    setup.close(wfd)
    setup.unmount()
    return true

proc main(args: Array):
    lib = ffi.open("libc.so.6")
    if lib == nil:
        note("  FAIL  could not open libc\n")
        return

    let img: String = "/tmp/opencode/fuse_loop.img"
    check("image built", make_image(img), true)

    ## socketpair(2) takes four arguments, past ffi.call's three-argument
    ## ceiling, hence bind/listen/connect/accept. sockaddr_un is 110 bytes and
    ## its family is a host-endian uint16, so AF_UNIX is the two bytes 01 00 --
    ## not the little-endian 32-bit encoding of 1, which bind rejects with
    ## EAFNOSUPPORT.
    let path: String = "/tmp/opencode/fuse_loop.sock"
    io.remove(path)
    let bp = mem_alloc(128)
    mem_write(bp, 0, "byte", 1)
    mem_write(bp, 1, "byte", 0)
    var q: Int = 0
    while q < len(path):
        mem_write(bp, 2 + q, "byte", bytes(path)[q])
        q = q + 1
    let srv: Int = ffi.call(lib, "socket", "int", [1, 1, 0])
    check("socket", srv >= 0, true)
    check("bind", ffi.call(lib, "bind", "int", [srv, bp, 110]) == 0, true)
    check("listen", ffi.call(lib, "listen", "int", [srv, 1]) == 0, true)
    let cli: Int = ffi.call(lib, "socket", "int", [1, 1, 0])
    check("connect", ffi.call(lib, "connect", "int", [cli, bp, 110]) == 0, true)
    let kfd: Int = ffi.call(lib, "accept", "int", [srv, 0, 0])
    check("accepted", kfd >= 0, true)
    ffi.call(lib, "close", "int", [srv])
    io.remove(path)

    ## The loop blocks in read() waiting for a kernel, so it gets its own
    ## process. fork() takes no arguments and ffi.call's argument list is fine
    ## empty, but passing one value the x86-64 SysV ABI ignores keeps the call
    ## shape uniform with the three-argument calls around it.
    let pid: Int = ffi.call(lib, "fork", "int", [0])
    if pid == 0:
        ## Child. _exit rather than return: this process shares the parent's
        ## memory image and must not run the parent's cleanup or assertions.
        let cfs: Any = vfs.VFS(img)
        if cfs.mount():
            fuse.fuse_run(cfs, "", cli)
            cfs.unmount()
        ffi.call(lib, "_exit", "int", [0])

    ## Checked here, not before the branch above: the child holds pid == 0, so a
    ## check placed earlier fails in the child too and reports a second failure
    ## that reads like a real one. That is what made an earlier version of this
    ## file look as though fork() had returned nil in the parent.
    check("forked the loop", pid > 0, true)

    ## Drop our end of the loop's channel, or its read() never sees end of
    ## stream and the loop spins on usleep forever.
    ffi.call(lib, "close", "int", [cli])

    ## --- FUSE_INIT: the kernel refuses to answer anything before this ---
    let init_body: Bytes = bytes(16)
    put_u32(init_body, 0, 7)
    put_u32(init_body, 4, 26)
    send_frame(kfd, make_req(fuse.FUSE_INIT, 1, 0, init_body))
    let r1 = recv_reply(kfd)
    check("INIT unique echoed", r1[1], 1)
    check("INIT no error", r1[0], 0)
    check("INIT carries fuse_init_out", bytes_len(r1[2]) >= fuse.FUSE_INIT_OUT_LEN - 16, true)

    ## --- GETATTR on the root ---
    send_frame(kfd, make_req(fuse.FUSE_GETATTR, 2, 1, bytes(0)))
    let r2 = recv_reply(kfd)
    check("GETATTR unique echoed", r2[1], 2)
    check("GETATTR no error", r2[0], 0)
    check("GETATTR carries attr_out", bytes_len(r2[2]) >= 88, true)

    ## --- LOOKUP: present, then absent ---
    send_frame(kfd, make_req(fuse.FUSE_LOOKUP, 3, 1, strbytes("hello.txt")))
    let r3 = recv_reply(kfd)
    check("LOOKUP unique echoed", r3[1], 3)
    check("LOOKUP found", r3[0], 0)
    check("LOOKUP reply has entry plus attrs", bytes_len(r3[2]) >= fuse.FUSE_ENTRY_OUT_LEN - 16, true)

    send_frame(kfd, make_req(fuse.FUSE_LOOKUP, 4, 1, strbytes("nope.tx")))
    let r4 = recv_reply(kfd)
    check("LOOKUP missing unique echoed", r4[1], 4)
    check("LOOKUP missing is -ENOENT", r4[0], -2)

    ## --- OPENDIR then READDIR ---
    ## Take the inode from the LOOKUP reply rather than assuming one. fuse_entry_out
    ## is nodeid@0, so the first eight bytes of the body are the id the kernel will
    ## use for this file. Guessing it made OPEN and READ address the wrong inode.
    let file_ino: Int = fuse.decode_u64_le(r3[2], 0)
    check("LOOKUP returned an inode id", file_ino > 1, true)

    send_frame(kfd, make_req(fuse.FUSE_OPENDIR, 5, 1, bytes(0)))
    let r5 = recv_reply(kfd)
    check("OPENDIR no error", r5[0], 0)
    let rdir: Bytes = bytes(24)
    put_u64(rdir, 0, 0)
    put_u32(rdir, 16, 4096)
    send_frame(kfd, make_req(fuse.FUSE_READDIR, 6, 1, rdir))
    let r6 = recv_reply(kfd)
    check("READDIR unique echoed", r6[1], 6)
    check("READDIR no error", r6[0], 0)
    check("READDIR returned entries", bytes_len(r6[2]) > 0, true)

    ## --- OPEN then READ the file back ---
    send_frame(kfd, make_req(fuse.FUSE_OPEN, 7, file_ino, bytes(0)))
    let r7 = recv_reply(kfd)
    check("OPEN unique echoed", r7[1], 7)
    ## fuse_read_in is fh@0, offset@8, size@16. Writing size at 8 instead put a
    ## 5 into the low half of the 64-bit offset and made the loop read ~5PiB
    ## past the file, which surfaced as "Bytes index out of bounds" rather than
    ## as a bad offset.
    let rbody: Bytes = bytes(24)
    put_u64(rbody, 0, 0)
    put_u64(rbody, 8, 0)
    put_u32(rbody, 16, 5)
    send_frame(kfd, make_req(fuse.FUSE_READ, 8, file_ino, rbody))
    let r8 = recv_reply(kfd)
    check("READ unique echoed", r8[1], 8)
    check("READ no error", r8[0], 0)
    check("READ returned the 5 bytes asked for", bytes_len(r8[2]) >= 5, true)

    ffi.call(lib, "close", "int", [kfd])
    ## Signalled, not waited for. With the peer gone, read(2) returns 0, and the
    ## loop treats 0 as "no request in flight yet" and keeps calling usleep --
    ## a 1ms busy-wait that never ends. Waiting for a clean exit therefore hangs
    ## forever. That is worth knowing about the real loop too: /dev/fuse reports
    ## an unmount as ENODEV, so the spin does not bite in production, but it is
    ## still unbounded CPU on any descriptor that reports EOF.
    ffi.call(lib, "kill", "int", [pid, 9])
    ffi.call(lib, "waitpid", "int", [pid, 0])
    io.remove(img)

    note("  " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " assertions passed\n")

main(sys.args())