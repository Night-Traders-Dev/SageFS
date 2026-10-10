## Low-level file I/O through the FFI, tested against real file descriptors.
##
## These primitives are what both imgio and the FUSE event loop are built on, and
## the pattern they need is easy to get wrong in a way that fails silently: the
## FFI takes a mem_alloc pointer for a buffer argument, and a Bytes matches no
## specialisation, so the call returns nil and the byte count is lost with no
## error. The tests below open real files and check the bytes that come back.

import fileio
import imgio
import sys

## Two distinguishable 4-byte payloads for the ranged-write test below.
let bytes_pattern_a: Bytes = bytes(4)
bytes_pattern_a[0] = 0xAB
bytes_pattern_a[1] = 0xCD
bytes_pattern_a[2] = 0xEF
bytes_pattern_a[3] = 0x01
let bytes_pattern_b: Bytes = bytes(4)
bytes_pattern_b[0] = 0x12
bytes_pattern_b[1] = 0x34
bytes_pattern_b[2] = 0x56
bytes_pattern_b[3] = 0x78

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

print("ranged writes:")
## Regression: open_rw() is O_WRONLY|O_CREAT|O_TRUNC, so a "write at offset N"
## built on it drops the file to zero length on open and leaves a hole. It
## reports the full byte count, so the caller believes the write worked while
## everything below the offset is gone. RAID stripes overwrite earlier stripes
## on the same device this way, and a repaired block reads back as zeros.
let rwpath: String = "/tmp/fileio_ranged_write.bin"
sys.exec("rm -f " + rwpath)
fileio.write_at(rwpath, 0, bytes_pattern_a)
let put: Int = fileio.write_at(rwpath, 0, bytes_pattern_a)
check("ranged write reports the byte count", put == bytes_len(bytes_pattern_a))
let head: Bytes = fileio.read_at(rwpath, 0, 4)
check("ranged write landed at offset 0",
      bytes_len(head) == 4 and head[0] == 0xAB and head[1] == 0xCD)
## The original failure mode: write a second block *past* existing content.
## Under O_TRUNC the open would zero the whole file, so bytes_pattern_a at 0..3
## would be gone even though the write returned 8.
let later: Bytes = bytes(8)
later[0] = 0x5A
later[1] = 0x5B
put = fileio.write_at(rwpath, 4, later)
check("write past existing content reports the byte count", put == 8)
let both: Bytes = fileio.read_at(rwpath, 0, 12)
check("file now spans both writes", bytes_len(both) == 12)
check("earlier bytes survive a later write",
      bytes_len(both) >= 4 and both[0] == 0xAB and both[1] == 0xCD and both[3] == 0x01)
check("later bytes were written", both[4] == 0x5A and both[5] == 0x5B)
sys.exec("rm -f " + rwpath)

## Regression: size_of() reported lseek's answer through the FFI's 32-bit "int"
## return type, so a file of 2 GiB or more came back negative. Callers that treat
## a negative size as "cannot be opened" then reject a perfectly good volume --
## mkfs reported "could not size" for an image it had just created correctly.
## The boundary the search has to find is where the last byte stops existing.
let bigpath: String = "/tmp/fileio_size_probe.bin"
sys.exec("rm -f " + bigpath)
fileio.write_at(bigpath, 0, bytes_pattern_a)
check("size_of a small file is its length",
      fileio.size_of(bigpath) == bytes_len(bytes_pattern_a))
## Extending past EOF leaves a hole; the length is where the data stops being
## reachable, not where the last real block was written.
let hole_at: Int = 3000000
fileio.write_at(bigpath, hole_at, later)
check("size_of counts the gap up to the far write",
      fileio.size_of(bigpath) == hole_at + 8)
let empty_path: String = "/tmp/fileio_size_empty.bin"
sys.exec("rm -f " + empty_path)
fileio.write_at(empty_path, 0, bytes(1))
sys.exec("rm -f " + empty_path)
sys.exec("touch " + empty_path)
check("size_of a zero-length file is 0", fileio.size_of(empty_path) == 0)
check("size_of a missing file is -1", fileio.size_of("/tmp/fileio_absent.bin") == -1)
sys.exec("rm -f " + bigpath)
sys.exec("rm -f " + empty_path)

## The wrap this fixes was not visible below 2 GiB, because the answer fitted.
## seek() and size() read lseek's off_t through a 32-bit int return, so a file at
## 4 GiB measured negative and every caller took that for "cannot be opened".
## Sparse, so the test costs a few kilobytes on disk rather than four gigabytes.
let hugepath: String = "/tmp/fileio_huge.bin"
sys.exec("rm -f " + hugepath)
let huge_size: Int = 4294967296
check("a 4 GiB file can be created and measured",
      imgio.truncate_to(hugepath, huge_size) and fileio.size_of(hugepath) == huge_size)
## size_of() recovers a wrapped answer by probing, so it would read correctly
## even with the narrow call underneath it. size(fd) is the primitive that wraps,
## and everything that measures a file goes through it.
let huge_fd: Int = fileio.open_rd(hugepath)
check("size(fd) reports a 4 GiB length, not a wrapped negative",
      huge_fd >= 0 and fileio.size(huge_fd) == huge_size)
fileio.close(huge_fd)
let far_gap: Int = huge_size - 4096
let tail = bytes(8)
tail[0] = 0x11
tail[7] = 0x77
check("a write near the far end of a 4 GiB file lands",
      fileio.write_at(hugepath, far_gap, tail) == 8)
let far_got: Bytes = fileio.read_at(hugepath, far_gap, 8)
check("and reads back", bytes_len(far_got) == 8 and far_got[0] == 0x11 and far_got[7] == 0x77)
let hole: Bytes = fileio.read_at(hugepath, huge_size / 2, 4)
check("the hole left between reads as zeros", bytes_len(hole) == 4)
check("the file is still the length it was asked to be",
      fileio.size_of(hugepath) == huge_size)
sys.exec("rm -f " + hugepath)

print("  Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
if TESTS_RUN == TESTS_PASSED:
    print("ALL FILEIO TESTS PASSED")
else:
    print("FILEIO TESTS FAILED")
