import sys
import std.testing
import compress

proc test_compress():
    let engine = compress.CompressionEngine()
    
    let algo = engine.select_algorithm("hot")
    assert.equal(algo, "lz4", "Hot data should use lz4")
    
    let cold_algo = engine.select_algorithm("cold")
    assert.equal(cold_algo, "zstd", "Cold data should use zstd")

proc main():
    test_compress()
    print "All compress tests passed!"

main()
