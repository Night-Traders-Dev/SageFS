# Async I/O Engine
**Module:** [`src/aio.sage`](../src/aio.sage) · **Phase:** 5 (Performance) · **Status:** ⚠️ Structurally present, not asynchronous

## Purpose
Queues I/O requests by priority so a caller *could* overlap them.

**There is no io_uring integration, and there never was** — the string only
appeared in documentation. `AsyncIOEngine` is three `Array` submission
queues indexed by priority, plus a `poll()` that walks all three, sets
`completed = true` on every request, and returns. There are no threads, no
event loop, no `io_uring`/`ioctl` calls, no submission or completion ring,
and no device callback. `submit_read` does not even carry the data. Because
`poll()` is synchronous and instant by construction, the module cannot make
any I/O faster; it is also not in the read/write path.

## Design
- `submit_read(lba, length)` and `submit_write(lba, data)` append to internal task queues.
- `poll()` reaps Completion Queue Entries (CQEs) and invokes continuations/callbacks for completed blocks.

## Related
[allocator.md](allocator.md)
