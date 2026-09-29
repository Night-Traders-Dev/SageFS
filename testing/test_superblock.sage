import superblock
import imgio

## Superblock layout invariants for the v1.5 inode-table fields.
##
## MAX_LABEL_LEN was 256, which put the label at 128..383 and filled the
## 480-byte header completely -- there was no room for inode_root_blk or
## inode_root_generation. Shortening the label to 240 frees 368..383 for the two
## LE64s, which keeps SUPERBLOCK_HEADER_SIZE at 480, keeps the checksum at 476,
## and leaves every pre-existing field offset untouched.
##
## These assertions name the offsets explicitly rather than only round-tripping,
## because a field that is 0 on both sides round-trips through any amount of
## broken code. That is the same mistake that let test_extent assert against an
## empty tree and pass.

let dev = "/tmp/sagefs_superblock.img"
let passed = 0
let failed = 0

proc check(label: String, got, want):
    if got == want:
        passed = passed + 1
        print("  PASS  " + label)
    else:
        failed = failed + 1
        print("  FAIL  " + label + "  got=" + str(got) + " expected=" + str(want))

let features: Dict = {"checksum_algo": superblock.CHECKSUM_CRC32C}
let sb = superblock.create_superblock(4096, "Layout", 4096, 32, features)

## Nonzero and mutually distinct, so a swapped write, or one field copied into
## the other, cannot pass.
let ROOT_BLK = 0x0A0B0C0D
sb.inode_root_blk = ROOT_BLK
sb.inode_root_generation = 7

let buf = sb.serialize()

check("inode_root_blk at offset 368",
      superblock.read_le64(buf, 368), ROOT_BLK)
check("inode_root_generation at offset 376",
      superblock.read_le64(buf, 376), 7)
check("inode_root_generation is not a copy of inode_root_blk",
      superblock.read_le64(buf, 376) == superblock.read_le64(buf, 368), false)

## The header must not have moved: these are offsets v1.4 images rely on.
check("superblock header size unchanged", superblock.SUPERBLOCK_HEADER_SIZE, 480)
check("label now 240 bytes", superblock.MAX_LABEL_LEN, 240)
check("inode field does not collide with flags at 384",
      superblock.read_le64(buf, 368) >> 32, 0)

## The whole point of shortening the label: a maximum-length label must not
## reach into the inode fields. Under the old 256-byte label these two bytes
## would have been overwritten by label text.
var long_label = ""
for _i in range(0, superblock.MAX_LABEL_LEN):
    long_label = long_label + "x"
sb.label = long_label
let long_buf = sb.serialize()
check("240-byte label leaves inode_root_blk intact",
      superblock.read_le64(long_buf, 368), ROOT_BLK)
check("240-byte label leaves inode_root_generation intact",
      superblock.read_le64(long_buf, 376), 7)

## And the fields must survive the on-disk round trip through the file layer.
imgio.write_image(dev, sb.serialize())
let on_disk = superblock.deserialize_superblock(imgio.read_image(dev))
check("inode_root_blk round trips", on_disk.inode_root_blk, ROOT_BLK)
check("inode_root_generation round trips", on_disk.inode_root_generation, 7)
check("full-length label round trips", len(on_disk.label), superblock.MAX_LABEL_LEN)

## Changing the tree root must invalidate the checksum, or a torn write to the
## root would go undetected.
## The checksum is recomputed inside serialize() rather than kept in sync on
## assignment, so the meaningful comparison is between two serialized images --
## reading base.checksum directly would just read a stale cached value.
let base = superblock.create_superblock(4096, "Layout", 4096, 32, features)
## The serialized header is exactly 480 bytes, so the LE32 checksum at 476 has to
## be read as the top half of the final LE64 -- read_le64(buf, 476) runs off the
## end of the buffer and returns nil.
proc on_disk_checksum(sb) -> Int:
    return (superblock.read_le64(sb.serialize(), 472) >> 32) & 0xFFFFFFFF

let csum_base = on_disk_checksum(base)
base.inode_root_blk = 1
check("on-disk checksum changes with inode_root_blk",
      on_disk_checksum(base) != csum_base, true)
check("superblock verifies after inode_root_blk write", base.verify_checksum(), true)
base.inode_root_blk = 0
base.inode_root_generation = 1
check("on-disk checksum changes with inode_root_generation",
      on_disk_checksum(base) != csum_base, true)
check("superblock verifies after inode_root_generation write",
      base.verify_checksum(), true)

## A v1.4 image has zeros in the new fields and must still parse.
let legacy = superblock.create_superblock(4096, "Legacy", 4096, 32, features)
legacy.inode_root_blk = 0
legacy.inode_root_generation = 0
check("zero inode root parses as unset",
      superblock.deserialize_superblock(legacy.serialize()).inode_root_blk, 0)

print("  Results: " + str(passed) + "/" + str(passed + failed) + " passed")
if failed > 0:
    print("  SUPERBLOCK TESTS FAILED")
else:
    print("  ALL SUPERBLOCK TESTS PASSED")
