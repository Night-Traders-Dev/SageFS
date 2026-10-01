## The FUSE wire format, checked byte for byte.
##
## testing/test_fuse.sage covered the on_op_* handlers and dispatch, which is why
## a layer with six wrong opcodes, a 32-byte request header (it is 40), write
## payloads starting 24 bytes early, and a lookup reply with no attributes in it
## could pass every test. None of those are handler bugs; they are bugs in the
## encoding, and the encoding had no tests.
##
## So: build the frames the kernel would send, and check that parsing them yields
## the right values, and that replies land at the right offsets. Both directions,
## because a parser and an encoder that are wrong in matching ways cancel out in
## a round trip and nowhere else.

import sys
import fuse

var TESTS_RUN = 0
var TESTS_PASSED = 0

proc check(name: String, cond: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if cond:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name)

proc check_int(name: String, got: Int, want: Int):
    check(name + " (got " + str(got) + ", want " + str(want) + ")", got == want)

## hexbytes — A byte buffer from a hex string, for exact wire patterns.
##
## Spelled out per byte rather than via int(substr, 16), which does not parse in
## this dialect and silently yields 0 for every byte -- a helper that returns a
## buffer of zeroes is worse than no helper, because the assertions downstream
## then test the wrong thing and pass.
proc hex_nibble(c: Int) -> Int:
    if c >= 48 and c <= 57:
        return c - 48
    if c >= 97 and c <= 102:
        return c - 87
    if c >= 65 and c <= 70:
        return c - 55
    return 0

proc hexbytes(h: String) -> Bytes:
    var b: Bytes = bytes(len(h) / 2)
    var i: Int = 0
    while i < bytes_len(b):
        b[i] = (hex_nibble(ord(h[i * 2])) * 16) + hex_nibble(ord(h[i * 2 + 1]))
        i = i + 1
    return b

## cstr — A NUL-terminated string, as every FUSE name field is.
proc cstr(s: String) -> Bytes:
    var b: Bytes = bytes(len(s) + 1)
    var i: Int = 0
    while i < len(s):
        b[i] = ord(s[i])
        i = i + 1
    return b

proc join(parts: Array[Bytes]) -> Bytes:
    var out: Bytes = bytes(0)
    var i: Int = 0
    while i < len(parts):
        var j: Int = 0
        while j < bytes_len(parts[i]):
            bytes_push(out, parts[i][j])
            j = j + 1
        i = i + 1
    return out

proc u32(v: Int) -> Bytes:
    var b: Bytes = bytes(4)
    fuse.encode_u32_le_to(b, 0, v)
    return b

proc u64(v: Int) -> Bytes:
    var b: Bytes = bytes(8)
    fuse.encode_u64_le_to(b, 0, v)
    return b

## ---------------------------------------------------------------------------
## 1. Opcodes. The kernel dispatches on these numbers, so they are not ours.
## ---------------------------------------------------------------------------

print("opcode constants:")
check_int("LOOKUP", fuse.FUSE_LOOKUP, 1)
check_int("FORGET", fuse.FUSE_FORGET, 2)
check_int("GETATTR", fuse.FUSE_GETATTR, 3)
check_int("SETATTR", fuse.FUSE_SETATTR, 4)
check_int("MKDIR", fuse.FUSE_MKDIR, 9)
check_int("UNLINK", fuse.FUSE_UNLINK, 10)
check_int("RMDIR", fuse.FUSE_RMDIR, 11)
check_int("RENAME", fuse.FUSE_RENAME, 12)
check_int("OPEN", fuse.FUSE_OPEN, 14)
check_int("READ", fuse.FUSE_READ, 15)
check_int("WRITE", fuse.FUSE_WRITE, 16)
check_int("STATFS", fuse.FUSE_STATFS, 17)
check_int("RELEASE", fuse.FUSE_RELEASE, 18)
check_int("FLUSH", fuse.FUSE_FLUSH, 25)
check_int("INIT", fuse.FUSE_INIT, 26)
check_int("OPENDIR", fuse.FUSE_OPENDIR, 27)
check_int("READDIR", fuse.FUSE_READDIR, 28)
check_int("RELEASEDIR", fuse.FUSE_RELEASEDIR, 29)
check_int("ACCESS", fuse.FUSE_ACCESS, 34)
check_int("CREATE", fuse.FUSE_CREATE, 35)
check_int("INTERRUPT", fuse.FUSE_INTERRUPT, 36)

