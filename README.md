# SageFS

> **A next-generation filesystem written in SageLang that combines the best of F2FS and BTRFS**

[![Language](https://img.shields.io/badge/Language-SageLang-blue)](#)
[![License](https://img.shields.io/badge/License-MIT-green)](#)
[![Status](https://img.shields.io/badge/Status-In%20Development-orange)](#)

---

## Overview

SageFS is a high-performance, copy-on-write filesystem designed from the ground up to combine:

- **F2FS's flash-optimized log-structured architecture** — multi-head logging, hot/warm/cold data separation, Node Address Table (NAT) for wandering-tree elimination
- **BTRFS's advanced data management** — CoW B+ trees, snapshots, subvolumes, transparent compression, checksumming, integrated RAID, deduplication

The result is a filesystem that delivers **superior SSD performance** with **enterprise-grade data integrity**, written entirely in [SageLang](https://github.com/Night-Traders-Dev/SageLang) — a systems programming language with Python-like readability and C-like performance.

---

## Key Features

### 🚀 Performance
- **Log-structured writes** — all writes are sequential, minimizing write amplification on SSDs/NVMe
- **Multi-head logging** — 6 concurrent log zones with hot/warm/cold temperature classification
- **NAT indirection** — eliminates cascading CoW updates (the "wandering tree" problem)
- **Async I/O** — io_uring integration for zero-copy, kernel-side polling
- **Lock-free hot paths** — per-CPU I/O submission queues
- **Inline data & directories** — small files stored directly in inodes (zero block allocation)

### 🛡️ Data Integrity
- **Per-block checksumming** — CRC32C (hardware-accelerated), xxHash, or SHA-256
- **Dual superblock mirroring** — survive superblock corruption
- **Checkpoint packs** — dual alternating packs for atomic metadata commits
- **Write-ahead journal** — metadata crash recovery with transaction replay
- **Online scrub** — background checksum verification
- **Repair-on-read** — automatic corruption repair with RAID redundancy

### 📸 Snapshots & Subvolumes
- **Instant CoW snapshots** — clone B+ tree root in O(1)
- **Writable snapshots** — branch and diverge from any point
- **Subvolumes** — independent filesystem trees in one partition
- **Snapshot diff** — efficient delta calculation between snapshots
- **Rotation policies** — automatic N hourly/daily/weekly retention

### 📦 Storage Efficiency
- **Transparent compression** — per-file algorithm (lz4 for speed, zstd for ratio, zlib for compat)
- **Inline deduplication** — bloom filter fast-path + block fingerprinting
- **Reflink copies** — instant file clones sharing physical extents
- **Extent-based allocation** — contiguous block runs for minimal metadata overhead

### 🔐 Security
- **Per-file encryption** — AES-256-XTS with fscrypt-compatible key management
- **Filename encryption** — AES-256-CTS
- **Hardware acceleration** — AES-NI for near-zero encryption overhead

### 🔗 Multi-Device
- **Integrated RAID** — 0 (stripe), 1 (mirror), 5 (parity), 6 (double parity), 10 (stripe+mirror)
- **Online device management** — add, remove, replace devices without unmounting
- **Scrub & balance** — periodic verification and data rebalancing

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    VFS Interface Layer                    │
│  (POSIX: open, read, write, mkdir, stat, ioctl, xattr)  │
├─────────────────────────────────────────────────────────┤
│                   SageFS Core Engine                     │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────┐ │
│  │ Namespace│ │ Allocator│ │ Journal  │ │ Transaction│ │
│  │ Manager  │ │ Engine   │ │ (Log)    │ │ Manager    │ │
│  └──────────┘ └──────────┘ └──────────┘ └────────────┘ │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────┐ │
│  │ Snapshot │ │ Compress │ │ Checksum │ │ Dedup      │ │
│  │ Engine   │ │ Engine   │ │ Engine   │ │ Engine     │ │
│  └──────────┘ └──────────┘ └──────────┘ └────────────┘ │
├─────────────────────────────────────────────────────────┤
│               On-Disk Layout Engine                      │
│  ┌────────────┐ ┌─────────┐ ┌──────────┐ ┌───────────┐ │
│  │ Superblock │ │ Segment │ │ NAT/SIT  │ │ CoW B+    │ │
│  │ Manager    │ │ Manager │ │ Tables   │ │ Tree      │ │
│  └────────────┘ └─────────┘ └──────────┘ └───────────┘ │
├─────────────────────────────────────────────────────────┤
│                Block I/O Layer                           │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────┐ │
│  │ Multi-   │ │ Zone-    │ │ RAID     │ │ Async I/O  │ │
│  │ Stream   │ │ Aware    │ │ Engine   │ │ Engine     │ │
│  └──────────┘ └──────────┘ └──────────┘ └────────────┘ │
├─────────────────────────────────────────────────────────┤
│                   Device Drivers                         │
│         (NVMe, SATA, eMMC, UFS, ZNS SSDs)               │
└─────────────────────────────────────────────────────────┘
```

---

## Performance Targets

| Benchmark | F2FS | BTRFS | SageFS Target |
|-----------|------|-------|---------------|
| Sequential write (4K) | ~1.8 GB/s | ~1.2 GB/s | **≥ 2.0 GB/s** |
| Sequential read (4K) | ~2.5 GB/s | ~2.3 GB/s | **≥ 2.5 GB/s** |
| Random write (4K, QD32) | ~350K IOPS | ~180K IOPS | **≥ 400K IOPS** |
| Random read (4K, QD32) | ~600K IOPS | ~500K IOPS | **≥ 650K IOPS** |
| Metadata ops (create/s) | ~250K | ~120K | **≥ 300K** |
| Mount time (1TB) | < 1s | 2–5s | **< 0.5s** |
| Fsync latency (p99) | ~200µs | ~500µs | **< 150µs** |
| Write amplification | 1.1–1.5x | 1.5–3.0x | **< 1.2x** |

---

## Quick Start

### Build

```bash
# Compile the filesystem tools
sage --compile src/mkfs.sage -o build/mkfs.sagefs -O3
sage --compile src/fsck.sage -o build/fsck.sagefs -O3
```

### Format a Disk Image

```bash
# Create a 1GB image
dd if=/dev/zero of=sagefs.img bs=1M count=1024

# Format with SageFS
./build/mkfs.sagefs sagefs.img --label "MyVolume" --compress zstd --checksum crc32c
```

### Run Tests

```bash
# Unit tests
sage testing/test_superblock.sage
sage testing/test_btree.sage
sage testing/test_allocator.sage

# Integration tests
sage testing/test_integration.sage

# Benchmarks
sage benchmark/bench_seq_write.sage
sage benchmark/bench_rand_write.sage
```

---

## Project Structure

```
SageFS/
├── src/                           # Core filesystem source
│   ├── superblock.sage            # Superblock & checkpoint management
│   ├── inode.sage                 # Inode allocation & management
│   ├── segment.sage               # Segment manager & SIT
│   ├── allocator.sage             # Block/segment allocator
│   ├── nat.sage                   # Node Address Table
│   ├── btree.sage                 # CoW B+ tree engine
│   ├── dir.sage                   # Directory operations
│   ├── extent.sage                # Extent mapping
│   ├── checksum.sage              # Checksum engine
│   ├── journal.sage               # Write-ahead log
│   ├── transaction.sage           # Transaction manager
│   ├── gc.sage                    # Garbage collector
│   ├── snapshot.sage              # Snapshot & subvolume engine
│   ├── compress.sage              # Transparent compression
│   ├── dedup.sage                 # Deduplication engine
│   ├── encrypt.sage               # Encryption layer
│   ├── raid.sage                  # Integrated RAID engine
│   ├── cache.sage                 # Caching subsystem
│   ├── aio.sage                   # Async I/O (io_uring)
│   ├── vfs.sage                   # VFS interface
│   ├── mkfs.sage                  # Filesystem formatter
│   ├── mount.sage                 # Mount helper
│   ├── fsck.sage                  # Filesystem checker
│   └── tools/                     # CLI utilities
├── docs/                          # Documentation
├── testing/                       # Test suite
├── benchmark/                     # Performance benchmarks
└── build/                         # Build configuration & artifacts
```

---

## Design Highlights

### Hybrid NAT + CoW Tree (Novel)

SageFS introduces a unique hybrid approach:

- **NAT (from F2FS)** handles data node address translation, eliminating the "wandering tree" problem where updating a leaf requires updating every node up to the root
- **CoW B+ trees (from BTRFS)** handle metadata indexing, enabling instant snapshots via tree root cloning

This combination gives us F2FS's write performance with BTRFS's snapshot capability — without the weaknesses of either approach in isolation.

### Adaptive Multi-Stream Allocation

Data is classified by temperature (hot/warm/cold) and node type, then directed to one of 6 dedicated logging zones. This:
- Reduces garbage collection overhead (cold segments have fewer valid blocks to relocate)
- Extends SSD lifespan (fewer erase cycles)
- Improves sequential write throughput (no mixing of hot and cold data)

### Tiered Compression

Unlike BTRFS's uniform compression policy, SageFS selects compression algorithms per-cluster based on data temperature:
- **Hot data** → lz4 (minimal CPU overhead, maintains throughput)
- **Cold data** → zstd (maximum compression ratio)
- **Incompressible data** → detected and skipped automatically

---

## Development Roadmap

| Phase | Timeline | Focus | Milestone |
|-------|----------|-------|-----------|
| 1 | Weeks 1–4 | Foundation | Format image, read/write inodes |
| 2 | Weeks 5–8 | Trees & Namespace | Create dirs, write/read files |
| 3 | Weeks 9–12 | Integrity & Recovery | Survive power-loss simulation |
| 4 | Weeks 13–18 | Advanced Features | BTRFS feature parity |
| 5 | Weeks 19–22 | Performance | Meet/exceed performance targets |
| 6 | Weeks 23–26 | Tooling & Polish | Production-ready toolchain |

See [plan.md](plan.md) for the full development plan.

**Current progress:** Phases 1–3 complete. Phase 1 & 2: superblock, segment/SIT, NAT, allocator, inode, CoW B+ tree, directory, extent map. Phase 3 (Integrity & Recovery): checksum engine, write-ahead journal, transaction manager (with nested transactions), crash-recovery replay, and offline fsck. Phase 4 (Advanced Features — snapshots, compression, dedup, encryption, RAID) is next.

---

## Documentation

Each implemented component is documented in its own file under [`docs/`](docs/):

| Component | Doc | Description |
|-----------|-----|-------------|
| Superblock & Checkpoint | [docs/superblock.md](docs/superblock.md) | On-disk root, feature flags, atomic checkpoints |
| Segment Manager (SIT) | [docs/segment.md](docs/segment.md) | Log-structured segments, multi-head logging, GC victim selection |
| Node Address Table | [docs/nat.md](docs/nat.md) | nid → block indirection, wandering-tree elimination |
| Block Allocator | [docs/allocator.md](docs/allocator.md) | Unified allocation over SIT + NAT |
| Inode Manager | [docs/inode.md](docs/inode.md) | File/dir metadata, inline data, block pointers |
| CoW B+ Tree | [docs/btree.md](docs/btree.md) | Copy-on-write index for dirs, extents, snapshots |
| Directory Manager | [docs/dir.md](docs/dir.md) | POSIX namespace, hashed dentries |
| Extent Map | [docs/extent.md](docs/extent.md) | Extent-based allocation, hole punching |
| Checksum Engine | [docs/checksum.md](docs/checksum.md) | CRC32C / xxHash / SHA-256 per-block integrity |
| Journal & Transactions | [docs/journal.md](docs/journal.md) | Write-ahead log & crash recovery |
| fsck | [docs/fsck.md](docs/fsck.md) | Offline consistency checker (NAT ↔ SIT ↔ inode tree) |
| Snapshot Engine | [docs/snapshot.md](docs/snapshot.md) | Copy-on-write snapshot and subvolume management |
| Compression | [docs/compress.md](docs/compress.md) | Transparent data compression |
| Deduplication | [docs/dedup.md](docs/dedup.md) | Inline and background deduplication |
| Encryption | [docs/encrypt.md](docs/encrypt.md) | File and filename encryption |
| RAID Engine | [docs/raid.md](docs/raid.md) | Multi-device integration and parity |

Start with the [documentation index](docs/README.md) for the recommended reading order.

---

## Why SageLang?

SageFS is written in [SageLang](https://github.com/Night-Traders-Dev/SageLang), which offers:

- **C11 compilation backend** — zero-overhead systems code with native performance
- **Native assembly emission** — x86-64, aarch64, rv64 for hot paths
- **Low-level primitives** — `mem_alloc`, `mem_read`, `mem_write`, `unsafe` blocks, FFI
- **First-class binary buffers** — `Bytes` type for block I/O operations
- **Full concurrency** — threads, mutexes, atomics, semaphores
- **Python-like syntax** — dramatically faster development velocity than raw C
- **Multiple optimization levels** — constant folding, DCE, function inlining

---

## Contributing

SageFS is in active development. Contributions welcome in:

- Core filesystem implementation (`src/`)
- Test coverage (`testing/`)
- Performance benchmarks (`benchmark/`)
- Documentation (`docs/`)

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

## Acknowledgments

- **F2FS** (Samsung) — for pioneering log-structured flash filesystem design
- **BTRFS** (Oracle/community) — for advancing CoW filesystem capabilities
- **SageLang** (Night-Traders-Dev) — for making systems programming accessible

---

*SageFS — Where flash performance meets data integrity.*
