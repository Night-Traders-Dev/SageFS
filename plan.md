# SageFS Development Plan

> **Project:** SageFS — A next-generation filesystem written in SageLang
> **Goal:** Combine the best features of F2FS and BTRFS, matching or surpassing their performance
> **Language:** SageLang (compiled via C backend or native ASM for kernel-space components)

---

## 1. Design Philosophy

SageFS takes the **log-structured, flash-friendly architecture** of F2FS and fuses it with the **advanced data integrity and management features** of BTRFS, while eliminating the weaknesses of both:

| Feature | F2FS Strength | BTRFS Strength | SageFS Approach |
|---------|---------------|----------------|------------------|
| Flash optimization | ✅ Multi-head logging, hot/cold separation | ❌ Write amplification issues on SSDs | Log-structured with adaptive multi-stream allocation |
| Data integrity | ❌ No built-in checksumming | ✅ Full metadata + data checksums | Per-block CRC32C / xxHash with selectable policies |
| Snapshots | ❌ Not supported | ✅ CoW snapshots & subvolumes | CoW B+ tree with reflink-based snapshots |
| Compression | ❌ Limited (LZO inline) | ✅ Transparent (zstd, lzo, zlib) | Tiered compression (zstd for cold, lz4 for hot, none for real-time) |
| RAID | ❌ Not supported | ✅ Integrated RAID (0/1/5/6/10) | Pluggable RAID engine with repair-on-read |
| GC efficiency | ✅ Greedy/cost-benefit GC | ❌ N/A (not log-structured) | Adaptive GC with ML-guided victim selection |
| Fragmentation | ⚠️ Can fragment over time | ⚠️ CoW fragmentation | Zone-aware allocation + defrag daemon |
| Metadata performance | ✅ NAT/SIT inline | ⚠️ B-tree contention at scale | Hybrid: NAT-style address translation + CoW B+ trees |
| Deduplication | ❌ Not supported | ✅ Out-of-band dedup | Inline dedup with bloom filter fast-path |

---

## 2. Architecture Overview

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

## 3. On-Disk Layout

### 3.1 Partition Structure

```
Offset (sectors)    Region                  Size
────────────────    ──────                  ────
0                   Superblock Primary       4 KiB
1                   Superblock Mirror        4 KiB
2 - 3               Checkpoint Pack 1        8 KiB
4 - 5               Checkpoint Pack 2        8 KiB
6 - N               Segment Info Table (SIT) Variable
N+1 - M             Node Address Table (NAT) Variable
M+1 - P             Segment Summary Area     Variable
P+1 - Q             CoW B+ Tree Root Zone    Variable
Q+1 - end           Main Area (Segments)     Remainder
```

### 3.2 Superblock Definition

```sage
struct SageFSSuperblock:
    magic: Int                  # 0x53414745 ("SAGE")
    version_major: Int
    version_minor: Int
    block_size: Int             # 4096 default (4K, 16K, 64K supported)
    segment_size: Int           # Blocks per segment (512 default)
    total_segments: Int
    total_blocks: Int
    free_segments: Int
    root_inode: Int             # Root directory inode number
    checkpoint_ver: Int         # Current checkpoint version
    nat_start_blk: Int          # NAT area start
    sit_start_blk: Int          # SIT area start
    ssa_start_blk: Int          # SSA area start
    main_start_blk: Int         # Main area start
    uuid: String                # 128-bit UUID as hex string
    label: String               # Volume label (max 256 chars)
    flags: Int                  # Feature flags (bitfield)
    checksum_algo: Int          # 0=CRC32C, 1=xxHash, 2=SHA-256
    compress_algo: Int          # 0=none, 1=lz4, 2=zstd, 3=zlib
    encryption_algo: Int        # 0=none, 1=AES-256-XTS
    raid_level: Int             # 0=none, 1=mirror, 5=parity, 10=stripe+mirror
    create_time: Int            # Filesystem creation timestamp
    mount_count: Int
    max_mount_count: Int
    state: Int                  # 0=clean, 1=dirty, 2=error
    checksum: Int               # Superblock self-checksum
```

### 3.3 Inode Structure

