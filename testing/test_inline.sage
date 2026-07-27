## test_inline.sage — Inline data I/O tests
##
## Tests that the VFS correctly stores and retrieves small files
## using inline data (stored directly in the inode).

import vfs
import imgio

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

proc make_test_image() -> String:
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
    imgio.write_image(path, buf)
    return path

proc main():
    print("=== SageFS Inline Data I/O Tests ===")

    let path: String = make_test_image()

    let fs: vfs.VFS = vfs.VFS(path, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
    let ok: Bool = fs.mount()
    check("mount", ok, true)

    let content: String = "This is test content stored directly in the inode."
    let content_len: Int = len(content)

    let fd: Int = fs.open("/hello.txt", vfs.O_CREAT | vfs.O_RDWR)
    check("open hello.txt", fd >= 0, true)

    let data_bytes: Bytes = bytes(content)
    let written: Int = fs.write(fd, data_bytes)
    check_int("write returns length", written, content_len)

    let st: Dict = fs.stat("/hello.txt")
    check("stat exists", st["exists"], true)
    check_int("stat size matches", st["size"], content_len)

    fs.lseek(fd, 0, vfs.SEEK_SET)

    let raw: Bytes = fs.read(fd, bytes_len(data_bytes))
    let data_str: String = bytes_to_string(raw)
    check_int("read returns full content", bytes_len(raw), content_len)
    check_str("content matches", data_str, content)

    fs.close(fd)

    let fd2: Int = fs.open("/hello.txt", vfs.O_RDONLY)
    check("second open succeeds", fd2 >= 0, true)
    let data2: Bytes = fs.read(fd2, 5)
    let prefix: String = bytes_to_string(data2)
    check_str("read prefix", prefix, "This ")
    fs.close(fd2)

    fs.unmount()

    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL INLINE DATA TESTS PASSED")

main()