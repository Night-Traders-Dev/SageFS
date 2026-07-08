## ============================================================================
## SageFS Superblock & Checkpoint Manager
## ============================================================================
##
## Foundational on-disk metadata structures for SageFS — a filesystem that
## combines the log-structured segment design of F2FS with the copy-on-write
## snapshot capabilities of BTRFS.
##
## On-disk layout (block 0 onwards):
##
##   Block 0        : Primary Superblock
##   Block 1        : Mirror  Superblock  (identical copy for redundancy)
##   Blocks 2-3     : Checkpoint Pack 1   (2 blocks = 8 KiB)
##   Blocks 4-7     : Checkpoint Pack 2   (4 blocks = 16 KiB, extra room)
##   Block N_nat    : NAT  (Node Address Table)
##   Block N_sit    : SIT  (Segment Info Table)
##   Block N_ssa    : SSA  (Segment Summary Area)
##   Block N_main   : Main area (actual file data + node blocks)
##
## The dual-checkpoint-pack scheme guarantees atomic metadata updates: we
## always write to the *inactive* pack, then flip the active pointer.  If a
## crash occurs mid-write the previously-active pack remains valid.
##
## All multi-byte integers are serialized in little-endian byte order so the
## on-disk format is portable across architectures.
## ============================================================================

import sys

# ---------------------------------------------------------------------------
# Constants — Magic, version, sizes
# ---------------------------------------------------------------------------

## Magic number "SAGE" as a 32-bit value (0x53 'S', 0x41 'A', 0x47 'G', 0x45 'E')
let SAGEFS_MAGIC: Int = 0x53414745

## On-disk format version
let SAGEFS_VERSION_MAJOR: Int = 1
let SAGEFS_VERSION_MINOR: Int = 0

## Default block size in bytes (must be power-of-two, >= 4096)
let DEFAULT_BLOCK_SIZE: Int = 4096

## Default segment size in blocks (each segment = 512 * 4096 = 2 MiB)
let DEFAULT_SEGMENT_SIZE: Int = 512

## Byte offsets of the two superblock copies
let SUPERBLOCK_OFFSET: Int = 0
let SUPERBLOCK_MIRROR_OFFSET: Int = 4096

## Byte offsets of the two checkpoint packs
let CHECKPOINT_PACK1_OFFSET: Int = 8192
let CHECKPOINT_PACK2_OFFSET: Int = 16384

## Maximum volume label length in bytes (UTF-8)
let MAX_LABEL_LEN: Int = 256

# ---------------------------------------------------------------------------
# Feature flags — stored as a bitfield in superblock.flags
# ---------------------------------------------------------------------------

## Data-integrity checksums on metadata and data blocks
let FEATURE_CHECKSUM: Int = 0x0001

## Transparent block-level compression
let FEATURE_COMPRESS: Int = 0x0002

## At-rest encryption of data blocks
let FEATURE_ENCRYPT: Int = 0x0004

## Content-addressable deduplication
let FEATURE_DEDUP: Int = 0x0008

## Copy-on-write snapshots (BTRFS-style)
let FEATURE_SNAPSHOTS: Int = 0x0010

## Multi-device RAID support
let FEATURE_RAID: Int = 0x0020

## Small files stored directly in the inode (F2FS-style)
let FEATURE_INLINE_DATA: Int = 0x0040

## Extended attributes
let FEATURE_XATTR: Int = 0x0080

# ---------------------------------------------------------------------------
# Algorithm selectors
# ---------------------------------------------------------------------------

## Checksum algorithm identifiers
let CHECKSUM_CRC32C: Int = 0
let CHECKSUM_XXHASH: Int = 1
let CHECKSUM_SHA256: Int = 2

## Compression algorithm identifiers
let COMPRESS_NONE: Int = 0
let COMPRESS_LZ4: Int = 1
let COMPRESS_ZSTD: Int = 2
let COMPRESS_ZLIB: Int = 3

## Encryption algorithm identifiers
let ENCRYPT_NONE: Int = 0
let ENCRYPT_AES256_XTS: Int = 1

# ---------------------------------------------------------------------------
# Filesystem state
# ---------------------------------------------------------------------------

## Clean unmount — no recovery needed
let STATE_CLEAN: Int = 0

## Mounted or not cleanly unmounted — journal replay required
let STATE_DIRTY: Int = 1

## Unrecoverable error detected — requires fsck
let STATE_ERROR: Int = 2

# ===========================================================================
# Helper functions — little-endian serialization & utilities
# ===========================================================================

proc write_le64(buf: Bytes, value: Int):
    ## Write a 64-bit integer to `buf` in little-endian order (8 bytes).
    ## Each byte is extracted via mask-and-shift.
    bytes_push(buf, value & 0xFF)
    bytes_push(buf, (value >> 8) & 0xFF)
    bytes_push(buf, (value >> 16) & 0xFF)
    bytes_push(buf, (value >> 24) & 0xFF)
    bytes_push(buf, (value >> 32) & 0xFF)
    bytes_push(buf, (value >> 40) & 0xFF)
    bytes_push(buf, (value >> 48) & 0xFF)
    bytes_push(buf, (value >> 56) & 0xFF)

proc read_le64(buf: Bytes, offset: Int) -> Int:
    ## Read a 64-bit little-endian integer from `buf` starting at `offset`.
    let b0: Int = bytes_get(buf, offset)
    let b1: Int = bytes_get(buf, offset + 1)
    let b2: Int = bytes_get(buf, offset + 2)
    let b3: Int = bytes_get(buf, offset + 3)
    let b4: Int = bytes_get(buf, offset + 4)
    let b5: Int = bytes_get(buf, offset + 5)
    let b6: Int = bytes_get(buf, offset + 6)
    let b7: Int = bytes_get(buf, offset + 7)
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24) | (b4 << 32) | (b5 << 40) | (b6 << 48) | (b7 << 56)

