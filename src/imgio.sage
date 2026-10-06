## imgio.sage — SageFS binary image persistence.
##
## Supports regular file images and raw block devices (/dev/sd*).
## For block devices, uses a C helper (bdev_io) for reads since
## io.readbytes cannot determine block device size via ftell.

import ffi
import fileio
import io
import sys

let BDEV_READ_SIZE: Int = 1048576  # 1 MB fallback when image_size is unknown

proc _is_block_device(path: String) -> Bool:
    return startswith(path, "/dev/")

proc write_image(path: String, buf: Bytes) -> Bool:
    if _is_block_device(path):
        let tmp: String = "/tmp/sagefs_bdev_write.bin"
        io.writebytes(tmp, buf)
        let cmd: String = "/tmp/bdev_io write " + path + " 0 " + tmp
        return sys.exec(cmd) == 0
    io.writebytes(path, buf)
    return true

## truncate_to — Set a file's length, extending it with zeros if needed.
##
## Used instead of building a full-volume buffer in memory. bytes() returns a
## zero-length buffer for large requests rather than failing, so an in-memory
## pad silently produces a truncated image.
proc truncate_to(path: String, size: Int) -> Bool:
    if _is_block_device(path):
        return true
    try:
        ## libc truncate() rather than anything in the standard library: there
        ## is no os.truncate here, and this needs to extend the file to a size
        ## far larger than it is comfortable allocating.
        let lib = ffi.open("libc.so.6")
        if lib == nil:
            return false
        return ffi.call(lib, "truncate", "int", [path, size]) == 0
    catch e:
        return false

proc read_image(path: String) -> Bytes:
    let data = io.readbytes(path)
    if bytes_len(data) > 0:
        return data
    if not _is_block_device(path):
        ## io.readbytes() refuses a whole-file read over 100 MiB and returns nil
        ## rather than an error, so any image larger than that came back empty with
        ## nothing logged. read_image_range() was written for exactly this and
        ## used it, while read_image() -- the function every mount goes through --
        ## kept the whole-file read and no fallback. A 256 MiB volume formatted by
        ## mkfs therefore could not be reopened: read_image returned 0 bytes and
        ## mount reported a corrupt superblock for a perfectly good image.
        ##
        ## Reassemble it from bounded ranges instead. The chunk is well under the
        ## cap, so each read succeeds on its own.
        let out: Bytes = bytes()
        var offset: Int = 0
        var empty_reads: Int = 0
        while empty_reads < 2:
            let piece = fileio.read_at(path, offset, BDEV_READ_SIZE)
            if bytes_len(piece) <= 0:
                empty_reads = empty_reads + 1
                if empty_reads >= 2:
                    break
                offset = offset + BDEV_READ_SIZE
                continue
            empty_reads = 0
            ## bytes_extend() appends the whole chunk in one C-level copy. Doing
            ## this with a per-byte loop is O(n) *interpreted* operations: a 256 MiB
            ## image took 4m19s, which reads as a hang, and a 1 GiB volume would take
            ## the better part of 20 minutes.
            bytes_extend(out, piece)
            offset = offset + bytes_len(piece)
        if bytes_len(out) > 0:
            return out
        return data
    let tmp: String = "/tmp/sagefs_bdev_read.bin"
    let cmd: String = "/tmp/bdev_io read " + path + " 0 " + str(BDEV_READ_SIZE) + " " + tmp
    let ok = sys.exec(cmd)
    if ok != 0:
        return data
    return io.readbytes(tmp)

## read_image_range — Read `size` bytes from `offset`, without loading the file.
##
## io.readbytes() caps a whole-file read at 100 MiB and returns nil past that,
## with no error, so anything larger reads back as length 0: a full-size image
## opens as an empty one and the mount reports a corrupt superblock. A bounded
## range works at any size.
proc read_image_range(path: String, offset: Int, size: Int) -> Bytes:
    if size <= 0:
        return bytes()
    let got: Bytes = fileio.read_at(path, offset, size)
    if bytes_len(got) > 0:
        return got
    ## Block devices are not seekable through the FFI path, so fall back to the
    ## whole-image read and take the range out of it.
    let whole: Bytes = read_image(path)
    if bytes_len(whole) <= offset:
        return bytes()
    return fileio.slice_bytes(whole, offset, offset + size)

