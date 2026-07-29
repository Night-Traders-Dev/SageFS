## bench_compress.sage — Compression benchmark via CompressionEngine

import sys
import compress

proc main():
    print "Running Compression Benchmark..."
    let engine = compress.CompressionEngine()

    let count: Int = 10000
    let data_size: Int = 4096
    var data: Bytes = bytes(data_size)
    var i: Int = 0
    while i < data_size:
        bytes_set(data, i, 65 + (i % 26))
        i = i + 1

    let t0: Int = time()
    i = 0
    while i < count:
        let compressed = engine.compress(data, compress.COMPRESS_LZ4)
        let _ = engine.decompress(compressed)
        i = i + 1
    let t1: Int = time()

    let elapsed_ms: Int = t1 - t0
    let stats = engine.get_stats()
    print "  count           : " + str(count)
    print "  data_size       : " + str(data_size) + " bytes"
    print "  elapsed         : " + str(elapsed_ms) + " ms"
    if elapsed_ms > 0:
        let ops_per_s: Int = (count * 1000) / elapsed_ms
        print "  compress+decompress: " + str(ops_per_s) + " ops/s"
    print "  ratio           : " + str(stats["ratio"])

main()
