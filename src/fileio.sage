## ffio.sage — low-level file I/O through FFI.
##
## The FFI passes at most three arguments to a C function, and a buffer argument
## has to be a mem_alloc pointer rather than a Bytes. Passing a Bytes matches no
## specialisation: the call returns nil and the byte count is silently lost.
## That is not a limitation worth working around once, so the pattern lives here
## and everything above it calls these.
##
## This module deliberately knows nothing about filesystems. It opens, reads,
## writes, seeks and closes. imgio builds image access on it; fuse builds the
## /dev/fuse loop on it. Neither depends on the other.

import ffi

## libc_handle — Cached libc handle. Not named `libc`: the FFI layer uses that
## name internally and shadowing it at module scope breaks the import.
var libc_handle: Any = nil

## init — Load libc. Returns true if the handle is usable.
proc init() -> Bool:
    if libc_handle != nil:
        return true
    try:
        libc_handle = ffi.open("libc.so.6")
        if libc_handle == nil:
            return false
        return true
    catch e:
        return false

## ffio_open_rd — open(path, O_RDONLY). Returns a descriptor, or -1.
proc open_rd(path: String) -> Int:
    if not init():
        return -1
    return ffi.call(libc_handle, "open", "int", [path, 0])

## ffio_open_rw — open(path, O_WRONLY|O_CREAT|O_TRUNC, 0644). Returns a descriptor, or -1.
proc open_rw(path: String) -> Int:
    if not init():
        return -1
    return ffi.call(libc_handle, "open", "int", [path, 577, 420])

## ffio_open_rdw — open(path, O_RDWR|O_CREAT, 0644): no truncation.
##
## Not the same as open_rw(), and the difference is not cosmetic. O_TRUNC drops
## the file to zero length the moment it is opened, so a "write at offset N"
## built on open_rw() destroys everything below N and leaves a hole above it --
## the write appears to succeed and returns the right byte count while silently
## erasing the file. Anything that places a block inside an existing file needs
## this instead.
proc open_rdw(path: String) -> Int:
    if not init():
        return -1
    ## O_RDWR|O_CREAT = 2|64 = 66.
    return ffi.call(libc_handle, "open", "int", [path, 66, 420])

## ffio_open_append — open(path, O_WRONLY|O_APPEND|O_CREAT, 0644).
proc open_append(path: String) -> Int:
    if not init():
        return -1
    ## O_WRONLY|O_CREAT|O_APPEND = 1|64|1024 = 1089.
    return ffi.call(libc_handle, "open", "int", [path, 1089, 420])

## ffio_close — close(2).
proc close(fd: Int):
    if fd >= 0:
        ffi.call(libc_handle, "close", "int", [fd])

## ffio_seek — lseek(2) to an absolute offset. Returns the new offset, or -1.
proc seek(fd: Int, offset: Int) -> Int:
    if not init():
        return -1
    return ffi.call(libc_handle, "lseek", "int", [fd, offset, 0])

## ffio_size — Size of the file behind fd, via lseek(0, SEEK_END).
proc size(fd: Int) -> Int:
    if not init():
        return -1
    ffi.call(libc_handle, "lseek", "int", [fd, 0, 2])
    let end: Int = ffi.call(libc_handle, "lseek", "int", [fd, 0, 1])
    ffi.call(libc_handle, "lseek", "int", [fd, 0, 0])
    return end

## ffio_truncate — truncate(2). Extends with zeros, or shortens.
proc truncate(path: String, size: Int) -> Bool:
    if not init():
        return false
    return ffi.call(libc_handle, "truncate", "int", [path, size]) == 0

## ffio_read — read(2) into buf, at most bytes_len(buf) bytes.
##
## Returns the number of bytes read, 0 at end of file, or a negative value on
## error. The buffer cannot be overrun: the request is capped at the buffer's own
## length, so a caller that under-allocates gets a short read rather than a
## scribble past the end.
proc read(fd: Int, buf: Bytes) -> Int:
    let cap: Int = bytes_len(buf)
    if cap <= 0:
        return 0
    let ptr = mem_alloc(cap)
    if ptr == nil:
        return 0
    let got: Int = ffi.call(libc_handle, "read", "int", [fd, ptr, cap])
    if got > 0:
        let n: Int = got
        if n > cap:
            n = cap
        ## One memcpy instead of one mem_read per byte.
        ##
        ## This used to loop `while i < n: buf[i] = mem_read(ptr, i, "byte")`, which
        ## made reading a large image cost one interpreted FFI round trip per byte.
        ## A 10,690,560-byte read is 10.7 million of them: that trips the
        ## interpreter's 10,000,000-iteration loop cap outright, so any volume over
        ## about 10 MB could not be read at all, and below the cap it still ran at
        ## roughly 1.4 MB/s.
        ##
        ## mem_copy_from_ptr returns nil rather than copying when n exceeds either
        ## the pointer's owned size or the Bytes, so this cannot overrun the buffer;
        ## the cap above already clamps n to cap, which is the binding limit.
        let copied: Int = mem_copy_from_ptr(ptr, buf, n)
        if copied == nil:
            mem_free(ptr)
            return -1
    mem_free(ptr)
    return got

