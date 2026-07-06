# Checksum Engine

**Module:** [`src/checksum.sage`](../src/checksum.sage) · **Phase:** 3 (Integrity & Recovery) · **Status:** ✅ Implemented

## Purpose

Provides per-block integrity checksums for both metadata and data blocks. Three algorithms are supported, selectable via the superblock's `checksum_algo` field. Metadata is *always* checksummed; data checksumming is configurable.

## Algorithms

| ID | Constant | Algorithm | Notes |
|----|----------|-----------|-------|
| 0 | `CHECKSUM_CRC32C` | CRC-32 Castagnoli (poly `0x82F63B78`) | Default; hardware-accelerated; BTRFS/iSCSI/ext4 compatible |
| 1 | `CHECKSUM_XXHASH` | xxHash32 | Very fast non-cryptographic hash; reference-compatible |
| 2 | `CHECKSUM_SHA256` | SHA-256 (folded to 32 bits) | Cryptographic ("paranoid") mode; full hex digest available for dedup |

`CHECKSUM_NONE = 0` (reserved) means "no checksum recorded / untracked". Fixed-width arithmetic is enforced with `MASK32`/`MASK64`.

## Public API

| Function | Description |
|----------|-------------|
| `crc32c(data: Bytes) -> Int` | CRC32C checksum (table-driven, reflected algorithm) |
| `xxhash32(data: Bytes, seed: Int) -> Int` | xxHash32 with seed |
| `sha256_hex(data: Bytes) -> String` | Full 64-char SHA-256 hex digest (dedup fingerprint) |
| `sha256_fold32(data: Bytes) -> Int` | SHA-256 folded to a 32-bit checksum |
| `checksum_block(data: Bytes, algo: Int) -> Int` | **Unified dispatch** by algorithm ID |
| `verify_block(data: Bytes, algo: Int, expected: Int) -> Bool` | Recompute and compare |

`checksum_block()` is the canonical entry point for every subsystem that writes or verifies a block. An unknown `algo` safely falls back to CRC32C so a corrupt selector never disables integrity checking.

## Checksum Policy

### `ChecksumPolicy`

Controls which blocks are checksummed and with which algorithm.

| Method | Description |
|--------|-------------|
| `for_metadata() -> Int` | Algorithm for metadata (always checksummed) |
| `for_data() -> Int` | Algorithm for data, or `-1` to skip |

`default_policy()` returns CRC32C with data checksumming on and verify-on-read enabled.

## Checksum Tree (BTRFS-style)

### `ChecksumTree`

Maps physical block address → expected checksum. On disk this is backed by a CoW B+ tree; in memory it's a dict with serialize/deserialize helpers. Each on-disk entry is **12 bytes** (LE64 block address + LE32 checksum).

| Method | Description |
|--------|-------------|
| `record(block_addr, data)` | Compute & store the checksum of a written block |
| `record_value(block_addr, checksum)` | Store a precomputed checksum |
| `lookup(block_addr) -> Int` | Recorded checksum, or `CHECKSUM_NONE` |
| `verify(block_addr, data) -> Bool` | Verify a read against its recorded checksum |
| `remove(block_addr)` | Drop a freed block's entry |
| `count() -> Int` | Tracked block count |
| `serialize() -> Bytes` | Encode all entries in ascending block order |
| `deserialize(buf)` | Load entries from a buffer |

## Verification

The CRC32C and xxHash32 implementations are validated against standard known-answer vectors (see [`../testing/test_checksum.sage`](../testing/test_checksum.sage)):

- `crc32c("123456789") = 0xE3069283`, `crc32c("a") = 0xC1D04330`
- `xxhash32("", 0) = 0x02CC5D05`, `xxhash32("abc", 0) = 0x32D153FF`

## Implementation Notes

- **CRC32C** uses a lazily-built 256-entry lookup table and the reflected algorithm, matching the hardware `crc32c` instruction and BTRFS output.
- **xxHash32** follows the canonical primes, rotate amounts, and avalanche for bit-compatible output.
- **SHA-256** uses SageLang's native `sha256()` builtin; the 256-bit digest is folded to 32 bits by XORing its eight 32-bit words for the fixed-width on-disk checksum fields.

## Roadmap Integration

- The superblock and inode `compute_checksum()` methods (currently FNV-1a placeholders) will migrate to `checksum_block()`.
- The upcoming [journal](journal.md) module consumes `checksum_block()` to protect each write-ahead-log record.
- The Phase 5 dedup engine will use `sha256_hex()` / `xxhash32()` for block fingerprinting.

## Related

[journal.md](journal.md) · [superblock.md](superblock.md) · [inode.md](inode.md)
