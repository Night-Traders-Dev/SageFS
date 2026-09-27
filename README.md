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

**Tests: 21/21 files, 526 assertions, no known failures.** The suite was
previously not running at all; see [Known issues](#known-issues) for what is
still broken.

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
- ❌ **SHA-256** — `checksum.sage` returns the hard-coded digest of the empty
  string for any input
- ❌ **Online scrub** — `scrub_cli.sage` compares each block against a freshly
  built empty tree, so it can never detect a mismatch
- ❌ **Repair-on-read** — not implemented

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
- ⚠️ **Deduplication** — fingerprinting and refcount tables exist, but
  `check_inline()` never increments a refcount and the fingerprint is a 32-bit
  polynomial hash, not SHA-256. Nothing is deduplicated.
- ❌ **Bloom filter** — `bloom_filter` is a `Dict`; `DEDUP_BLOOM_SIZE` is unused
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
  - CRC32C and xxHash per-block checksumming (SHA-256 is a stub)
  - Dual superblock mirroring; checkpoint packs defined but not yet written
  - Write-ahead journal with a correct recover/replay, but no region reserved

- **Storage efficiency**:
  - Inline data & directories (<=3.4 KiB) — live in the I/O path
  - Transparent compression, deduplication, RAID — defined, not yet wired in

- **Performance**:
  - The targets listed above are aspirational; no benchmark harness has been run
    against this implementation
  - No lock-free hot paths, no io_uring

- **Development**: 21 test files, 526 assertions, 6 CLI tools

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

> **Note:** The native C backend does not support `bytes_*` builtins. `./sagemake build` automatically falls back to the SageVM bytecode backend, which fully supports all `Bytes` operations.

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
# Full test suite — 21 files, 526 assertions
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

**8. `_write_extents` is undefined.** It is called from `truncate()` and
`punch_hole()` in `extent.sage` but defined nowhere, so both fail at runtime.

**9. The node cache is never invalidated on write.** `VFS.write()` does not drop
the cached entry, so read-write-read of a block-mapped file can return stale
content.

**10. SIT region sizing.** `segment.sage` declares `SIT_ENTRY_SIZE = 72` while
`superblock.sage` sizes the region with `sit_entry_size = 64`, allocating the
SIT 12.5% too small.

**11. The NAT, SIT, SSA and checkpoint packs are never persisted.** They are
in-memory structures that die at unmount, despite `compute_layout()` reserving
regions for them.

**12. ~~A read-only `open()` could truncate a file to zero bytes.~~ Fixed.**
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