proc write_le32(buf: Bytes, value: Int):
    ## Write a 32-bit integer to `buf` in little-endian order (4 bytes).
    bytes_push(buf, value & 0xFF)
    bytes_push(buf, (value >> 8) & 0xFF)
    bytes_push(buf, (value >> 16) & 0xFF)
    bytes_push(buf, (value >> 24) & 0xFF)

proc read_le32(buf: Bytes, offset: Int) -> Int:
    ## Read a 32-bit little-endian integer from `buf` starting at `offset`.
    let b0: Int = bytes_get(buf, offset)
    let b1: Int = bytes_get(buf, offset + 1)
    let b2: Int = bytes_get(buf, offset + 2)
    let b3: Int = bytes_get(buf, offset + 3)
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)

proc write_bytes_padded(buf: Bytes, data: String, padded_len: Int):
    ## Write a string into `buf` as UTF-8 bytes, zero-padded to `padded_len`.
    ## If the string is longer than `padded_len` it is silently truncated.
    let data_bytes: Bytes = bytes(data)
    var written: Int = 0
    while written < padded_len:
        if written < bytes_len(data_bytes):
            bytes_push(buf, bytes_get(data_bytes, written))
        else:
            bytes_push(buf, 0)
        written = written + 1

proc read_bytes_string(buf: Bytes, offset: Int, max_len: Int) -> String:
    ## Read a zero-padded string field from `buf`.  Stops at the first NUL
    ## byte or after `max_len` bytes, whichever comes first.
    var endstring: Int = offset
    while endstring < offset + max_len:
        if bytes_get(buf, endstring) == 0:
            break
        endstring = endstring + 1
    return bytes_to_string(bytes_slice(buf, offset, endstring))

proc generate_uuid() -> String:
    ## Generate a simple UUID-like identifier.
    ##
    ## Uses the current clock value combined with hash() to produce a
    ## 128-bit hex string formatted as 8-4-4-4-12.  This is *not*
    ## cryptographically random but is sufficient for volume identification
    ## during development.  A production implementation would read from
    ## /dev/urandom or use a CSPRNG.
    let seed1: Int = hash(str(sys.clock()))
    let seed2: Int = hash(str(sys.clock()) + "_sagefs_uuid")
    let seed3: Int = hash(str(seed1) + str(seed2))
    let seed4: Int = hash(str(seed3) + "_tail")

    ## Convert each seed to 8 hex chars and concatenate to get 32 hex digits
    let hex_chars: String = "0123456789abcdef"
    var result: String = ""
    var seeds = [seed1, seed2, seed3, seed4]
    var idx: Int = 0
    while idx < len(seeds):
        var val: Int = seeds[idx]
        if val < 0:
            val = -val
        var nibble_idx: Int = 0
        while nibble_idx < 8:
            let nibble: Int = (val >> (nibble_idx * 4)) & 0x0F
            result = result + slice(hex_chars, nibble, nibble + 1)
            nibble_idx = nibble_idx + 1
        idx = idx + 1

    ## Format as 8-4-4-4-12
    let part1: String = slice(result, 0, 8)
    let part2: String = slice(result, 8, 12)
    let part3: String = slice(result, 12, 16)
    let part4: String = slice(result, 16, 20)
    let part5: String = slice(result, 20, 32)
    return part1 + "-" + part2 + "-" + part3 + "-" + part4 + "-" + part5

proc is_power_of_two(n: Int) -> Bool:
    ## Return true if `n` is a positive power of two.
    if n <= 0:
        return false
    return (n & (n - 1)) == 0

# ===========================================================================
# Layout computation
# ===========================================================================