proc read_image_exact(path: String, size: Int) -> Bytes:
    let data = io.readbytes(path)
    if bytes_len(data) > 0:
        return data
    if not _is_block_device(path):
        return data
    let tmp: String = "/tmp/sagefs_bdev_exact.bin"
    let cmd: String = "/tmp/bdev_io read " + path + " 0 " + str(size) + " " + tmp
    let ok = sys.exec(cmd)
    if ok != 0:
        return bytes()
    return io.readbytes(tmp)

proc write_inode_entry(buf: Bytes, ino: Int, mode: Int, size: Int, name: String, data: String):
    bytes_push(buf, ino & 0xFF)
    bytes_push(buf, (ino >> 8) & 0xFF)
    bytes_push(buf, (ino >> 16) & 0xFF)
    bytes_push(buf, (ino >> 24) & 0xFF)
    bytes_push(buf, mode & 0xFF)
    bytes_push(buf, (mode >> 8) & 0xFF)
    bytes_push(buf, (mode >> 16) & 0xFF)
    bytes_push(buf, (mode >> 24) & 0xFF)
    bytes_push(buf, size & 0xFF)
    bytes_push(buf, (size >> 8) & 0xFF)
    bytes_push(buf, (size >> 16) & 0xFF)
    bytes_push(buf, (size >> 24) & 0xFF)
    let name_len: Int = len(name)
    let data_len: Int = len(data)
    bytes_push(buf, name_len & 0xFF)
    bytes_push(buf, (name_len >> 8) & 0xFF)
    bytes_push(buf, data_len & 0xFF)
    bytes_push(buf, (data_len >> 8) & 0xFF)
    var i: Int = 0
    while i < name_len:
        bytes_push(buf, bytes_get(bytes(name), i))
        i = i + 1
    i = 0
    while i < data_len:
        bytes_push(buf, bytes_get(bytes(data), i))
        i = i + 1

proc read_inode_entries(buf: Bytes) -> Array:
    let total_len: Int = bytes_len(buf)
    var entries: Array = []
    var off: Int = 0
    while off + 16 <= total_len:
        let ino: Int = bytes_get(buf, off) | (bytes_get(buf, off + 1) << 8) | (bytes_get(buf, off + 2) << 16) | (bytes_get(buf, off + 3) << 24)
        let mode: Int = bytes_get(buf, off + 4) | (bytes_get(buf, off + 5) << 8) | (bytes_get(buf, off + 6) << 16) | (bytes_get(buf, off + 7) << 24)
        let size: Int = bytes_get(buf, off + 8) | (bytes_get(buf, off + 9) << 8) | (bytes_get(buf, off + 10) << 16) | (bytes_get(buf, off + 11) << 24)
        let name_len: Int = bytes_get(buf, off + 12) | (bytes_get(buf, off + 13) << 8)
        let data_len: Int = bytes_get(buf, off + 14) | (bytes_get(buf, off + 15) << 8)
        let entry_off: Int = off + 16
        if entry_off + name_len + data_len > total_len:
            break
        var name_bytes: Bytes = bytes()
        var j: Int = 0
        while j < name_len:
            bytes_push(name_bytes, bytes_get(buf, entry_off + j))
            j = j + 1
        var data_bytes: Bytes = bytes()
        j = 0
        while j < data_len:
            bytes_push(data_bytes, bytes_get(buf, entry_off + name_len + j))
            j = j + 1
        var entry: Dict = {}
        entry["ino"] = ino
        entry["mode"] = mode
        entry["size"] = size
        entry["name"] = bytes_to_string(name_bytes)
        entry["data"] = bytes_to_string(data_bytes)
        push(entries, entry)
        off = entry_off + name_len + data_len
    return entries

