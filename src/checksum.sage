## ============================================================================
## SageFS Checksum Engine
## ============================================================================
##
## Phase 3 — Data Integrity & Recovery.
##
## Provides per-block integrity checksums for both metadata and data blocks.
## Three algorithms are supported, selectable via the `checksum_algo` field
## stored in the superblock:
##
##   CHECKSUM_CRC32C (0) : Castagnoli CRC-32 — the default.  Fast, hardware
##                         accelerated on modern CPUs (SSE4.2 crc32 / ARM CRC),
##                         and the same polynomial used by BTRFS, ext4, iSCSI
##                         and SCTP.  32-bit result.
##   CHECKSUM_XXHASH (1) : xxHash32 — a very fast non-cryptographic hash with
##                         excellent avalanche behaviour.  32-bit result.
##   CHECKSUM_SHA256 (2) : SHA-256 — cryptographic integrity ("paranoid" mode).
##                         The 256-bit digest is folded down to a 32-bit
##                         checksum for the on-disk 32-bit checksum fields;
##                         the full hex digest is available separately for
##                         dedup fingerprinting.
##
## Design notes
## ------------
## SageLang integers are tagged 64-bit values, so all 32-bit arithmetic is
## kept in range by masking with `& 0xFFFFFFFF` after every operation that
## could overflow.  This mirrors the little-endian, mask-and-shift style used
## throughout superblock.sage.
##
## Metadata blocks are ALWAYS checksummed.  Data-block checksumming is
## configurable (see `ChecksumPolicy`).  A dedicated checksum tree — keyed by
## physical block address, BTRFS-style — records the expected checksum of every
## tracked block so that reads can be verified and, when RAID redundancy is
## present, auto-repaired (repair-on-read, wired up in Phase 4).
## ============================================================================

import crypto.hash

# ---------------------------------------------------------------------------
# Algorithm identifiers — MUST match the constants in superblock.sage
# ---------------------------------------------------------------------------

let CHECKSUM_CRC32C: Int = 0
let CHECKSUM_XXHASH: Int = 1
let CHECKSUM_SHA256: Int = 2

## 32-bit and 64-bit masks used to emulate fixed-width unsigned arithmetic.
let MASK32: Int = 0xFFFFFFFF
let MASK64: Int = 0xFFFFFFFFFFFFFFFF

## A checksum of 0 is reserved to mean "no checksum recorded / not tracked".
let CHECKSUM_NONE: Int = 0

# ===========================================================================
# CRC32C (Castagnoli) — polynomial 0x1EDC6F41, reflected form 0x82F63B78
# ===========================================================================
#
# We use the reflected (bit-reversed) algorithm, matching the hardware crc32c
# instruction and the value produced by BTRFS.  A 256-entry lookup table is
# built once at module load and cached in a module-global.
# ---------------------------------------------------------------------------

let CRC32C_POLY: Int = 0x82F63B78

## Module-global lookup table, lazily initialised on first use.
var CRC32C_TABLE: Array[Int] = []

proc crc32c_build_table():
    ## Populate the 256-entry CRC32C lookup table (reflected algorithm).
    ## Idempotent — a second call is a no-op once the table is built.
    if len(CRC32C_TABLE) == 256:
        return

    CRC32C_TABLE = []
    var n: Int = 0
    while n < 256:
        var crc: Int = n
        var k: Int = 0
        while k < 8:
            if (crc & 1) != 0:
                crc = (crc >> 1) ^ CRC32C_POLY
            else:
                crc = crc >> 1
            crc = crc & MASK32
            k = k + 1
        CRC32C_TABLE.push(crc & MASK32)
        n = n + 1

proc crc32c(data: Bytes) -> Int:
    ## Compute the CRC32C (Castagnoli) checksum of `data`.
    ## Returns a 32-bit unsigned integer.
    crc32c_build_table()

    var crc: Int = MASK32              # initial value 0xFFFFFFFF
    let n: Int = bytes_len(data)
    var i: Int = 0
    while i < n:
        let byte: Int = bytes_get(data, i)
        let idx: Int = (crc ^ byte) & 0xFF
        crc = (crc >> 8) ^ CRC32C_TABLE[idx]
        crc = crc & MASK32
        i = i + 1

    ## Final XOR with 0xFFFFFFFF (one's complement of the residue).
    return (crc ^ MASK32) & MASK32

