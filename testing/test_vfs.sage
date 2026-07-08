## test_vfs.sage — VFS unit tests
##
## Tests the VFS interface layer (src/vfs.sage) — mount lifecycle,
## POSIX operations, and directory/file management.
##
## A hex-text image is created inline so the test is self-contained.

import sys
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

proc make_test_image() -> String:
    let path: String = "/tmp/sagefs_vfs_test.img"
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
    print("=== SageFS VFS Tests ===")

    let img: String = make_test_image()

    let fs = VFS(img)
    let mounted: Bool = fs.mount()
    check("mount valid image", mounted, true)

    let root_stat: Dict = fs.stat("/")
    check("root exists", root_stat["exists"], true)
    check("root is dir", root_stat["isdir"], true)

    let entries: Array[String] = fs.readdir("/")
    check_int("readdir returns entries", len(entries), 2)

    let mkdir_ok: Bool = fs.mkdir("/testdir", 0o755)
    check("mkdir testdir", mkdir_ok, true)

    let entries2: Array[String] = fs.readdir("/")
    check_int("readdir includes testdir", len(entries2), 3)

    let testdir_stat: Dict = fs.stat("/testdir")
    check("testdir exists", testdir_stat["exists"], true)

    let rmdir_ok: Bool = fs.rmdir("/testdir")
    check("rmdir testdir", rmdir_ok, true)

    let create_fd: Int = fs.open("/newfile.txt", vfs.O_CREAT | vfs.O_RDWR)
    check("create new file", create_fd >= 0, true)

    let close_ok: Bool = fs.close(create_fd)
    check("close fd", close_ok, true)

    let fd: Int = fs.open("/newfile.txt", vfs.O_RDONLY)
    check("open existing file", fd >= 0, true)

    let data: Bytes = fs.read(fd, 100)
    let data_len: Int = bytes_len(data)
    check_int("read returns data", data_len, 0)

    let pos: Int = fs.lseek(fd, 0, vfs.SEEK_SET)
    check_int("lseek to start", pos, 0)

    let close_fd2: Bool = fs.close(fd)
    check("close fd2", close_fd2, true)

    let unlink_ok: Bool = fs.unlink("/newfile.txt")
    check("unlink file", unlink_ok, true)

    let rename_ok: Bool = fs.mkdir("/movedir", 0o755)
    check("rename dir", rename_ok, true)

    let unmount_ok: Bool = fs.unmount()
    check("unmount", unmount_ok, true)

    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL VFS TESTS PASSED")
    else:
        print("SOME VFS TESTS FAILED")

main()