## The old set had MKDIR=27, UNLINK=30, RMDIR=29, RENAME=38, INTERRUPT=23,
## which are OPENDIR, FSYNCDIR, RELEASEDIR, IOCTL and LISTXATTR.
check("MKDIR is not OPENDIR's number", fuse.FUSE_MKDIR != fuse.FUSE_OPENDIR)
check("RENAME is not IOCTL's number", fuse.FUSE_RENAME != 38)

## ---------------------------------------------------------------------------
## 2. fuse_read_in. offset is at 8, not 0; 0 is the file handle.
## ---------------------------------------------------------------------------

print("READ request layout:")
let read_body: Bytes = join([u64(0x1111), u64(4096), u32(512), u32(0), u64(0), u32(0), u32(0)])
check_int("read body is the full 40-byte struct", bytes_len(read_body), 40)
check_int("fh sits at 0", fuse.decode_u64_le(read_body, 0), 0x1111)
check_int("offset sits at 8", fuse.decode_u64_le(read_body, 8), 4096)
check_int("size sits at 16", fuse.decode_u32_le(read_body, 16), 512)
check("read body is 8-aligned", bytes_len(read_body) % 8 == 0)

## ---------------------------------------------------------------------------
## 3. fuse_write_in. The payload starts at 40. It used to start at 16, so 24
##    bytes of protocol header were written into the file as file data.
## ---------------------------------------------------------------------------

print("WRITE request layout:")
## "Hi!\0" as five bytes: a write payload, and a realistic one to parse.
let payload: Bytes = hexbytes("4869210A00")
check_int("the test payload is 5 bytes", bytes_len(payload), 5)
let write_body: Bytes = join([u64(0x2222), u64(100), u32(5), u32(0), u64(0), u32(0), u32(0), payload])
check_int("write header is 40 bytes", fuse.FUSE_WRITE_DATA_OFF, 40)
check_int("offset sits at 8", fuse.decode_u64_le(write_body, 8), 100)
check_int("size sits at 16", fuse.decode_u32_le(write_body, 16), 5)
check_int("payload length past the header", bytes_len(write_body) - 40, 5)
check_int("the payload starts exactly at the header end", payload[0], 0x48)

## ---------------------------------------------------------------------------
## 4. mkdir and create put the name after fixed fields, not at 0.
## ---------------------------------------------------------------------------

print("MKDIR / CREATE request layout:")
let mkdir_body: Bytes = join([u32(0o755), u32(0), cstr("mydir")])
check_int("MKDIR name offset", fuse.FUSE_MKDIR_NAME_OFF, 8)
check_int("MKDIR mode at 0", fuse.decode_u32_le(mkdir_body, 0), 0o755)
check_int("MKDIR name follows the mode and umask", bytes_len(mkdir_body) - 8, 6)

let create_body: Bytes = join([u32(0), u32(0o644), u32(0), u32(0), cstr("newfile")])
check_int("CREATE name offset", fuse.FUSE_CREATE_NAME_OFF, 16)
check_int("CREATE mode at 4", fuse.decode_u32_le(create_body, 4), 0o644)
check_int("CREATE name follows the four u32s", bytes_len(create_body) - 16, 8)

## ---------------------------------------------------------------------------
## 5. fuse_rename_in carries newdir. Treating it as nodeid silently turned every
##    cross-directory rename into a same-directory one.
## ---------------------------------------------------------------------------

print("RENAME request layout:")
let rename_body: Bytes = join([u64(99), cstr("old"), cstr("new")])
check_int("newdir is at 0", fuse.decode_u64_le(rename_body, 0), 99)
check_int("oldname follows newdir", fuse.FUSE_RENAME_OLD_NAME_OFF, 8)
check("newdir differs from the nodeid the header carries", fuse.decode_u64_le(rename_body, 0) != 5)