# ===========================================================================
# xxHash32 — Yann Collet's fast non-cryptographic hash
# ===========================================================================
#
# Reference: https://github.com/Cyan4973/xxHash (32-bit variant).
# Constants (primes) and rotate amounts follow the canonical specification so
# that our output is bit-compatible with reference implementations.
# ---------------------------------------------------------------------------

let XXH_PRIME32_1: Int = 0x9E3779B1
let XXH_PRIME32_2: Int = 0x85EBCA77
let XXH_PRIME32_3: Int = 0xC2B2AE3D
let XXH_PRIME32_4: Int = 0x27D4EB2F
let XXH_PRIME32_5: Int = 0x165667B1

proc rotl32(x: Int, r: Int) -> Int:
    ## Rotate a 32-bit value left by `r` bits.
    let v: Int = x & MASK32
    return ((v << r) | (v >> (32 - r))) & MASK32

proc xxh32_round(acc: Int, input: Int) -> Int:
    ## Single xxHash32 accumulator round.
    var a: Int = (acc + ((input & MASK32) * XXH_PRIME32_2)) & MASK32
    a = rotl32(a, 13)
    a = (a * XXH_PRIME32_1) & MASK32
    return a

proc xxhash32(data: Bytes, seed: Int) -> Int:
    ## Compute the 32-bit xxHash of `data` with the given `seed`.
    ## Returns a 32-bit unsigned integer.
    let n: Int = bytes_len(data)
    var h32: Int = 0
    var idx: Int = 0

    if n >= 16:
        ## Initialise the four accumulators.
        var v1: Int = (seed + XXH_PRIME32_1 + XXH_PRIME32_2) & MASK32
        var v2: Int = (seed + XXH_PRIME32_2) & MASK32
        var v3: Int = (seed) & MASK32
        var v4: Int = (seed - XXH_PRIME32_1) & MASK32

        let limit: Int = n - 16
        while idx <= limit:
            v1 = xxh32_round(v1, read_le32(data, idx))
            v2 = xxh32_round(v2, read_le32(data, idx + 4))
            v3 = xxh32_round(v3, read_le32(data, idx + 8))
            v4 = xxh32_round(v4, read_le32(data, idx + 12))
            idx = idx + 16

        h32 = (rotl32(v1, 1) + rotl32(v2, 7) + rotl32(v3, 12) + rotl32(v4, 18)) & MASK32
    else:
        ## Small input: skip the main loop, start from the seed.
        h32 = (seed + XXH_PRIME32_5) & MASK32

    ## Mix in the total length.
    h32 = (h32 + n) & MASK32

    ## Process remaining 4-byte chunks.
    while idx + 4 <= n:
        let k1: Int = (read_le32(data, idx) * XXH_PRIME32_3) & MASK32
        h32 = (h32 + k1) & MASK32
        h32 = rotl32(h32, 17)
        h32 = (h32 * XXH_PRIME32_4) & MASK32
        idx = idx + 4

    ## Process remaining single bytes.
    while idx < n:
        let b: Int = bytes_get(data, idx)
        h32 = (h32 + ((b * XXH_PRIME32_5) & MASK32)) & MASK32
        h32 = rotl32(h32, 11)
        h32 = (h32 * XXH_PRIME32_1) & MASK32
        idx = idx + 1

    ## Final avalanche.
    h32 = h32 ^ (h32 >> 15)
    h32 = (h32 * XXH_PRIME32_2) & MASK32
    h32 = h32 ^ (h32 >> 13)
    h32 = (h32 * XXH_PRIME32_3) & MASK32
    h32 = h32 ^ (h32 >> 16)
    return h32 & MASK32

# ===========================================================================
# SHA-256 — cryptographic integrity + dedup fingerprint
# ===========================================================================

proc sha256_hex(data: Bytes) -> String:
    ## Full 256-bit SHA-256 digest as a 64-character lowercase hex string.
    ## Used for dedup block fingerprinting (Phase 5) and paranoid verification.
    return sha256(data)

proc hex_nibble(ch: String) -> Int:
    ## Convert a single hex character to its 0-15 value, or -1 if not hex.
    if ch >= "0" and ch <= "9":
        return ord(ch) - ord("0")
    if ch >= "a" and ch <= "f":
        return ord(ch) - ord("a") + 10
    if ch >= "A" and ch <= "F":
        return ord(ch) - ord("A") + 10
    return -1

