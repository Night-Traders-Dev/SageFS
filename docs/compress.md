# Transparent Compression
**Module:** [`src/compress.sage`](../src/compress.sage) · **Phase:** 4 (Advanced) · **Status:** ✅ Implemented

## Purpose
Provides transparent inline block compression for data. Supports configurable algorithms based on data temperature (hot vs cold).

## Algorithms
- `lz4` - Fast, for hot data.
- `zstd` - High ratio, for cold archival data.
- `zlib` - Fallback compatibility.
- `none` - No compression.

## API
- `select_algorithm(temperature)`
- `compress_cluster(data, algo) -> Bytes`
- `decompress_cluster(data, algo) -> Bytes`
- `is_incompressible(original_size, compressed_size) -> Bool`

## Related
[allocator.md](allocator.md) · [inode.md](inode.md)