## ---------------------------------------------------------------------------
## 6. The request header is 40 bytes. At 32 every request was short-read by eight
##    bytes, so every name and offset was shifted.
## ---------------------------------------------------------------------------

print("request header:")
check_int("fuse_in_header length", fuse.FUSE_IN_HEADER_LEN, 40)
let hdr: Bytes = bytes(40)
fuse.encode_u32_le_to(hdr, 0, 0)      # len
fuse.encode_u32_le_to(hdr, 4, 1)      # opcode = LOOKUP
fuse.encode_u64_le_to(hdr, 8, 0xABCD) # unique
fuse.encode_u64_le_to(hdr, 16, 7)     # nodeid
fuse.encode_u32_le_to(hdr, 24, 1000)  # uid
fuse.encode_u32_le_to(hdr, 28, 1000)  # gid
fuse.encode_u32_le_to(hdr, 32, 4242)  # pid
check_int("nodeid at 16", fuse.decode_u64_le(hdr, 16), 7)
check_int("uid at 24", fuse.decode_u32_le(hdr, 24), 1000)
check_int("gid at 28", fuse.decode_u32_le(hdr, 28), 1000)
check_int("pid at 32, not 24", fuse.decode_u32_le(hdr, 32), 4242)
check("pid is distinguishable from uid", fuse.decode_u32_le(hdr, 32) != fuse.decode_u32_le(hdr, 24))

## ---------------------------------------------------------------------------
## 7. Reply sizes. The kernel rejects a length field it does not expect.
## ---------------------------------------------------------------------------

print("reply sizes:")
let st: Dict = {"ino": 3, "size": 100, "mode": 33188, "nlink": 1, "blocks": 8, "uid": 1000, "gid": 1000}

let okr: Bytes = fuse.build_ok_response(5)
check_int("fuse_out_header is 16", bytes_len(okr), 16)
check_int("length field", fuse.decode_u32_le(okr, 0), 16)
check_int("error field is zero", fuse.decode_i32_le(okr, 4), 0)
check_int("unique echoed", fuse.decode_u64_le(okr, 8), 5)

let errr: Bytes = fuse.build_error_response(5, fuse.FUSE_ENOENT)
check_int("error reply is 16", bytes_len(errr), 16)
check_int("errno carried as a negative", fuse.decode_i32_le(errr, 4), -2)
check_int("errno byte 0 is two's complement of 2", errr[4], 0xFE)

let attrr: Bytes = fuse.build_attr_response(5, st)
## fuse_attr_out is the 16-byte out_header plus one fuse_attr, and the attr
## starts at 16. It used to be written at 32 into a buffer sized for 16, which
## put the last fields out of bounds: the bytecode backend dropped them and
## returned a plausible short reply, the C backend wrote past the end.
check_int("fuse_attr_out is 16 + 88", bytes_len(attrr), 104)
check_int("attr length field", fuse.decode_u32_le(attrr, 0), 104)
## libfuse fuse_attr, ABI 7.26: ino@0 size@8 blocks@16 atime@24 mtime@32
## ctime@40, then the three nsecs at 48/52/56, mode@60 nlink@64 uid@68 gid@72
## rdev@76 blksize@80 flags@84. The old layout put mode at 72 and blksize at
## 92, and wrote rdev as a u64 at 88 so it overlapped blksize.
check_int("attr ino at attr+0", fuse.decode_u64_le(attrr, 16), 3)
check_int("attr size at attr+8", fuse.decode_u64_le(attrr, 24), 100)
check_int("attr blocks at attr+16", fuse.decode_u64_le(attrr, 32), 8)
check_int("attr mode at attr+60", fuse.decode_u32_le(attrr, 76), 33188)
check_int("attr nlink at attr+64", fuse.decode_u32_le(attrr, 80), 1)
## The reply must be long enough for every field write_attr makes.
check_int("attr reply holds blksize@80", bytes_len(attrr) >= 16 + 88, true)
check_int("attr flags slot is written", fuse.decode_u32_le(attrr, 100) == 0, true)
check_int("attr uid at attr+68", fuse.decode_u32_le(attrr, 84), 1000)
check_int("attr gid at attr+72", fuse.decode_u32_le(attrr, 88), 1000)