```sage
struct SageFSInode:
    ino: Int                    # Inode number
    mode: Int                   # File type + permissions (POSIX)
    uid: Int                    # Owner UID
    gid: Int                    # Owner GID
    size: Int                   # File size in bytes
    blocks: Int                 # Allocated blocks
    atime: Int                  # Access time (nanosecond epoch)
    mtime: Int                  # Modification time
    ctime: Int                  # Change time
    crtime: Int                 # Creation time (BTRFS-inspired)
    nlink: Int                  # Hard link count
    flags: Int                  # Inode flags (inline, compressed, encrypted, immutable)
    generation: Int             # Generation number (for NFS/snapshot)
    xattr_nid: Int              # Xattr node ID
    inline_data: String         # Inline data for small files (< 3.4 KiB)
    direct_ptrs: Array[Int]     # Direct block pointers (923 entries)
    indirect_ptr: Int           # Single indirect
    dbl_indirect_ptr: Int       # Double indirect
    checksum: Int               # Inode checksum
```

### 3.4 Data Temperature Classification (from F2FS)

```sage
enum DataTemperature:
    Hot                         # Frequently written (journals, metadata)
    Warm                        # Moderately active (recent user data)
    Cold                        # Rarely modified (archives, media)

enum NodeTemperature:
    HotNode                     # Directory inodes, frequently updated nodes
    WarmNode                    # File inodes
    ColdNode                    # Indirect node blocks
```

Six logging zones (3 data temps × 2 node types), matching F2FS's multi-head logging.

---

## 4. Core Subsystems — Detailed Design

### Phase 1: Foundation (Weeks 1–4)

#### 4.1 Superblock & Checkpoint Manager
- **File:** `src/superblock.sage`
- Read/write/validate superblock from raw block device
- Dual superblock mirroring (primary + backup)
- Checkpoint pack rotation (two alternating packs for crash consistency)
- Atomic checkpoint commit via dual-pack flip

#### 4.2 Block Allocator & Segment Manager
- **File:** `src/segment.sage`, `src/allocator.sage`
- Segment Information Table (SIT): per-segment valid block bitmap + modification count
- Free segment bitmap with O(1) free-segment lookup
- Multi-head log allocator with 6 active logging zones
- Segment type classification: data, node, meta
- Zone-aware allocation for ZNS SSDs (append-only zones)

#### 4.3 Node Address Table (NAT)
- **File:** `src/nat.sage`
- Maps logical node IDs to physical block addresses (from F2FS)
- Enables wandering-tree-free updates — only NAT entries change on node updates
- NAT journal in checkpoint for recently changed entries
- Batch NAT flush to reduce write amplification

#### 4.4 Inode Manager
- **File:** `src/inode.sage`
- Inode allocation/deallocation with generation tracking
- Inline data support (small files stored directly in inode — no block allocation)
- Inline directory support (small directories stored in inode)
- Extended attribute (xattr) support via dedicated xattr nodes

### Phase 2: Tree Structures & Namespace (Weeks 5–8)

#### 4.5 CoW B+ Tree Engine
- **File:** `src/btree.sage`
- Copy-on-Write B+ tree for metadata indexing (inspired by BTRFS)
- Used for: directory entries, extent maps, xattr indexes, snapshot trees
- Node size = filesystem block size (4K default)
- Supports structural sharing for snapshots (reference counting on tree nodes)
- Write coalescing: batch multiple updates into single tree mutation

#### 4.6 Directory & Namespace Manager
- **File:** `src/dir.sage`
- Multi-level hash table directories (from F2FS) for large directories
- Inline directories for ≤ ~200 entries
- Case-insensitive lookup option (via folded hash)
- `.` and `..` hardcoded in directory format
- Atomic rename via journal + tree swap

#### 4.7 Extent Map
- **File:** `src/extent.sage`
- Extent-based allocation (contiguous block runs)
- Extent tree per inode (B+ tree of `[file_offset, disk_offset, length]`)
- Hole-punch and fallocate support
- Preallocation hints for sequential workloads

### Phase 3: Data Integrity & Recovery (Weeks 9–12)

