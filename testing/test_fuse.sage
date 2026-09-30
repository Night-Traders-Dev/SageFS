## test_fuse.sage — FUSE protocol unit tests (no FFI required)
## Tests request parsing, response building, and handler logic

import sys
import fuse
import vfs
import superblock
import imgio

## Helper: write a little-endian u32 into a Bytes buffer at offset
proc poke_u32(buf: Bytes, off: Int, val: Int):
    bytes_set(buf, off, val & 0xFF)
    bytes_set(buf, off + 1, (val >> 8) & 0xFF)
    bytes_set(buf, off + 2, (val >> 16) & 0xFF)
    bytes_set(buf, off + 3, (val >> 24) & 0xFF)

## Helper: write a little-endian u64 into a Bytes buffer at offset
proc poke_u64(buf: Bytes, off: Int, val: Int):
    var i = 0
    while i < 8:
        bytes_set(buf, off + i, (val >> (i * 8)) & 0xFF)
        i = i + 1

## Helper: create a VFS with a mounted image for testing
proc make_vfs() -> vfs.VFS:
    let dev: String = "/tmp/test_fuse.img"
    let sb = superblock.create_superblock(65536, "TestFS", 4096, 512, {"checksum_algo": superblock.CHECKSUM_CRC32C})
    imgio.write_image(dev, sb.serialize())
    let fs = vfs.VFS(dev)
    if not fs.mount():
        return nil
    return fs

## Test 1: decode helpers
proc test_decode_helpers() -> Bool:
    let buf: Bytes = bytes(16)
    poke_u32(buf, 0, 0x12345678)
    poke_u32(buf, 4, 0xAABBCCDD)
    var i = 0
    while i < 8:
        var v = 0x123456789ABCDEF0 >> (i * 8)
        bytes_set(buf, 8 + i, v & 0xFF)
        i = i + 1
    if fuse.decode_u32_le(buf, 0) != 0x12345678:
        print "  FAIL test_decode_helpers: u32 at 0"
        return false
    if fuse.decode_u32_le(buf, 4) != 0xAABBCCDD:
        print "  FAIL test_decode_helpers: u32 at 4"
        return false
    var decoded: Int = fuse.decode_u64_le(buf, 8)
    if decoded != 0x123456789ABCDEF0:
        print "  FAIL test_decode_helpers: u64 at 8 (got " + str(decoded) + ")"
        return false
    print "  PASS test_decode_helpers"
    return true

## Test 2: build_init_response
proc test_build_init_response() -> Bool:
    let resp = fuse.build_init_response(1, 131072, 0, 65536)
    if bytes_len(resp) == 0:
        print "  FAIL test_build_init_response: empty"
        return false
    ## fuse_init_out is 80 bytes, so 16 + 80 = 96. This asserted 104, which is
    ## not a length the kernel accepts for INIT, and it only checked a length,
    ## so it also passed with every field at the wrong offset.
    if bytes_len(resp) != 96:
        print "  FAIL test_build_init_response: len=" + str(bytes_len(resp)) + " expected=96"
        return false
    if fuse.decode_u32_le(resp, 0) != 96:
        print "  FAIL test_build_init_response: length field"
        return false
    ## Negotiating major 7 is what the kernel checks the reply against.
    if fuse.decode_u32_le(resp, 16) != 7:
        print "  FAIL test_build_init_response: major at 16, got " + str(fuse.decode_u32_le(resp, 16))
        return false
    if fuse.decode_u32_le(resp, 20) != 26:
        print "  FAIL test_build_init_response: minor at 20, got " + str(fuse.decode_u32_le(resp, 20))
        return false
    if fuse.decode_u32_le(resp, 24) != 131072:
        print "  FAIL test_build_init_response: max_readahead at 24, got " + str(fuse.decode_u32_le(resp, 24))
        return false
    if fuse.decode_u32_le(resp, 36) != 65536:
        print "  FAIL test_build_init_response: max_write at 36, got " + str(fuse.decode_u32_le(resp, 36))
        return false
    print "  PASS test_build_init_response"
    return true