proc compute_layout(total_blocks: Int, block_size: Int, segment_size: Int) -> Dict:
    ## Compute starting block addresses for the major on-disk areas.
    ##
    ## The layout reserves the first few blocks for superblocks and checkpoint
    ## packs, then allocates contiguous regions for the NAT (Node Address
    ## Table), SIT (Segment Info Table), SSA (Segment Summary Area), and
    ## finally the main data/node area.
    ##
    ## Returns a dict with keys:
    ##   nat_start, sit_start, ssa_start, main_start,
    ##   nat_segments, sit_segments
    ##
    ## The sizes of NAT and SIT are proportional to `total_blocks` so the
    ## filesystem can address every block/segment in the volume.

    ## Number of segments in the entire volume (round down)
    let total_segments: Int = int(total_blocks / segment_size)

    ## Reserve first 8 blocks for superblocks (2) + checkpoint packs (up to 6)
    let reserved_blocks: Int = 8

    ## ------------------------------------------------------------------
    ## SIT: one bit per segment (valid/invalid) plus per-segment metadata.
    ## We budget 64 bytes per segment entry (type, valid-block-count, etc.)
    ## and round up to full blocks.
    ## ------------------------------------------------------------------
    let sit_entry_size: Int = 64
    let sit_bytes: Int = total_segments * sit_entry_size
    var sit_blocks: Int = int(sit_bytes / block_size)
    if sit_bytes % block_size != 0:
        sit_blocks = sit_blocks + 1
    var sit_segments: Int = int(sit_blocks / segment_size)
    if sit_blocks % segment_size != 0:
        sit_segments = sit_segments + 1
    ## Minimum 1 segment for SIT
    if sit_segments < 1:
        sit_segments = 1

    ## ------------------------------------------------------------------
    ## NAT: maps node IDs → block addresses.  We assume a maximum of
    ## total_blocks / 4 inodes (conservative upper bound) with 16 bytes
    ## per NAT entry (nid, block_addr, version, padding).
    ## ------------------------------------------------------------------
    let max_nodes: Int = int(total_blocks / 4)
    let nat_entry_size: Int = 16
    let nat_bytes: Int = max_nodes * nat_entry_size
    var nat_blocks: Int = int(nat_bytes / block_size)
    if nat_bytes % block_size != 0:
        nat_blocks = nat_blocks + 1
    var nat_segments: Int = int(nat_blocks / segment_size)
    if nat_blocks % segment_size != 0:
        nat_segments = nat_segments + 1
    if nat_segments < 1:
        nat_segments = 1

    ## ------------------------------------------------------------------
    ## SSA: one summary block per segment in the main area.
    ## We approximate main_segments ≈ total_segments - overhead; refine later.
    ## Allocate 1 block per main-area segment as summary.
    ## ------------------------------------------------------------------
    let estimated_main_segments: Int = total_segments - sit_segments - nat_segments - 1
    var ssa_blocks: Int = estimated_main_segments
    if ssa_blocks < 1:
        ssa_blocks = 1
    var ssa_segments: Int = int(ssa_blocks / segment_size)
    if ssa_blocks % segment_size != 0:
        ssa_segments = ssa_segments + 1
    if ssa_segments < 1:
        ssa_segments = 1

    ## ------------------------------------------------------------------
    ## Assign starting block offsets
    ## ------------------------------------------------------------------
    let nat_start: Int = reserved_blocks
    let sit_start: Int = nat_start + nat_segments * segment_size
    let ssa_start: Int = sit_start + sit_segments * segment_size
    let main_start: Int = ssa_start + ssa_segments * segment_size

    var layout: Dict = {}
    layout["nat_start"] = nat_start
    layout["sit_start"] = sit_start
    layout["ssa_start"] = ssa_start
    layout["main_start"] = main_start
    layout["nat_segments"] = nat_segments
    layout["sit_segments"] = sit_segments
    return layout

# ===========================================================================
# SageFSSuperblock
# ===========================================================================

