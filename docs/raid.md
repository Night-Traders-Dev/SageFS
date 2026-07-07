# RAID Engine
**Module:** [`src/raid.sage`](../src/raid.sage) · **Phase:** 6 (Tooling) · **Status:** ✅ Implemented

## Purpose
Provides multi-device support with parity protection (RAID 0, 1, 5, 6, 10). Integrates directly with the filesystem rather than sitting below it, allowing features like metadata mirroring and degraded mode reading.

## Features
- Dynamic device addition.
- `chunk_size` stripping.
- Background scrub for parity verification.
- Drive rebuild capabilities.

## API
- `add_device(dev_path)`
- `read_block(logical_addr) -> Bytes`
- `write_block(logical_addr, data)`
- `scrub() -> Bool`
- `rebuild(target_dev) -> Bool`

## Related
[allocator.md](allocator.md)