## ffio_write — write(2) all of buf. Returns bytes written, or negative.
proc write(fd: Int, buf: Bytes) -> Int:
    let n: Int = bytes_len(buf)
    if n <= 0:
        return 0
    let ptr = mem_alloc(n)
    if ptr == nil:
        return 0
    ## One memcpy instead of one mem_write per byte -- same 10M-iteration-cap
    ## problem as read() above. Returns nil rather than copying if n exceeds
    ## either bound.
    let copied: Int = mem_copy_to_ptr(ptr, buf, n)
    if copied == nil:
        mem_free(ptr)
        return -1
    let put: Int = ffi.call(libc_handle, "write", "int", [fd, ptr, n])
    mem_free(ptr)
    return put

## write_at — Write all of buf at `offset`, without truncating the file.
##
## The ranged counterpart to read_at(). io.writebytes() replaces the whole file,
## so the only way to place a block was to rebuild the entire image in memory
## each time -- which silently works right up until the image is large enough
## that bytes() returns an empty buffer for it, and then the block lands at
## offset 0. Seeks and writes instead, so a write costs one block of I/O
## regardless of volume size. Returns bytes written, or negative on failure.
proc write_at(path: String, offset: Int, buf: Bytes) -> Int:
    let n: Int = bytes_len(buf)
    if n <= 0:
        return 0
    let fd: Int = open_rdw(path)
    if fd < 0:
        return -1
    if seek(fd, offset) < 0:
        close(fd)
        return -1
    let put: Int = write(fd, buf)
    close(fd)
    return put

## size_of — Length of a file in bytes, or -1 if it cannot be opened.
##
## Not the same as size(fd): that one needs an open descriptor, and the tools
## that want to know how big an image is have none yet. Reuses size()'s
## lseek-to-end rather than stat(), because the FFI returns only an int and
## st_size would have to be read back out of the struct by hand.
proc size_of(path: String) -> Int:
    let fd: Int = open_rd(path)
    if fd < 0:
        return -1
    let n: Int = size(fd)
    close(fd)
    return n

## slice_bytes — A Bytes covering buf[start, end).
##
## slice() on a Bytes returns an *array of numbers*, not a Bytes. It matches what
## indexing a Bytes yields, which is a defensible rule and a trap here: the
## result indexes correctly but bytes_len() on it is 0, so anything that measures
## a slice before using it sees an empty buffer. Every protocol parser that
## sliced a request body and then wrote it out was writing nothing.
proc slice_bytes(buf: Bytes, start: Int, end: Int) -> Bytes:
    let n: Int = bytes_len(buf)
    var a: Int = start
    var b: Int = end
    if a < 0:
        a = 0
    if b > n:
        b = n
    if b <= a:
        return bytes()
    ## One memmove rather than a per-byte loop.
    ##
    ## Slicing a 256 MiB image was 268 million interpreted index assignments, which
    ## is what produced the ten million "Invalid index assignment" lines and the
    ## iteration-ceiling abort: mounting a volume mkfs had just created walked this
    ## loop once per byte and never finished. It also used `out[i] = buf[a + i]`,
    ## which is not the bytes_set() form, so the write was a generic index
    ## assignment on a Bytes.
    let out: Bytes = bytes(b - a)
    bytes_copy_range(out, 0, buf, a, b - a)
    return out

## read_at — Read `size` bytes from `offset` into a new Bytes.
##
## This is the ranged read that the whole-file path cannot do. io.readbytes()
## refuses anything over 100 MiB and returns nil with no error, so a larger image
## reads back as length 0. A bounded range works at any size.
proc read_at(path: String, offset: Int, size: Int) -> Bytes:
    if size <= 0:
        return bytes()
    let fd: Int = open_rd(path)
    if fd < 0:
        return bytes()
    let ok: Int = seek(fd, offset)
    if ok < 0:
        close(fd)
        return bytes()
    var buf: Bytes = bytes(size)
    let got: Int = read(fd, buf)
    close(fd)
    if got <= 0:
        return bytes()
    if got < size:
        return slice_bytes(buf, 0, got)
    return buf