class SageFSSuperblock:
    ## The primary on-disk superblock for a SageFS volume.
    ##
    ## Two identical copies are stored at block 0 (SUPERBLOCK_OFFSET) and
    ## block 1 (SUPERBLOCK_MIRROR_OFFSET).  The mirror is used for recovery
    ## if the primary copy is corrupted.
    ##
    ## The superblock is written only during mkfs and infrequently during
    ## certain mount operations (e.g. mount-count increment, state changes).
    ## All rapidly-changing metadata lives in the checkpoint packs instead.

    proc init(self):
        ## Initialize a superblock with safe defaults.
        ## Most layout-dependent fields (nat_start_blk, etc.) are set to zero
        ## and must be filled in by `create_superblock()` or deserialization.

        # -- identity --
        self.magic = SAGEFS_MAGIC
        self.version_major = SAGEFS_VERSION_MAJOR
        self.version_minor = SAGEFS_VERSION_MINOR

        # -- geometry --
        self.block_size = DEFAULT_BLOCK_SIZE
        self.segment_size = DEFAULT_SEGMENT_SIZE
        self.total_segments = 0
        self.total_blocks = 0
        self.free_segments = 0

        # -- key addresses --
        self.root_inode = 3          # inode 3 is traditionally the root dir
        self.checkpoint_ver = 0
        self.nat_start_blk = 0
        self.sit_start_blk = 0
        self.ssa_start_blk = 0
        self.main_start_blk = 0

        # -- identity / labeling --
        self.uuid = ""
        self.label = ""

        # -- features & algorithms --
        self.flags = 0
        self.checksum_algo = CHECKSUM_CRC32C
        self.compress_algo = COMPRESS_NONE
        self.encryption_algo = ENCRYPT_NONE
        self.raid_level = 0

        # -- housekeeping --
        self.create_time = 0
        self.mount_count = 0
        self.max_mount_count = 1000  # suggest fsck after this many mounts
        self.state = STATE_CLEAN

        # -- integrity --
        self.checksum = 0

    # -----------------------------------------------------------------------
    # Validation
    # -----------------------------------------------------------------------

    proc validate(self) -> Bool:
        ## Validate critical superblock invariants.
        ##
        ## Returns true if all of the following hold:
        ##   1. Magic number matches SAGEFS_MAGIC
        ##   2. Major version matches SAGEFS_VERSION_MAJOR (minor may differ)
        ##   3. Block size is a power of two and >= 4096
        ##   4. Segment size > 0

        if self.magic != SAGEFS_MAGIC:
            return false

        if self.version_major != SAGEFS_VERSION_MAJOR:
            return false

        if self.block_size < 4096:
            return false

        if not is_power_of_two(self.block_size):
            return false

        if self.segment_size <= 0:
            return false

        return true

    # -----------------------------------------------------------------------
    # Checksum helpers
    # -----------------------------------------------------------------------

    proc compute_checksum(self) -> Int:
        ## Compute a deterministic checksum over all superblock fields.
        ##
        ## We concatenate every field (except `checksum` itself) into a
        ## canonical string representation and feed it to the built-in
        ## hash() function.  This gives us a fast, deterministic integer
        ## suitable for corruption detection.
        ##
        ## A production implementation would use CRC32C for speed or SHA-256
        ## for cryptographic integrity, selectable via `checksum_algo`.

        var payload: String = ""
        payload = payload + str(self.magic)
        payload = payload + str(self.version_major)
        payload = payload + str(self.version_minor)
        payload = payload + str(self.block_size)
        payload = payload + str(self.segment_size)
        payload = payload + str(self.total_segments)
        payload = payload + str(self.total_blocks)
        payload = payload + str(self.free_segments)
        payload = payload + str(self.root_inode)
        payload = payload + str(self.checkpoint_ver)
        payload = payload + str(self.nat_start_blk)
        payload = payload + str(self.sit_start_blk)
        payload = payload + str(self.ssa_start_blk)
        payload = payload + str(self.main_start_blk)
        payload = payload + self.uuid
        payload = payload + self.label
        payload = payload + str(self.flags)
        payload = payload + str(self.checksum_algo)
        payload = payload + str(self.compress_algo)
        payload = payload + str(self.encryption_algo)
        payload = payload + str(self.raid_level)
        payload = payload + str(self.create_time)
        payload = payload + str(self.mount_count)
        payload = payload + str(self.max_mount_count)
        payload = payload + str(self.state)

        let raw: Int = hash(payload)
        ## Ensure non-negative 32-bit value
        if raw < 0:
            return (-raw) & 0xFFFFFFFF
        return raw & 0xFFFFFFFF

    proc update_checksum(self):
        ## Recompute and store the checksum.  Call this after any field change
        ## and before writing the superblock to disk.
        self.checksum = self.compute_checksum()

    proc verify_checksum(self) -> Bool:
        ## Return true if the stored checksum matches a freshly computed one.
        return self.checksum == self.compute_checksum()

    # -----------------------------------------------------------------------
    # Feature flag management
    # -----------------------------------------------------------------------

    proc has_feature(self, flag: Int) -> Bool:
        ## Check whether a specific feature flag is enabled.
        return (self.flags & flag) != 0

    proc set_feature(self, flag: Int):
        ## Enable a feature flag.  Idempotent — setting an already-set flag
        ## is a no-op.
        self.flags = self.flags | flag

    proc clear_feature(self, flag: Int):
        ## Disable a feature flag.
        self.flags = self.flags & (~flag)

    # -----------------------------------------------------------------------
    # Serialization
    # -----------------------------------------------------------------------

    proc serialize(self) -> Bytes:
        ## Serialize the superblock into a deterministic byte buffer suitable
        ## for writing to block 0 (and block 1 as a mirror).
        ##
        ## Field layout (byte offsets):
        ##
        ##   0-3     : magic          (LE32)
        ##   4-5     : version_major  (LE32 — we use 32-bit slots for alignment)
        ##   8-11    : version_minor  (LE32)
        ##   12-15   : block_size     (LE32)
        ##   16-19   : segment_size   (LE32)
        ##   20-27   : total_segments (LE64)
        ##   28-35   : total_blocks   (LE64)
        ##   36-43   : free_segments  (LE64)
        ##   44-51   : root_inode     (LE64)
        ##   52-59   : checkpoint_ver (LE64)
        ##   60-67   : nat_start_blk  (LE64)
        ##   68-75   : sit_start_blk  (LE64)
        ##   76-83   : ssa_start_blk  (LE64)
        ##   84-91   : main_start_blk (LE64)
        ##   92-127  : uuid           (36 bytes, zero-padded)
        ##   128-383 : label          (256 bytes, zero-padded)
        ##   384-387 : flags          (LE32)
        ##   388-391 : checksum_algo  (LE32)
        ##   392-395 : compress_algo  (LE32)
        ##   396-399 : encryption_algo(LE32)
        ##   400-403 : raid_level     (LE32)
        ##   404-411 : create_time    (LE64)
        ##   412-415 : mount_count    (LE32)
        ##   416-419 : max_mount_count(LE32)
        ##   420-423 : state          (LE32)
        ##   424-427 : checksum       (LE32)
        ##
        ## Total fixed size: 428 bytes.  The remainder of the block is zero.

        let buf: Bytes = bytes()

        # -- 32-bit fields (identity & geometry) --
        write_le32(buf, self.magic)           # 0
        write_le32(buf, self.version_major)   # 4
        write_le32(buf, self.version_minor)   # 8
        write_le32(buf, self.block_size)      # 12
        write_le32(buf, self.segment_size)    # 16

        # -- 64-bit fields (counts & addresses) --
        write_le64(buf, self.total_segments)  # 20
        write_le64(buf, self.total_blocks)    # 28
        write_le64(buf, self.free_segments)   # 36
        write_le64(buf, self.root_inode)      # 44
        write_le64(buf, self.checkpoint_ver)  # 52
        write_le64(buf, self.nat_start_blk)   # 60
        write_le64(buf, self.sit_start_blk)   # 68
        write_le64(buf, self.ssa_start_blk)   # 76
        write_le64(buf, self.main_start_blk)  # 84

        # -- strings (fixed-width, zero-padded) --
        write_bytes_padded(buf, self.uuid, 36)    # 92  (UUID is 36 chars)
        write_bytes_padded(buf, self.label, MAX_LABEL_LEN)  # 128

        # -- algorithm & feature selectors (32-bit) --
        write_le32(buf, self.flags)           # 384
        write_le32(buf, self.checksum_algo)   # 388
        write_le32(buf, self.compress_algo)   # 392
        write_le32(buf, self.encryption_algo) # 396
        write_le32(buf, self.raid_level)      # 400

        # -- timestamps & housekeeping --
        write_le64(buf, self.create_time)     # 404
        write_le32(buf, self.mount_count)     # 412
        write_le32(buf, self.max_mount_count) # 416
        write_le32(buf, self.state)           # 420

        # -- integrity checksum (must be last) --
        write_le32(buf, self.checksum)        # 424

        return buf

    # -----------------------------------------------------------------------
    # Debug / inspection
    # -----------------------------------------------------------------------

    proc to_dict(self) -> Dict:
        ## Return all superblock fields as a dictionary.
        ## Useful for debugging, logging, and test assertions.
        var d: Dict = {}
        d["magic"] = self.magic
        d["version_major"] = self.version_major
        d["version_minor"] = self.version_minor
        d["block_size"] = self.block_size
        d["segment_size"] = self.segment_size
        d["total_segments"] = self.total_segments
        d["total_blocks"] = self.total_blocks
        d["free_segments"] = self.free_segments
        d["root_inode"] = self.root_inode
        d["checkpoint_ver"] = self.checkpoint_ver
        d["nat_start_blk"] = self.nat_start_blk
        d["sit_start_blk"] = self.sit_start_blk
        d["ssa_start_blk"] = self.ssa_start_blk
        d["main_start_blk"] = self.main_start_blk
        d["uuid"] = self.uuid
        d["label"] = self.label
        d["flags"] = self.flags
        d["checksum_algo"] = self.checksum_algo
        d["compress_algo"] = self.compress_algo
        d["encryption_algo"] = self.encryption_algo
        d["raid_level"] = self.raid_level
        d["create_time"] = self.create_time
        d["mount_count"] = self.mount_count
        d["max_mount_count"] = self.max_mount_count
        d["state"] = self.state
        d["checksum"] = self.checksum
        return d

    proc to_string(self) -> String:
        ## Return a human-readable multi-line representation of the superblock.
        var s: String = "=== SageFS Superblock ===\n"
        s = s + "  magic:           0x" + str(self.magic) + "\n"
        s = s + "  version:         " + str(self.version_major) + "." + str(self.version_minor) + "\n"
        s = s + "  block_size:      " + str(self.block_size) + "\n"
        s = s + "  segment_size:    " + str(self.segment_size) + " blocks\n"
        s = s + "  total_segments:  " + str(self.total_segments) + "\n"
        s = s + "  total_blocks:    " + str(self.total_blocks) + "\n"
        s = s + "  free_segments:   " + str(self.free_segments) + "\n"
        s = s + "  root_inode:      " + str(self.root_inode) + "\n"
        s = s + "  checkpoint_ver:  " + str(self.checkpoint_ver) + "\n"
        s = s + "  nat_start_blk:   " + str(self.nat_start_blk) + "\n"
        s = s + "  sit_start_blk:   " + str(self.sit_start_blk) + "\n"
        s = s + "  ssa_start_blk:   " + str(self.ssa_start_blk) + "\n"
        s = s + "  main_start_blk:  " + str(self.main_start_blk) + "\n"
        s = s + "  uuid:            " + self.uuid + "\n"
        s = s + "  label:           " + self.label + "\n"
        s = s + "  flags:           0x" + str(self.flags) + "\n"
        s = s + "  checksum_algo:   " + str(self.checksum_algo) + "\n"
        s = s + "  compress_algo:   " + str(self.compress_algo) + "\n"
        s = s + "  encryption_algo: " + str(self.encryption_algo) + "\n"
        s = s + "  raid_level:      " + str(self.raid_level) + "\n"
        s = s + "  create_time:     " + str(self.create_time) + "\n"
        s = s + "  mount_count:     " + str(self.mount_count) + "/" + str(self.max_mount_count) + "\n"
        s = s + "  state:           " + str(self.state) + "\n"
        s = s + "  checksum:        0x" + str(self.checksum) + "\n"
        return s

