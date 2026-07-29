## imgio.sage — SageFS binary image persistence.
##
## Supports regular file images and raw block devices (/dev/sd*).
## For block devices, uses a C helper (bdev_io) for reads since
## io.readbytes cannot determine block device size via ftell.

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

proc read_image(path: String) -> Bytes:
    let data = io.readbytes(path)
    if bytes_len(data) > 0:
        return data
    if not _is_block_device(path):
        return data
    let tmp: String = "/tmp/sagefs_bdev_read.bin"
    let cmd: String = "/tmp/bdev_io read " + path + " 0 " + str(BDEV_READ_SIZE) + " " + tmp
    let ok = sys.exec(cmd)
    if ok != 0:
        return data
    return io.readbytes(tmp)

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

proc write_inode_entry_at(buf: Bytes, offset: Int, ino: Int, mode: Int, size: Int, name: String, data: String) -> Int:
    ## Write an inode entry at a specific offset in buf. Returns the number of
    ## bytes written (the entry size). Expands buf with zeros if offset is
    ## beyond current length.
    let entry_hdr_size: Int = 16
    let name_len: Int = len(name)
    let data_len: Int = len(data)
    let total_entry_size: Int = entry_hdr_size + name_len + data_len
    let end_offset: Int = offset + total_entry_size
    let current_len: Int = bytes_len(buf)
    var i = current_len
    while i < end_offset:
        bytes_push(buf, 0)
        i = i + 1
    bytes_set(buf, offset, ino & 0xFF)
    bytes_set(buf, offset + 1, (ino >> 8) & 0xFF)
    bytes_set(buf, offset + 2, (ino >> 16) & 0xFF)
    bytes_set(buf, offset + 3, (ino >> 24) & 0xFF)
    bytes_set(buf, offset + 4, mode & 0xFF)
    bytes_set(buf, offset + 5, (mode >> 8) & 0xFF)
    bytes_set(buf, offset + 6, (mode >> 16) & 0xFF)
    bytes_set(buf, offset + 7, (mode >> 24) & 0xFF)
    bytes_set(buf, offset + 8, size & 0xFF)
    bytes_set(buf, offset + 9, (size >> 8) & 0xFF)
    bytes_set(buf, offset + 10, (size >> 16) & 0xFF)
    bytes_set(buf, offset + 11, (size >> 24) & 0xFF)
    bytes_set(buf, offset + 12, name_len & 0xFF)
    bytes_set(buf, offset + 13, (name_len >> 8) & 0xFF)
    bytes_set(buf, offset + 14, data_len & 0xFF)
    bytes_set(buf, offset + 15, (data_len >> 8) & 0xFF)
    var k: Int = 0
    while k < name_len:
        bytes_set(buf, offset + entry_hdr_size + k, bytes_get(bytes(name), k))
        k = k + 1
    var m = 0
    while m < data_len:
        bytes_set(buf, offset + entry_hdr_size + name_len + m, bytes_get(bytes(data), m))
        m = m + 1
    return total_entry_size

proc read_inode_entries_from_area(buf: Bytes, area_offset: Int, area_size: Int) -> Array:
    ## Read inode entries from a fixed area of buf starting at area_offset.
    ## Returns parsed entries until the area end is reached or zero padding
    ## is encountered (indicating end of valid entries).
    let end_offset: Int = area_offset + area_size
    var entries: Array = []
    var off: Int = area_offset
    while off + 16 <= end_offset:
        let ino: Int = bytes_get(buf, off) | (bytes_get(buf, off + 1) << 8) | (bytes_get(buf, off + 2) << 16) | (bytes_get(buf, off + 3) << 24)
        let mode: Int = bytes_get(buf, off + 4) | (bytes_get(buf, off + 5) << 8) | (bytes_get(buf, off + 6) << 16) | (bytes_get(buf, off + 7) << 24)
        let sz: Int = bytes_get(buf, off + 8) | (bytes_get(buf, off + 9) << 8) | (bytes_get(buf, off + 10) << 16) | (bytes_get(buf, off + 11) << 24)
        let name_len: Int = bytes_get(buf, off + 12) | (bytes_get(buf, off + 13) << 8)
        let data_len: Int = bytes_get(buf, off + 14) | (bytes_get(buf, off + 15) << 8)
        let entry_off: Int = off + 16
        if entry_off + name_len + data_len > end_offset:
            break
        if ino == 0 and mode == 0 and sz == 0 and name_len == 0 and data_len == 0:
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
        entry["size"] = sz
        entry["name"] = bytes_to_string(name_bytes)
        entry["data"] = bytes_to_string(data_bytes)
        push(entries, entry)
        off = entry_off + name_len + data_len
    return entries