proc encode_inode_entry(ino: Int, mode: Int, size: Int, name: String, data: String) -> Bytes:
    ## Serialize one inode entry to its canonical byte form.
    ##
    ## Layout (16-byte header, then payload):
    ##     0-3   ino (LE32)
    ##     4-7   mode (LE32)
    ##     8-11  size (LE32)
    ##    12-13  name_len (LE16)
    ##    14-15  data_len (LE16)
    ##    16..   name bytes, then data bytes
    ##
    ## This is the single codec for inode metadata on disk. Both the v1.4 fixed
    ## area and the v1.5 inode B+ tree use it, so a tree value is byte-identical
    ## to what the area would have stored and migrating between the two is a
    ## straight copy rather than a re-encoding.
    var out: Bytes = bytes()
    bytes_push(out, ino & 0xFF)
    bytes_push(out, (ino >> 8) & 0xFF)
    bytes_push(out, (ino >> 16) & 0xFF)
    bytes_push(out, (ino >> 24) & 0xFF)
    bytes_push(out, mode & 0xFF)
    bytes_push(out, (mode >> 8) & 0xFF)
    bytes_push(out, (mode >> 16) & 0xFF)
    bytes_push(out, (mode >> 24) & 0xFF)
    bytes_push(out, size & 0xFF)
    bytes_push(out, (size >> 8) & 0xFF)
    bytes_push(out, (size >> 16) & 0xFF)
    bytes_push(out, (size >> 24) & 0xFF)
    bytes_push(out, len(name) & 0xFF)
    bytes_push(out, (len(name) >> 8) & 0xFF)
    bytes_push(out, len(data) & 0xFF)
    bytes_push(out, (len(data) >> 8) & 0xFF)
    var k: Int = 0
    while k < len(name):
        bytes_push(out, ord(name[k]))
        k = k + 1
    k = 0
    while k < len(data):
        bytes_push(out, ord(data[k]))
        k = k + 1
    return out


proc decode_inode_entry(buf: Bytes, off: Int) -> Dict:
    ## Parse one inode entry at off, returning ino/mode/size/name/data and the
    ## entry's total byte length. Requires at least 16 readable bytes at off.
    let ino: Int = bytes_get(buf, off) | (bytes_get(buf, off + 1) << 8) | (bytes_get(buf, off + 2) << 16) | (bytes_get(buf, off + 3) << 24)
    let mode: Int = bytes_get(buf, off + 4) | (bytes_get(buf, off + 5) << 8) | (bytes_get(buf, off + 6) << 16) | (bytes_get(buf, off + 7) << 24)
    let sz: Int = bytes_get(buf, off + 8) | (bytes_get(buf, off + 9) << 8) | (bytes_get(buf, off + 10) << 16) | (bytes_get(buf, off + 11) << 24)
    let name_len: Int = bytes_get(buf, off + 12) | (bytes_get(buf, off + 13) << 8)
    let data_len: Int = bytes_get(buf, off + 14) | (bytes_get(buf, off + 15) << 8)
    let payload: Int = off + 16
    ## Reject an entry whose declared lengths do not fit before reading any of it.
    ##
    ## name_len and data_len come from the buffer, so they are whatever is on disk.
    ## The two copy loops below walk that many bytes with no check of their own, and
    ## the caller's `off + total > end_offset` test runs only *after* this returns --
    ## far too late, because the out-of-range reads have already happened.
    ##
    ## This is not a corrupt-disk-only path. A freshly formatted volume has real
    ## inode entries in this area, and decoding them walked off the end of the
    ## buffer: "Invalid index assignment" once per byte, millions of times, and the
    ## mount never completed. Every test in testing/ builds a bare superblock with a
    ## zeroed inode area, where name_len and data_len are both 0 and the loops never
    ## execute -- which is why the suite never saw it.
    if off < 0 or off + 16 > bytes_len(buf):
        return {"ino": 0, "mode": 0, "size": 0, "name": "", "data": "", "total": 0}
    if name_len < 0 or data_len < 0:
        return {"ino": 0, "mode": 0, "size": 0, "name": "", "data": "", "total": 0}
    if payload + name_len + data_len > bytes_len(buf):
        return {"ino": 0, "mode": 0, "size": 0, "name": "", "data": "", "total": 0}
    var name_bytes: Bytes = bytes()
    var j: Int = 0
    while j < name_len:
        bytes_push(name_bytes, bytes_get(buf, payload + j))
        j = j + 1
    var data_bytes: Bytes = bytes()
    j = 0
    while j < data_len:
        bytes_push(data_bytes, bytes_get(buf, payload + name_len + j))
        j = j + 1
    var entry: Dict = {}
    entry["ino"] = ino
    entry["mode"] = mode
    entry["size"] = sz
    entry["name"] = bytes_to_string(name_bytes)
    entry["data"] = bytes_to_string(data_bytes)
    entry["total"] = 16 + name_len + data_len
    return entry