proc sha256_fold32(data: Bytes) -> Int:
    ## Fold the 256-bit SHA-256 digest into a 32-bit checksum by XORing the
    ## eight little-endian 32-bit words together.  Suitable for the fixed
    ## 32-bit checksum fields while still deriving from a cryptographic hash.
    let hex: String = sha256(data)
    var acc: Int = 0
    var word: Int = 0
    var nibble_count: Int = 0
    var i: Int = 0
    let hlen: Int = len(hex)

    while i < hlen:
        let c: Int = hex_nibble(hex[i])
        if c >= 0:
            word = ((word << 4) | c) & MASK32
            nibble_count = nibble_count + 1
            if nibble_count == 8:
                acc = acc ^ word
                word = 0
                nibble_count = 0
        i = i + 1

    ## Fold any trailing partial word.
    if nibble_count > 0:
        acc = acc ^ word

    return acc & MASK32

# ===========================================================================
# Unified dispatch — the public checksum interface
# ===========================================================================

proc checksum_block(data: Bytes, algo: Int) -> Int:
    ## Compute the integrity checksum of a single block using the selected
    ## algorithm.  This is the canonical entry point used by every subsystem
    ## that writes or verifies a block.
    ##
    ##   algo == CHECKSUM_CRC32C -> CRC32C (default)
    ##   algo == CHECKSUM_XXHASH -> xxHash32 (seed 0)
    ##   algo == CHECKSUM_SHA256 -> SHA-256 folded to 32 bits
    ##
    ## Returns a 32-bit unsigned integer.  Unknown algorithms fall back to
    ## CRC32C so a corrupt/forward-incompatible `checksum_algo` never silently
    ## disables integrity checking.
    if algo == CHECKSUM_XXHASH:
        return xxhash32(data, 0)
    if algo == CHECKSUM_SHA256:
        return sha256_fold32(data)
    return crc32c(data)

proc verify_block(data: Bytes, algo: Int, expected: Int) -> Bool:
    ## Recompute the checksum of `data` and compare it against `expected`.
    ## Returns true when they match (block is intact).
    return checksum_block(data, algo) == (expected & MASK32)

# ===========================================================================
# Checksum policy — configurable data checksumming
# ===========================================================================

class ChecksumPolicy:
    ## Controls which blocks are checksummed and with which algorithm.
    ## Metadata is always checksummed regardless of `checksum_data`.
    var algo: Int                # active algorithm (CHECKSUM_*)
    var checksum_data: Bool      # whether data blocks are checksummed
    var verify_on_read: Bool     # verify checksums on every read

    proc init(self, algo: Int, checksum_data: Bool, verify_on_read: Bool):
        self.algo = algo
        self.checksum_data = checksum_data
        self.verify_on_read = verify_on_read

    proc for_metadata(self) -> Int:
        ## Algorithm to use for a metadata block (always checksummed).
        return self.algo

    proc for_data(self) -> Int:
        ## Algorithm to use for a data block, or -1 to skip checksumming.
        if self.checksum_data:
            return self.algo
        return -1

proc default_policy() -> ChecksumPolicy:
    ## Sensible default: CRC32C, data checksumming on, verify on read.
    return ChecksumPolicy(CHECKSUM_CRC32C, true, true)

# ===========================================================================
# Checksum tree — per-block checksum store (BTRFS-style)
# ===========================================================================
#
# Maps physical block address -> expected checksum.  In the on-disk layout
# this is backed by a CoW B+ tree (btree.sage); here we keep an in-memory
# Dict index plus serialize/deserialize helpers for persistence.  Entries are
# 12 bytes each on disk: 8-byte block address (LE64) + 4-byte checksum (LE32).
# ---------------------------------------------------------------------------

let CSUM_ENTRY_SIZE: Int = 12

