## Byte-order contract for everything SageFS writes to disk.
##
## The concern this file settles: the inode-entry codec packs integers by hand
## (`x & 0xFF`, then `x >> 8`, and so on, ascending) while the B+ tree uses
## named read_le/write_le helpers, and the B+ tree's magic is stored
## big-endian. That looks like two conventions at war.
##
## It is not. The decision is:
##
##   * All on-disk integers are little-endian. That covers the hand-packed inode
##     entry and every B+ tree field, and it is what every existing image already
##     contains. Changing either would invalidate images on disk for no gain.
##
##   * The B+ tree magic is the single exception, and it is a tag rather than
##     data: it is written and read with the same helper, so no field is ever
##     misread, and it exists to be recognised rather than interpreted. It is
##     left as-is deliberately. Reordering it is a format change and would need a
##     version bump, not a cleanup.
##
## These are byte-level assertions on purpose. A round-trip test passes just as
## happily when both ends are wrong in the same way, which is exactly the failure
## a byte-order change produces and exactly what would be invisible if the layout
## were only ever checked by encoding and decoding again.

import sys
import io
import imgio
import btree

let BTreeNode = btree.BTreeNode

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

## ---------------------------------------------------------------------------
## 1. The inode entry packs little-endian, least significant byte first.
## ---------------------------------------------------------------------------

print("inode entry byte order:")
let entry = imgio.encode_inode_entry(0x04030201, 0x41ED, 0, "", "")
## ino occupies the first four bytes, and 0x04030201 must appear as 01 02 03 04.
check("entry is long enough to hold the ino", bytes_len(entry) >= 8)
check_int("ino byte 0 is the least significant", bytes_get(entry, 0), 0x01)
check_int("ino byte 1", bytes_get(entry, 1), 0x02)
check_int("ino byte 2", bytes_get(entry, 2), 0x03)
check_int("ino byte 3 is the most significant", bytes_get(entry, 3), 0x04)
check_int("mode byte 0 is the least significant", bytes_get(entry, 4), 0xED)
check_int("mode byte 1 is the most significant", bytes_get(entry, 5), 0x41)

let decoded = imgio.decode_inode_entry(entry, 0)
check_int("the ino survives the round trip", decoded["ino"], 0x04030201)
check_int("the mode survives the round trip", decoded["mode"], 0x41ED)

## ---------------------------------------------------------------------------
## 2. The B+ tree stores its fields little-endian too.
## ---------------------------------------------------------------------------

print("B+ tree byte order:")
let node = BTreeNode()
node.level = 1
node.generation = 2
node.owner_nid = 7
node.num_items = 0
node.data_area = bytes()
let encoded = node.serialize()
check_int("the level is stored least significant byte first", bytes_get(encoded, 5), 1)
check_int("the generation is stored least significant byte first", bytes_get(encoded, 9), 2)
check_int("the owner nid is stored least significant byte first", bytes_get(encoded, 17), 7)

## The magic is the documented exception and is deliberately not asserted here:
## it is a tag, written and read with the same helper, so no field is ever
## misread, and it exists to be recognised rather than interpreted. Reordering it
## is a format change, not a cleanup.

## No reparse round trip here on purpose. A round trip passes just as happily
## when both ends are wrong in the same way, which is exactly the failure a
## byte-order change produces. The assertions above read the bytes directly, so
## they fail if the layout moves even when encoding and decoding still agree.

print("  Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
if TESTS_RUN == TESTS_PASSED:
    print("ALL ENDIANNESS TESTS PASSED")
else:
    print("ENDIANNESS TESTS FAILED")
    sys.exit(1)