#### 4.8 Checksum Engine
- **File:** `src/checksum.sage`
- Per-block checksums stored in dedicated checksum tree (BTRFS-style)
- Algorithms: CRC32C (default, hardware-accelerated), xxHash (fast), SHA-256 (paranoid)
- Metadata always checksummed; data checksumming is configurable
- Checksum verification on read; error reported or auto-repaired (with RAID)

#### 4.9 Journal & Transaction Manager
- **File:** `src/journal.sage`, `src/transaction.sage`
- Hybrid journaling:
  - Metadata: write-ahead log (WAL) for crash recovery
  - Data: log-structured (F2FS style) — no data journal needed
- Transaction grouping: batch multiple ops into atomic transactions
- Nested transaction support for complex operations (rename + unlink)
- Recovery: replay journal from last valid checkpoint on mount

#### 4.10 Fsck & Online Repair
- **File:** `src/fsck.sage`
- Offline fsck: full tree walk, cross-reference NAT ↔ SIT ↔ data
- Online scrub: background verification of checksums
- Auto-repair with RAID redundancy (repair-on-read)
- Orphan inode cleanup on mount

### Phase 4: Advanced Features (Weeks 13–18)

#### 4.11 Snapshot & Subvolume Engine
- **File:** `src/snapshot.sage`
- CoW snapshots via B+ tree root cloning (BTRFS-style)
- Subvolumes: independent filesystem trees within the same partition
- Writable snapshots (branching)
- Snapshot diff: efficient delta calculation between snapshots
- Automatic snapshot rotation policy (keep N hourly/daily/weekly)

#### 4.12 Transparent Compression Engine
- **File:** `src/compress.sage`
- Cluster-based compression (compress N blocks into M blocks, M ≤ N)
- Algorithm selection per-file or per-directory:
  - `lz4` — hot data, real-time workloads (fastest)
  - `zstd` — cold data, archival (best ratio)
  - `zlib` — compatibility fallback
- Compression ratio tracking per segment for GC decisions
- Incompressible data detection: skip after failed attempt

#### 4.13 Deduplication Engine
- **File:** `src/dedup.sage`
- Inline dedup with bloom filter pre-check
- Block-level fingerprinting (SHA-256 or xxHash)
- Reflink-based dedup: shared extents with refcount
- Background dedup daemon for post-write dedup
- Dedup domain isolation (per-subvolume or global)

#### 4.14 Encryption Layer
- **File:** `src/encrypt.sage`
- Per-file encryption (fscrypt-compatible key management)
- AES-256-XTS for data blocks
- AES-256-CTS for filenames
- Key derivation from user passphrase via Argon2 / PBKDF2
- Hardware AES-NI acceleration

#### 4.15 RAID Engine
- **File:** `src/raid.sage`
- Integrated multi-device support:
  - RAID 0 (stripe) — performance
  - RAID 1 (mirror) — redundancy
  - RAID 5 (single parity) — balanced
  - RAID 6 (double parity) — high redundancy
  - RAID 10 (stripe + mirror) — performance + redundancy
- Repair-on-read: auto-fix corrupt blocks from parity/mirror
- Online device add/remove/replace
- Scrub: periodic parity/mirror verification

### Phase 5: Performance Optimization (Weeks 19–22)

#### 4.16 Garbage Collector
- **File:** `src/gc.sage`
- Foreground GC: triggered when free segments < threshold (synchronous)
- Background GC: runs during idle periods
- Victim selection policies:
  - Greedy: pick segment with fewest valid blocks
  - Cost-benefit: weigh age × invalid ratio
  - Adaptive/ML-guided: learn workload patterns (stretch goal)
- Section-level GC for large erase units
- GC throttling to prevent I/O starvation

#### 4.17 Async I/O Engine
- **File:** `src/aio.sage`
- io_uring integration for Linux (zero-copy, kernel-side polling)
- Read-ahead: predictive prefetch for sequential access
- Write-back: delayed allocation + batched writeback
- I/O priority queues (real-time, best-effort, idle)
- Per-CPU I/O submission queues (lock-free)

#### 4.18 Caching Layer
- **File:** `src/cache.sage`
- Node page cache: LRU/LFU hybrid for metadata nodes
- Extent cache: recently resolved extent mappings
- NAT cache: hot NAT entries pinned in memory
- Compressed page cache: keep compressed pages to reduce I/O
- Adaptive cache sizing based on memory pressure

