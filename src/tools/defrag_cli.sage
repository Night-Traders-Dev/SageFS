import sys
import cli_args
import vfs as vfs_module
from extent import ExtentTree, Extent

proc main(args: Array):
    ## Two positional arguments, so two are required and they start at 0.
    ## This asked for three and read from index 1, so it refused to run unless
    ## given an extra argument and then defragmented the wrong one.
    if len(args) < 2:
        print "Usage: defrag_cli.sage <image> <inode>"
        return
    let image_path = args[0]
    let ino = tonumber(args[1])
    if ino < 0:
        print "Invalid inode number"
        return
    let fs = vfs_module.VFS(image_path, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
    if not fs.mount():
        print "Failed to mount image '" + image_path + "'"
        return
    let extents = fs.extent._collect_extents(ino)
    let count = len(extents)
    if count == 0:
        print "No extents found for inode " + str(ino)
        fs.unmount()
        return
    var total_length = 0
    var min_extent = extents[0].length
    var max_extent = extents[0].length
    for ext in extents:
        total_length = total_length + ext.length
        if ext.length < min_extent:
            min_extent = ext.length
        if ext.length > max_extent:
            max_extent = ext.length
    let avg_extent = int(total_length / count)
    let frag_ratio = int((count * 100) / (total_length / 64 + 1))
    print "Inode " + str(ino) + " fragmentation report:"
    print "  Extent count:       " + str(count)
    print "  Total blocks:       " + str(total_length)
    print "  Average extent:     " + str(avg_extent) + " blocks"
    print "  Min extent:         " + str(min_extent) + " blocks"
    print "  Max extent:         " + str(max_extent) + " blocks"
    print "  Fragmentation:      " + str(frag_ratio) + "%"
    if frag_ratio > 50:
        print "  Status:             heavily fragmented, defrag recommended"
    elif frag_ratio > 20:
        print "  Status:             moderately fragmented"
    else:
        print "  Status:             healthy"
    if count > 1:
        print "  Note: defragmentation (merging extents) is handled by"
        print "  ExtentTree.insert_extent() when new extents are allocated."
    else:
        print "  No defragmentation needed (single extent)"
    fs.unmount()

main(cli_args.program_args(sys.args()))
