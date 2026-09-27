## test_integration.sage — End-to-end format → mount → operate → unmount → remount cycle
##
## Tests the full lifecycle: format an image using the same superblock pipeline
## as mkfs, mount it via VFS, perform POSIX operations, persist, remount, verify.

import io
import superblock
import imgio
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

proc format_image(dev: String, label: String) -> Bool:
    let total_blocks: Int = 512
    let block_size: Int = 4096
    let segment_size: Int = 8
    let features: Dict = {"checksum_algo": superblock.CHECKSUM_CRC32C}

    let sb = superblock.create_superblock(total_blocks, label, block_size, segment_size, features)
    let buf = sb.serialize()

    let readme: String = ""
    readme = readme + "SageFS Filesystem\n"
    readme = readme + "=================\n"
    readme = readme + "Label: " + label + "\n"
    readme = readme + "This is a test image for integration testing.\n"

    let S_IFREG: Int = 0x8000

    ## Place the entry in the reserved inode-entry area, the way src/mkfs.sage
    ## does, rather than appending it after the superblock.
    ##
    ## imgio.write_inode_entry() *appends* to the end of buf, so the entry landed
    ## at ~468 while VFS.mount() reads the area at inode_entry_start_blk *
    ## block_size (8 * 4096 = 32768). The mount then read past the end of a
    ## 583-byte image, and bytes_get() returning nil for an out-of-range index
    ## turned into "Operands must be numbers or strings (number + nil)" inside
    ## imgio.read_inode_entries_from_area(). So this test never exercised a
    ## correctly formatted image at all -- it failed at mount for a reason that
    ## had nothing to do with what it meant to test.
    let bs: Int = sb.block_size
    let inode_area_offset: Int = sb.inode_entry_start_blk * bs
    var pad = bytes_len(buf)
    while pad < inode_area_offset + 200:
        bytes_push(buf, 0)
        pad = pad + 1
    imgio.write_inode_entry_at(buf, inode_area_offset, 2, S_IFREG | 0x1A4,
                               len(readme), "README.txt", readme)

    ## Pad out to image_size so the reserved area is really present on disk.
    let min_image_size: Int = sb.inode_entry_start_blk * sb.block_size + sb.inode_entry_byte_size
    if bytes_len(buf) > min_image_size:
        sb.image_size = bytes_len(buf)
    else:
        sb.image_size = min_image_size
    var j = bytes_len(buf)
    while j < sb.image_size:
        bytes_push(buf, 0)
        j = j + 1

    ## Re-serialise so the superblock records the final image_size.
    let sb_bytes = sb.serialize()
    var k = 0
    while k < bytes_len(sb_bytes):
        buf[k] = sb_bytes[k]
        k = k + 1

    return imgio.write_image(dev, buf)

proc main():
    print("=== SageFS End-to-End Integration Tests ===")

    let dev: String = "/tmp/sagefs_integration_test.img"

    let label: String = "IntegrationTest"
    let fmt_ok: Bool = format_image(dev, label)
    check("format image", fmt_ok, true)

    let fs: vfs.VFS = vfs.VFS(dev)
    let mount_ok: Bool = fs.mount()
    check("mount", mount_ok, true)

    let root_entries: Array[String] = fs.readdir("/")
    check("readdir root", len(root_entries) >= 3, true)

    var found_readme: Bool = false
    for entry in root_entries:
        if entry == "README.txt":
            found_readme = true
    check("README.txt in root", found_readme, true)

    let st_readme: Dict = fs.stat("/README.txt")
    check("README.txt exists", st_readme["exists"], true)
    check("README.txt size > 0", st_readme["size"] > 0, true)

    let readme_fd: Int = fs.open("/README.txt", vfs.O_RDONLY)
    check("open README.txt", readme_fd >= 0, true)

    let readme_content: Bytes = fs.read(readme_fd, 256)
    let readme_str: String = bytes_to_string(readme_content)
    check("READEME.txt starts with SageFS", readme_str[0:7] == "SageFS ", true)
    fs.close(readme_fd)

    let mkdir_ok: Bool = fs.mkdir("/subdir", 0x1ED)
    check("mkdir /subdir", mkdir_ok, true)

    let subdir_entries: Array[String] = fs.readdir("/subdir")
    check("readdir /subdir", len(subdir_entries) == 2, true)

    let fd: Int = fs.open("/subdir/testfile.txt", vfs.O_CREAT | vfs.O_RDWR)
    check("create file in subdir", fd >= 0, true)

    let test_content: String = "Integration test data for SageFS end-to-end verification."
    let content_len: Int = len(test_content)
    let written: Int = fs.write(fd, bytes(test_content))
    check_int("write returns length", written, content_len)

    fs.lseek(fd, 0, vfs.SEEK_SET)
    let raw: Bytes = fs.read(fd, content_len)
    let readback: String = bytes_to_string(raw)
    check_str("readback matches written", readback, test_content)
    fs.close(fd)

    let st_file: Dict = fs.stat("/subdir/testfile.txt")
    check("testfile.txt exists", st_file["exists"], true)
    check_int("testfile.txt size matches", st_file["size"], content_len)

    let unmount_ok: Bool = fs.unmount()
    check("unmount", unmount_ok, true)

    let fs2: vfs.VFS = vfs.VFS(dev)
    let remount_ok: Bool = fs2.mount()
    check("remount", remount_ok, true)

    let root2: Array[String] = fs2.readdir("/")
    check("root readable after remount", len(root2) >= 3, true)

    let st2: Dict = fs2.stat("/README.txt")
    check("README.txt persists", st2["exists"], true)

    let st3: Dict = fs2.stat("/subdir/testfile.txt")
    check("testfile.txt persists", st3["exists"], true)
    check_int("testfile.txt size persists", st3["size"], content_len)

    let fd2: Int = fs2.open("/subdir/testfile.txt", vfs.O_RDONLY)
    check("reopen after remount", fd2 >= 0, true)

    let raw2: Bytes = fs2.read(fd2, content_len)
    let readback2: String = bytes_to_string(raw2)
    check_str("content persists after remount", readback2, test_content)
    fs2.close(fd2)

    fs2.unmount()

    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL INTEGRATION TESTS PASSED")

main()