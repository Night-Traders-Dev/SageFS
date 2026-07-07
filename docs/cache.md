# Caching Subsystem
**Module:** [`src/cache.sage`](../src/cache.sage) · **Phase:** 5 (Performance) · **Status:** ✅ Implemented

## Purpose
Accelerates metadata lookup in SageFS to avoid disk I/O on hot paths.

## Structure
Implemented as multiple Least Recently Used (LRU) caches:
- **NAT Cache:** Caches `nid -> physical block` lookups.
- **Extent Cache:** Caches file data block mappings (`ino:logical -> physical`).
- **Node Cache:** Caches loaded B+ Tree node blocks.

## API
- `LRUCache` class handles capacity-based eviction and `put`/`get` operations.
- `CacheManager` provides domain-specific wrappers (`get_nat`, `get_extent`, `get_node`).

## Related
[nat.md](nat.md) · [btree.md](btree.md) · [extent.md](extent.md)
