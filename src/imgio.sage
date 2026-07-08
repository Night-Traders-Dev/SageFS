## imgio.sage — SageFS on-disk image persistence.
##
## The SageLang runtime available in this environment does not implement
## binary file I/O (io.writebytes / io.readbytes return -1 / empty), and
## string I/O cannot represent byte values > 127.  To keep the filesystem
## fully testable we persist images as hexadecimal text via io.writefile /
## io.readfile.  All serialization logic still operates on real `Bytes`
## buffers (see superblock.sage); only the final persistence step is
## hex-encoded here.  Swapping to io.writebytes is a one-line change in
## write_image() once the toolchain supports binary I/O.

import io

proc hex_digit(v: Int) -> String:
    if v == 0:
        return "0"
    if v == 1:
        return "1"
    if v == 2:
        return "2"
    if v == 3:
        return "3"
    if v == 4:
        return "4"
    if v == 5:
        return "5"
    if v == 6:
        return "6"
    if v == 7:
        return "7"
    if v == 8:
        return "8"
    if v == 9:
        return "9"
    if v == 10:
        return "a"
    if v == 11:
        return "b"
    if v == 12:
        return "c"
    if v == 13:
        return "d"
    if v == 14:
        return "e"
    return "f"

proc to_hex2(b: Int) -> String:
    return hex_digit((b >> 4) & 0xF) + hex_digit(b & 0xF)

proc hex_val(c: String) -> Int:
    if c == "0":
        return 0
    if c == "1":
        return 1
    if c == "2":
        return 2
    if c == "3":
        return 3
    if c == "4":
        return 4
    if c == "5":
        return 5
    if c == "6":
        return 6
    if c == "7":
        return 7
    if c == "8":
        return 8
    if c == "9":
        return 9
    if c == "a" or c == "A":
        return 10
    if c == "b" or c == "B":
        return 11
    if c == "c" or c == "C":
        return 12
    if c == "d" or c == "D":
        return 13
    if c == "e" or c == "E":
        return 14
    if c == "f" or c == "F":
        return 15
    return 0

proc write_image(path: String, buf: Bytes) -> Bool:
    ## Persist a `Bytes` buffer as a hex-text image file.
    var hex = ""
    var i = 0
    while i < bytes_len(buf):
        hex = hex + to_hex2(bytes_get(buf, i))
        i = i + 1
    io.writefile(path, hex)
    return true

proc read_image(path: String) -> Bytes:
    ## Read a hex-text image file back into a `Bytes` buffer.
    let hex = io.readfile(path)
    let n = len(hex) / 2
    let buf = bytes()
    var i = 0
    while i < n:
        let hi = hex_val(hex[i * 2])
        let lo = hex_val(hex[(i * 2) + 1])
        bytes_push(buf, (hi << 4) | lo)
        i = i + 1
    return buf