proc deserialize_superblock(buf: Bytes) -> SageFSSuperblock:
    let sb: SageFSSuperblock = SageFSSuperblock()
    sb.magic         = read_le32(buf, 0)
    sb.version_major = read_le32(buf, 4)
    sb.version_minor = read_le32(buf, 8)
    sb.block_size    = read_le32(buf, 12)
    sb.segment_size  = read_le32(buf, 16)
    sb.total_segments   = read_le64(buf, 20)
    sb.total_blocks     = read_le64(buf, 28)
    sb.free_segments    = read_le64(buf, 36)
    sb.root_inode       = read_le64(buf, 44)
    sb.checkpoint_ver   = read_le64(buf, 52)
    sb.nat_start_blk    = read_le64(buf, 60)
    sb.sit_start_blk    = read_le64(buf, 68)
    sb.ssa_start_blk    = read_le64(buf, 76)
    sb.main_start_blk   = read_le64(buf, 84)
    sb.uuid         = read_bytes_string(buf, 92, 36)
    sb.label        = read_bytes_string(buf, 128, MAX_LABEL_LEN)
    sb.flags        = read_le32(buf, 384)
    sb.checksum_algo  = read_le32(buf, 388)
    sb.compress_algo  = read_le32(buf, 392)
    sb.encryption_algo = read_le32(buf, 396)
    sb.raid_level    = read_le32(buf, 400)
    sb.create_time   = read_le64(buf, 404)
    sb.mount_count   = read_le32(buf, 412)
    sb.max_mount_count = read_le32(buf, 416)
    sb.state         = read_le32(buf, 420)
    sb.checksum      = read_le32(buf, 424)
    return sb

# ===========================================================================
# SageFSCheckpoint
# ===========================================================================

