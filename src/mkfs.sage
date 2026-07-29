## mkfs.sage — SageFS filesystem formatter (build entry point).
##
## This is the program sagemake compiles into the runnable `mkfs.sagefs`
## binary.  It imports the full filesystem component graph so the whole
## source tree is built, parses command-line arguments, formats a device /
## image, and verifies the result by reading it back.
##
## Usage:
##   mkfs.sagefs <device|image> [--size MB] [--label NAME]
##               [--block-size N] [--segment-size N] [--force]
##   mkfs.sagefs --check <image>        verify an existing image
##   mkfs.sagefs --help

## mkfs.sage — SageFS formatter (runtime entry point).
##
## This is the program sagemake wires into the runnable `mkfs.sagefs` binary.
## It imports the runtime-compatible core (superblock + image I/O) so it can
## execute through the `sage` bytecode runtime, which is the only execution
## path that forwards command-line arguments to sys.args().
##
## The FULL filesystem source tree (all components) is compiled separately by
## sagemake via src/all.sage, proving every module builds.
import sys
import io
import superblock
import imgio

proc usage() -> Int:
    print "SageFS mkfs — format a SageFS volume"
    print ""
    print "Usage:"
    print "  mkfs.sagefs <device|image> [options]   format a new volume"
    print "  mkfs.sagefs --check <image>            verify an existing image"
    print ""
    print "Options:"
    print "  --size MB          volume size in MiB (default 64)"
    print "  --label NAME       volume label (default 'SageFS')"
    print "  --block-size N     block size in bytes, power of two >= 4096 (default 4096)"
    print "  --segment-size N   blocks per segment (default 512)"
    print "  --force            overwrite an existing image"
    return 0

proc is_launcher_token(a: String) -> Bool:
    ## Drop Sage interpreter launcher tokens (sage, --runtime, the script
    ## path, etc.) so that only the program's own arguments remain.
    if a == "sage" or a == "sagevm":
        return true
    if a == "--runtime" or a == "--gc:arc" or a == "--gc:orc" or a == "--gc:tracing":
        return true
    if a == "--verbose" or a == "--math-work":
        return true
    if len(a) >= 5 and a[len(a) - 5:len(a)] == ".sage":
        return true
    if len(a) >= 5 and a[len(a) - 5:len(a)] == ".sgvm":
        return true
    if len(a) >= 4 and a[len(a) - 4:len(a)] == ".svm":
        return true
    return false

proc parse_args(args: Array) -> Dict:
    ## Strip Sage launcher tokens, then parse the program's own arguments.
    let prog_args = []
    var k = 0
    while k < len(args):
        ## Skip --runtime and --gc:* and -I paired flags (flag + value)
        if args[k] == "--runtime" or args[k] == "--gc:arc" or args[k] == "--gc:orc" or args[k] == "--gc:tracing" or args[k] == "-I":
            k = k + 2
            continue
        if not is_launcher_token(args[k]):
            push(prog_args, args[k])
        k = k + 1
    let opts = {}
    opts["device"] = ""
    opts["size_mb"] = 64
    opts["label"] = "SageFS"
    opts["block_size"] = 4096
    opts["segment_size"] = 512
    opts["force"] = false
    opts["check"] = false
    var i = 0
    while i < len(prog_args):
        let a = prog_args[i]
        if a == "--help" or a == "-h":
            usage()
            opts["device"] = "__help__"
            return opts
        if a == "--check":
            opts["check"] = true
        elif a == "--size":
            i = i + 1
            opts["size_mb"] = tonumber(prog_args[i])
        elif a == "--label":
            i = i + 1
            opts["label"] = prog_args[i]
        elif a == "--block-size":
            i = i + 1
            opts["block_size"] = tonumber(prog_args[i])
        elif a == "--segment-size":
            i = i + 1
            opts["segment_size"] = tonumber(prog_args[i])
        elif a == "--force":
            opts["force"] = true
        elif a == "__help__":
            ## no-op
        else:
            ## First non-flag token is the device / image path.
            if opts["device"] == "":
                opts["device"] = a
        i = i + 1
    return opts

