import sys
import vfs as vfs_module
from checksum import ChecksumTree, checksum_block, crc32c, CHECKSUM_CRC32C

proc main(args: Array):
    if len(args) < 2:
        print "Usage: scrub_cli.sage <image>"
        return
    let image_path = args[1]
    let fs = vfs_module.VFS(image_path)
    if not fs.mount():
        print "Failed to mount image '" + image_path + "'"
        return
    if fs.sb == nil:
        print "No superblock found"
        return
    let block_size = fs.sb.block_size
    let total_blocks = fs.sb.total_blocks
    let csum_algo = fs.sb.checksum_algo
    let csum_tree = ChecksumTree(csum_algo)
    var scrubbed = 0
    var errors = 0
    print "Scrubbing '" + image_path + "'..."
    print "  Block size:   " + str(block_size)
    print "  Total blocks: " + str(total_blocks)
    let image_data = fs.image_buf
    for blk in range(total_blocks):
        let offset = blk * block_size
        var data = bytes()
        for i in range(block_size):
            if offset + i < bytes_len(image_data):
                bytes_push(data, bytes_get(image_data, offset + i))
            else:
                bytes_push(data, 0)
        let computed = checksum_block(data, csum_algo)
        let expected = csum_tree.lookup(blk)
        if expected != 0:
            csum_tree.record(blk, data)
            if computed != expected:
                errors = errors + 1
                if errors <= 10:
                    print "  ERROR: block " + str(blk) + " checksum mismatch (computed=" + str(computed) + " expected=" + str(expected) + ")"
        else:
            csum_tree.record(blk, data)
        scrubbed = scrubbed + 1
        if scrubbed % 2048 == 0:
            print "  Scrubbed " + str(scrubbed) + "/" + str(total_blocks) + " blocks..."
    print "Scrub completed for '" + image_path + "'"
    print "  Total blocks scrubbed: " + str(scrubbed)
    print "  Checksum errors found: " + str(errors)
    if errors == 0:
        print "  Status: filesystem is clean"
    else:
        print "  Status: " + str(errors) + " errors detected — run fsck for repair"
    fs.unmount()

main(sys.args())