class SageFSCheckpoint:
    ## A checkpoint pack captures the transient filesystem state at a
    ## consistent point in time.
    ##
    ## Two packs are maintained (pack1 at CHECKPOINT_PACK1_OFFSET, pack2 at
    ## CHECKPOINT_PACK2_OFFSET).  Only one is "active" at any moment; the
    ## other is the target for the next commit.  This dual-pack strategy
    ## mirrors the design used in F2FS:
    ##
    ##   1. Write new metadata to the *inactive* pack.
    ##   2. Flip the active pointer atomically (single LE32 version bump).
    ##   3. If a crash occurs during step 1, the previously-active pack
    ##      remains intact and is used for recovery.
    ##
    ## The `version` field is monotonically increasing; the pack with the
    ## *higher* valid version is the active one after a crash.

    proc init(self):
        ## Initialise all fields to zero / empty defaults.

        ## Monotonically increasing commit counter
        self.version = 0

        ## Wall-clock timestamp of this commit (seconds since epoch)
        self.timestamp = 0

        ## Block offsets of NAT/SIT bitmaps within their respective areas
        self.nat_bitmap_offset = 0
        self.sit_bitmap_offset = 0

        ## Version bitmaps track which copy of a NAT/SIT block is current
        ## (used for the double-buffered update scheme)
        self.nat_ver_bitmap_offset = 0
        self.sit_ver_bitmap_offset = 0

        ## Aggregate counters
        self.free_segments = 0
        self.valid_blocks = 0
        self.valid_nodes = 0
        self.next_free_nid = 4   # nids 0-3 are reserved (0=null, 1=meta,
                                 # 2=node-meta, 3=root)

        ## Time elapsed since filesystem creation (seconds)
        self.elapsed_time = 0

        ## Multi-head log allocation types (F2FS uses 6 cursors):
        ##   0 = HOT_NODE, 1 = WARM_NODE, 2 = COLD_NODE
        ##   3 = HOT_DATA, 4 = WARM_DATA, 5 = COLD_DATA
        self.alloc_type = [0, 0, 0, 0, 0, 0]

        ## Current active segment numbers for node logs (hot/warm/cold)
        self.cur_node_segno = [0, 0, 0]

        ## Current active segment numbers for data logs (hot/warm/cold)
        self.cur_data_segno = [0, 0, 0]

        ## Block offset within the current node segments (write cursor)
        self.cur_node_blkoff = [0, 0, 0]

        ## Block offset within the current data segments (write cursor)
        self.cur_data_blkoff = [0, 0, 0]

        ## Integrity checksum over all fields above
        self.checksum = 0

    # -----------------------------------------------------------------------
    # Checksum
    # -----------------------------------------------------------------------

    proc compute_checksum(self) -> Int:
        ## Compute a deterministic checksum over all checkpoint fields,
        ## excluding the checksum field itself.
        var payload: String = ""
        payload = payload + str(self.version)
        payload = payload + str(self.timestamp)
        payload = payload + str(self.nat_bitmap_offset)
        payload = payload + str(self.sit_bitmap_offset)
        payload = payload + str(self.nat_ver_bitmap_offset)
        payload = payload + str(self.sit_ver_bitmap_offset)
        payload = payload + str(self.free_segments)
        payload = payload + str(self.valid_blocks)
        payload = payload + str(self.valid_nodes)
        payload = payload + str(self.next_free_nid)
        payload = payload + str(self.elapsed_time)

        var i: Int = 0
        while i < 6:
            payload = payload + str(self.alloc_type[i])
            i = i + 1

        i = 0
        while i < 3:
            payload = payload + str(self.cur_node_segno[i])
            payload = payload + str(self.cur_data_segno[i])
            payload = payload + str(self.cur_node_blkoff[i])
            payload = payload + str(self.cur_data_blkoff[i])
            i = i + 1

        let raw: Int = hash(payload)
        if raw < 0:
            return (-raw) & 0xFFFFFFFF
        return raw & 0xFFFFFFFF

    proc update_checksum(self):
        ## Recompute and store the checkpoint checksum.
        self.checksum = self.compute_checksum()

    proc verify_checksum(self) -> Bool:
        ## Return true if the stored checksum is valid.
        return self.checksum == self.compute_checksum()

    # -----------------------------------------------------------------------
    # Serialization
    # -----------------------------------------------------------------------

    proc serialize(self) -> Bytes:
        ## Serialize the checkpoint into a deterministic byte buffer.
        ##
        ## Field layout (byte offsets):
        ##
        ##   0-7     : version               (LE64)
        ##   8-15    : timestamp              (LE64)
        ##   16-23   : nat_bitmap_offset      (LE64)
        ##   24-31   : sit_bitmap_offset      (LE64)
        ##   32-39   : nat_ver_bitmap_offset  (LE64)
        ##   40-47   : sit_ver_bitmap_offset  (LE64)
        ##   48-55   : free_segments          (LE64)
        ##   56-63   : valid_blocks           (LE64)
        ##   64-71   : valid_nodes            (LE64)
        ##   72-79   : next_free_nid          (LE64)
        ##   80-87   : elapsed_time           (LE64)
        ##   88-111  : alloc_type[0..5]       (6 x LE32 = 24 bytes)
        ##   112-123 : cur_node_segno[0..2]   (3 x LE32)
        ##   124-135 : cur_data_segno[0..2]   (3 x LE32)
        ##   136-147 : cur_node_blkoff[0..2]  (3 x LE32)
        ##   148-159 : cur_data_blkoff[0..2]  (3 x LE32)
        ##   160-163 : checksum               (LE32)
        ##
        ## Total fixed size: 164 bytes.

        let buf: Bytes = bytes()

        # -- 64-bit scalar fields --
        write_le64(buf, self.version)
        write_le64(buf, self.timestamp)
        write_le64(buf, self.nat_bitmap_offset)
        write_le64(buf, self.sit_bitmap_offset)
        write_le64(buf, self.nat_ver_bitmap_offset)
        write_le64(buf, self.sit_ver_bitmap_offset)
        write_le64(buf, self.free_segments)
        write_le64(buf, self.valid_blocks)
        write_le64(buf, self.valid_nodes)
        write_le64(buf, self.next_free_nid)
        write_le64(buf, self.elapsed_time)

        # -- alloc_type array (6 entries, 32-bit each) --
        var i: Int = 0
        while i < 6:
            write_le32(buf, self.alloc_type[i])
            i = i + 1

        # -- cursor arrays (3 entries each, 32-bit) --
        i = 0
        while i < 3:
            write_le32(buf, self.cur_node_segno[i])
            i = i + 1

        i = 0
        while i < 3:
            write_le32(buf, self.cur_data_segno[i])
            i = i + 1

        i = 0
        while i < 3:
            write_le32(buf, self.cur_node_blkoff[i])
            i = i + 1

        i = 0
        while i < 3:
            write_le32(buf, self.cur_data_blkoff[i])
            i = i + 1

        # -- checksum (last field) --
        write_le32(buf, self.checksum)

        return buf

    # -----------------------------------------------------------------------
    # Debug / inspection
    # -----------------------------------------------------------------------

    proc to_dict(self) -> Dict:
        ## Return all checkpoint fields as a dictionary for debugging.
        var d: Dict = {}
        d["version"] = self.version
        d["timestamp"] = self.timestamp
        d["nat_bitmap_offset"] = self.nat_bitmap_offset
        d["sit_bitmap_offset"] = self.sit_bitmap_offset
        d["nat_ver_bitmap_offset"] = self.nat_ver_bitmap_offset
        d["sit_ver_bitmap_offset"] = self.sit_ver_bitmap_offset
        d["free_segments"] = self.free_segments
        d["valid_blocks"] = self.valid_blocks
        d["valid_nodes"] = self.valid_nodes
        d["next_free_nid"] = self.next_free_nid
        d["elapsed_time"] = self.elapsed_time
        d["alloc_type"] = self.alloc_type
        d["cur_node_segno"] = self.cur_node_segno
        d["cur_data_segno"] = self.cur_data_segno
        d["cur_node_blkoff"] = self.cur_node_blkoff
        d["cur_data_blkoff"] = self.cur_data_blkoff
        d["checksum"] = self.checksum
        return d

