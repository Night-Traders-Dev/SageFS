import imgio

## The inode-entry codec is now the single on-disk format for inode metadata.
## Both the v1.4 fixed area and the v1.5 inode B+ tree use encode_inode_entry()
## and decode_inode_entry(), so a tree value is byte-identical to what the area
## would have stored and migrating between the two is a straight copy.
##
## The header carries ino, mode and size as LE32, not single bytes. The values
## used here deliberately exceed 8 and 16 bits, so a writer that truncated any
## of them to one or two bytes would pass a test that only ever used ino 1 and
## mode 0o644.

let passed = 0
let failed = 0

proc check(label: String, got, want):
    if got == want:
        passed = passed + 1
        print("  PASS  " + label)
    else:
        failed = failed + 1
        print("  FAIL  " + label + "  got=" + str(got) + " expected=" + str(want))

proc read_le32_at(buf, off: Int) -> Int:
    return imgio.bytes_get(buf, off) | (imgio.bytes_get(buf, off + 1) << 8) | (imgio.bytes_get(buf, off + 2) << 16) | (imgio.bytes_get(buf, off + 3) << 24)

proc read_le16_at(buf, off: Int) -> Int:
    return imgio.bytes_get(buf, off) | (imgio.bytes_get(buf, off + 1) << 8)

let INO: Int = 0x01020304
let MODE: Int = 0x0A0B0C0D
let SIZE: Int = 0x00112233
let NAME: String = "entry-name"
let DATA: String = "deadbeefcafe"

let enc = imgio.encode_inode_entry(INO, MODE, SIZE, NAME, DATA)

check("encoded length is 16 + name + data",
      imgio.bytes_len(enc), 16 + len(NAME) + len(DATA))
check("ino at 0 is LE32", read_le32_at(enc, 0), INO)
check("mode at 4 is LE32", read_le32_at(enc, 4), MODE)
check("size at 8 is LE32", read_le32_at(enc, 8), SIZE)
check("name_len at 12 is LE16", read_le16_at(enc, 12), len(NAME))
check("data_len at 14 is LE16", read_le16_at(enc, 14), len(DATA))
var name_ok = true
for _k in range(0, len(NAME)):
    if imgio.bytes_get(enc, 16 + _k) != ord(NAME[_k]):
        name_ok = false
check("name payload starts at 16", name_ok, true)

## A single-byte writer would pass all of the above with small values but fail
## here; assert the high bytes individually.
check("ino high byte survives", imgio.bytes_get(enc, 3), (INO >> 24) & 0xFF)
check("mode high byte survives", imgio.bytes_get(enc, 7), (MODE >> 24) & 0xFF)
check("size high byte survives", imgio.bytes_get(enc, 11), (SIZE >> 24) & 0xFF)

let dec = imgio.decode_inode_entry(enc, 0)
check("decode ino", dec["ino"], INO)
check("decode mode", dec["mode"], MODE)
check("decode size", dec["size"], SIZE)
check("decode name", dec["name"], NAME)
check("decode data", dec["data"], DATA)
check("decode reports total length", dec["total"], 16 + len(NAME) + len(DATA))

## Empty name and data, which is the shape of a directory inode.
let bare = imgio.encode_inode_entry(7, 0o040755, 0, "", "")
check("bare entry is 16 bytes", imgio.bytes_len(bare), 16)
let bare_dec = imgio.decode_inode_entry(bare, 0)
check("bare decode ino", bare_dec["ino"], 7)
check("bare decode name is empty", bare_dec["name"], "")
check("bare decode total", bare_dec["total"], 16)

## The area writer must emit exactly the codec's bytes, so that an image
## written by either path is readable by the other.
var area: Bytes = imgio.bytes()
let written = imgio.write_inode_entry_at(area, 0, INO, MODE, SIZE, NAME, DATA)
check("write_inode_entry_at reports encoded length", written, imgio.bytes_len(enc))
var same = imgio.bytes_len(area) == imgio.bytes_len(enc)
var k: Int = 0
while same and k < imgio.bytes_len(enc):
    if imgio.bytes_get(area, k) != imgio.bytes_get(enc, k):
        same = false
    k = k + 1
check("area writer is byte-identical to the codec", same, true)

## Offset writes, so the area path at a nonzero offset still decodes.
var area2: Bytes = imgio.bytes()
imgio.write_inode_entry_at(area2, 64, INO, MODE, SIZE, NAME, DATA)
let at64 = imgio.decode_inode_entry(area2, 64)
check("decode at a nonzero offset", at64["ino"], INO)
check("decode at a nonzero offset name", at64["name"], NAME)

## Several entries packed back to back must all come back, in order: this is
## what _persist_all() does, appending at a running offset.
## Capture each entry's size before advancing off. Writing
##     off = off + write_inode_entry_at(multi, off, ...)
## assigns to off while also passing it as an argument, and the result depends on
## evaluation order: the third write returned 0 here and the entry was silently
## lost. _persist_all() in vfs.sage already uses the safe two-step form.
var multi: Bytes = imgio.bytes()
var off: Int = 0
let n1 = imgio.write_inode_entry_at(multi, off, 1, 0o100644, 10, "a", "01")
off = off + n1
let n2 = imgio.write_inode_entry_at(multi, off, 2, 0o100644, 20, "bb", "0203")
off = off + n2
let n3 = imgio.write_inode_entry_at(multi, off, 3, 0o040755, 0, "ccc", "")
off = off + n3
let parsed = imgio.read_inode_entries_from_area(multi, 0, 4096)
check("area reader returns all three", len(parsed), 3)
check("first entry ino", parsed[0]["ino"], 1)
check("second entry name", parsed[1]["name"], "bb")
check("second entry data", parsed[1]["data"], "0203")
check("third entry name", parsed[2]["name"], "ccc")
check("packed total advances by each encoded length", off, n1 + n2 + n3)
check("packed total is 16 + all names + all data", off, 16 * 3 + (1 + 2 + 3) + (2 + 4 + 0))

## Zero padding ends the scan, as it did before the refactor.
var padded: Bytes = imgio.bytes()
imgio.write_inode_entry_at(padded, 0, 5, 0o100644, 1, "x", "0")
imgio.write_inode_entry_at(padded, 512, 6, 0o100644, 2, "y", "00")
check("padding stops the area scan", len(imgio.read_inode_entries_from_area(padded, 0, 4096)), 1)

## An entry claiming to run past the area end must not be returned, or a
## truncated tail would decode as a real inode.
var clipped: Bytes = imgio.bytes()
imgio.write_inode_entry_at(clipped, 0, 9, 0o100644, 3, "toolong", "aabbcc")
check("entry past area end is dropped", len(imgio.read_inode_entries_from_area(clipped, 0, 20)), 0)

print("  Results: " + str(passed) + "/" + str(passed + failed) + " passed")
if failed > 0:
    print("  INODE CODEC TESTS FAILED")
else:
    print("  ALL INODE CODEC TESTS PASSED")