proc format_device(dev: String, opts: Dict) -> Bool:
    let block_size = opts["block_size"]
    let segment_size = opts["segment_size"]
    let size_bytes = opts["size_mb"] * 1024 * 1024
    let total_blocks = size_bytes / block_size

    if total_blocks / segment_size < 64:
        print "error: volume too small — need at least 64 segments"
        print "       (current: " + str(total_blocks / segment_size) + " segments)"
        return false

    print "Formatting " + dev + " as SageFS..."
    let sb = superblock.create_superblock(total_blocks, opts["label"], block_size, segment_size, {"checksum_algo": superblock.CHECKSUM_CRC32C})
    let buf = sb.serialize()

    let readme: String = ""
    readme = readme + "SageFS Filesystem\n"
    readme = readme + "=================\n"
    readme = readme + "Label:           " + opts["label"] + "\n"
    readme = readme + "Block Size:      " + str(block_size) + "\n"
    readme = readme + "Segment Size:    " + str(segment_size) + "\n"
    readme = readme + "Total Blocks:    " + str(total_blocks) + "\n"
    readme = readme + "Free Segments:   " + str(sb.free_segments) + "\n"
    readme = readme + "Root Inode:      " + str(sb.root_inode) + "\n"

    let S_IFREG: Int = 0x8000
    ## Write initial README.txt inode entry to the inode area
    let bs = sb.block_size
    let inode_area_offset = sb.inode_entry_start_blk * bs
    var i = bytes_len(buf)
    while i < inode_area_offset + 200:
        bytes_push(buf, 0)
        i = i + 1
    imgio.write_inode_entry_at(buf, inode_area_offset, 2, S_IFREG | 0x1A4, len(readme), "README.txt", readme)

    let min_image_size = sb.inode_entry_start_blk * sb.block_size + sb.inode_entry_byte_size
    if bytes_len(buf) > min_image_size:
        sb.image_size = bytes_len(buf)
    else:
        sb.image_size = min_image_size

    ## Pad buf to image_size with zeros
    var i2 = bytes_len(buf)
    while i2 < sb.image_size:
        bytes_push(buf, 0)
        i2 = i2 + 1

    let sb_bytes = sb.serialize()
    var j = 0
    while j < bytes_len(sb_bytes):
        bytes_set(buf, j, bytes_get(sb_bytes, j))
        j = j + 1

    if io.filesize(dev) > 0 and not opts["force"]:
        print "error: " + dev + " already exists (use --force to overwrite)"
        return false

    imgio.write_image(dev, buf)

    print "  label        : " + sb.label
    print "  uuid         : " + sb.uuid
    print "  block_size   : " + str(block_size) + " bytes"
    print "  segment_size : " + str(segment_size) + " blocks"
    print "  total_blocks : " + str(total_blocks)
    print "  free_segments: " + str(sb.free_segments)
    verify_image(dev)
    return true

proc verify_image(dev: String) -> Bool:
    let is_bdev = imgio._is_block_device(dev)
    var buf: Bytes = bytes()
    if is_bdev:
        let header = imgio.read_image_exact(dev, superblock.SUPERBLOCK_HEADER_SIZE)
        if bytes_len(header) < 428:
            print "verify: FAIL (image too small: " + str(bytes_len(header)) + " bytes)"
            return false
        let sb = superblock.deserialize_superblock(header)
        let needed = sb.image_size
        if needed < superblock.SUPERBLOCK_HEADER_SIZE:
            needed = superblock.SUPERBLOCK_HEADER_SIZE
        buf = imgio.read_image_exact(dev, needed)
    else:
        buf = imgio.read_image(dev)
    if bytes_len(buf) < 428:
        print "verify: FAIL (image too small: " + str(bytes_len(buf)) + " bytes)"
        return false
    let m0 = bytes_get(buf, 0)
    let m1 = bytes_get(buf, 1)
    let m2 = bytes_get(buf, 2)
    let m3 = bytes_get(buf, 3)
    if not (m0 == 69 and m1 == 71 and m2 == 65 and m3 == 83):
        print "verify: FAIL (bad magic: " + str(m0) + " " + str(m1) + " " + str(m2) + " " + str(m3) + ")"
        return false
    print "verify: OK (superblock magic SAGEFS, " + str(bytes_len(buf)) + " bytes)"
    return true

proc main(args: Array):
    let opts = parse_args(args)
    if opts["device"] == "":
        usage()
        return
    if opts["device"] == "__help__":
        return
    if opts["check"]:
        verify_image(opts["device"])
        return
    format_device(opts["device"], opts)

main(sys.args())