### Phase 6: Tooling & Integration (Weeks 23–26)

#### 4.19 mkfs.sagefs — Formatter
- **File:** `src/mkfs.sage`
- Create fresh SageFS filesystem on a block device or image file
- Options: block size, segment size, label, UUID, features, compression, checksum

#### 4.20 mount.sagefs — Mount Helper
- **File:** `src/mount.sage`
- Parse mount options, initialize in-memory structures
- Journal replay if dirty unmount detected
- Orphan inode cleanup

#### 4.21 fsck.sagefs — Filesystem Checker
- **File:** `src/fsck.sage` (extended)
- Full consistency check: superblock → checkpoint → NAT → SIT → trees → data
- Interactive repair mode
- Report: corruption summary, auto-fix log

#### 4.22 sagefs-tools — Utility Suite
- **File:** `src/tools/`
- `sagefs-snapshot` — create/list/delete/diff snapshots
- `sagefs-dedup` — run dedup scan
- `sagefs-scrub` — verify checksums
- `sagefs-defrag` — online defragmentation
- `sagefs-balance` — rebalance data across devices
- `sagefs-stats` — filesystem statistics & health dashboard

---

## 5. Performance Targets

| Benchmark | F2FS | BTRFS | SageFS Target |
|-----------|------|-------|---------------|
| Sequential write (4K) | ~1.8 GB/s | ~1.2 GB/s | ≥ 2.0 GB/s |
| Sequential read (4K) | ~2.5 GB/s | ~2.3 GB/s | ≥ 2.5 GB/s |
| Random write (4K, QD32) | ~350K IOPS | ~180K IOPS | ≥ 400K IOPS |
| Random read (4K, QD32) | ~600K IOPS | ~500K IOPS | ≥ 650K IOPS |
| Metadata ops (create/s) | ~250K | ~120K | ≥ 300K |
| Mount time (1TB vol) | < 1s | 2–5s | < 0.5s |
| Fsync latency (p99) | ~200µs | ~500µs | < 150µs |
| Write amplification | 1.1–1.5x | 1.5–3.0x | < 1.2x |
| Compression (zstd, silesia) | N/A | 2.8:1 | ≥ 3.0:1 |

### Performance Strategy

1. **Log-structured writes** — all writes are sequential (like F2FS), minimizing seek and write amplification on SSDs
2. **NAT indirection** — eliminates the wandering tree problem (BTRFS weakness), reducing cascading CoW updates
3. **Multi-head logging** — 6 concurrent log heads sorted by data temperature reduces GC overhead
4. **Lock-free I/O submission** — per-CPU io_uring queues eliminate contention on multi-core
5. **Adaptive compression** — lz4 for hot data maintains throughput; zstd for cold data maximizes capacity
6. **Extent-based allocation** — large contiguous extents minimize metadata overhead and maximize sequential throughput
7. **Inline data/dir** — small files and directories avoid block allocation entirely

---

## 6. File & Directory Structure

