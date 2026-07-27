## test_inline.sage — Inline data I/O tests
##
## Tests that the VFS correctly stores and retrieves small files
## using inline data (stored directly in the inode).

import vfs

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

    let fs: vfs.VFS = vfs.VFS(path)
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

    let raw: Bytes = fs.read(fd, 200)
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

    let fs2: vfs.VFS = vfs.VFS(path)
    let ok2: Bool = fs2.mount()
    check("remount", ok2, true)

    let fd3: Int = fs2.open("/hello.txt", vfs.O_RDONLY)
    check("reopen after remount", fd3 >= 0, true)
    let data3: Bytes = fs2.read(fd3, 200)
    let data3_str: String = bytes_to_string(data3)
    check_str("content persists after remount", data3_str, content)
    fs2.close(fd3)
    fs2.unmount()

    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL INLINE DATA TESTS PASSED")

main()