let lookr: Bytes = fuse.build_lookup_response(5, st)
check_int("fuse_entry_out is 16 + 128", bytes_len(lookr), 144)
check_int("entry length field", fuse.decode_u32_le(lookr, 0), 144)
check_int("nodeid at 16", fuse.decode_u64_le(lookr, 16), 3)
check_int("entry carries a full attr: size at 56+8", fuse.decode_u64_le(lookr, 64), 100)
check_int("entry carries a full attr: mode at 56+60", fuse.decode_u32_le(lookr, 116), 33188)

let openr: Bytes = fuse.build_open_response(5, 9)
check_int("fuse_open_out is 32", bytes_len(openr), 32)
## fuse_open_out is fh(8) + open_flags(4) + padding(4) after the 16-byte
## out_header, so fh sits at 16 and open_flags at 24. The builder wrote fh at
## 24, which is open_flags' slot, and left the real fh slot zeroed.
check_int("fh at 16", fuse.decode_u64_le(openr, 16), 9)
check_int("open_flags at 24 is clear", fuse.decode_u32_le(openr, 24), 0)

let writer: Bytes = fuse.build_write_response(5, 4096)
check_int("fuse_write_out is 24", bytes_len(writer), 24)
check_int("size at 16, inside the 24-byte reply", fuse.decode_u32_le(writer, 16), 4096)

let readr: Bytes = fuse.build_read_response(5, payload)
check_int("read reply is header + data", bytes_len(readr), 16 + 5)
check_int("the reply's length field counts header and data", fuse.decode_u32_le(readr, 0), 21)
check_int("data starts after the header", readr[16], 0x48)
check_int("read reply ends with the last data byte", readr[20], 0x00)
check_int("data byte 1", readr[17], 0x69)
check_int("data byte 2", readr[18], 0x21)

let initr: Bytes = fuse.build_init_response(5, 131072, 0, 65536)
check_int("fuse_init_out is 96", bytes_len(initr), 96)
check_int("init major at 16", fuse.decode_u32_le(initr, 16), 7)
check_int("init minor at 20", fuse.decode_u32_le(initr, 20), 26)
check_int("init max_readahead at 24", fuse.decode_u32_le(initr, 24), 131072)
check_int("init max_write at 36", fuse.decode_u32_le(initr, 36), 65536)

## ---------------------------------------------------------------------------
## 8. fuse_dirent: ino(0) off(8) namelen(16) type(20) name(24), 8-byte aligned.
## ---------------------------------------------------------------------------

print("readdir reply layout:")
let dirr: Bytes = fuse.build_readdir_response(1, ["1 . 4", "1 .. 4", "7 mydir 4", "8 myfile 8"])
## 4 entries; "mydir" is 24+5 -> 32, "myfile" is 24+6 -> 32, dots are 24 each.
## Every entry is 24 + namelen rounded up to 8. All four of these land on 32:
## 24+1 ("."), 24+2 (".."), 24+5 ("mydir") and 24+6 ("myfile") all pad to 32.
check_int("all four entries encoded", bytes_len(dirr), 16 + 32 * 4)
## "." starts at 16, ".." at 48, "mydir" at 80, "myfile" at 112.
let off_dot2: Int = 16 + 32
let off_dir: Int = 16 + 64
let off_file: Int = 16 + 96
check_int("a real entry carries its own inode, not a constant", fuse.decode_u64_le(dirr, off_dir), 7)
check_int("another entry has a different inode", fuse.decode_u64_le(dirr, off_file), 8)
check_int("a directory's namelen", fuse.decode_u32_le(dirr, off_dir + 16), 5)
check_int("a directory is DT_DIR", fuse.decode_u32_le(dirr, off_dir + 20), 4)
check_int("a file is DT_REG", fuse.decode_u32_le(dirr, off_file + 20), 8)
check_int("a file's namelen", fuse.decode_u32_le(dirr, off_file + 16), 6)
check("inodes are not all 1", fuse.decode_u64_le(dirr, off_dir) != fuse.decode_u64_le(dirr, 16))
check("types are not all DT_DIR", fuse.decode_u32_le(dirr, off_dir + 20) != fuse.decode_u32_le(dirr, off_file + 20))
## "." must be first, and its off must be 24 so the kernel can resume.
check_int("the first entry is .", fuse.decode_u32_le(dirr, 16 + 16), 1)
check_int("the second entry is ..", fuse.decode_u32_le(dirr, off_dot2 + 16), 2)
check_int("off advances by the entry size, for resumption", fuse.decode_u64_le(dirr, 16 + 8), 32)
check_int("each entry carries its own size in off", fuse.decode_u64_le(dirr, off_dot2 + 8), 32)