## bytes_to_hex -- lowercase hex, no separator. The inverse is inode.hex_to_bytes.
##
## Inline inode payloads are stored hex-encoded: a raw payload cannot represent a
## zero byte, and README.txt is full of them (every line ends "\n"). Module-level
## so mkfs can encode without importing vfs.
proc bytes_to_hex(buf: Bytes) -> String:
    var hex: String = ""
    let hex_chars: String = "0123456789abcdef"
    var i: Int = 0
    while i < bytes_len(buf):
        let b: Int = bytes_get(buf, i)
        hex = hex + hex_chars[(b >> 4) & 0xF]
        hex = hex + hex_chars[b & 0xF]
        i = i + 1
    return hex

proc write_inode_entry_at(buf: Bytes, offset: Int, ino: Int, mode: Int, size: Int, name: String, data: String) -> Int:
    ## Write an inode entry at a specific offset in buf. Returns the number of
    ## bytes written (the entry size). Expands buf with zeros if offset is
    ## beyond current length.
    let entry: Bytes = encode_inode_entry(ino, mode, size, name, data)
    let total_entry_size: Int = bytes_len(entry)
    let end_offset: Int = offset + total_entry_size
    var i: Int = bytes_len(buf)
    while i < end_offset:
        bytes_push(buf, 0)
        i = i + 1
    var k: Int = 0
    while k < total_entry_size:
        bytes_set(buf, offset + k, bytes_get(entry, k))
        k = k + 1
    return total_entry_size


proc read_inode_entries_from_area(buf: Bytes, area_offset: Int, area_size: Int) -> Array:
    ## Read inode entries from a fixed area of buf starting at area_offset.
    ## Returns parsed entries until the area end is reached or zero padding
    ## is encountered (indicating end of valid entries).
    ##
    ## This is the v1.4 path. It shares decode_inode_entry() with the v1.5 inode
    ## B+ tree, so the two agree on the format by construction rather than via
    ## two parsers that have to be kept in step by hand.
    ## Bound the scan by the buffer as well as the declared area. Checking only
    ## the area end read past the end of a short buffer and returned nil fields
    ## that then blew up in the comparison below; on a real image the bytes
    ## beyond the last entry are zero padding, so the read was harmless and the
    ## exposure was invisible.
    var end_offset: Int = area_offset + area_size
    let buf_len: Int = bytes_len(buf)
    if end_offset > buf_len:
        end_offset = buf_len
    var entries: Array = []
    var off: Int = area_offset
    while off + 16 <= end_offset:
        let entry: Dict = decode_inode_entry(buf, off)
        if off + entry["total"] > end_offset:
            break
        let empty: Bool = entry["ino"] == 0 and entry["mode"] == 0 and entry["size"] == 0 and entry["name"] == "" and entry["data"] == ""
        if empty:
            break
        push(entries, entry)
        off = off + entry["total"]
    return entries
