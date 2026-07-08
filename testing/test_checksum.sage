## ============================================================================
## test_checksum.sage — unit tests for the SageFS checksum engine
## ============================================================================
##
## Covers:
##   - CRC32C known-answer vectors (BTRFS / iSCSI compatible)
##   - xxHash32 known-answer vectors (reference xxHash compatible)
##   - checksum_block() algorithm dispatch
##   - verify_block() positive & negative cases
##   - ChecksumTree record / lookup / verify / remove
##   - ChecksumTree serialize -> deserialize round-trip
## ============================================================================

import checksum
let crc32c = checksum.crc32c
let xxhash32 = checksum.xxhash32
let checksum_block = checksum.checksum_block
let verify_block = checksum.verify_block
let CHECKSUM_CRC32C = checksum.CHECKSUM_CRC32C
let CHECKSUM_XXHASH = checksum.CHECKSUM_XXHASH
let CHECKSUM_SHA256 = checksum.CHECKSUM_SHA256
let ChecksumTree = checksum.ChecksumTree
let ChecksumPolicy = checksum.ChecksumPolicy
let default_policy = checksum.default_policy
let sha256_hex = checksum.sha256_hex
let sha256_fold32 = checksum.sha256_fold32

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check(name: String, got: Int, expected: Int):
    ## Assert two integers are equal; print PASS/FAIL.
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc check_bool(name: String, got: Bool, expected: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name)

# ---------------------------------------------------------------------------
# CRC32C known-answer vectors
# ---------------------------------------------------------------------------

proc test_crc32c():
    print("CRC32C known-answer vectors:")
    check("crc32c('123456789')", crc32c(bytes("123456789")), 0xE3069283)
    check("crc32c('')", crc32c(bytes("")), 0x00000000)
    check("crc32c('a')", crc32c(bytes("a")), 0xC1D04330)

# ---------------------------------------------------------------------------
# xxHash32 known-answer vectors
# ---------------------------------------------------------------------------

proc test_xxhash32():
    print("xxHash32 known-answer vectors:")
    check("xxhash32('', 0)", xxhash32(bytes(""), 0), 0x02CC5D05)
    check("xxhash32('abc', 0)", xxhash32(bytes("abc"), 0), 0x32D153FF)
    check("xxhash32(long, 0)", xxhash32(bytes("Nobody inspects the spammish repetition"), 0), 0xE2293B2F)

# ---------------------------------------------------------------------------
# Dispatch + verify
# ---------------------------------------------------------------------------

proc test_dispatch():
    print("checksum_block dispatch + verify_block:")
    let data: Bytes = bytes("The quick brown fox")

    ## Dispatch must match the direct algorithm calls.
    check("dispatch CRC32C", checksum_block(data, CHECKSUM_CRC32C), crc32c(data))
    check("dispatch xxHash", checksum_block(data, CHECKSUM_XXHASH), xxhash32(data, 0))
    check("dispatch SHA256", checksum_block(data, CHECKSUM_SHA256), sha256_fold32(data))

    ## Unknown algo falls back to CRC32C.
    check("dispatch fallback", checksum_block(data, 99), crc32c(data))

    ## verify_block: correct checksum passes, tampered fails.
    let good: Int = checksum_block(data, CHECKSUM_CRC32C)
    check_bool("verify good", verify_block(data, CHECKSUM_CRC32C, good), true)
    check_bool("verify bad", verify_block(data, CHECKSUM_CRC32C, good ^ 0x1), false)

    ## A single-bit change in data must change the checksum.
    let data2: Bytes = bytes("The quick brown foy")
    check_bool("data change detected", checksum_block(data, CHECKSUM_CRC32C) == checksum_block(data2, CHECKSUM_CRC32C), false)

# ---------------------------------------------------------------------------
# ChecksumTree behaviour
# ---------------------------------------------------------------------------

proc test_tree():
    print("ChecksumTree record / lookup / verify / remove:")
    let tree: ChecksumTree = ChecksumTree(CHECKSUM_CRC32C)
    let blk_a: Bytes = bytes("block-A-contents")
    let blk_b: Bytes = bytes("block-B-contents")

    tree.record(1000, blk_a)
    tree.record(2000, blk_b)

    check("tree count", tree.count(), 2)
    check("lookup 1000", tree.lookup(1000), crc32c(blk_a))
    check("lookup missing", tree.lookup(9999), 0)

    check_bool("verify intact", tree.verify(1000, blk_a), true)
    check_bool("verify corrupt", tree.verify(1000, blk_b), false)
    check_bool("verify untracked", tree.verify(9999, blk_a), true)

    tree.remove(1000)
    check("count after remove", tree.count(), 1)
    check("lookup removed", tree.lookup(1000), 0)

proc test_tree_serialize():
    print("ChecksumTree serialize -> deserialize round-trip:")
    let tree: ChecksumTree = ChecksumTree(CHECKSUM_XXHASH)
    tree.record(4096, bytes("alpha"))
    tree.record(8192, bytes("beta"))
    tree.record(12288, bytes("gamma"))

    let blob: Bytes = tree.serialize()
    ## 3 entries * 12 bytes = 36 bytes.
    check("serialized size", bytes_len(blob), 36)

    let restored: ChecksumTree = ChecksumTree(CHECKSUM_XXHASH)
    restored.deserialize(blob)

    check("restored count", restored.count(), 3)
    check("restored 4096", restored.lookup(4096), tree.lookup(4096))
    check("restored 8192", restored.lookup(8192), tree.lookup(8192))
    check("restored 12288", restored.lookup(12288), tree.lookup(12288))

# ---------------------------------------------------------------------------
# Policy
# ---------------------------------------------------------------------------

proc test_policy():
    print("ChecksumPolicy:")
    let p: ChecksumPolicy = default_policy()
    check("default algo", p.for_metadata(), CHECKSUM_CRC32C)
    check("default data algo", p.for_data(), CHECKSUM_CRC32C)

    let meta_only: ChecksumPolicy = ChecksumPolicy(CHECKSUM_XXHASH, false, true)
    check("metadata always on", meta_only.for_metadata(), CHECKSUM_XXHASH)
    check("data off -> -1", meta_only.for_data(), -1)

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

proc main():
    print("=== SageFS Checksum Engine Tests ===")
    test_crc32c()
    test_xxhash32()
    test_dispatch()
    test_tree()
    test_tree_serialize()
    test_policy()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
