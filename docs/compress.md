# Transparent Compression Engine

## Overview
The Transparent Compression Engine performs cluster-based compression (compressing N blocks into M blocks).

## Key Features
- **Tiered Algorithms**:
  - `lz4` for hot data (fastest).
  - `zstd` for cold data (best ratio).
  - `zlib` for compatibility fallback.
- **Dynamic Selection**: Per-file, per-directory, or temperature-based selection.
- **Incompressible Data Detection**: Automatically skips compression if the data is incompressible.

## Implementation (Phase 4)
*In Progress*
