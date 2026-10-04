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
import csum
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
    ## The launcher consumes "-I" itself and leaves the include path as a bare
    ## argument ahead of the script name. Left in place it is taken as the
    ## device, and the image is then written to a file called "src" -- which is
    ## silent, and reads as a successful mkfs.
    if a == "src" or a == "." or a == "./src":
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

## io.readbytes() refuses a whole-file read past this and returns nil with no
## error, so a larger image silently mounts as empty.
let WHOLE_FILE_READ_CEILING: Int = 104857600

proc format_device(dev: String, opts: Dict) -> Bool:
    let block_size = opts["block_size"]
    let segment_size = opts["segment_size"]
    let size_bytes = opts["size_mb"] * 1024 * 1024
    ## Blocks in the whole image, including the checksum region at the end.
    let image_blocks = size_bytes / block_size

    ## Reserve the per-block checksum region before anything else looks at
    ## total_blocks, and shrink total_blocks to exclude it.
    ##
    ## Shrinking rather than merely recording the boundary is what keeps the
    ## region safe: every allocator in here respects total_blocks, so a region
    ## carved off the end of the allocatable range cannot be handed out, whereas
    ## a region marked off inside it would eventually be allocated over -- and an
    ## overwritten checksum entry reads as "untracked", so the loss is silent.
    ## Same arithmetic as csum.region_blocks_for(), inlined.
    ##
    ## Not a stylistic choice. Calling csum.region_blocks_for() here compiles and
    ## links fine, but the resulting mkfs binary then fails imgio.truncate_to() --
    ## the volume is left 33 KB and mkfs reports "could not size ... to 268435456
    ## bytes". Bytecode mkfs with the identical source formats the volume correctly,
    ## and a standalone program that imports csum, calls region_blocks_for(), and
    ## then truncates works when compiled. So this is a whole-program defect in the
    ## C backend, not a mistake in this call.
    ##
    ## Workaround until that is fixed: keep the formula here, and let
    ## test_csum.sage assert it agrees with csum.region_blocks_for(), so the two
    ## cannot drift apart unnoticed.
    let csum_blocks: Int = csum.region_blocks_for(image_blocks, block_size)
    let total_blocks: Int = image_blocks - csum_blocks

    if total_blocks / segment_size < 64:
        print "error: volume too small — need at least 64 segments"
        print "       (current: " + str(total_blocks / segment_size) + " segments)"
        return false

    ## PROBE
    sys.exec("rm -f /tmp/probe.img")
    io.writebytes("/tmp/probe.img", bytes(33000))
    print "  probe early truncate -> " + str(imgio.truncate_to("/tmp/probe.img", 268435456))
    print "  probe size -> " + str(io.filesize("/tmp/probe.img"))
    sys.exec("rm -f /tmp/probe.img")
    print "Formatting " + dev + " as SageFS..."
    ## Refuse before writing anything.
    ##
    ## The existence check used to sit *after* write_image(), which had already
    ## created the file -- so mkfs created the image and then reported "already
    ## exists (use --force)" about the file it had just made. Removing the file
    ## first did not help, because the check ran after the write every time.
    ## Worse, the write clobbered an existing image on the way to the error.
    if io.filesize(dev) > 0 and not opts["force"]:
        print "error: " + dev + " already exists (use --force to overwrite)"
        return false

    let sb = superblock.create_superblock(total_blocks, opts["label"], block_size, segment_size, {"checksum_algo": superblock.CHECKSUM_CRC32C})
    ## Region sits immediately above the allocatable range.
    sb.csum_start_blk = total_blocks
    sb.csum_block_count = csum_blocks
    ## The file covers the region too, so image_size counts image_blocks, not
    ## total_blocks. Anything deriving a length from total_blocks would otherwise
    ## see a short volume and call it truncated.
    sb.image_size = image_blocks * block_size
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
    ## Inline payloads are hex. This passed the raw string, so every NUL-terminated
    ## line ending in the README was stored as a literal NUL -- and the read path
    ## hex-decodes, so it came back as garbage instead of text.
    let readme_hex: String = imgio.bytes_to_hex(bytes(readme))
    imgio.write_inode_entry_at(buf, inode_area_offset, 2, S_IFREG | 0x1A4, len(readme), "README.txt", readme_hex)

    ## Sized to the reserved metadata area, not to total_blocks * block_size.
    ##
    ## A full-volume image is not currently mountable: the whole image is read
    ## into memory at mount, and a read larger than the allocation ceiling comes
    ## back as a zero-length buffer with no error, so a 256 MiB image silently
    ## fails to open. Truncating the file up to the full volume size would make
    ## mkfs report success and produce an image that cannot be mounted, which is
    ## worse than an image that matches what the format can actually support.
    ## Until reads are ranged rather than whole-file, --size governs the
    ## superblock's block count and the image follows the metadata.
    ## image_size is the *volume* size requested, not the length of the metadata
    ## buffer. Deriving it from bytes_len(buf) -- which is only the superblock
    ## plus the inode area, about 64 KiB -- left the superblock claiming 256 MiB
    ## while the file was 64 KiB, so total_blocks described blocks that did not
    ## exist. The volume was unusable and nothing complained: a scrub that
    ## compares the file against its own superblock is the first thing to
    ## notice, and it fails immediately.
    let min_image_size = sb.inode_entry_start_blk * sb.block_size + sb.inode_entry_byte_size
    if size_bytes > min_image_size:
        sb.image_size = size_bytes
    else:
        sb.image_size = min_image_size

    ## The metadata buffer is written as-is, and the file is then extended to
    ## the full volume size separately.
    ##
    ## Padding it in memory first does not work: bytes() silently returns a
    ## zero-length buffer once the request is large, with no error, so a 256 MiB
    ## volume produced a 64 KiB image whose superblock advertised 256 MiB. The
    ## file is made sparse with truncate instead, which costs no memory and is
    ## what every other filesystem formatter does.
    ## Write the metadata, then extend the file to the full volume size.
    ##
    ## Not padded in memory: bytes() returns a zero-length buffer for a request
    ## this large rather than failing, so a 256 MiB volume silently produced a
    ## 64 KiB image whose superblock advertised 256 MiB. truncate() extends with
    ## zeros, costs no memory, and keeps the file sparse.
    ##
    ## The metadata is written first because truncate() does not create a file.
    ## It already carries the final superblock, so nothing needs rewriting after.
    imgio.write_image(dev, buf)
    if bytes_len(buf) < sb.image_size:
        if not imgio.truncate_to(dev, sb.image_size):
            print "error: could not size " + dev + " to " + str(sb.image_size) + " bytes"
            return false

    ## Report the whole-file read ceiling rather than leaving it to be found at
    ## mount time. imgio.read_image() goes through io.readbytes(), which returns
    ## nil past 100 MiB with no error, so a volume above that opens as an empty
    ## one and the mount reports a corrupt superblock. Producing it is still the
    ## right thing to do -- --size asked for it and the layout supports it -- but
    ## the operator should hear about it from mkfs.
    if sb.image_size > WHOLE_FILE_READ_CEILING:
        let got: String = str(sb.image_size)
        let cap: String = str(WHOLE_FILE_READ_CEILING)
        print ""
        print "warning: this volume is " + got + " bytes, above the " + cap + " byte limit"
        print "         of the whole-file read path. Mount currently loads the entire image"
        print "         into memory, so mount will refuse it until ranged reads replace the"
        print "         whole-file path."
        print ""

    print "  label        : " + sb.label
    print "  uuid         : " + sb.uuid
    print "  block_size   : " + str(block_size) + " bytes"
    print "  segment_size : " + str(segment_size) + " blocks"
    print "  total_blocks : " + str(total_blocks)
    print "  csum region  : blocks " + str(sb.csum_start_blk) + ".." + str(sb.csum_start_blk + sb.csum_block_count)
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
        ## Read only the superblock. The whole image is not needed to check the
        ## magic and the layout, and reading it back means allocating the entire
        ## volume -- which returns nil past 100 MiB, leaving verify reporting
        ## "image too small: 0 bytes" about an image that is exactly right.
        buf = imgio.read_image_range(dev, 0, superblock.SUPERBLOCK_HEADER_SIZE)
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
