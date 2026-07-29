## bench_seq_read.sage — Sequential read benchmark via VFS

import sys
import superblock
import imgio
import vfs

proc format_image(dev: String) -> Bool:
    let sb = superblock.create_superblock(65536, "BenchFS", 4096, 512, {"checksum_algo": superblock.CHECKSUM_CRC32C})
    return imgio.write_image(dev, sb.serialize())

proc main():
    print "Running Sequential Read Benchmark..."
    let dev: String = "/tmp/sagefs_bench_sr.img"
    format_image(dev)
    let fs: vfs.VFS = vfs.VFS(dev)
    if not fs.mount():
        print "  mount failed"
        return
    let fd: Int = fs.open("/benchfile", vfs.O_CREAT | vfs.O_RDWR)
    if fd < 0:
        print "  open (create) failed"
        return
    let block_size: Int = 4096
    let total_mb: Int = 8
    let blocks: Int = total_mb * 1024 * 1024 / block_size
    var block_data: Bytes = bytes(block_size)
    var i: Int = 0
    while i < block_size:
        bytes_set(block_data, i, 65 + (i % 26))
        i = i + 1
    i = 0
    while i < blocks:
        let w = fs.write(fd, block_data)
        i = i + 1
    fs.close(fd)
    let fd2: Int = fs.open("/benchfile", vfs.O_RDONLY)
    if fd2 < 0:
        print "  open (read) failed"
        return
    let t0: Int = time()
    var total_bytes: Int = 0
    i = 0
    while i < blocks:
        let data: Bytes = fs.read(fd2, block_size)
        total_bytes = total_bytes + bytes_len(data)
        i = i + 1
    let t1: Int = time()
    fs.close(fd2)
    fs.unmount()
    let elapsed_ms: Int = t1 - t0
    if elapsed_ms <= 0:
        print "  elapsed: <1 ms"
    else:
        let mb_per_s: Int = (total_bytes * 1000) / (elapsed_ms * 1024 * 1024)
        print "  blocks : " + str(blocks)
        print "  total  : " + str(total_mb) + " MB"
        print "  elapsed: " + str(elapsed_ms) + " ms"
        print "  read   : " + str(mb_per_s) + " MB/s"

main()