# ===========================================================================
# CheckpointManager
# ===========================================================================

class CheckpointManager:
    ## Manages the dual checkpoint packs and implements atomic commits.
    ##
    ## The core invariant is simple: we *never* overwrite the active pack.
    ## Instead we write to the inactive pack, and only after the write is
    ## fully persisted do we flip `active_pack`.  Recovery after a crash
    ## simply selects the pack with the higher valid version number.
    ##
    ## Usage:
    ##
    ##   let mgr = CheckpointManager(sb)
    ##   mgr.create_initial()
    ##   # ... filesystem operations ...
    ##   mgr.commit()   # atomic metadata checkpoint

    proc init(self, sb: SageFSSuperblock):
        ## Create a new checkpoint manager bound to the given superblock.
        self.sb = sb
        self.pack1 = SageFSCheckpoint()
        self.pack2 = SageFSCheckpoint()
        self.active_pack = 1   # start with pack 1 as active

    proc get_active(self) -> SageFSCheckpoint:
        ## Return a reference to the currently active checkpoint pack.
        if self.active_pack == 1:
            return self.pack1
        return self.pack2

    proc get_inactive(self) -> SageFSCheckpoint:
        ## Return a reference to the currently *inactive* checkpoint pack.
        ## This is the target for the next commit.
        if self.active_pack == 1:
            return self.pack2
        return self.pack1

    proc commit(self) -> Bool:
        ## Perform an atomic checkpoint commit.
        ##
        ## Steps:
        ##   1. Copy the active pack's live state into the inactive pack.
        ##   2. Increment the version counter.
        ##   3. Update the timestamp.
        ##   4. Compute and store the checksum.
        ##   5. Flip the active_pack pointer.
        ##
        ## Returns true on success, false if validation fails.

        let active: SageFSCheckpoint = self.get_active()
        let target: SageFSCheckpoint = self.get_inactive()

        ## Copy live state from active → target (this is the "write to
        ## inactive pack" step — in a real implementation this would also
        ## flush the serialized bytes to the block device)
        target.version = active.version + 1
        target.timestamp = int(sys.clock())
        target.nat_bitmap_offset = active.nat_bitmap_offset
        target.sit_bitmap_offset = active.sit_bitmap_offset
        target.nat_ver_bitmap_offset = active.nat_ver_bitmap_offset
        target.sit_ver_bitmap_offset = active.sit_ver_bitmap_offset
        target.free_segments = active.free_segments
        target.valid_blocks = active.valid_blocks
        target.valid_nodes = active.valid_nodes
        target.next_free_nid = active.next_free_nid
        target.elapsed_time = active.elapsed_time

        ## Deep copy array fields
        var i: Int = 0
        while i < 6:
            target.alloc_type[i] = active.alloc_type[i]
            i = i + 1

        i = 0
        while i < 3:
            target.cur_node_segno[i] = active.cur_node_segno[i]
            target.cur_data_segno[i] = active.cur_data_segno[i]
            target.cur_node_blkoff[i] = active.cur_node_blkoff[i]
            target.cur_data_blkoff[i] = active.cur_data_blkoff[i]
            i = i + 1

        ## Finalise the target pack
        target.update_checksum()

        ## Also bump the superblock's checkpoint version
        self.sb.checkpoint_ver = target.version

        ## Flip the active pack pointer — this is the atomic commit point
        if self.active_pack == 1:
            self.active_pack = 2
        else:
            self.active_pack = 1

        return true

    proc rollback(self):
        ## Switch to the other checkpoint pack.
        ##
        ## This is used during recovery: if the currently-active pack is
        ## found to have an invalid checksum, we fall back to the other one.
        if self.active_pack == 1:
            self.active_pack = 2
        else:
            self.active_pack = 1

    proc create_initial(self):
        ## Populate the initial checkpoint state from the superblock.
        ##
        ## Called once during mkfs to set up a baseline checkpoint that
        ## reflects the freshly-formatted filesystem state.

        let cp: SageFSCheckpoint = self.pack1
        self.active_pack = 1

        cp.version = 1
        cp.timestamp = int(sys.clock())

        ## Bitmap offsets — in the initial layout these immediately follow
        ## their respective table areas.  Zeroes are fine as placeholders
        ## until the NAT/SIT writers compute exact positions.
        cp.nat_bitmap_offset = 0
        cp.sit_bitmap_offset = 0
        cp.nat_ver_bitmap_offset = 0
        cp.sit_ver_bitmap_offset = 0

        ## Aggregate counters from the superblock
        cp.free_segments = self.sb.free_segments
        cp.valid_blocks = 0
        cp.valid_nodes = 1   # root inode
        cp.next_free_nid = 4

        cp.elapsed_time = 0

        ## Initialise all cursors to point at the start of the main area.
        ## In a real implementation, the first HOT_NODE segment would be
        ## assigned during mkfs; here we use segment 0 of main.
        let main_seg: Int = self.sb.main_start_blk / self.sb.segment_size

        var j: Int = 0
        while j < 6:
            cp.alloc_type[j] = 0   # LFS mode (log-structured)
            j = j + 1

        j = 0
        while j < 3:
            cp.cur_node_segno[j] = main_seg + j
            cp.cur_data_segno[j] = main_seg + 3 + j
            cp.cur_node_blkoff[j] = 0
            cp.cur_data_blkoff[j] = 0
            j = j + 1

        cp.update_checksum()

        ## Also set superblock checkpoint version
        self.sb.checkpoint_ver = cp.version

