import sys
import imgio
from dedup import DedupEngine

proc main(args: Array):
    if len(args) < 2:
        print "Usage: dedup_cli.sage <image>"
        return
    let image_path = args[1]
    let image_data = imgio.read_image(image_path)
    if bytes_len(image_data) == 0:
        print "Error: cannot read image '" + image_path + "'"
        return
    let engine = DedupEngine()
    let block_size = 4096
    let total_blocks = int(bytes_len(image_data) / block_size)
    var scanned_blocks = 0
    var duplicate_blocks = 0
    var unique_blocks = 0
    for blk in range(total_blocks):
        let offset = blk * block_size
        var data = bytes()
        for i in range(block_size):
            if offset + i < bytes_len(image_data):
                bytes_push(data, bytes_get(image_data, offset + i))
            else:
                bytes_push(data, 0)
        let result = engine.check_inline(data)
        if result >= 0:
            duplicate_blocks = duplicate_blocks + 1
        else:
            unique_blocks = unique_blocks + 1
        scanned_blocks = scanned_blocks + 1
        if scanned_blocks % 1024 == 0:
            print "  Scanned " + str(scanned_blocks) + "/" + str(total_blocks) + " blocks..."
    let stats = engine.get_stats()
    let space_reclaimed = duplicate_blocks * block_size
    print "Dedup scan completed for '" + image_path + "'"
    print "  Total blocks scanned: " + str(scanned_blocks)
    print "  Unique blocks:        " + str(unique_blocks)
    print "  Duplicate blocks:     " + str(duplicate_blocks)
    print "  Space reclaimed:      " + str(space_reclaimed) + " bytes"
    print "  Stats:                hits=" + str(stats["hits"]) + " misses=" + str(stats["misses"]) + " deduped=" + str(stats["total_deduped"])

main(sys.args())
