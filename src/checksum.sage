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

## FNV-1a over a string, byte for byte the same function the interpreter's hash()
## builtin uses (core/src/c/interpreter.c fnv1a_str). SageFS used to call hash()
## directly in three places; the interpreter and bytecode backend have it and
## neither compiled backend does, so sage-c rejected those files and sagemake
## silently fell back to the SageVM backend. Checksums computed here therefore
## match ones computed by the interpreter, which is what keeps a formatted image
## verifiable across toolchains.
proc fnv1a_str(s: String) -> Int:
    var h: Int = 2166136261
    var i: Int = 0
    while i < len(s):
        ## ord() of a one-character slice gives that character's code point,
        ## which is the byte FNV-1a expects for the ASCII text these hashes cover.
        h = (h ^ ord(slice(s, i, i + 1))) * 16777619
        h = h & 0xFFFFFFFF
        i = i + 1
    return h

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
        push(CRC32C_TABLE, crc & MASK32)
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
# Safe 32-bit modular arithmetic helpers
# ===========================================================================
#
# Sage's 64-bit tagged integers overflow into float ~ 2^53, so direct
# multiplication of two 32-bit values can lose precision.  We split each
# operand into 16-bit halves and reassemble modulo 2^32, keeping all
# intermediate products well below 2^53 (max ~ 5.6 × 10^14).
# ---------------------------------------------------------------------------

proc mul32(a: Int, b: Int) -> Int:
    ## Compute (a × b) mod 2^32 without overflow.
    let a_lo: Int = a & 0xFFFF
    let a_hi: Int = (a >> 16) & 0xFFFF
    let b_lo: Int = b & 0xFFFF
    let b_hi: Int = (b >> 16) & 0xFFFF
    let p_lo: Int = a_lo * b_lo
    let p_mid: Int = (a_lo * b_hi) + (a_hi * b_lo)
    return (p_lo + ((p_mid << 16) & MASK32)) & MASK32

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
    var a: Int = (acc + mul32(input & MASK32, XXH_PRIME32_2)) & MASK32
    a = rotl32(a, 13)
    a = mul32(a, XXH_PRIME32_1)
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
        let k1: Int = mul32(read_le32(data, idx), XXH_PRIME32_3)
        h32 = (h32 + k1) & MASK32
        h32 = rotl32(h32, 17)
        h32 = mul32(h32, XXH_PRIME32_4)
        idx = idx + 4

    ## Process remaining single bytes.
    while idx < n:
        let b: Int = bytes_get(data, idx)
        h32 = (h32 + mul32(b, XXH_PRIME32_5)) & MASK32
        h32 = rotl32(h32, 11)
        h32 = mul32(h32, XXH_PRIME32_1)
        idx = idx + 1

    ## Final avalanche.
    h32 = h32 ^ (h32 >> 15)
    h32 = mul32(h32, XXH_PRIME32_2)
    h32 = h32 ^ (h32 >> 13)
    h32 = mul32(h32, XXH_PRIME32_3)
    h32 = h32 ^ (h32 >> 16)
    return h32 & MASK32

# ===========================================================================
# SHA-256 — cryptographic integrity + dedup fingerprint
# ===========================================================================
#
# Sage has no built-in SHA-256.  This stub returns the well-known digest of
# the empty string so that the dispatch table and checksum-fold functions
# compile and return consistent (if not input-dependent) values.
# A proper native implementation should be wired in at the VM level.
# ---------------------------------------------------------------------------

proc rotr32(x: Int, n: Int) -> Int:
    ## Rotate a 32-bit word right by n bits, staying inside 32 bits throughout.
    ##
    ## The obvious form, (x >> n) | (x << (32 - n)), overflows a double: x is
    ## nearly 2^32 and the shift adds up to 31, so the intermediate reaches 2^63
    ## and a 53-bit significand silently rounds away the low bits -- which are
    ## exactly the bits being rotated into the high half. Masking before the shift
    ## keeps every intermediate under 2^32, so the OR is exact before the final
    ## mask.
    let v: Int = x & MASK32
    if n == 0:
        return v
    ## A right rotate moves x's low n bits to the top and its high (32 - n) bits
    ## down by n. Masking to n bits before shifting keeps the shifted term under
    ## 2^32, so nothing is rounded on the way.
    let low_mask: Int = (1 << n) - 1
    let lo: Int = v & low_mask
    return ((v >> n) | (lo << (32 - n))) & MASK32