class ChecksumTree:
    ## Tracks the expected checksum of every checksummed block.
    var algo: Int
    var entries: Dict[Int, Int]     # block_addr -> checksum

    proc init(self, algo: Int):
        self.algo = algo
        self.entries = {}

    proc record(self, block_addr: Int, data: Bytes):
        ## Compute and store the checksum for a freshly written block.
        self.entries[block_addr] = checksum_block(data, self.algo)

    proc record_value(self, block_addr: Int, checksum: Int):
        ## Store a pre-computed checksum directly.
        self.entries[block_addr] = checksum & MASK32

    proc lookup(self, block_addr: Int) -> Int:
        ## Return the recorded checksum for a block, or CHECKSUM_NONE if the
        ## block is not tracked.
        if dict_has(self.entries, block_addr):
            return self.entries[block_addr]
        return CHECKSUM_NONE

    proc verify(self, block_addr: Int, data: Bytes) -> Bool:
        ## Verify a block read from disk against its recorded checksum.
        ## Blocks with no recorded checksum are treated as valid (untracked).
        let expected: Int = self.lookup(block_addr)
        if expected == CHECKSUM_NONE:
            return true
        return checksum_block(data, self.algo) == expected

    proc remove(self, block_addr: Int):
        ## Drop the checksum entry for a freed block.
        if dict_has(self.entries, block_addr):
            dict_delete(self.entries, block_addr)

    proc count(self) -> Int:
        ## Number of tracked blocks.
        return len(dict_keys(self.entries))

    proc serialize(self) -> Bytes:
        ## Serialize all entries into a contiguous byte buffer.
        ## Layout: repeated (LE64 block_addr, LE32 checksum) records.
        ## Entries are emitted in ascending block-address order for
        ## determinism and efficient range scans.
        let buf: Bytes = bytes()
        let addrs: Array[Int] = sort_ints(dict_keys(self.entries))
        for addr in addrs:
            write_le64(buf, addr)
            write_le32(buf, self.entries[addr] & MASK32)
        return buf

    proc deserialize(self, buf: Bytes):
        ## Load entries from a buffer produced by `serialize`.
        ## Replaces the current in-memory index.
        self.entries = {}
        let n: Int = bytes_len(buf)
        var off: Int = 0
        while off + CSUM_ENTRY_SIZE <= n:
            let addr: Int = read_le64(buf, off)
            let csum: Int = read_le32(buf, off + 8)
            self.entries[addr] = csum
            off = off + CSUM_ENTRY_SIZE


# ===========================================================================
# Little-endian helpers
# ===========================================================================
#
# These mirror the helpers in superblock.sage.  They are redefined here so
# checksum.sage is self-contained and can be unit-tested in isolation; when
# linked into the full build the linker deduplicates identical definitions.
# ---------------------------------------------------------------------------

proc sort_ints(arr: Array[Int]) -> Array[Int]:
    ## Return a new ascending-sorted copy of an integer array (insertion sort).
    ## Used to emit checksum-tree entries in deterministic block-address order.
    ## The tree is typically small per-flush, so O(n^2) is acceptable here.
    var out: Array[Int] = []
    for v in arr:
        var i: Int = len(out) - 1
        out.push(v)
        while i >= 0 and out[i] > v:
            out[i + 1] = out[i]
            out[i] = v
            i = i - 1
    return out

proc write_le32(buf: Bytes, value: Int):
    ## Append a 32-bit little-endian integer to `buf`.
    bytes_push(buf, value & 0xFF)
    bytes_push(buf, (value >> 8) & 0xFF)
    bytes_push(buf, (value >> 16) & 0xFF)
    bytes_push(buf, (value >> 24) & 0xFF)

proc write_le64(buf: Bytes, value: Int):
    ## Append a 64-bit little-endian integer to `buf`.
    bytes_push(buf, value & 0xFF)
    bytes_push(buf, (value >> 8) & 0xFF)
    bytes_push(buf, (value >> 16) & 0xFF)
    bytes_push(buf, (value >> 24) & 0xFF)
    bytes_push(buf, (value >> 32) & 0xFF)
    bytes_push(buf, (value >> 40) & 0xFF)
    bytes_push(buf, (value >> 48) & 0xFF)
    bytes_push(buf, (value >> 56) & 0xFF)

proc read_le32(buf: Bytes, offset: Int) -> Int:
    ## Read a 32-bit little-endian integer from `buf` at `offset`.
    let b0: Int = bytes_get(buf, offset)
    let b1: Int = bytes_get(buf, offset + 1)
    let b2: Int = bytes_get(buf, offset + 2)
    let b3: Int = bytes_get(buf, offset + 3)
    return (b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)) & MASK32

proc read_le64(buf: Bytes, offset: Int) -> Int:
    ## Read a 64-bit little-endian integer from `buf` at `offset`.
    let b0: Int = bytes_get(buf, offset)
    let b1: Int = bytes_get(buf, offset + 1)
    let b2: Int = bytes_get(buf, offset + 2)
    let b3: Int = bytes_get(buf, offset + 3)
    let b4: Int = bytes_get(buf, offset + 4)
    let b5: Int = bytes_get(buf, offset + 5)
    let b6: Int = bytes_get(buf, offset + 6)
    let b7: Int = bytes_get(buf, offset + 7)
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24) | (b4 << 32) | (b5 << 40) | (b6 << 48) | (b7 << 56)
