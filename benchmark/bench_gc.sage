## bench_gc.sage — Garbage collection benchmark via VFS
##
## Demonstrates write/delete cycles that would trigger GC.
## GC runs automatically during operations; this benchmark
## measures the overhead of creating and deleting many files.

import sys
import superblock
import imgio
import vfs

proc format_image(dev: String) -> Bool:
    let sb = superblock.create_superblock(131072, "BenchFS", 4096, 512, {"checksum_algo": superblock.CHECKSUM_CRC32C})
    return imgio.write_image(dev, sb.serialize())

proc main():
    print "Running GC Workload (write+delete cycle)..."
    let dev: String = "/tmp/sagefs_bench_gc.img"
    format_image(dev)
    let fs: vfs.VFS = vfs.VFS(dev)
    if not fs.mount():
        print "  mount failed"
        return
    let block_size: Int = 4096
    let files: Int = 200
    var block_data: Bytes = bytes(block_size)
    var i: Int = 0
    while i < block_size:
        bytes_set(block_data, i, 66)
        i = i + 1
    let t0: Int = time()
    i = 0
    while i < files:
        let path: String = "/gcfile_" + str(i)
        let fd: Int = fs.open(path, vfs.O_CREAT | vfs.O_RDWR)
        if fd >= 0:
            var j = 0
            while j < 5:
                fs.write(fd, block_data)
                j = j + 1
            fs.close(fd)
        i = i + 1
    i = 0
    while i < files / 2:
        let path: String = "/gcfile_" + str(i)
        fs.unlink(path)
        i = i + 1
    let t1: Int = time()
    fs.unmount()
    let elapsed_ms: Int = t1 - t0
    print "  files created : " + str(files)
    print "  files deleted : " + str(files / 2)
    print "  elapsed       : " + str(elapsed_ms) + " ms"
    print "  GC is triggered automatically by the allocator"
    print "  when segment utilization drops below threshold."

main()
