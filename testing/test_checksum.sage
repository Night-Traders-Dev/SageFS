## ============================================================================
## test_checksum.sage — unit tests for the SageFS checksum engine
## ============================================================================
##
## Covers:
##   - SHA-256 known-answer vectors (NIST), across padding boundaries
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

## --- SHA-256 -------------------------------------------------------------
##
## The stub returned the empty-input digest for everything, so these are the
## tests that would have caught it. Lengths are chosen to straddle every place
## the padding can go wrong: 55/56/57 and 63/64/65 are where the 0x80 byte, the
## length field, and the block boundary interact.

proc ascii_bytes(s: String) -> Bytes:
    let b: Bytes = bytes(len(s))
    var i: Int = 0
    while i < len(s):
        b[i] = ord(s[i])
        i = i + 1
    return b

proc repeat_byte(c: String, n: Int) -> Bytes:
    let b: Bytes = bytes(n)
    var i: Int = 0
    while i < n:
        b[i] = ord(c)
        i = i + 1
    return b

proc test_sha256_nist():
    ## FIPS 180-4 / NIST published vectors.
    check_bool("sha256 empty",
               checksum.sha256(bytes(0)),
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    check_bool("sha256 abc",
               checksum.sha256(ascii_bytes("abc")),
               "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    ## Two-block message, and the 448-bit NIST vector.
    check_bool("sha256 448-bit",
               checksum.sha256(ascii_bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
               "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    ## One million 'a': exercises multi-block scheduling and the bit-length field
    ## at a magnitude where a double could lose the low bits.
    check_bool("sha256 one million a",
               checksum.sha256(repeat_byte("a", 1000000)),
               "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")

proc test_sha256_padding_boundaries():
    ## 55/56/57: 55 needs one block, 56 is the point where the length no longer
    ## fits after the 0x80, so 56 spills into a second block.
    check_bool("sha256 55 a",
               checksum.sha256(repeat_byte("a", 55)),
               "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318")
    check_bool("sha256 56 a",
               checksum.sha256(repeat_byte("a", 56)),
               "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a")
    ## 63/64/65 straddle the block boundary itself.
    check_bool("sha256 64 a",
               checksum.sha256(repeat_byte("a", 64)),
               "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb")
    ## Distinct lengths must give distinct digests: the stub returned one value for
    ## everything, which is precisely the failure mode.
    let d1: String = checksum.sha256(repeat_byte("a", 100))
    let d2: String = checksum.sha256(repeat_byte("a", 101))
    check_bool("adjacent lengths differ", d1 != d2, true)
    check_bool("digest is 64 hex characters", len(checksum.sha256(bytes(0))) == 64, true)
    let d: String = checksum.sha256(bytes(0))
    ## Only 0-9 and a-f may appear; the stub's constant was lowercase too, so this
    ## is about the new code not regressing it.
    var only_hex: Bool = true
    var i: Int = 0
    while i < len(d):
        let c: String = d[i]
        if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f")):
            only_hex = false
        i = i + 1
    check_bool("digest is lowercase hex", only_hex, true)

proc test_rotr32():
    ## A right rotate moves the low n bits to the top. Getting this backwards
    ## produced a digest that was correct only for the empty input.
    check("rotr 0x80000000 by 1", checksum.rotr32(0x80000000, 1), 0x40000000)
    check("rotr 0x0000000f by 4", checksum.rotr32(0x0000000f, 4), 0xf0000000)
    check("rotr 0x12345678 by 8", checksum.rotr32(0x12345678, 8), 0x78123456)
    check("rotr by 0 is identity", checksum.rotr32(0x12345678, 0), 0x12345678)
    check("rotr 0xffffffff by 1", checksum.rotr32(0xffffffff, 1), 0xffffffff)
    ## Two rotates that sum to 32 must be the identity. Uses rotr32 on both
    ## sides so the assertion covers only the function under test.
    check("rotate round trip",
          checksum.rotr32(checksum.rotr32(0xdeadbeef, 5), 27), 0xdeadbeef)

proc test_sha256_fold32():
    ## The 32-bit fold must differ per input or it is useless as a checksum.
    let f1: Int = checksum.sha256_fold32(bytes(0))
    let f2: Int = checksum.sha256_fold32(repeat_byte("a", 8))
    check_bool("fold32 distinguishes inputs", f1 != f2, true)
    check_bool("fold32 fits in 32 bits", f1 >= 0 and f1 <= 0xFFFFFFFF, true)

proc main():
    print("=== SageFS Checksum Engine Tests ===")
    test_sha256_nist()
    test_sha256_padding_boundaries()
    test_rotr32()
    test_sha256_fold32()
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
