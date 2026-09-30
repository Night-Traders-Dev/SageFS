## The FFI layer the FUSE event loop actually depends on, tested against a real
## file descriptor.
##
## This exists because every read() in fuse_run() was passing a Bytes where the
## FFI wants a mem_alloc pointer. That matches no specialisation, so the call
## returned nil and the byte count was lost -- silently, with no error. On a
## host where the mount succeeded, the loop would have read nil, compared nil to
## 0, and exited immediately.
##
## The handlers were all correct. This is the one layer beneath them that had
## never been exercised against anything real.

import fuse

var total = 0
var passed = 0
var fails = 0

proc ck(name: String, cond: Bool):
    total = total + 1
    if cond:
        passed = passed + 1
        print("  PASS  " + name)
    else:
        fails = fails + 1
        print("  FAIL  " + name)

## Build a fixture here rather than depending on an image file that other tests
## create, resize or delete. The original version read a mkfs image, and failed
## whenever that image was a different size than it happened to be when written.
let fixture: String = "/tmp/fuse_ffi_fixture.bin"
let mkfd = fuse.fuse_open_rw(fixture)
var mkbuf: Bytes = bytes(64)
var mk: Int = 0
while mk < 64:
    mkbuf[mk] = mk
    mk = mk + 1
fuse.fuse_write_fd(mkfd, mkbuf)
fuse.fuse_close_fd(mkfd)

## Read its contents back through the FFI.
let fd = fuse.fuse_open_rd(fixture)
ck("open returned a descriptor", fd >= 3)

var buf: Bytes = bytes(4)
let n = fuse.fuse_read_fd(fd, buf, 4)
ck("read returned 4", n == 4)
ck("byte 0", buf[0] == 0)
ck("byte 1", buf[1] == 1)
ck("byte 2", buf[2] == 2)
ck("byte 3", buf[3] == 3)

## A buffer smaller than the request must not overrun.
var small: Bytes = bytes(2)
let fd2 = fuse.fuse_open_rd(fixture)
let n2 = fuse.fuse_read_fd(fd2, small, 4)
ck("a short buffer caps the read at its own length", n2 == 2)
ck("and still fills what it can", small[0] == 0 and small[1] == 1)

## Reading past EOF returns 0, not a crash.
let fd3 = fuse.fuse_open_rd(fixture)
fuse.fuse_lseek(fd3, 1000000)
let n3 = fuse.fuse_read_fd(fd3, buf, 4)
ck("reading past EOF returns 0", n3 == 0)

## Round trip through write.
let outp: String = "/tmp/fuse_io_rt.bin"
var wbuf: Bytes = bytes(5)
wbuf[0] = 72
wbuf[1] = 105
wbuf[2] = 33
wbuf[3] = 10
wbuf[4] = 0
let wfd = fuse.fuse_open_rw(outp)
ck("open for writing returned a descriptor", wfd >= 3)
let wn = fuse.fuse_write_fd(wfd, wbuf)
ck("write reported all 5 bytes", wn == 5)
fuse.fuse_close_fd(wfd)

let rfd = fuse.fuse_open_rd(outp)
var rbuf: Bytes = bytes(5)
let rn = fuse.fuse_read_fd(rfd, rbuf, 5)
ck("read back 5 bytes", rn == 5)
var same = true
var i = 0
while i < 5:
    if rbuf[i] != wbuf[i]:
        same = false
    i = i + 1
ck("the bytes survived the round trip", same)

print("  Results: " + str(passed) + "/" + str(total) + " passed")
if fails == 0:
    print "ALL FUSE FFI IO TESTS PASSED"
else:
    print "FUSE FFI IO TESTS FAILED"
