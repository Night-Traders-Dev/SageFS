# Deduplication Engine
**Module:** [`src/dedup.sage`](../src/dedup.sage) · **Phase:** 4 (Advanced) · **Status:** ✅ Implemented

## Purpose
Provides inline and background data deduplication. Identical blocks are mapped to the same physical address, incrementing reference counts in the deduplication engine.

## Implementation Details
- Uses SHA-256 for block fingerprinting.
- Fast path: Bloom filter to skip unique blocks without a hash table lookup.
- Fingerprint store tracking block addresses for matched hashes.
- Reference counting to manage deduplicated blocks lifecycle.

## API
- `check_inline(data) -> Int` — returns block address on hit, or -1 on miss
- `add_fingerprint(data, block_addr)` — registers a new unique block
- `inc_ref(block_addr) -> Int`
- `dec_ref(block_addr) -> Int`
- `get_stats() -> Dict`

## Related
[checksum.md](checksum.md)
