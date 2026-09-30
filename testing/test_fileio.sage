## Low-level file I/O through the FFI, tested against real file descriptors.
##
## These primitives are what both imgio and the FUSE event loop are built on, and
## the pattern they need is easy to get wrong in a way that fails silently: the
## FFI takes a mem_alloc pointer for a buffer argument, and a Bytes matches no
## specialisation, so the call returns nil and the byte count is lost with no
## error. The tests below open real files and check the bytes that come back.

import fileio

var TESTS_RUN = 0
var TESTS_PASSED = 0

proc check(name: String, cond: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if cond:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name)

## Build a small file to read back, without depending on any image.
proc make_fixture(path: String) -> Bool:
    let fd: Int = fileio.open_rw(path)
    if fd < 0:
        return false
    var b: Bytes = bytes(64)
    var i: Int = 0
    while i < 64:
        b[i] = i
        i = i + 1
    let n: Int = fileio.write(fd, b)
    fileio.close(fd)
    return n == 64

print("open, read, close:")
let path: String = "/tmp/fileio_test_fixture.bin"
check("wrote a 64-byte fixture", make_fixture(path))

let fd: Int = fileio.open_rd(path)
check("open_rd returned a descriptor", fd >= 3)
check("size is 64", fileio.size(fd) == 64)

var buf: Bytes = bytes(8)
check("read 8 bytes", fileio.read(fd, buf) == 8)
check("byte 0", buf[0] == 0)
check("byte 1", buf[1] == 1)
check("byte 7", buf[7] == 7)

print("bounds:")
var small: Bytes = bytes(2)
let fd2: Int = fileio.open_rd(path)
check("a short buffer caps the read at its own length", fileio.read(fd2, small) == 2)
check("and fills what it can", small[0] == 0 and small[1] == 1)
fileio.close(fd2)

fileio.seek(fd, 1000000)
var past: Bytes = bytes(4)
check("reading past EOF returns 0", fileio.read(fd, past) == 0)
var empty: Bytes = bytes(0)
check("reading into a zero-length buffer returns 0", fileio.read(fd, empty) == 0)
fileio.close(fd)

print("seek and ranged reads:")
check("seek to 10", fileio.seek(fileio.open_rd(path), 10) == 10)
let r1: Bytes = fileio.read_at(path, 0, 16)
check("read_at returns the requested length", bytes_len(r1) == 16)
check("read_at returns the right bytes", r1[0] == 0 and r1[1] == 1 and r1[10] == 10)
let r2: Bytes = fileio.read_at(path, 60, 16)
check("read_at clamps at EOF rather than failing", bytes_len(r2) == 4)
check("and the clamped bytes are the last ones", r2[3] == 63)
check("read_at of zero bytes", bytes_len(fileio.read_at(path, 0, 0)) == 0)
check("read_at past EOF", bytes_len(fileio.read_at(path, 1000, 4)) == 0)

print("write and truncate:")
let wpath: String = "/tmp/fileio_test_write.bin"
let wfd: Int = fileio.open_rw(wpath)
check("open_rw returned a descriptor", wfd >= 3)
var w: Bytes = bytes(3)
w[0] = 10
w[1] = 20
w[2] = 30
check("wrote 3 bytes", fileio.write(wfd, w) == 3)
fileio.close(wfd)
let wback: Bytes = fileio.read_at(wpath, 0, 3)
check("the bytes came back", bytes_len(wback) == 3 and wback[0] == 10 and wback[2] == 30)
check("truncate extends the file", fileio.truncate(wpath, 100000))
let rfd: Int = fileio.open_rd(wpath)
check("the extended size is 100000", fileio.size(rfd) == 100000)
fileio.close(rfd)
let tail: Bytes = fileio.read_at(wpath, 99999, 1)
check("the extension reads back as a zero", bytes_len(tail) == 1 and tail[0] == 0)

print("errors:")
check("open_rd of a missing file returns -1", fileio.open_rd("/tmp/fileio_no_such_file") == -1)
check("read_at of a missing file is empty", bytes_len(fileio.read_at("/tmp/fileio_no_such_file", 0, 8)) == 0)

print("  Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
if TESTS_RUN == TESTS_PASSED:
    print("ALL FILEIO TESTS PASSED")
else:
    print("FILEIO TESTS FAILED")