# ===========================================================================
# Top-level factory
# ===========================================================================

proc create_superblock(total_blocks: Int, label: String, block_size: Int, segment_size: Int, features_dict: Dict) -> SageFSSuperblock:
    ## Create and return a fully initialised SageFSSuperblock.
    ##
    ## This is the primary entry point for `mkfs.sagefs`.  It:
    ##
    ##   1. Validates parameters (block size, segment size, minimum volume).
    ##   2. Computes the on-disk layout via `compute_layout()`.
    ##   3. Populates all superblock fields including UUID and timestamps.
    ##   4. Applies requested feature flags and algorithm selections.
    ##   5. Computes the integrity checksum.
    ##
    ## Parameters:
    ##   total_blocks   — Total number of blocks on the device.
    ##   label          — Human-readable volume label (max MAX_LABEL_LEN bytes).
    ##   block_size     — Block size in bytes (must be power-of-two, >= 4096).
    ##   segment_size   — Blocks per segment (must be > 0).
    ##   features_dict  — Optional configuration. Recognised keys:
    ##                       "features"      : Int  (bitfield of FEATURE_* flags)
    ##                       "checksum_algo" : Int  (CHECKSUM_*)
    ##                       "compress_algo" : Int  (COMPRESS_*)
    ##                       "encrypt_algo"  : Int  (ENCRYPT_*)
    ##
    ## Returns a ready-to-write SageFSSuperblock instance.

    ## --- Parameter validation ---
    if not is_power_of_two(block_size):
        raise "block_size must be a power of two"

    if block_size < 4096:
        raise "block_size must be >= 4096"

    if segment_size <= 0:
        raise "segment_size must be > 0"

    ## Minimum volume: at least 64 segments so there is room for metadata + data
    let total_segments: Int = total_blocks / segment_size
    if total_segments < 64:
        raise "volume too small: need at least 64 segments"

    ## --- Truncate label if necessary ---
    var safe_label: String = label
    if len(safe_label) > MAX_LABEL_LEN:
        safe_label = slice(safe_label, 0, MAX_LABEL_LEN)

    ## --- Compute layout ---
    let layout: Dict = compute_layout(total_blocks, block_size, segment_size)

    ## --- Build superblock ---
    let sb: SageFSSuperblock = SageFSSuperblock()

    sb.block_size = block_size
    sb.segment_size = segment_size
    sb.total_blocks = total_blocks
    sb.total_segments = total_segments

    ## Free segments = total minus metadata overhead
    let main_start_seg: Int = int(layout["main_start"] / segment_size)
    sb.free_segments = total_segments - main_start_seg
    if sb.free_segments < 0:
        sb.free_segments = 0

    sb.root_inode = 3
    sb.checkpoint_ver = 0

    sb.nat_start_blk = layout["nat_start"]
    sb.sit_start_blk = layout["sit_start"]
    sb.ssa_start_blk = layout["ssa_start"]
    sb.main_start_blk = layout["main_start"]

    sb.uuid = generate_uuid()
    sb.label = safe_label

    ## --- Apply features from features_dict ---
    if dict_has(features_dict, "features"):
        sb.flags = features_dict["features"]

    if dict_has(features_dict, "checksum_algo"):
        sb.checksum_algo = features_dict["checksum_algo"]

    if dict_has(features_dict, "compress_algo"):
        sb.compress_algo = features_dict["compress_algo"]

    if dict_has(features_dict, "encrypt_algo"):
        sb.encryption_algo = features_dict["encrypt_algo"]

    sb.create_time = int(sys.clock())
    sb.mount_count = 0
    sb.state = STATE_CLEAN

    sb.update_checksum()

    return sb