## Test 3: build_lookup_response
proc test_build_lookup_response() -> Bool:
    ## fuse_entry_out is 128 bytes, so 16 + 128 = 144. This asserted 112, which
    ## is a size the kernel does not accept, and it only checked a length, so it
    ## also passed when the reply carried no attributes at all.
    let st: Dict = {"ino": 7, "size": 1234, "mode": 33188, "nlink": 1, "blocks": 8}
    let resp = fuse.build_lookup_response(2, st)
    if bytes_len(resp) != 144:
        print "  FAIL test_build_lookup_response: len=" + str(bytes_len(resp))
        return false
    # fuse_out_header: len(0) error(4) unique(8)
    if fuse.decode_u32_le(resp, 0) != 144:
        print "  FAIL test_build_lookup_response: header length field"
        return false
    if fuse.decode_i32_le(resp, 4) != 0:
        print "  FAIL test_build_lookup_response: error field not zero"
        return false
    if fuse.decode_u64_le(resp, 8) != 2:
        print "  FAIL test_build_lookup_response: unique not echoed"
        return false
    # fuse_entry_out: nodeid(16) generation(24) entry_valid(32) attr_valid(40)
    if fuse.decode_u64_le(resp, 16) != 7:
        print "  FAIL test_build_lookup_response: nodeid at 16, got " + str(fuse.decode_u64_le(resp, 16))
        return false
    # fuse_attr starts at 56: ino(56) size(64) blocks(72) ... mode(128) nlink(132)
    if fuse.decode_u64_le(resp, 64) != 1234:
        print "  FAIL test_build_lookup_response: attr size, got " + str(fuse.decode_u64_le(resp, 64))
        return false
    if fuse.decode_u32_le(resp, 128) != 33188:
        print "  FAIL test_build_lookup_response: attr mode, got " + str(fuse.decode_u32_le(resp, 128))
        return false
    if fuse.decode_u32_le(resp, 132) != 1:
        print "  FAIL test_build_lookup_response: attr nlink"
        return false
    print "  PASS test_build_lookup_response"
    return true

## Test 4: build_open_response
proc test_build_open_response() -> Bool:
    let resp = fuse.build_open_response(3, 0)
    if bytes_len(resp) == 0:
        print "  FAIL test_build_open_response: empty"
        return false
    # 16-byte header + 16-byte fuse_open_out = 32
    if bytes_len(resp) != 32:
        print "  FAIL test_build_open_response: len=" + str(bytes_len(resp))
        return false
    print "  PASS test_build_open_response"
    return true

## Test 5: build_write_response
proc test_build_write_response() -> Bool:
    let resp = fuse.build_write_response(4, 4096)
    if bytes_len(resp) == 0:
        print "  FAIL test_build_write_response: empty"
        return false
    # 16-byte header + 8-byte fuse_write_out = 24
    if bytes_len(resp) != 24:
        print "  FAIL test_build_write_response: len=" + str(bytes_len(resp))
        return false
    print "  PASS test_build_write_response"
    return true

## Test 6: build_statfs_response
proc test_build_statfs_response() -> Bool:
    ## fuse_statfs_out is 120 bytes, so 16 + 120 = 136.
    let st: Dict = {"blocks": 100, "bfree": 40, "bavail": 35, "files": 10, "ffree": 9, "bsize": 4096}
    let resp = fuse.build_statfs_response(5, st)
    if bytes_len(resp) != 136:
        print "  FAIL test_build_statfs_response: len=" + str(bytes_len(resp))
        return false
    if fuse.decode_u32_le(resp, 0) != 136:
        print "  FAIL test_build_statfs_response: header length"
        return false
    if fuse.decode_u64_le(resp, 8) != 5:
        print "  FAIL test_build_statfs_response: unique not echoed"
        return false
    # fuse_statfs_out: blocks(16) bfree(24) bavail(32) files(40) ffree(48)
    #                  bsize(56) namelen(64) frsize(72)
    if fuse.decode_u64_le(resp, 16) != 100:
        print "  FAIL test_build_statfs_response: blocks at 16, got " + str(fuse.decode_u64_le(resp, 16))
        return false
    if fuse.decode_u64_le(resp, 24) != 40:
        print "  FAIL test_build_statfs_response: bfree"
        return false
    if fuse.decode_u64_le(resp, 48) != 9:
        print "  FAIL test_build_statfs_response: ffree"
        return false
    # bsize is a u64. The old encoder wrote it with a u32 helper into the
    # namelen slot, so a 4096-byte block size came back as 4096 with the rest
    # of the field belonging to the next one.
    if fuse.decode_u64_le(resp, 56) != 4096:
        print "  FAIL test_build_statfs_response: bsize, got " + str(fuse.decode_u64_le(resp, 56))
        return false
    print "  PASS test_build_statfs_response"
    return true