```
SageFS/
├── SageLang_Reference.md          # Language reference
├── README.md                      # Project readme
├── plan.md                        # This plan
├── src/
│   ├── superblock.sage            # Superblock & checkpoint
│   ├── inode.sage                 # Inode management
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
│   ├── raid.sage                  # RAID engine
│   ├── cache.sage                 # Caching subsystem
│   ├── aio.sage                   # Async I/O engine
│   ├── vfs.sage                   # VFS interface layer
│   ├── mkfs.sage                  # Filesystem formatter
│   ├── mount.sage                 # Mount helper
│   ├── fsck.sage                  # Filesystem checker
│   └── tools/
│       ├── snapshot_cli.sage      # Snapshot management tool
│       ├── dedup_cli.sage         # Dedup scanner
│       ├── scrub_cli.sage         # Scrub tool
│       ├── defrag_cli.sage        # Defragmenter
│       ├── balance_cli.sage       # Device balancer
│       └── stats_cli.sage         # Statistics dashboard
├── docs/
│   ├── on_disk_format.md          # On-disk format specification
│   ├── architecture.md            # Architecture deep-dive
│   ├── performance.md             # Performance analysis & tuning
│   └── api_reference.md           # API reference for tools
├── testing/
│   ├── test_superblock.sage       # Superblock tests
│   ├── test_btree.sage            # B+ tree tests
│   ├── test_allocator.sage        # Allocator tests
│   ├── test_checksum.sage         # Checksum tests
│   ├── test_snapshot.sage         # Snapshot tests
│   ├── test_compress.sage         # Compression tests
│   ├── test_gc.sage               # GC tests
│   ├── test_journal.sage          # Journal/recovery tests
│   ├── test_integration.sage      # End-to-end tests
│   └── fuzz/
│       ├── fuzz_btree.sage        # B+ tree fuzzer
│       └── fuzz_journal.sage      # Journal fuzzer
├── benchmark/
│   ├── bench_seq_write.sage       # Sequential write benchmark
│   ├── bench_rand_write.sage      # Random write benchmark
│   ├── bench_seq_read.sage        # Sequential read benchmark
│   ├── bench_rand_read.sage       # Random read benchmark
│   ├── bench_metadata.sage        # Metadata operation benchmark
│   ├── bench_compress.sage        # Compression benchmark
│   └── bench_gc.sage              # GC overhead benchmark
└── build/
    ├── build.sage                 # Build system configuration
    └── config.sage                # Compile-time feature flags
```

---

## 7. Development Phases & Milestones

### Phase 1: Foundation (Weeks 1–4) — MVP on disk image
- [ ] Superblock read/write/validate
- [ ] Checkpoint pack management
- [ ] Segment manager + SIT
- [ ] NAT implementation
- [ ] Block allocator (single-stream first)
- [ ] Basic inode create/read/write/delete
- **Milestone:** Can format an image and write/read inodes

### Phase 2: Tree & Namespace (Weeks 5–8)
- [ ] CoW B+ tree (insert, delete, search, split, merge)
- [ ] Directory operations (create, lookup, list, remove, rename)
- [ ] Extent map implementation
- [ ] Inline data & inline directory
- [ ] Multi-head logging (6 zones)
- **Milestone:** Can create directories, write files, and read them back

### Phase 3: Integrity & Recovery (Weeks 9–12)
- [x] Checksum engine (CRC32C + xxHash)
- [x] Journal (WAL) implementation
- [x] Transaction manager
- [x] Crash recovery (journal replay)
- [x] Basic fsck
- [x] Orphan inode recovery
- **Milestone:** Survives power-loss simulation without data loss

### Phase 4: Advanced Features (Weeks 13–18)
- [x] Snapshot engine (create, delete, diff)
- [x] Subvolume support
- [x] Transparent compression (lz4, zstd)
- [x] Deduplication engine
- [x] Encryption layer
- [x] Extended attributes (xattr)
- **Milestone:** Full feature parity with BTRFS core features

### Phase 5: Performance (Weeks 19–22)
- [x] Garbage collector (greedy + cost-benefit)
- [x] Async I/O engine (io_uring)
- [ ] Caching layer (NAT cache, extent cache, node cache)
- [ ] Multi-stream allocation optimization
- [ ] Lock-free data structures for hot paths
- [ ] Read-ahead & write coalescing
- **Milestone:** Meets or exceeds performance targets on NVMe

### Phase 6: Tooling & Polish (Weeks 23–26)
- [x] mkfs.sagefs (full-featured formatter)
- [x] mount.sagefs (mount helper)
- [x] fsck.sagefs (comprehensive checker)
- [x] CLI tool suite (snapshot, scrub, defrag, balance, stats)
- [x] RAID engine (mirror, stripe, parity)
- [x] Documentation (on-disk format spec, API reference)
- [x] Benchmark suite - [ ] Benchmark suite & regression tests regression tests
- **Milestone:** Production-ready filesystem with full toolchain

---

## 8. Key Technical Decisions

### 8.1 Why SageLang?

