## test_compress.sage — unit tests for the SageFS compression engine

import compress
let CompressionEngine = compress.CompressionEngine
let COMPRESS_NONE = compress.COMPRESS_NONE
let COMPRESS_LZ4 = compress.COMPRESS_LZ4
let COMPRESS_ZSTD = compress.COMPRESS_ZSTD

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check(name: String, got: Int, expected: Int):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc check_bool(name: String, got: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if got:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name)

proc check_str(name: String, got: String, expected: String):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + got + " expected=" + expected)

proc test_select_algo():
    print("select_algorithm:")
    let engine = CompressionEngine()
    check("hot algo", engine.select_algorithm("hot"), COMPRESS_LZ4)
    check("cold algo", engine.select_algorithm("cold"), COMPRESS_ZSTD)
    check("default algo", engine.select_algorithm("warm"), COMPRESS_LZ4)

proc test_compress_none():
    print("compress with NONE:")
    let engine = CompressionEngine()
    var data = bytes("hello world this is test data")
    let result = engine.compress(data, COMPRESS_NONE)
    check("none: same length", bytes_len(result), bytes_len(data))
    check("none: same content", bytes_get(result, 0), bytes_get(data, 0))

proc test_small_data_returns_original():
    print("small data (<64 bytes) returns original:")
    let engine = CompressionEngine()
    var small = bytes("small")
    let result = engine.compress(small, COMPRESS_LZ4)
    check("small: same length", bytes_len(result), bytes_len(small))
    check("small: same first byte", bytes_get(result, 0), bytes_get(small, 0))

proc test_compress_decompress_lz4():
    print("compress/decompress roundtrip LZ4:")
    let engine = CompressionEngine()
    let original = bytes("This is a test string for LZ4 compression roundtrip verification in SageFS")
    let compressed = engine.compress(original, COMPRESS_LZ4)
    check_bool("compressed longer due to header", bytes_len(compressed) > bytes_len(original))
    let decompressed = engine.decompress(compressed)
    check_bool("decompressed length matches", bytes_len(decompressed) == bytes_len(original))
    var is_match = true
    for i in range(bytes_len(original)):
        if bytes_get(decompressed, i) != bytes_get(original, i):
            is_match = false
    check_bool("decompressed matches original", is_match)

proc test_compress_decompress_zstd():
    print("compress/decompress roundtrip ZSTD:")
    let engine = CompressionEngine()
    let original = bytes("ZSTD compression test with some repetitive data that should compress nicely")
    let compressed = engine.compress(original, COMPRESS_ZSTD)
    check_bool("zstd compressed", bytes_len(compressed) > bytes_len(original))
    let decompressed = engine.decompress(compressed)
    var zstd_match = true
    for i in range(bytes_len(original)):
        if bytes_get(decompressed, i) != bytes_get(original, i):
            zstd_match = false
    check_bool("zstd roundtrip ok", zstd_match)

proc test_is_incompressible():
    print("is_incompressible:")
    let engine = CompressionEngine()
    check_bool("size zero is incompressible", engine.is_incompressible(0, 0))
    check_bool("ratio > 0.95 is incompressible", engine.is_incompressible(100, 99))
    check_bool("ratio 0.5 is compressible", engine.is_incompressible(100, 50) == false)

proc test_stats():
    print("stats tracking:")
    let engine = CompressionEngine()
    var stats = engine.get_stats()
    check("initial original_bytes", stats["original_bytes"], 0)
    check("initial compressed_bytes", stats["compressed_bytes"], 0)

    var d1 = bytes()
    for i in range(200):
        bytes_push(d1, 97)
    engine.compress(d1, COMPRESS_LZ4)
    stats = engine.get_stats()
    check_bool("stats original > 0", stats["original_bytes"] > 0)
    check_bool("stats compressed > 0", stats["compressed_bytes"] > 0)
    check_bool("stats ratio valid", stats["ratio"] > 0.0)

proc test_decompress_uncompressed_data():
    print("decompress uncompressed data:")
    let engine = CompressionEngine()
    var data = bytes("plain data")
    let result = engine.decompress(data)
    check("uncompressed passthrough len", bytes_len(result), bytes_len(data))

proc main():
    print("=== SageFS Compression Engine Tests ===")
    test_select_algo()
    test_compress_none()
    test_small_data_returns_original()
    test_compress_decompress_lz4()
    test_compress_decompress_zstd()
    test_is_incompressible()
    test_stats()
    test_decompress_uncompressed_data()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
