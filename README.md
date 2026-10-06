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

## Project status

Read this before the feature list, because a lot of the design is further along
than the I/O path.

SageFS currently has two very different halves. The **metadata and data layer**
— superblock, inodes, inline data, the reserved inode-entry area, the B+ tree,
the segment manager, the journal, and a POSIX VFS over them — works, and is
exercised end to end: `test_integration.sage` formats an image, mounts it,
writes, unmounts, remounts and reads the data back. The **optional feature
modules** are largely written but not wired into that path.

Status markers used below:

| | meaning |
| --- | --- |
| ✅ | implemented and reached from the read/write path |
| ⚠️ | implemented, but not currently called by any I/O path |
| ❌ | stubbed, simulated, or not implemented |

**Tests: 42/42 files, 1336 assertions, all passing** under the bytecode VM
(`./sagemake test`). A test file that asserts nothing is reported as a failure
rather than passing silently. The C backend compiles all 33 modules, but the assertion
suite is run on the bytecode VM only, so a native regression would not be caught
by it. See [Known issues](#known-issues) for what is still broken.

The bytecode VM is more forgiving about indentation than the C backend, so a
module that the interpreter accepts can still fail to compile natively. Run both:
the module loop in `Known issues` lists the command.

## Key Features

### 🚀 Performance
- ✅ **Multi-head logging** — 6 log zones with hot/warm/cold classification (`segment.sage`)
- ✅ **NAT indirection** — nid allocation with a journal-buffered write-back (`nat.sage`)
- ✅ **Extent-based allocation** — contiguous runs with neighbour merging (`extent.sage`)
- ✅ **Inline data & directories** — small files stored in the inode, no block allocated
- ⚠️ **Async I/O** — `aio.sage` is a 3-deep priority queue with an instant-drain
  `poll()`. No threads, no event loop, no io_uring. The io_uring integration
  described in earlier revisions was never written.
- ❌ **Lock-free hot paths / per-CPU submission queues** — not implemented

### 🛡️ Data Integrity
- ✅ **CRC32C** — real, table-driven, verified against known-answer vectors
- ✅ **xxHash32** — real implementation
- ✅ **Dual superblock mirroring** — primary at block 0, mirror at block 1
- ⚠️ **Write-ahead journal** — a reserved region, the record format and a correct
  two-pass recover/replay are implemented, but no production path ever stages an
  `REC_UPDATE`, so the log is structurally present and semantically empty.
- ⚠️ **Checkpoint packs** — structures and (de)serialisation exist; `mkfs` never
  writes them and nothing reads them back
  - ✅ **SHA-256** — implemented in `checksum.sage` and verified against the NIST
    vectors (empty, `abc`, 448-bit, one million `a`) on **both** the bytecode VM and
    the compiled C backend, plus the padding boundaries at 55/56/64 bytes.

    Two things had to be right that were not obvious. Sage numbers are IEEE doubles
    with a 53-bit significand, so `rotr32` masks *before* shifting: the obvious
    `(x >> n) | (x << (32 - n))` reaches 2^63 and silently rounds away exactly the
    low bits being rotated into the high half — correct for the empty input, wrong
    for nearly everything else. And a right rotate moves the low **n** bits to the
    top; masking the wrong half compiles and runs, it just returns the wrong digest.

    The previous stub returned the empty-input digest for every input, so every block
    hashed identically and nothing could be deduplicated. That is fixed. The C
    backend segfault that blocked the first attempt was the `ffi.call` and
    expression-temporary use-after-free, now fixed in the compiler.

    An implementation was written and verified against the NIST vectors under the
    bytecode VM, then reverted: the C backend segfaulted executing it. That crash
    was real, and diagnosing it is what found the `ffi.call` use-after-free now
    fixed in the compiler — the emitted argument list freed itself before
    `sage_ffi_call` read it. The SHA-256 code itself was never committed, so there
    is nothing in the tree to re-verify and no partial work to salvage. The next
    step is simply to write it again; it should now survive compilation.
- ✅ **Online scrub** — `scrub.sage` verifies a volume block by block and reports
  **OK / DAMAGE / INCONCLUSIVE / ERROR**. It replaces a tool that built a fresh
  `ChecksumTree`, found nothing recorded in it, compared nothing, and then printed
  "filesystem is clean" — a checker that cannot fail, trusted, and always wrong in
  the direction that hides damage. Two modes:
  - **Against a reference image** — every block compared byte for byte.
  - **Against the volume's own checksum region** (`csum.sage`) — one LE32 per block,
    written by `VFS._write_block()` as data lands, so a mounted volume can be
    scrubbed with nothing external to compare it to.

  Truncation is caught by comparing file length against the superblock's `image_size`
  before any block comparison, so a short volume cannot match across its missing
  tail. Coverage is reported against blocks actually verified, and a volume whose
  region is still empty returns **INCONCLUSIVE**, not OK — calling that a pass would
  be the original bug verbatim. The region is carved off the *end* of the allocatable
  range, so adding it shifted no existing absolute block number, and `total_blocks`
  excludes it so no allocator can ever hand it out.

  `VFS._read_block()` also verifies each block against its entry on the way out,
  so corruption is caught by the read that hits it rather than only by a scrub you
  have to remember to run. It is **off by default** (`VFS.verify_on_read`) because
  it hashes every block read; untracked blocks and volumes with no region are
  skipped, and region blocks are never verified against their own entries. A
  mismatch is reported once per bad block and counted via
  `VFS.csum_error_count()`.
  built empty tree, so it can never detect a mismatch
- ✅ **Repair-on-read** — `Raid5Array` in `raid.sage` is a byte-level RAID5 over real
  devices or image files. A lost block is rebuilt by XOR-ing the survivors with the
  parity block and written back to the failed device during the read, so the damage is
  fixed while the surviving copy is still known to exist rather than on the next boot.
  Reconstructing without writing back would leave the array one device failure from
  total loss. Two failures in one stripe cannot be rebuilt from one parity block and
  are **refused** rather than answered with zeros. Parity is per byte — the existing
  `compute_parity()` folds block *numbers*, which simulates the mapping but cannot
  rebuild anything.

### 📸 Snapshots & Subvolumes
- ✅ **CoW B+ tree** — real copy-on-write with generation counters, sibling
  borrow and merge (`btree.sage`)
- ⚠️ **Snapshots** — a snapshot records a root block and a generation, and the
  CoW machinery it depends on is real, but there is no read path: a snapshot
  cannot be mounted or read from. The tree is also re-rooted to block 0 on every
  mount, so snapshot roots do not survive a remount.
- ❌ **Writable snapshots, snapshot diff, rotation policy** — not implemented.
  `diff_snapshots()` returns the two root blocks; it does not diff.

### 📦 Storage Efficiency
- ✅ **Extent tree** — one B+ tree keyed by `(inode, type, offset)`
- ⚠️ **Transparent compression** — `compress.sage` picks an algorithm by
  temperature and tracks ratios, then writes a 3-byte header followed by the
  original bytes. No compression is performed.
  - ✅ **Deduplication** — wired into the block write path. A whole block whose content is
    already stored shares that block instead of being written twice, and the sharing is
    expressed in the extent: both files' extents name the same physical block and the
    engine's reference count says how many files hold it. Any write into a shared block
    takes a private copy first — copy-on-write, on partial writes as well as whole ones,
    since a 16-byte edit into a shared block corrupts every other holder exactly as a
    full-block write would. `test_dedup_share` asserts this in both backends, because the
    failure mode is silent: the edited file reads back correctly while the others are
    quietly wrong.

    The engine (Bloom pre-check, exact fingerprint table, refcounts, shared-fingerprint
    handling) is complete and **SHA-256 is available as the block fingerprint**, verified
    against the published digests. It is *not* the default:
    `DEDUP_FP_FAST` (32-bit polynomial) stays default because SHA-256 costs ~16x more per
    block in this runtime — measured ~95 ms vs ~6 ms for a 4096-byte block, i.e. ~43 KiB/s
    against ~670 KiB/s — so whole-volume dedup on SHA-256 would take hours. Set
    `DedupEngine.fingerprint_algo = DEDUP_FP_SHA256` for content addressing against an
    adversary. Fingerprints are prefixed by algorithm, so a table can hold both without
    confusing a fast hash with a digest.

    Still **⚠️** because the engine is not wired into the read/write path:
    `check_inline()` is never called during I/O, so nothing is deduplicated yet.
- ✅ **Bloom filter** — `bloom_filter` is a fixed `DEDUP_BLOOM_SIZE`-bit array with 7 probes. A real filter, not an exact-set `Dict`, so its memory no longer grows with the image. It is safe here only because a hit is always confirmed against the exact fingerprint table before anything is deduped, so a false positive costs one lookup. Bits are never cleared on removal: clearing one would make a still-shared fingerprint look absent to every other block sharing it, which would be a false negative and therefore corruption.
- ❌ **Reflink copies** — not implemented

### 🔐 Security
- ❌ **AES-256-XTS / AES-256-CTS** — not implemented. `encrypt.sage` is a
  repeating-key XOR stream cipher, and `VFS.mount()` constructs it with an
  **empty** master key. It is not AES, has no KDF, and is not in the I/O path.
  Do not use it to protect anything.

### 🔗 Multi-Device
- ⚠️ **RAID address mapping** — `raid.sage` computes striping geometry and parity
  for levels 0/1/5/6/10, but has no `read`, `write`, `add_device`, `scrub` or
  `rebuild`. It is arithmetic with no I/O behind it.
- ❌ **Online device management, scrub & balance** — not implemented.
  `balance_cli.sage` prints "Balance completed successfully" without doing
  anything.

---

## Architecture

![SageFS Architecture](assets/architecture.png)

SageFS integrates Python-like readable and C-like performant SageLang to deliver:

- **Log-structured flash optimization** (F2FS):
  - Multi-head logging, hot/warm/cold data classification
  - Node Address Table (NAT) for wandering-tree elimination

- **Copy-on-write metadata** (BTRFS):
  - CoW B+ trees, instant snapshots, snapshot diffing
  - Integration of metadata tree with data management

- **Enterprise data integrity**:
  - CRC32C and xxHash per-block checksumming (SHA-256 verified)
  - Dual superblock mirroring; checkpoint packs defined but not yet written
  - Write-ahead journal with a correct recover/replay, but no region reserved

- **Storage efficiency**:
  - Inline data & directories (<=3.4 KiB) — live in the I/O path
  - Transparent compression, deduplication, RAID — defined, not yet wired in

- **Performance**:
  - The targets listed above are aspirational; no benchmark harness has been run
    against this implementation
  - No lock-free hot paths, no io_uring

- **Development**: 42 test files, 1336 assertions, 9 CLI tools

The binary image format uses little-endian encoding with 4 KiB blocks and 512
blocks per segment. The B+ tree is the exception: its node magic and its keys
are big-endian, and `Extent.serialize()` is big-endian too, so the
"all little-endian" claim in `superblock.sage` and in earlier revisions of this
file holds only for the superblock, journal, NAT, SIT and inode-entry
structures.

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
# Compile the filesystem tools (SageVM backend — recommended)
./sagemake build

# Optionally, compile against SageVM stack and register modes
./sagemake build --build-vm-stack --build-vm-riscv
```

> **Note:** The native C backend does not support `bytes_*` builtins. `./sagemake build

#### Toolchain

`sagemake` invokes the compiler as `sage-c`, so `sage-c` must be on `PATH`. It is
the original name for the SageLang binary and a normal SageLang `make install`
provides it as a link to `sage`, so installing SageLang is enough:

```bash
cd ../SageLang/core && make && sudo make install
```

Check that both names resolve to the same build before trusting a test result:

```bash
sage --version && sage-c --version   # must agree
```

A `sage-c` left over from an older SageLang release keeps working and reports no
error, so a mismatch here does not announce itself. It did exactly that here: a
month-old `sage-c` lacked `mem_copy_to_ptr`, and four test files failed on
"Undefined variable" while the freshly built `sage` passed all four.

` automatically falls back to the SageVM bytecode backend, which fully supports all `Bytes` operations.

### Format a Disk Image

```bash
# Create a 1GB image
dd if=/dev/zero of=sagefs.img bs=1M count=1024

# Format with SageFS
./build/mkfs.sagefs sagefs.img --label "MyVolume" --compress zstd --checksum crc32c
```

### Mount & Access (FUSE)

```bash
mkdir -p /mnt/sagefs
sage --runtime bytecode -I src src/mount.sage sagefs.img /mnt/sagefs
ls /mnt/sagefs/
fusermount3 -u /mnt/sagefs
```

**FUSE mounting does not currently work.** Two things block it, and an earlier
revision of this file claimed otherwise:

- `fuse_init()` calls `fuse_session_new()` with one argument (the real function
  takes four or five) and never calls `fuse_session_mount()`, so the kernel
  never routes requests to the file descriptor. `fuse_run()` then ignores the
  session and reads `/dev/fuse` directly, which has nothing on it.
- `ffi` is an undefined variable in the current runtime, so `fuse_init_libc()`
  fails, is swallowed by its own `try`/`catch`, and `fuse_run()` returns
  immediately. Mounting prints "FFI unavailable, using Python FUSE bridge" and
  exits.

There is no Python FUSE bridge either. `./build/sagefs-fuse` is referenced from
this file and from `docs/fuse.md`, `docs/mount.md` and `docs/vfs.md`, but it has
never existed.

The FUSE *protocol* layer is fine and tested — `test_fuse.sage` covers the ABI
codec, the response builders, all the `on_op_*` handlers and the opcode dispatch.
What is missing is a working session setup.

`src/kernel/sagefs.ko` is a separate route (`mount -t sagefs`); see
`docs/kernel_driver.md` for its state.

### Run Tests

```bash
# Full test suite — 42 files, 1336 assertions
./sagemake test

# A single file
sage --runtime bytecode -I src testing/test_btree.sage

# Verify an image
./build/mkfs.sagefs --check sagefs.img
```

Note that `exit` is not a global builtin — it lives on the `sys` module, so
scripts must call `sys.exit(0)`. Under the bytecode runtime an undefined
variable is fatal (the process exits 70), which is a quieter way to fail than it
looks.

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
│   ├── imgio.sage                 # Binary image persistence
│   ├── journal.sage               # Write-ahead log
│   ├── transaction.sage           # Transaction manager
│   ├── xattr.sage                 # Extended attributes
│   ├── gc.sage                    # Garbage collector
│   ├── snapshot.sage              # Snapshot & subvolume engine
│   ├── compress.sage              # Transparent compression
│   ├── dedup.sage                 # Deduplication engine
│   ├── encrypt.sage               # Encryption layer
│   ├── raid.sage                  # Integrated RAID engine
│   ├── cache.sage                 # Caching subsystem
│   ├── aio.sage                   # Async I/O (io_uring)
│   ├── vfs.sage                   # VFS interface
│   ├── fuse.sage                  # FUSE protocol interface
│   ├── mkfs.sage                  # Filesystem formatter
│   ├── mount.sage                 # Mount helper
│   ├── fsck.sage                  # Filesystem checker
│   ├── kernel/
│   │   ├── sagefs.c              # Linux VFS kernel driver (Phase 9)
│   │   ├── Makefile              # Kernel module build
│   │   └── README.md             # Build & usage
│   └── tools/                     # CLI utilities
├── docs/                          # Documentation
├── testing/                       # Test suite
├── benchmark/                     # Performance benchmarks
├── build/                         # Build configuration & artifacts
│   ├── sagefs_full.sgvm          # Full SageFS bytecode bundle
│   └── mkfs.sagefs               # Formatter shell script
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

**Current progress:** Phases 1–6 complete. 16 test files (343 tests) all passing. SageFS **FFI integration complete** (Phase 1) — SageVM can now call libfuse3 via FFI, enabling native kernel driver integration. Kernel VFS driver mounts successfully (nodev) but OOM's on readdir/unmount due to `i_lru` initialization issue in kernel 7.1.

### Phase 7+: Kernel Driver Integration
- **Phase 7:** SageVM FFI backend (sage_ffi_call with type marshaling for C functions) — ✅ Done
- **Phase 8:** SageFS FUSE FFI integration (fuse_init, fuse_run with /dev/fuse direct I/O, libfuse3 session support) — ✅ Done
- **Phase 9:** Linux kernel VFS driver (`sagefs.ko`) implementing `mount -t sagefs` directly through the kernel block layer — ⏳ In progress (mount/stat works; OOM on readdir/umount; see `docs/kernel_driver.md`)
- **SageVM v1.0.0:** Updated to latest SageVM (GA) and SageLang — full test conformance, JIT engine, dual-architecture (SVM stack + SRVM RISC-V) support, security sandboxing.
- **VFS write persistence:** Fixed `write()` to persist data to in-memory inode entries, enabling create/write/read cycles.
- **FFI Integration (Phase 1):** SageVM now supports native FFI calling (sage_ffi_call with type marshaling). SageFS FUSE module has FFI session initialization with libfuse3 and Python bridge fallback. fuse_run implements native /dev/fuse event loop via libc FFI (ABI 7.26). mount.sage supports mountpoint argument.

---

## Documentation

Each component is documented under [`docs/`](docs/):

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
| Image I/O | [docs/imgio.md](docs/imgio.md) | Binary image persistence |
| VFS Interface | [docs/vfs.md](docs/vfs.md) | POSIX file/directory operations |
| Mount Helper | [docs/mount.md](docs/mount.md) | Mount workflow and FUSE integration |
| FUSE Bindings | [docs/fuse.md](docs/fuse.md) | FUSE protocol interface and handlers |

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

## Known issues

Ordered by severity. The first two can destroy data.

**1. ~~The journal overlaps the superblock and can brick a volume.~~ Fixed.**
`VFS.mount()` used to construct `Journal(self, 0, 16, bs)` — blocks 0-15, being
the superblock, its mirror, both checkpoint packs and the whole inode-entry
area — because the layout never reserved a region for the journal. Since
`Journal.sync()` rewrites its buffer from `start_blk`, any write too large to
inline stamped the journal's magic over the superblock. It went unnoticed
because `unmount()` re-serialises the superblock afterwards; a crash in between
left an unreadable volume.

Format v1.3 reserves `JOURNAL_RESERVED_BLKS` (32) blocks after the metadata
area, records `journal_start_blk` / `journal_block_count` in the superblock, and
mounts the journal there. Volumes written before v1.3 have no region and get a
*disabled* journal rather than a dangerous one. Covered by
`testing/test_journal_region.sage` (14 assertions), which asserts the superblock
magic survives a non-inline write.

**2. ~~`fsgc.do_gc` discards live data.~~ Made safe; relocation still missing.**
It used to walk a victim segment's validity bitmap, increment `blocks_moved` for
each valid block, and then free the segment without relocating anything — so
every live block in it was deleted while being reported as "moved". `do_gc` now
counts the live blocks and refuses, leaving the segment untouched. Relocating
them needs a block -> owner index that does not exist, so this is a guard rather
than a fix; `needs_gc()` can still report true while nothing is reclaimable.

**3. ~~The extent map does not survive a remount.~~ Fixed, and two more bugs
came with it.** Three separate defects, each masking the next:

- The tree was rebuilt as `BTreeEngine(self, 0, 1)` — root block 0, which the
  tree reads as "empty" — so every remount started with no extent map. Format
  v1.4 records `extent_root_blk` and `extent_generation` in the superblock.
- `_ensure_stub_inode()` restored an inode's size only when the inline payload
  was non-empty, so a block-mapped file reported size 0 after a remount even
  though the right size was in the inode-entry area.
- **`VFS.write()` silently truncated.** It allocated one block per call and
  passed the whole buffer to `_write_block()`, which copies at most one block. A
  write larger than 4096 bytes kept only its first 4 KiB, still reported the
  full byte count as written, and set the inode size to the full length. No error
  anywhere. Writes now spread across as many blocks as they need.

**3b. Inode numbers were reused across remounts.** `next_ino` starts at 2 and is
advanced only by `create_inode()`. Inodes restored from disk were inserted into
the table without advancing it, so the first file created after a remount was
given a number a restored file already owned — two files sharing one inode, each
overwriting the other's data, silently. `InodeManager.note_inode()` now keeps
the allocator ahead of anything in the table, and `create_root()` uses it too.

**4. Only one directory can persist.** `_save_dir()` writes a directory listing
into the inode-entry slot at `area_start` regardless of which inode is the
parent, so nested directories share the first slot. Root survives only because
`_get_dir(ROOT_INO)` short-circuits to the in-memory `DirManager`.

**5. ~~The superblock checksum is never recomputed.~~ Fixed.** `mkfs` and
`unmount()` both mutate fields (`image_size`, and now `extent_root_blk` /
`extent_generation`) and then serialise without recomputing, so the stored
checksum described the superblock as it was *before* those changes. A cleanly
unmounted volume failed `verify_checksum()`. That was not cosmetic: fsck's first
check is `ISSUE_SB_CHECKSUM` at `SEV_FATAL`, so every healthy volume was reported
corrupt. Both serializers now recompute the checksum they write —
`compute_checksum()` excludes the field itself, so doing it on every serialise is
safe, and it means a future caller cannot reintroduce the staleness.

**6. `fsck` cannot be run.** `src/fsck.sage` is a library with no `main()`.
Its orphan and link-count checks are also vacuous, because
`read_dir_entries()` is a stub that always returns `[]`.

**7. ~~`ROOT_INO` disagrees across the codebase.~~ Fixed.** Three different
numbers: `inode.sage` used 1, `superblock.sage` recorded 3, and the C driver
compiled in `SAGEFS_ROOT_INO 3`. Nothing in the VFS honoured the superblock
field — `create_root()` used `inode.ROOT_INO`, and a remount resolved `/` to 1.

That made `fsck` dangerous rather than merely wrong. It walks inode reachability
from `sb.root_inode`, so it began at inode 3, found the real root unreachable,
and reported the root and everything beneath it as orphans — which `--repair`
deletes. Both sides now say 1, and `testing/test_root_inode.sage` asserts the
superblock's value equals what `resolve("/")` returns, before and after a
remount, so the two cannot drift apart again.

The driver was a minimal stub that never reads the on-disk superblock, so it
still uses the constant; the constant now matches, and a comment marks where to
switch to the parsed field once real superblock parsing lands.

**8. ~~`_write_extents` is undefined.~~ Fixed.** `truncate()` and `punch_hole()`
in `extent.sage` both computed a replacement extent list and handed it to a
`_write_extents()` that existed nowhere, so both raised at runtime. Since
`punch_hole()` is how a filesystem releases blocks, it freed nothing, and
`truncate()` could not shrink a file — the map kept describing the old size.
Implemented, with existing keys collected before deletion so the B+ tree is not
mutated mid-walk.

Chasing that turned up two more defects underneath it, both in the extent map
and both previously invisible:

- **`VFS.write()` recorded every extent as one byte long.** It called
  `insert_extent(ino, offset, block, 1)`, but `length` is in bytes
  (`end_offset() = file_offset + length`). An 8192-byte file became two extents
  of length 1 instead of one of 8192. `read_inode_data()` masked it by walking
  `block_addr` and the inode size rather than the extents, so reads looked
  correct while the map — the authoritative description of a file's block
  layout — was wrong for every block-mapped file. Now passes `chunk_len`.
- **`punch_hole()` added byte offsets to block addresses.** Trimming or
  splitting computed `e.block_addr + trim` where `trim` was a byte count, so
  punching 1024..3072 in a file starting at block 240 produced a tail extent at
  block 3312 — a block number pointing at unrelated data. Block size is now
  threaded into `ExtentTree` and the deltas are in blocks.

`testing/test_extent_resize.sage` covers all three (28 assertions).

**9. ~~The node cache is never invalidated on write.~~ Fixed — and it was much
worse than "stale reads".** `read_inode_data()` cached an inode's content in
`CacheManager.get_node()`/`put_node()`, which is a *block address* cache, so file
content was filed under an inode number in the same map `invalidate_node()`
treats as block addresses. Nothing ever invalidated it, so a read after a write
returned the pre-write content. Verified before fixing: rewriting a file and
reading it back still returned the original bytes.

Content caching now lives in its own bounded dict, and every path that changes
what `read_inode_data()` would return — `write()`, `truncate()`, `unlink()` —
calls `_invalidate_content()`. Chasing this surfaced four more write-path bugs,
all data loss, all now fixed:

- **A small write to a large file destroyed it.** The inline/block decision was
  `is_inline() or new_size <= INLINE_DATA_MAX`, so a 16-byte edit at offset 0 of
  an 8192-byte block-mapped file took the inline path, rewrote the file as inline
  data, and set `size = len(new_data) == 16`. The other 8178 bytes were gone.
  Storage class now depends on the file's current state, not the write's size.
- **In-place writes allocated new blocks.** The block path allocated a fresh
  block for every chunk of every write, even writes wholly inside existing data,
  orphaning the block that held the rest of the file. It now consults
  `lookup_extent()` and writes into the block already mapped there.
- **A write could shrink a file.** `size` was assigned `f.pos + written`
  unconditionally, so an edit inside existing data truncated the file to the
  edit's length. Size now only grows.
- **Zero-length files were never persisted.** `_persist_all()` skipped inodes
  with no inline data and `size == 0`, so `truncate(path, 0)` — or creating an
  empty file — left nothing in the inode area and the file did not survive a
  remount.

`testing/test_content_cache.sage` covers all of it (31 assertions), including
that a re-created file does not inherit a recycled inode's cached bytes.

**10. ~~fsck could not run, and every check in it was broken.~~ Fixed — and one
of the bugs was destroying the filesystem.** fsck had no `main()` at all, so
nothing had ever executed it. Four separate defects, each of which failed
silently:

- `mount()` swept the inode table on **every mount**, deleting every inode whose
  `nlink <= 0`. Nothing in the write path maintains `nlink`, so this was not a
  recovery step — mounting a filesystem was enough to delete its inodes, and the
  freshly created root was itself a candidate. Removed.
- `FsckReport.add()` called `self.issues.push(issue)`. Lists in this runtime are
  appended with the global `push(list, value)`, so fsck raised "`.push` is not
  callable" on the *first issue it found* — crashing on exactly the input it
  exists to report. A volume with no problems looked clean only because `add()`
  was never reached.
- `Fsck.walk()` passed each `DirEntry` into a parameter typed `Int`. The visited
  set never matched, the cycle guard never fired, and issues came back reported
  against a `DirEntry`. Every real child was judged unreachable, so a healthy
  filesystem had its root and its whole subtree flagged as orphans.
- The link-count check compared `nlink` against the number of directory entries
  *naming* an inode. A directory's `nlink` is 2 plus its subdirectory count, so
  the check was wrong by construction for every directory.

`mount()` was also passing the whole manager graph to the `VFS` constructor by
keyword. That call is broken in this runtime — the constructor's `allocator`
parameter resolves as an undefined variable, `init()` aborts partway,
`fs.journal` is left nil, and the mount ends with a single inode. It bought
nothing: `VFS.mount()` already validates the magic, sizes the read from
`sb.image_size` and builds every manager. `mount()` now validates and delegates,
and lives in `src/fsimage.sage` so fsck and mount can share it.

**`nlink` is not stored on disk.** The on-disk inode entry is a 16-byte header of
`ino`/`mode`/`size`/`name_len`/`data_len` followed by the name and payload;
`write_inode_entry_at()` takes no `nlink` argument, so no link count ever reached
stable storage and a remount reset every one of them. Rather than widen the entry
format for a value that is entirely derivable, mount recomputes it: a file's
count is the number of entries naming it, a directory's is 2 plus its subdirectory
count. `mkdir`/`unlink` maintain the parent's count in between. This is the same
rule fsck checks, so the two agree by construction.

**11. ~~`mkdir(path)` silently created a non-directory.~~ Fixed.** `mkdir` had no
default for `mode`, and this runtime passes `nil` for a missing argument rather
than raising. `mkdir("/dir")` therefore built an inode with `mode = nil`:
`is_dir()` was false, `_get_dir()` returned nil, and the failure surfaced far away
— `mkdir("/dir/nested")` just returned false, and fsck reported a healthy-looking
tree as inconsistent. `mode` now defaults to `0o755` and nil is guarded. Every
existing test passed an explicit mode, which is why this was never hit.

**12. SIT region sizing.** `segment.sage` declares `SIT_ENTRY_SIZE = 72` while
`superblock.sage` sizes the region with `sit_entry_size = 64`, allocating the
SIT 12.5% too small.

**13. The NAT, SIT, SSA and checkpoint packs are never persisted.** They are
in-memory structures that die at unmount, despite `compute_layout()` reserving
regions for them.

**14. ~~A read-only `open()` could truncate a file to zero bytes.~~ Fixed.**
`_persist_all()` skips any inode with no inline data **and** `size == 0`, so an
inode truncated to zero was silently dropped from the superblock — the file's
extents stayed in the tree but a later mount came up without it.

The cause was two bugs compounding. `VFS.open()` honoured `O_TRUNC` regardless
of access mode, so `O_RDONLY | O_TRUNC` destroyed the file. The trigger was a
caller referencing an `O_*` constant off an instance (`fs.O_RDONLY`) instead of
off the module (`vfs.O_RDONLY`): that resolves to nil, and nil satisfied
`(flags & O_TRUNC) != 0` while still looking read-only. `open()` now requires
write access before truncating, matching Linux, which ignores `O_TRUNC` on a
read-only descriptor. The test also uses the module-qualified constants.

Worth recording how this hid for so long: the assertion that was supposed to
catch it resolved `"/small.txt"` — the inline file — and then compared its
contents against `payload`, the block-mapped file's 8192 bytes. It compared two
different files and could never pass, so it was filed as an unexplained
filesystem failure with a plausible-sounding theory about entry framing. Both
halves were wrong. `testing/test_persistence.sage` now checks each file against
its own contents on the third mount, and asserts that a read-only open with
`O_TRUNC` set leaves the data intact.

**15. ~~Reads through a hole returned the wrong data.~~ Fixed.** `punch_hole()`
freed the blocks correctly but `read_inode_data()` appended each extent's bytes
to the end of the result buffer and ignored `ext.file_offset`. That is only
correct while extents are contiguous and sorted, which the first hole breaks:
punching block 0 out of a 12288-byte file left extents at 4096 and 8192, whose
data was concatenated into offsets 0 and 4096, so a read at offset 0 returned
what belongs at 4096 and a read at 8192 — surviving, untouched data — fell off
the end of an 8192-byte buffer and returned nothing. The data was not merely
misplaced, it was unreachable, and the blocks behind it had been freed. Reads
are now laid out by file offset, with uncovered regions reading as zeroes, which
is what a hole means. `testing/test_sparse_and_rename.sage` covers a hole in the
middle, a hole at the start, and both across a remount.

**16. ~~`VFS` exposes no `punch_hole`.~~ Superseded by the entry above.**

**17. `rename()` re-inserted directories as regular files.** Fixed. It hardcoded
`DT_REG` on the moved entry, so renaming a directory made `is_dir()` false, its
dentries became unreachable, and fsck reported the subtree below it as orphans.
The type is now resolved from the inode.

**18. `create_file()` and `mkdir()` had no default mode.** Fixed. This runtime
passes `nil` for a missing argument rather than raising, so both silently built
inodes with a nil mode -- a non-directory, with `is_dir()` false and
`_get_dir()` nil. `mkdir` now defaults to `0o755` and guards nil; `create_file`
defaults to `O_WRONLY|O_CREAT|O_TRUNC`. `create_file` also checked for a free
descriptor *after* creating the inode and saving the directory entry, so a full
descriptor table returned -1 having already made the file; the check now runs
first.

**19. `VFS` exposes no `punch_hole`.** `VFS.truncate()` has been added and
updates both halves — the extent map via `ExtentTree.truncate()` and the inode's
`size` — refusing to grow rather than zero-filling bytes that were never written.
`punch_hole()` still only exists on `ExtentTree`, so blocks cannot be released
through the filesystem API, and `ExtentTree.punch_hole()` still requires a
block-aligned range because extents are block-granular.

**16. A write to a block-mapped file now works in place.** This was folded into
issue 9 above rather than listed separately: before the fix, *any* in-place
modification of a block-mapped file silently destroyed the parts it did not
touch.

**13. Inode metadata is capped by a fixed 32 KiB reserved area.** Every inode's
metadata is stored as hex text in a fixed 8-block area at block 8, and the area
ends exactly where the journal begins (`inode_entry_start_blk` 8 +
`INODE_ENTRY_RESERVED_BLKS` 8 == `RESERVED_BLKS` 16). Two measured limits follow:

- `MAX_INLINE_DENTRIES` is 200, so a single directory holds at most 200 entries.
  Verified: a directory listing stops growing at 3384 bytes / 258 persisted
  inodes whether 400 or 1500 files are attempted — the extra `open()` calls
  simply fail.
- In principle the 32 KiB area bounds total inodes far below that, and
  `write_inode_entry_at` does no bounds checking of its own; it grows the image
  and writes wherever it is told. `_persist_all()` now checks the bound itself
  and reports how many inodes did not fit rather than writing past the end.

This is architectural, not a bug to patch: the inode table has to move into real
blocks, like the extent tree already does. Until then a volume holds a few
hundred inodes. I have **not** reproduced the area actually overflowing — the
200-entry directory cap keeps the total well under the limit — so treat the
bound as a guard on an invariant rather than a fix for observed corruption.

---

## Command-line tools

There is **no** unified `sagefs` binary. An earlier revision of this file
documented one; it was never written. What exists is `sagemake` plus individual
entry points:

| Command | What it does |
| --- | --- |
| `./sagemake build` | compiles the tools into `build/` |
| `./sagemake test` | runs all 20 test files |
| `build/mkfs.sagefs <image> [--size MB] [--label NAME] [--block-size N] [--segment-size N] [--force]` | format an image |
| `build/mkfs.sagefs --check <image>` | verify the magic number |
| `sage --runtime bytecode -I src src/mount.sage <image> <mountpoint>` | mount via FUSE |
| `sage --runtime bytecode -I src src/tools/stats_cli.sage <image>` | superblock/segment/allocator/cache summary |
| `sage --runtime bytecode -I src src/tools/defrag_cli.sage <image> <inode>` | extent report — reports only, does not defragment |
| `sage --runtime bytecode -I src src/tools/scrub_cli.sage <image>` | currently cannot detect any mismatch |
| `sage --runtime bytecode -I src src/tools/snapshot_cli.sage <cmd> <subvol>` | operates on an in-memory engine; never opens the image |
| `sage --runtime bytecode -I src src/tools/dedup_cli.sage <image>` | byte-scan reporting every block as unique |
| `sage --runtime bytecode -I src src/tools/balance_cli.sage` | prints RAID geometry; does nothing |

`mkfs` is also documented as accepting `--compress` and `--checksum`. It does
not parse them — they are silently discarded, and every volume is created with
no feature flags set.

`src/fsck.sage` has no `main()` and cannot be invoked. See known issues.

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

**20. ~~Renaming a directory that has children failed under the bytecode VM.~~
Fixed — and the diagnosis was wrong twice.** Renaming a non-empty directory and
then resolving it raised "Arity mismatch" in the bytecode VM, while the same
code passed under the C backend. The C backend's own stderr for the failing
build named the real cause: `rename()` was assigning `entry_type` from
`target_ino` before `target_ino` existed, and the C backend reported that as
"Undefined variable" while the VM reported it as an arity error. The differing
message is what sent the investigation after `_get_dir()` aliasing and the
bytecode VM specifically, when the defect was neither. Renaming empty
directories, non-empty directories and cross-directory moves are all now pinned
in `testing/test_sparse_and_rename.sage` and pass in both runtimes.

**21. ~~`testing/test_extent.sage` verified nothing.~~ Fixed.** Its 55
`assert.equal()` calls came from `std.testing`, and in this runtime `assert.equal`
is a **silent no-op** — it neither raises on failure nor reports anything. The
file also printed `PASS` after every test proc and ended with an unconditional
`ALL TESTS PASSED` banner, so there was no failure path at all. Confirmed by
mutation: changing an expected block address from 100 to 999 left every test
reporting `PASS`.

Replacing the assertions with real comparisons immediately exposed how much was
hidden — 39 of the 55 were failing, all reading `got=nil`. Three distinct causes,
all now fixed:

- **The mock handed out block 0.** `alloc_block()` returned
  `len(self.blocks) - 1`, so the first block it ever allocated was block 0 — the
  B-tree's "no tree yet" sentinel, which both `search()` and `insert()`
  special-case. The engine created its root there, `root_block` stayed 0, and
  every later search short-circuited to "no such key" forever. Note that
  `BTreeEngine(alloc, 0, 1)` is *correct* for a fresh tree; the mock was wrong,
  not the root. Allocation now starts at `BLOCK_BASE = 8`, matching
  `main_start_blk`.
- **The mock did not materialise blocks.** `read_block()` returned an empty buffer
  for any address it had not been given, where `VFS._read_block()` grows the
  image on demand. Both `read_block()` and `write_block()` now materialise.
- **Two tests asserted the wrong answer.** They punched *byte* ranges and expected
  the surviving extent to move by a *byte* delta on a *block* address
  (`500 + 30`, `1000 + 125`) — the exact confusion `punch_hole()` was fixed for
  earlier. A 200-byte extent occupies one 4096-byte block, so a 50-byte hole
  inside it cannot move the right-hand piece anywhere; `block_addr` correctly
  stayed put. Both tests now punch whole blocks and assert block arithmetic.

The file is back in the suite at **55 of 55 real assertions**, and making it
honest is what found the two extent bugs in the two issues below.

**22. Appended extents never merged.** Fixed. `insert_extent()` decided whether to
merge with the extent on the left by asking `_search_ge()` for the item before the
insertion point, but `_search_ge()` returns the first item with a key *greater than
or equal to* the search key, and `nil` when the key is past every item in the tree
— which is exactly the case when a new extent is written past the end of a file.
So on every append there was no candidate at all and adjacent extents were never
merged. A new `_search_le()` finds the predecessor, descending to the leaf that
would hold the key and, when the insertion point is that leaf's start, walking up
the path to the previous leaf.

The existing merge tests all passed because they inserted in the *middle*, where
`_search_ge()` had a successor to return. The cost was not cosmetic: a file built
by repeated appends grew one extent per write instead of merging them, so a GiB
written in 4 KiB chunks accumulated 262144 extents of 24 bytes plus keys in the
B+ tree, and `MAX_EXTENT_LEN` never capped anything. Caught by the rebuilt extent
harness, in `test_merge_up_to_max_len`.

**23. `lookup_extent()` could not find the middle or tail of a file.** Fixed, and
found by the same rebuilt harness. It asked `_search_ge()` for the first extent
*starting at or after* the offset and returned nil when there was none — but the
usual question is "which extent *contains* offset X", and for any X past every
extent's start key there is none, so the call reported no such extent for a file
that plainly had one. The successor branch was only ever reached when a successor
existed, which left the tail of every file unreachable through this call. It now
falls back to the predecessor via `_search_le()` and checks containment.

**24. A root block of zeros crashed the B-tree instead of reading as empty.**
Fixed. `BTreeEngine.search()` walked `while not current.is_leaf`, and a root
block of zeros — a freshly formatted volume, or damaged metadata —
deserialises with `is_leaf = false`, no items and no pointers. The index
arithmetic then produced `idx = num_items - 1 = -1`, `pointers[-1]` was nil, and
the search died on a property access rather than reporting that there was nothing
to find. `search()` now returns "no such key" when an internal node has no child
pointers, and clamps the child index into range. The same input previously took
down the filesystem on the next lookup.

**13. Inode metadata is capped by a fixed 32 KiB reserved area.** Every inode's
metadata is hex text written sequentially into a fixed region — 8 blocks
(`inode_entry_start_blk` 8, `INODE_ENTRY_RESERVED_BLKS` 8, i.e. 32 KiB at 4 KiB
blocks) sitting between the checkpoint packs and the journal. `_persist_all()`
walks the inode table at unmount and appends each entry at the running offset;
`imgio.read_inode_entries_from_area()` parses them back on mount. There is no
indirection, so the table cannot grow: the area is the ceiling. Directory entries
are separately capped at `MAX_INLINE_DENTRIES` = 200, and inline file data at
`INLINE_DATA_MAX`. The area is bounded on write precisely because
`write_inode_entry_at()` does no bounds checking of its own and will happily grow
the image and write past the region.

Not yet fixed. The design, worked out:

- **The superblock is full, and must be trimmed rather than resized.** Bytes
  92–383 look like padding between `main_start_blk` at 84 and `flags` at 384, but
  they are not: `uuid` occupies 92–127 and `label` occupies 128–383
  (`MAX_LABEL_LEN`, now 240). The 480-byte header had no free bytes at all.
  I previously reported 292 free bytes here by reading the offset gap between
  numeric fields and missing the two fixed-width strings in it. That was wrong and
  it changes the design.
  The better fix is to shorten `MAX_LABEL_LEN` from 256 to 240, freeing bytes
  368–383 for `inode_root_blk` (LE64 @ 368) and `inode_root_generation`
  (LE64 @ 376). That keeps `SUPERBLOCK_HEADER_SIZE` at 480, keeps the checksum at
  476, and leaves every existing field offset untouched — so the change really is
  additive, and the only images that stop reading are ones written with a
  >240-byte label. 240 characters is far more than a filesystem label needs
  (ext4 allows 16, XFS 12, F2FS 16).
  The alternative — growing the header to 496 and relocating the checksum from
  476 — moves the checksum field and every offset after it, and buys nothing for
  a 240-vs-256 character label.
- **A separate B+ tree for the inode table, with its own root and generation.**
  This was left open as a judgement call and is now decided, against the
  alternative of sharing the extent tree's root: `docs/btree.md` states the CoW
  B+ tree "backs directory entries, extent maps, extended-attribute indexes, and
  snapshot trees", and snapshots work by cloning a tree root, which is O(1) only
  while each index has an independent root. Putting inode metadata and extent
  metadata under one root would make the two share a COW generation, so updating
  any inode would copy the extent tree's root too, and a snapshot could not
  capture the two at different generations. Separate roots also keep inode churn
  from splitting extent nodes and vice versa, which matters because the whole
  point of the hybrid is F2FS-style separation of concerns. The cost is one more
  superblock field pair and one more tree to mount, which is cheap.
  The machinery is the same code: `ExtentTree` and the inode table become two
  instances of the same block-backed CoW B+ tree over the same allocator, so the
  COW, split, remount and predecessor-search behaviour the extent tree already
  has is reused rather than reimplemented.
- **`_persist_all()`** becomes "serialize every dirty inode and insert it under
  its inode number", and mount reads them back by walking the tree from
  `sb.inode_root_blk` instead of parsing the area. The dirty set
  (`InodeManager.get_dirty_inodes()`) already exists and is already maintained,
  so this also stops rewriting every inode on every unmount.
- **The reserved area becomes a v1.4 fallback**, gated on `version_minor < 5`, so
  existing images still mount. A v1.5 image with a corrupt or missing inode root
  should fall back to the area if it is non-empty, and otherwise come up empty
  rather than refusing to mount.

**In progress.** Done: `MAX_LABEL_LEN` is now 240, and `inode_root_blk` (LE64 @
368) and `inode_root_generation` (LE64 @ 376) are wired through the superblock's
init, checksum payload, serializer, deserializer, `to_dict` and `__str__`.
`SUPERBLOCK_HEADER_SIZE` stays 480 and the checksum stays at 476, so no
pre-existing field offset moved. `test_superblock.sage` (16 assertions) checks
the raw bytes at the two new offsets, that a maximum-length label does not
overwrite them, that both are covered by the superblock checksum, and that a
v1.4 image with zeros there still parses.

Also done: inode metadata now has a single on-disk codec.
`imgio.encode_inode_entry()` and `imgio.decode_inode_entry()` are the only
encoder and decoder for the 16-byte header, and both the v1.4 area writer and
reader go through them. A v1.5 tree value is therefore byte-identical to what
the area would have stored, so migrating between the two is a straight copy
rather than a re-encoding, and the two readers cannot drift apart the way two
hand-written parsers can. `test_inode_codec.sage` (33 assertions) checks the
header at each documented offset with values exceeding 8 and 16 bits — a writer
that truncated `ino` or `mode` to a single byte passes every test that only uses
ino 1 and mode 0o644 — and asserts the area writer is byte-identical to the
codec. The area scan is now bounded by the buffer length as well as the declared
area: it previously checked only the area end, which on a real image was harmless
because the bytes past the last entry are zero padding, but read past the end of
a short buffer and produced nil fields.

Also done: `BTreeEngine` can enumerate itself. `scan()` returns every key/value
pair in ascending key order and `count()` returns the number of them, both walking
the internal nodes down to every leaf. The inode table needs this at mount, which
has to load every inode rather than look one up, and so does fsck. `collect_leaves`
treats an internal node with no pointers as a dead end, matching the guard `search`
already has for a zeroed root, so damaged metadata cannot send the walk to
`pointers[-1]`. `test_btree.sage` covers it with 200 keys so the tree has really
split and the scan has to descend past a single leaf, checks ordering and that
each value stays with its own key, reopens the tree against the same allocator to
stand in for reading a saved image, and checks that deletions are reflected.

Also found and fixed while building on it: a B+ tree leaf's data area grew
without bound when a key's value was replaced. Replacing a value appends the new
bytes and repoints the item, leaving the old ones behind, and
`compact_data_area()` was only ever called from `delete()`. Values still read back
correctly throughout, because the item points at the newest bytes, so nothing
looked wrong until the leaf outgrew `BTREE_NODE_SIZE`. Updating one key 500 times
with a 28-byte value produced a 14000-byte data area and a **14064-byte serialized
node — 3.4× the block**, written straight through the end of it. Rewriting a dirty
inode on every unmount hits this directly, which is why it had to be fixed before
the inode table rather than during it. `BTreeNode.insert` now compacts once the
dead bytes exceed twice the live bytes, rather than on every replacement, so
reclaiming does not make a bulk rewrite quadratic.

A second, more serious one surfaced while building the inode table on it: a leaf
was split on **key count only**, never on serialized **byte size**. A leaf's size
is its header plus 32 bytes per item plus its data area, so a node can sit well
under `BTREE_MAX_KEYS` and still outgrow `BTREE_NODE_SIZE` — one large value
among small ones is enough. The allocator's `write_block` copies at most one
block, so the oversized node lost everything past the boundary, with no error
reported. `count()` read the key count out of the surviving header and reported
every key present while `search()` returned nothing for the ones whose bytes had
been dropped. A root directory's dentry blob is a value big enough to do this,
which is how it was found; extent values are too small to reach it.

`BTreeEngine.needs_split()` now splits on either limit. A single item larger than
a block is left alone — splitting cannot shrink it — and needs an overflow chain,
which this format does not have yet.

Two smaller robustness fixes came out of the same work:

- `insert()` into a tree whose recorded root is not a node walked to
  `pointers[-1]` and took the filesystem down, while `search()` and `scan()`
  already read such a root as empty. `root_is_readable()` now checks the magic,
  so damage is distinguishable from emptiness, and `insert()` starts a new root
  rather than indexing into a dead one.
- `BTreeNode.deserialize()` records whether it found the node magic, which is
  what makes that distinction possible at all.

## Format v1.5 — inode metadata in a B+ tree

All inode metadata used to be written as hex text into a single fixed 32 KiB area
carved out of the reserved blocks. That capped the filesystem at whatever fitted
in 32 KiB, and `_persist_all()` had to know it was about to run out and drop
inodes on the floor — reporting how many on stdout, which is not something a
filesystem should do silently or at all. The ceiling was architectural rather than
a matter of tuning: it could not be raised without another on-disk format change,
and a volume with more metadata than that simply could not be represented.

`src/inodetable.sage` moves it into a B+ tree with its own root and generation,
recorded at superblock 368/376. A separate root is not incidental: sharing one
with the extent map would put both under a single CoW generation, so writing one
inode would copy the whole extent map too, and O(1) snapshot cloning would need
every other index cloned as well. Separate roots are also what makes an
inode-only snapshot possible.

- The entries are byte-identical to what the area held, via the shared
  `imgio.encode_inode_entry()`, so migration is not a second parser and a volume
  can move between the two without rewriting entries.
- `mount()` decides from the *tree*, not the version: a volume whose root block
  does not hold a node is reported and falls back to the area, and a volume with
  no root is read from the area and rewritten into the tree by the first unmount.
  An old image needs no conversion step.
- Unmount writes the version as 1.5 whenever a tree exists, so the fields survive
  the `version_minor >= 5` gate on the next mount. Without that a migrated volume
  stayed stamped 1.4, its root was zeroed again, and it went back to an area that
  no longer held the file.
- Only dirty inodes are written, so unmount cost tracks what changed rather than
  how much exists. Getting there needed three fixes to dirty tracking, each of
  which alone made every mount rewrite the whole table: the loader noted every
  inode it read, `_recompute_link_counts` marked every inode whose recomputed link
  count differed from the default a freshly loaded inode carries (nlink is derived
  and has no field in the on-disk entry, so it is never written back), and
  `_ensure_stub_inode` correctly marks what it creates — which is every inode,
  because the in-memory table starts empty on each mount.
- Deletions are found by diffing the tree against the in-memory set. A deleted
  inode is *absent* from `list_inodes()`, so a loop over the in-memory set never
  visits its number and the stale entry survives; the area writer did not hit this
  only because it rewrote everything and zeroed the remainder, making absence
  implicit.
- `InodeTable` advances its CoW generation on first write rather than at mount.
  Opening at `generation + 1` makes every node stale at once, so any mount that
  wrote anything copied the entire table — and that was not merely expensive, see
  below.

`testing/test_inodetable.sage` is 147 assertions covering the table over a mock
allocator, the VFS round trip, unlink (both the retained-with-data case and the
deleted-when-empty case), migration from the area, a deliberately corrupted root,
dirty-only persist, and a genuine v1.4 image rewritten to look like one.

## Directory entries still do not scale (the next piece, and it is now loud)

The inode table removed the 32 KiB metadata ceiling, but **directory entries are a
separate limit and were not touched**. A directory is still stored as one hex blob
in the parent inode's inline data, capped by `INLINE_DATA_MAX` of 3400. A
`fileNNN.txt` dentry costs 36 hex characters, so one directory holds **94
entries**; `MAX_INLINE_DENTRIES` caps it at 200 by the same mechanism.

Past that ceiling the directory was not recorded *at all*. `set_inline_data()`
refuses anything over the limit and returns false having changed nothing, so the
inode kept whatever it had and every subsequent change was discarded. The inodes
were still written to the table, so files past the point existed, were handed file
descriptors, and were unreachable by name after a remount — with no error
anywhere. `_save_dir()` now checks the return and reports, once per volume, that
the directory is not being saved and that its files will not survive.

Better still, `create_file()`, `mkdir()` and `rename()` now **refuse** an entry
that would not fit, checked before the inode is created. Reporting was only half a
fix: the filesystem still accepted the name that would not fit, handed back a
working descriptor, wrote to it, and lost the name at unmount. A caller told "no"
still has its file; a caller told "yes" does not. The check runs before inode
creation because checked after, a refused create left an inode in the table that
the inode table wrote to disk on every unmount with nothing pointing at it.

The property now guaranteed is the one that matters: **nothing the filesystem
accepts is ever lost.** Measured, 400 create attempts in one directory give
**100 accepted, 300 refused, 0 lost**, contents intact after a remount. The
ceiling is real; it is no longer a lie.

The fix is to give directory entries their own index — the same treatment the
inode table just got, and independent for the same reason. That is the next piece
of work; it is the last thing standing between this and a filesystem whose
metadata does not stop scaling at a fixed size.

## Block allocation did not survive a remount (fixed, and it was the real bug)

The NAT was not persisted, so on mount the segment manager came up with no record
of which physical blocks the previous session had used and would hand one out
again. Any metadata written after a remount could therefore land on top of a
file's live data.

This sat unnoticed for a long time because the extent tree allocates few enough
blocks after a remount to avoid overlapping anything. The inode table's per-mount
CoW allocates enough to collide, and the collision is silent: the file keeps its
length, its extents and its inode entry, and the blocks those extents point at now
hold tree nodes instead of data. The bytes are gone with nothing to indicate it —
`read_inode_data()` returned a correctly sized buffer of the wrong contents.

The segment manager already had the machinery: `SITEntry` carries a per-block
validity bitmap and `allocate_block()` maintains it correctly. It was simply never
written out. `SITEntry.deserialize()`, `SegmentManager.load_sit()` and
`save_sit()` now round-trip it through the SIT region the layout has always
reserved at `sit_start_blk`, loaded at mount before anything can allocate and
saved at unmount after allocation has finished. The validity count is recomputed
from the bitmap rather than trusted, since the two are written separately and a
torn write can leave them disagreeing — and the bitmap is the one consulted when
allocating, so it is the one that has to be right. Segments holding valid blocks
are taken out of the free list and the current-segment cursors are reset, so a
segment with live blocks is never reissued.