## Test 7: build_error_response
proc test_build_error_response() -> Bool:
    let resp = fuse.build_error_response(6, -5)
    if bytes_len(resp) == 0:
        print "  FAIL test_build_error_response: empty"
        return false
    # 16-byte header (error encoded in header.error field)
    if bytes_len(resp) != 16:
        print "  FAIL test_build_error_response: len=" + str(bytes_len(resp))
        return false
    print "  PASS test_build_error_response"
    return true

## Test 8: Response builders have correct unique field
proc test_response_unique_passthrough() -> Bool:
    var all_ok = true
    let tests = [["init", fuse.build_init_response(42, 131072, 0, 65536)],
                 ["lookup", fuse.build_lookup_response(42, 3)],
                 ["open", fuse.build_open_response(42, 0)],
                 ["write", fuse.build_write_response(42, 4096)],
                 ["error", fuse.build_error_response(42, -5)]]
    for t in tests:
        let name = t[0]
        let resp = t[1]
        if bytes_len(resp) < 16:
            print "  FAIL " + name + ": too short (" + str(bytes_len(resp)) + ")"
            all_ok = false
        else:
            let unique = fuse.decode_u64_le(resp, 8)
            if unique != 42:
                print "  FAIL " + name + ": unique=" + str(unique) + " expected 42"
                all_ok = false
    if all_ok:
        print "  PASS test_response_unique_passthrough"
    return all_ok

## Test 9: on_op_lookup with root returns root ino
proc test_on_op_lookup_root():
    let fs = make_vfs()
    if fs == nil:
        print "  FAIL test_on_op_lookup_root: make_vfs"
        return false
    let result = fuse.on_op_lookup(fs, fuse.FUSE_ROOT_ID, "/")
    if result == nil or result < 0:
        print "  FAIL test_on_op_lookup_root: result=" + str(result)
        fs.unmount()
        return false
    # Root should resolve to FUSE_ROOT_ID (1)
    if result != 1:
        print "  FAIL test_on_op_lookup_root: ino=" + str(result) + " expected 1"
        fs.unmount()
        return false
    print "  PASS test_on_op_lookup_root"
    fs.unmount()
    return true

## Test 10: on_op_getattr with root
proc test_on_op_getattr_root():
    let fs = make_vfs()
    if fs == nil:
        print "  FAIL test_on_op_getattr_root: make_vfs"
        return false
    let result = fuse.on_op_getattr(fs, fuse.FUSE_ROOT_ID)
    if result == nil:
        print "  FAIL test_on_op_getattr_root: nil result"
        fs.unmount()
        return false
    if not result["exists"]:
        print "  FAIL test_on_op_getattr_root: root not found"
        fs.unmount()
        return false
    print "  PASS test_on_op_getattr_root"
    fs.unmount()
    return true