proc sha256(data: Bytes) -> String:
    ## SHA-256 of `data`, as 64 lowercase hex characters.
    ##
    ## Sage numbers are IEEE doubles with a 53-bit significand, so every
    ## intermediate here is masked to 32 bits. The widest sum is five masked words,
    ## under 2^35, still exactly representable.
    let K: Array[Int] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]

    var H: Array[Int] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]

    let n: Int = bytes_len(data)
    let bitlen: Int = n * 8
    ## Pad: 0x80, zeros to 56 mod 64, then the length as 8 big-endian bytes.
    var total: Int = n + 1
    while (total % 64) != 56:
        total = total + 1
    total = total + 8
    var msg: Bytes = bytes(total)
    var i: Int = 0
    while i < n:
        msg[i] = data[i]
        i = i + 1
    msg[n] = 0x80
    var lb: Int = 7
    while lb >= 0:
        ## bitlen < 2^53 for any input this runtime can hold, so the shifts are
        ## exact even before masking.
        msg[total - 1 - lb] = (bitlen >> (lb * 8)) & 0xFF
        lb = lb - 1

    var block: Int = 0
    while block * 64 < total:
        ## Message schedule: 16 words read big-endian from the block, then expanded
        ## in place to 64.
        var w: Array[Int] = []
        var t: Int = 0
        while t < 16:
            let p: Int = block * 64 + t * 4
            push(w, (msg[p] << 24) | (msg[p + 1] << 16) | (msg[p + 2] << 8) | msg[p + 3])
            t = t + 1
        t = 16
        while t < 64:
            let v15: Int = w[t - 15]
            let v2: Int = w[t - 2]
            let s0: Int = rotr32(v15, 7) ^ rotr32(v15, 18) ^ (v15 >> 3)
            let s1: Int = rotr32(v2, 17) ^ rotr32(v2, 19) ^ (v2 >> 10)
            push(w, (w[t - 16] + s0 + w[t - 7] + s1) & MASK32)
            t = t + 1

        var a: Int = H[0]
        var b: Int = H[1]
        var c: Int = H[2]
        var d: Int = H[3]
        var e: Int = H[4]
        var f: Int = H[5]
        var g: Int = H[6]
        var h: Int = H[7]

        t = 0
        while t < 64:
            let S1: Int = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
            let ch: Int = (e & f) ^ ((MASK32 ^ e) & g)
            let t1: Int = (h + S1 + ch + K[t] + w[t]) & MASK32
            let S0: Int = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
            let maj: Int = (a & b) ^ (a & c) ^ (b & c)
            let t2: Int = (S0 + maj) & MASK32
            h = g
            g = f
            f = e
            e = (d + t1) & MASK32
            d = c
            c = b
            b = a
            a = (t1 + t2) & MASK32
            t = t + 1

        H[0] = (H[0] + a) & MASK32
        H[1] = (H[1] + b) & MASK32
        H[2] = (H[2] + c) & MASK32
        H[3] = (H[3] + d) & MASK32
        H[4] = (H[4] + e) & MASK32
        H[5] = (H[5] + f) & MASK32
        H[6] = (H[6] + g) & MASK32
        H[7] = (H[7] + h) & MASK32
        block = block + 1

    let HEX: String = "0123456789abcdef"
    var out: String = ""
    var wi: Int = 0
    while wi < 8:
        let word: Int = H[wi]
        ## Eight hex digits per 32-bit state word, most significant nibble first.
        ## Stepping by 4 bits rather than 8 matters: shifting a 32-bit word by 32 or
        ## more always yields zero, so a byte-stepped loop silently emits a 128-bit
        ## digest with the top half of every word zero.
        var pos: Int = 7
        while pos >= 0:
            let nyb: Int = (word >> (pos * 4)) & 0xF
            out = out + HEX[nyb:nyb + 1]
            pos = pos - 1
        wi = wi + 1
    return out

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

    proc init(self, algo: Int):
        self.algo = algo
        self.entries = {}

    proc record(self, block_addr: Int, data: Bytes):
        ## Compute and store the checksum for a freshly written block.
        self.entries[str(block_addr)] = checksum_block(data, self.algo)

    proc record_value(self, block_addr: Int, checksum: Int):
        ## Store a pre-computed checksum directly.
        self.entries[str(block_addr)] = checksum & MASK32

    proc lookup(self, block_addr: Int) -> Int:
        ## Return the recorded checksum for a block, or CHECKSUM_NONE if the
        ## block is not tracked.
        let key: String = str(block_addr)
        if dict_has(self.entries, key):
            return self.entries[key]
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
        let key: String = str(block_addr)
        if dict_has(self.entries, key):
            dict_delete(self.entries, key)

    proc count(self) -> Int:
        ## Number of tracked blocks.
        return len(dict_keys(self.entries))

    proc serialize(self) -> Bytes:
        ## Serialize all entries into a contiguous byte buffer.
        ## Layout: repeated (LE64 block_addr, LE32 checksum) records.
        ## Entries are emitted in ascending block-address order for
        ## determinism and efficient range scans.
        let buf: Bytes = bytes()
        var addrs: Array[Int] = []
        for s in dict_keys(self.entries):
            push(addrs, tonumber(s))
        addrs = sort_ints(addrs)
        for addr in addrs:
            write_le64(buf, addr)
            write_le32(buf, self.entries[str(addr)] & MASK32)
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
            self.entries[str(addr)] = csum
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
        push(out, v)
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
