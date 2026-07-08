## imgio.sage — SageFS binary image persistence.

import io

proc write_image(path: String, buf: Bytes) -> Bool:
    io.writebytes(path, buf)
    return true

proc read_image(path: String) -> Bytes:
    return io.readbytes(path)

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