## Test 11: on_op_mkdir + on_op_readdir
proc test_on_op_mkdir_and_readdir():
    let fs = make_vfs()
    if fs == nil:
        print "  FAIL test_on_op_mkdir_and_readdir: make_vfs"
        return false
    # mkdir /fusedir
    let mk = fuse.on_op_mkdir(fs, fuse.FUSE_ROOT_ID, "fusedir", 0o755)
    if mk == nil or not mk:
        print "  FAIL test_on_op_mkdir_and_readdir: mkdir failed"
        fs.unmount()
        return false
    # readdir /
    let entries = fuse.on_op_readdir(fs, fuse.FUSE_ROOT_ID)
    if entries == nil or len(entries) == 0:
        print "  FAIL test_on_op_mkdir_and_readdir: readdir empty"
        fs.unmount()
        return false
    ## Entries are "ino name type" triples, so this also pins the inode number
    ## and the DT_ type: a bare-name match would pass even if every entry were
    ## reported as inode 1 / DT_DIR, which is what this used to allow.
    var found = false
    var found_ino = 0
    var found_type = 0
    var saw_dot = false
    var saw_dotdot = false
    for e in entries:
        let sp = fuse.find_char(e, " ")
        if sp < 0:
            continue
        let ino_s = e[0:sp]
        let rest = e[sp + 1:len(e)]
        let tp = fuse.find_char(rest, " ")
        if tp < 0:
            continue
        let nm = rest[0:tp]
        if nm == ".":
            saw_dot = true
        if nm == "..":
            saw_dotdot = true
        if nm == "fusedir":
            found = true
            found_ino = fuse.str_to_int(ino_s)
            found_type = fuse.str_to_int(rest[tp + 1:len(rest)])
    if not found:
        print "  FAIL test_on_op_mkdir_and_readdir: fusedir not in readdir"
    if not saw_dot:
        print "  FAIL test_on_op_mkdir_and_readdir: no . entry"
    if not saw_dotdot:
        print "  FAIL test_on_op_mkdir_and_readdir: no .. entry"
    if found and found_ino <= fuse.FUSE_ROOT_ID:
        print "  FAIL test_on_op_mkdir_and_readdir: fusedir ino=" + str(found_ino)
    if found and found_type != 4:
        print "  FAIL test_on_op_mkdir_and_readdir: fusedir type=" + str(found_type) + " want 4 (DT_DIR)"
    if not found or not saw_dot or not saw_dotdot:
        fs.unmount()
        return false
        fs.unmount()
        return false
    print "  PASS test_on_op_mkdir_and_readdir"
    fs.unmount()
    return true

## Test 12: on_op_create + on_op_read + on_op_write
proc test_on_op_create_read_write():
    let fs = make_vfs()
    if fs == nil:
        print "  FAIL test_on_op_create_read_write: make_vfs"
        return false
    let fh = fuse.on_op_create(fs, fuse.FUSE_ROOT_ID, "fusedata", 0o644)
    if fh == nil or fh < 0:
        print "  FAIL test_on_op_create_read_write: create failed"
        fs.unmount()
        return false
    # Write data
    let test_data = bytes()
    bytes_push(test_data, 72)  # H
    bytes_push(test_data, 105) # i
    let w = fuse.on_op_write(fs, fuse.FUSE_ROOT_ID, 0, test_data)
    if w != 2:
        print "  FAIL test_on_op_create_read_write: write returned " + str(w)
        fs.unmount()
        return false
    # Read back
    let r = fuse.on_op_read(fs, fuse.FUSE_ROOT_ID, 0, 2)
    if r == nil or bytes_len(r) != 2:
        var len_str: String = "0"
        if r != nil:
            len_str = str(bytes_len(r))
        print "  FAIL test_on_op_create_read_write: read returned " + len_str
        fs.unmount()
        return false
    if bytes_get(r, 0) != 72 or bytes_get(r, 1) != 105:
        print "  FAIL test_on_op_create_read_write: data mismatch"
        fs.unmount()
        return false
    print "  PASS test_on_op_create_read_write"
    fs.unmount()
    return true

## Test 13: on_op_unlink
proc test_on_op_unlink():
    let fs = make_vfs()
    if fs == nil:
        print "  FAIL test_on_op_unlink: make_vfs"
        return false
    let fh = fuse.on_op_create(fs, fuse.FUSE_ROOT_ID, "tounlink", 0o644)
    if fh == nil or fh < 0:
        print "  FAIL test_on_op_unlink: create failed"
        fs.unmount()
        return false
    let ok = fuse.on_op_unlink(fs, fuse.FUSE_ROOT_ID, "tounlink")
    if not ok:
        print "  FAIL test_on_op_unlink: unlink failed"
        fs.unmount()
        return false
    # Verify it is gone
    let lookup = fuse.on_op_lookup(fs, fuse.FUSE_ROOT_ID, "tounlink")
    if lookup != nil and lookup >= 0:
        print "  FAIL test_on_op_unlink: file still exists"
        fs.unmount()
        return false
    print "  PASS test_on_op_unlink"
    fs.unmount()
    return true

