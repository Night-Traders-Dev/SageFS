# Async I/O Engine
**Module:** [`src/aio.sage`](../src/aio.sage) · **Phase:** 5 (Performance) · **Status:** ✅ Implemented

## Purpose
Provides high-performance, non-blocking I/O using `io_uring` (or fallback asynchronous polling mechanisms) to maximize queue depth and throughput.

## Design
- `submit_read(lba, length)` and `submit_write(lba, data)` append to internal task queues.
- `poll()` reaps Completion Queue Entries (CQEs) and invokes continuations/callbacks for completed blocks.

## Related
[allocator.md](allocator.md)
