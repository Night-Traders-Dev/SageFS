## test_inline.sage — Inline data I/O tests
##
## Tests that the VFS reads inline data from the on-disk inode directory
## rather than returning empty bytes.  Builds an image with a real inode
## entry containing inline data, mounts it, and verifies the data round-trips.

import imgio
import vfs
let VFS = vfs.VFS

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check(name: String, got: Bool, expected: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc check_int(name: String, got: Int, expected: Int):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc check_str(name: String, got: String, expected: String):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + got + " expected=" + expected)

proc main():
    print("=== SageFS Inline Data I/O Tests ===")

    let path: String = "/tmp/sagefs_inline_test.img"
    var buf: Bytes = bytes()

    bytes_push(buf, 69)
    bytes_push(buf, 71)
    bytes_push(buf, 65)
    bytes_push(buf, 83)
    var i: Int = 4
    while i < 428:
        bytes_push(buf, 0)
        i = i + 1

    let greeting: String = "Hello from inline data!"
    let content: String = "This is test content stored directly in the inode."

    let S_IFREG: Int = 0x8000
    imgio.write_inode_entry(buf, 2, S_IFREG | 0x1A4, len(content), "hello.txt", content)

    imgio.write_image(path, buf)

    let fs = VFS(path)
    let mounted: Bool = fs.mount()
    check("mount", mounted, true)

    let fd: Int = fs.open("/hello.txt", vfs.O_RDONLY)
    check("open hello.txt", fd >= 0, true)

    let raw: Bytes = fs.read(fd, 200)
    let data_str: String = bytes_to_string(raw)
    check_int("read returns full content", bytes_len(raw), len(content))
    check_str("content matches", data_str, content)

    let st: Dict = fs.stat("/hello.txt")
    check("stat exists", st["exists"], true)
    check_int("stat size matches", st["size"], len(content))

    let fd2: Int = fs.open("/hello.txt", vfs.O_RDONLY)
    check("second open succeeds", fd2 >= 0, true)
    let data2: Bytes = fs.read(fd2, 5)
    let prefix: String = bytes_to_string(data2)
    check_str("read prefix", prefix, "This ")
    fs.close(fd2)

    fs.close(fd)
    fs.unmount()

    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL INLINE DATA TESTS PASSED")

main()