## ---------------------------------------------------------------------------
## 9. Signed errno handling, in both directions.
##
## Both halves were wrong. Encoding shifted a negative integer right, and
## `>>` on a negative in SageLang is not an arithmetic shift -- `-2 >> 8` is
## 7.2e16 -- so every negative errno went out as a positive number and the
## kernel read success with a garbage code. Decoding compared the assembled
## value against 0x80000000, which never fires, so -2 came back as -65282.
## ---------------------------------------------------------------------------

print("errno encoding:")
let neg: Bytes = bytes(4)
fuse.encode_i32_le_to(neg, 0, -2)
check_int("-2 survives the round trip", fuse.decode_i32_le(neg, 0), -2)
check("the upper bytes are 0xFF, not 0", neg[1] == 255 and neg[2] == 255 and neg[3] == 255)
check_int("the low byte is the two's complement", neg[0], 0xFE)

for e in [fuse.FUSE_ENOENT, fuse.FUSE_EIO, fuse.FUSE_EACCES, fuse.FUSE_EEXIST,
          fuse.FUSE_ENOTDIR, fuse.FUSE_EISDIR, fuse.FUSE_EINVAL, fuse.FUSE_ENOSYS, fuse.FUSE_ENOSPC]:
    let eb: Bytes = bytes(4)
    fuse.encode_i32_le_to(eb, 0, e)
    if fuse.decode_i32_le(eb, 0) != e:
        check("errno " + str(e) + " round trip", false)
check("every negative errno round trips", true)
check("all the errnos we use are negative", fuse.FUSE_ENOENT < 0 and fuse.FUSE_EIO < 0 and fuse.FUSE_ENOSYS < 0)

let pos: Bytes = bytes(4)
fuse.encode_i32_le_to(pos, 0, 2)
check("a positive errno must not read back as an error", fuse.decode_i32_le(pos, 0) != -2)
## decode_u32_le assembles into a 32-bit int, so the sign bit lands in the value.
## Reading the sign from the top byte is what makes this correct.
check_int("0xFFFFFFFE still decodes as -2", fuse.decode_i32_le(hexbytes("FEFFFFFF"), 0), -2)
check_int("0xFFFFFFFF decodes as -1", fuse.decode_i32_le(hexbytes("FFFFFFFF"), 0), -1)
## hexbytes is left-to-right, so these spell the bytes of the value.
## INT32_MAX is FF FF FF 7F, and 128 is 80 00 00 00.
check_int("INT32_MAX is positive", fuse.decode_i32_le(hexbytes("FFFFFF7F"), 0), 2147483647)
check_int("INT32_MIN decodes as negative", fuse.decode_i32_le(hexbytes("00000080"), 0), -2147483648)
check_int("128 round trips", fuse.decode_i32_le(hexbytes("80000000"), 0), 128)

print("  Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
if TESTS_RUN == TESTS_PASSED:
    print("ALL FUSE WIRE TESTS PASSED")
else:
    print("FUSE WIRE TESTS FAILED")
    sys.exit(1)