- **C backend** — SageLang compiles to C11, giving us native performance with no runtime overhead
- **Native ASM backend** — direct x86-64/aarch64 assembly for performance-critical paths
- **Low-level access** — `mem_alloc`, `mem_read`, `mem_write`, `unsafe` blocks, FFI, inline assembly
- **Struct interop** — `struct_def`, `struct_new`, `struct_get`, `struct_set` for C-compatible layouts
- **Bytes type** — first-class binary buffer support for block I/O
- **Concurrency** — threads, mutexes, atomics, semaphores for multi-core I/O
- **Python-like readability** — faster development than raw C with equivalent performance

### 8.2 Compilation Strategy

```sage
# Development: use AST interpreter for rapid iteration
sage src/mkfs.sage -- /dev/sda1

# Testing: bytecode VM for faster execution
sage --runtime bytecode testing/test_btree.sage

# Production: compile to native binary
sage --compile src/mkfs.sage -o build/mkfs.sagefs -O3

# Kernel module: emit C, integrate with kernel build system
sage --emit-c src/vfs.sage -o build/sagefs_vfs.c
```

### 8.3 Crash Consistency Model

1. **Metadata:** Protected by WAL journal + checkpoint packs
2. **Data:** Log-structured writes + NAT indirection (no overwrite = no partial write)
3. **Atomicity:** Transaction groups commit together or not at all
4. **Recovery order:** Superblock → Checkpoint → Journal replay → NAT rebuild → SIT verify

### 8.4 F2FS Features We Adopt

- Multi-head logging with hot/warm/cold separation
- Node Address Table (NAT) for wandering-tree elimination
- Segment Information Table (SIT) for valid block tracking
- Inline data and inline directories
- Adaptive logging (normal log vs threaded log modes)
- fsync optimization via node chain tracking

### 8.5 BTRFS Features We Adopt

- Copy-on-Write B+ trees for metadata
- Snapshots and subvolumes via tree root cloning
- Transparent compression with per-file algorithm selection
- Data and metadata checksumming
- Integrated RAID with repair-on-read
- Reflinks and deduplication
- Online scrub and balance
- Extended attributes and access control lists

### 8.6 Novel SageFS Innovations

- **Hybrid NAT + CoW tree:** NAT eliminates wandering-tree updates for data nodes, CoW B+ tree provides snapshot capability — best of both worlds
- **Adaptive GC with workload learning:** GC victim selection learns from write patterns to predict future invalidation
- **Tiered compression selection:** automatic per-cluster algorithm choice based on data temperature and compressibility
- **Unified checkpoint + snapshot:** checkpoints and snapshots share the same CoW tree infrastructure, reducing code complexity
- **Zone-aware multi-stream:** automatic alignment with ZNS SSD zone boundaries for next-gen storage

---

## 9. Risk Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| SageLang compiler bugs in low-level ops | Data corruption | Extensive fuzz testing, C backend inspection, fallback to raw C for critical paths |
| Performance gap vs C implementations | Miss targets | Profile-guided optimization, hot-path assembly, C FFI for bottlenecks |
| Crash consistency bugs | Data loss | Formal checkpoint model, power-fail injection testing, fsck verification loops |
| CoW fragmentation | Performance degradation | Background defrag daemon, extent merge heuristics, preallocation |
| GC stalls | Latency spikes | Concurrent GC with I/O priority, emergency GC with reduced threshold |
| Complexity creep | Schedule slip | Phase-gated delivery, MVP-first approach, defer RAID/encryption to Phase 4 |

---

## 10. Testing Strategy

### Unit Tests
- Every subsystem has dedicated test file in `testing/`
- Property-based testing for B+ tree invariants
- Edge cases: empty fs, full fs, single-block files, max-depth directories

### Fuzz Testing
- B+ tree operations: random insert/delete/search sequences
- Journal: random crash points during write sequences
- Checksum: bit-flip injection and detection verification

### Integration Tests
- Format → mount → create/write/read → unmount → remount → verify
- Snapshot create → modify original → verify snapshot unchanged
- Compression: write → read → verify data integrity
- Power-fail simulation: kill during write → recovery → verify consistency

### Performance Regression
- Automated benchmark suite run on every commit
- Comparison against F2FS and BTRFS on identical hardware
- Metrics tracked: IOPS, throughput, latency (p50/p99/p999), write amplification

---

> **Next Steps:** Begin Phase 1 implementation with `src/superblock.sage` and `src/segment.sage`.
