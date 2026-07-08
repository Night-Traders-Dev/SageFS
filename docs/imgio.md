# Image Persistence (imgio)

| Module | `src/imgio.sage` |
|--------|------------------|
| Status | ✅ Implemented |
| Phase  | 6 — Tooling & Integration |

## Purpose

The imgio module provides the low-level I/O layer for reading and writing
SageFS disk images.  Because the SageLang runtime does not yet implement
binary file I/O (`io.writebytes` / `io.readbytes` return false/empty),
images are persisted as **hexadecimal text** via `io.writefile` /
`io.readfile`.  Swapping to native binary I/O is a one-line change once
the toolchain supports it.

## API

| Proc | Signature | Description |
|------|-----------|-------------|
| `write_image` | `(path, buf) -> Bool` | Write a `Bytes` buffer as hex text |
| `read_image` | `(path) -> Bytes` | Read a hex-text image back to `Bytes` |
| `write_inode_entry` | `(buf, ino, mode, size, name, data)` | Append a binary inode directory record |
| `read_inode_entries` | `(buf) -> Array[Dict]` | Parse all inode directory records |

## Inode Directory Format

After the 428-byte superblock, the image may contain zero or more inode
directory entries.  Each entry is a variable-length binary record:

| Offset | Size | Field |
|--------|------|-------|
| 0 | 4 | ino (LE32) |
| 4 | 4 | mode (LE32) |
| 8 | 4 | size (LE32) |
| 12 | 2 | name_len (LE16) |
| 14 | 2 | data_len (LE16) |
| 16 | name_len | filename (ASCII) |
| 16+name_len | data_len | inline data |

The entry list is terminated by end-of-buffer (no length prefix).

## Hex-Text Format

The hex-text format is a single line of lowercase hex digits, one pair per
byte, written via `io.writefile`.  For example, a minimal superblock hex
image begins with `454741530000...` (SAGE magic).

## Related

- `src/superblock.sage` — superblock (first 428 bytes of every image)
- `src/vfs.sage` — VFS mount reads the inode directory after the superblock
- `src/mkfs.sage` — formats images (superblock + inode directory)
