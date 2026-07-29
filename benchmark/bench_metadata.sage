## bench_metadata.sage — Metadata operation benchmark via VFS

import sys
import superblock
import imgio
import vfs

proc format_image(dev: String) -> Bool:
    let sb = superblock.create_superblock(65536, "BenchFS", 4096, 512, {"checksum_algo": superblock.CHECKSUM_CRC32C})
    return imgio.write_image(dev, sb.serialize())

proc main():
    print "Running Metadata Benchmark (create, stat, readdir, unlink)..."
    let dev: String = "/tmp/sagefs_bench_md.img"
    format_image(dev)
    let fs: vfs.VFS = vfs.VFS(dev)
    if not fs.mount():
        print "  mount failed"
        return
    let count: Int = 500
    var i: Int = 0
    let t0: Int = time()
    while i < count:
        let path: String = "/file_" + str(i)
        let fd: Int = fs.open(path, vfs.O_CREAT | vfs.O_RDWR)
        if fd >= 0:
            fs.close(fd)
        i = i + 1
    i = 0
    while i < count:
        let path: String = "/file_" + str(i)
        let st = fs.stat(path)
        i = i + 1
    let root_entries = fs.readdir("/")
    i = 0
    while i < count / 2:
        let path: String = "/file_" + str(i)
        fs.unlink(path)
        i = i + 1
    let t1: Int = time()
    let root_entries2 = fs.readdir("/")
    fs.unmount()
    let elapsed_ms: Int = t1 - t0
    if elapsed_ms <= 0:
        print "  elapsed: <1 ms"
    else:
        let total_ops: Int = count + count + (count / 2)
        let ops_per_s: Int = (total_ops * 1000) / elapsed_ms
        print "  creates : " + str(count)
        print "  stats   : " + str(count)
        print "  unlinks : " + str(count / 2)
        print "  elapsed : " + str(elapsed_ms) + " ms"
        print "  ops/sec : " + str(ops_per_s)

main()
