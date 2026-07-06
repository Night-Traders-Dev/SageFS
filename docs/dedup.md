# Deduplication Engine

## Overview
The Deduplication Engine implements inline and background deduplication to maximize storage efficiency.

## Key Features
- **Inline Dedup**: Fast-path using a bloom filter.
- **Block-level Fingerprinting**: SHA-256 or xxHash.
- **Reflink-based Dedup**: Shared extents with reference counting.
- **Background Daemon**: Post-write deduplication.

## Implementation (Phase 4)
*In Progress*