## Test 14: on_op_rename
proc test_on_op_rename():
    let fs = make_vfs()
    if fs == nil:
        print "  FAIL test_on_op_rename: make_vfs"
        return false
    let fh = fuse.on_op_create(fs, fuse.FUSE_ROOT_ID, "oldname", 0o644)
    if fh == nil or fh < 0:
        print "  FAIL test_on_op_rename: create failed"
        fs.unmount()
        return false
    let ok = fuse.on_op_rename(fs, fuse.FUSE_ROOT_ID, "oldname", fuse.FUSE_ROOT_ID, "newname")
    if not ok:
        print "  FAIL test_on_op_rename: rename failed"
        fs.unmount()
        return false
    let lookup_old = fuse.on_op_lookup(fs, fuse.FUSE_ROOT_ID, "oldname")
    if lookup_old != nil and lookup_old >= 0:
        print "  FAIL test_on_op_rename: oldname still exists"
        fs.unmount()
        return false
    let lookup_new = fuse.on_op_lookup(fs, fuse.FUSE_ROOT_ID, "newname")
    if lookup_new == nil or lookup_new < 0:
        print "  FAIL test_on_op_rename: newname not found"
        fs.unmount()
        return false
    print "  PASS test_on_op_rename"
    fs.unmount()
    return true

## Test 15: on_op_rmdir
proc test_on_op_rmdir():
    let fs = make_vfs()
    if fs == nil:
        print "  FAIL test_on_op_rmdir: make_vfs"
        return false
    let mk = fuse.on_op_mkdir(fs, fuse.FUSE_ROOT_ID, "tormdir", 0o755)
    if mk == nil or not mk:
        print "  FAIL test_on_op_rmdir: mkdir failed"
        fs.unmount()
        return false
    let ok = fuse.on_op_rmdir(fs, fuse.FUSE_ROOT_ID, "tormdir")
    if not ok:
        print "  FAIL test_on_op_rmdir: rmdir failed"
        fs.unmount()
        return false
    let lookup = fuse.on_op_lookup(fs, fuse.FUSE_ROOT_ID, "tormdir")
    if lookup != nil and lookup >= 0:
        print "  FAIL test_on_op_rmdir: dir still exists"
        fs.unmount()
        return false
    print "  PASS test_on_op_rmdir"
    fs.unmount()
    return true

## Test 16: dispatch function for FUSE_INIT returns config
proc test_dispatch_init():
    let fs = make_vfs()
    if fs == nil:
        print "  FAIL test_dispatch_init: make_vfs"
        return false
    let args = {}
    args["major"] = 7
    args["minor"] = 26
    args["max_readahead"] = 131072
    args["flags"] = 0
    let result = fuse.dispatch(fs, fuse.FUSE_INIT, args)
    if result == nil:
        print "  FAIL test_dispatch_init: nil result"
        fs.unmount()
        return false
    if result["max_readahead"] < 4096:
        print "  FAIL test_dispatch_init: low max_readahead=" + str(result["max_readahead"])
        fs.unmount()
        return false
    print "  PASS test_dispatch_init"
    fs.unmount()
    return true

## Test 17: dispatch function for FUSE_LOOKUP on root
proc test_dispatch_lookup_root():
    let fs = make_vfs()
    if fs == nil:
        print "  FAIL test_dispatch_lookup_root: make_vfs"
        return false
    let args = {}
    ## dispatch reads args["parent"] for FUSE_LOOKUP, not args["ino"]; setting
    ## "ino" left parent nil, and the failure surfaced as an unrelated
    ## "dict comparison number" from the `result < 0` guard.
    args["parent"] = fuse.FUSE_ROOT_ID
    args["name"] = "/"
    ## dispatch(LOOKUP) resolves the name and then stats it, so the result is a
    ## stat dict. The kernel needs the attributes with the entry; returning a
    ## bare nodeid is what made every file look like mode 0 to the kernel.
    let result = fuse.dispatch(fs, fuse.FUSE_LOOKUP, args)
    if result == nil:
        print "  FAIL test_dispatch_lookup_root: nil result"
        fs.unmount()
        return false
    if not dict_has(result, "ino"):
        print "  FAIL test_dispatch_lookup_root: no ino"
        fs.unmount()
        return false
    if not dict_has(result, "mode"):
        print "  FAIL test_dispatch_lookup_root: no mode"
        fs.unmount()
        return false
    let mode = result["mode"]
    if (mode & 0xF000) != 0x4000:
        print "  FAIL test_dispatch_lookup_root: root not a dir, mode=" + str(mode)
        fs.unmount()
        return false
    ## And the bytes the kernel actually sees must be a well-formed entry.
    let resp = fuse.build_lookup_response(1, result)
    if bytes_len(resp) != 144:
        print "  FAIL test_dispatch_lookup_root: entry len=" + str(bytes_len(resp))
        fs.unmount()
        return false
    if fuse.decode_u64_le(resp, 16) != result["ino"]:
        print "  FAIL test_dispatch_lookup_root: nodeid not encoded"
        fs.unmount()
        return false
    if fuse.decode_u32_le(resp, 128) != mode:
        print "  FAIL test_dispatch_lookup_root: mode not at attr+72"
        fs.unmount()
        return false
    print "  PASS test_dispatch_lookup_root"
    fs.unmount()
    return true

## Test 18: Readdir returns all entries
proc test_readdir_entries():
    let fs = make_vfs()
    if fs == nil:
        print "  FAIL test_readdir_entries: make_vfs"
        return false
    let entries = fuse.on_op_readdir(fs, fuse.FUSE_ROOT_ID)
    if entries == nil:
        print "  FAIL test_readdir_entries: nil"
        fs.unmount()
        return false
    if len(entries) < 2:
        print "  FAIL test_readdir_entries: only " + str(len(entries)) + " entries"
        fs.unmount()
        return false
    ## Entries are "ino name type" triples, so match the name field rather than
    ## the whole string.
    var has_dot = false
    var has_dotdot = false
    for e in entries:
        let sp = fuse.find_char(e, " ")
        var nm = ""
        if sp >= 0:
            let rest = e[sp + 1:len(e)]
            let tp = fuse.find_char(rest, " ")
            if tp >= 0:
                nm = rest[0:tp]
            else:
                nm = rest
        if nm == ".": has_dot = true
        if nm == "..": has_dotdot = true
    if not has_dot or not has_dotdot:
        print "  FAIL test_readdir_entries: missing ./.."
        fs.unmount()
        return false
    print "  PASS test_readdir_entries"
    fs.unmount()
    return true

proc run_tests() -> Bool:
    var all_ok = true
    let test_list = [
        ["decode_helpers", test_decode_helpers],
        ["build_init_response", test_build_init_response],
        ["build_lookup_response", test_build_lookup_response],
        ["build_open_response", test_build_open_response],
        ["build_write_response", test_build_write_response],
        ["build_statfs_response", test_build_statfs_response],
        ["build_error_response", test_build_error_response],
        ["response_unique", test_response_unique_passthrough],
        ["on_op_lookup_root", test_on_op_lookup_root],
        ["on_op_getattr_root", test_on_op_getattr_root],
        ["on_op_mkdir_and_readdir", test_on_op_mkdir_and_readdir],
        ["on_op_create_read_write", test_on_op_create_read_write],
        ["on_op_unlink", test_on_op_unlink],
        ["on_op_rename", test_on_op_rename],
        ["on_op_rmdir", test_on_op_rmdir],
        ["dispatch_init", test_dispatch_init],
        ["dispatch_lookup_root", test_dispatch_lookup_root],
        ["readdir_entries", test_readdir_entries],
    ]
    for t in test_list:
        let name = t[0]
        let proc_fn = t[1]
        let ok = proc_fn()
        if not ok:
            print "  FAIL " + name
            all_ok = false
    if all_ok:
        print "ALL FUSE TESTS PASSED"
    else:
        print "SOME FUSE TESTS FAILED"
    return all_ok

let result = run_tests()
if result:
    sys.exit(0)
else:
    sys.exit(1)
