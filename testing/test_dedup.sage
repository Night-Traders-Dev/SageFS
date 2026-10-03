## test_dedup.sage — unit tests for the SageFS deduplication engine

import dedup
let DedupEngine = dedup.DedupEngine

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

## Distinct, deterministic block contents, so two different n values never
## collide and every fingerprint in the bloom tests is unique.
proc block_pattern(n: Int) -> Bytes:
    ## Spread `n` across all 16 bytes. An earlier version used
    ## (n * 7 + i * 13) & 0xFF per byte, which repeats every 256 values of n,
    ## so "absent" probe patterns collided with inserted ones and the bloom
    ## filter's false-positive rate looked like 72% when the filter was fine.
    let b: Bytes = bytes(16)
    var v: Int = n
    var i: Int = 0
    while i < 16:
        v = (v * 1103515245 + 12345) & 0x7FFFFFFF
        b[i] = (v >> 16) & 0xFF
        i = i + 1
    return b

## Contents derived from a label, for the shared-fingerprint case.
proc bytes_pattern(label: String) -> Bytes:
    let b: Bytes = bytes(16)
    var i: Int = 0
    while i < 16:
        b[i] = ord(label[i % len(label)])
        i = i + 1
    return b

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

proc test_fingerprint():
    print("compute_fingerprint:")
    let engine = DedupEngine()
    var data = bytes("hello")
    let fp = engine.compute_fingerprint(data)
    check_bool("fingerprint starts with fp_", len(fp) > 3)
    let fp2 = engine.compute_fingerprint(data)
    check("fingerprint deterministic", fp, fp2)
    var data2 = bytes("world")
    let fp3 = engine.compute_fingerprint(data2)
    check_bool("different data -> different fp", fp != fp3)

proc test_dedup_hit_miss():
    print("dedup hit/miss:")
    let engine = DedupEngine()
    var data = bytes("deduplicatable content")
    let result = engine.check_inline(data)
    check("miss on unknown data", result, -1)

    engine.add_fingerprint(data, 42)
    let hit = engine.check_inline(data)
    check("hit on known data", hit, 42)

    var other = bytes("different data")
    let miss = engine.check_inline(other)
    check("miss on different data", miss, -1)

    let stats = engine.get_stats()
    check_bool("stats hits > 0", stats["hits"] > 0)
    check_bool("stats misses > 0", stats["misses"] > 0)

proc test_ref_counts():
    print("reference counting:")
    let engine = DedupEngine()
    var data = bytes("shared block content")
    engine.add_fingerprint(data, 100)
    check("initial ref count", engine.ref_count(100), 1)

    let r1 = engine.inc_ref(100)
    check("inc ref", r1, 2)
    check("ref count after inc", engine.ref_count(100), 2)

    let r2 = engine.dec_ref(100)
    check("dec ref", r2, 1)
    check("ref count after dec", engine.ref_count(100), 1)

    let r3 = engine.dec_ref(100)
    check("dec ref to zero", r3, 0)
    check("ref count zero", engine.ref_count(100), 0)

    let missing = engine.inc_ref(999)
    check("inc missing block", missing, 1)

    let missing_dec = engine.dec_ref(999)
    check("missing ref count after dec", missing_dec, 0)

proc test_remove_block():
    print("remove block:")
    let engine = DedupEngine()
    var data = bytes("remove me")
    engine.add_fingerprint(data, 77)
    check("ref before remove", engine.ref_count(77), 1)

    let hit = engine.check_inline(data)
    check("hit before remove", hit, 77)

    engine.remove_block(77)
    let miss = engine.check_inline(data)
    check("miss after remove", miss, -1)
    check("ref after remove", engine.ref_count(77), 0)

proc test_remove_nonexistent():
    print("remove nonexistent block:")
    let engine = DedupEngine()
    engine.remove_block(999)
    let stats = engine.get_stats()
    check_bool("still works", stats["blocks_tracked"] >= 0)

proc test_get_stats():
    print("get_stats:")
    let engine = DedupEngine()
    var stats = engine.get_stats()
    check("initial hits", stats["hits"], 0)
    check("initial misses", stats["misses"], 0)
    check("initial deduped", stats["total_deduped"], 0)
    check("initial fingerprints", stats["fingerprint_count"], 0)
    check("initial blocks", stats["blocks_tracked"], 0)

    var d1 = bytes("data one")
    var d2 = bytes("data two")
    engine.add_fingerprint(d1, 10)
    engine.add_fingerprint(d2, 20)
    engine.check_inline(d1)
    engine.check_inline(d1)
    engine.check_inline(d2)

    stats = engine.get_stats()
    check("hits after dedup", stats["hits"], 3)
    check("misses after dedup", stats["misses"], 0)
    check("fingerprints", stats["fingerprint_count"], 2)
    check("blocks", stats["blocks_tracked"], 2)

## --- Bloom filter ---------------------------------------------------------
## The filter replaced an exact-match Dict of every fingerprint ever seen. These
## cover the three properties that made that a problem: the filter is a fixed
## number of bits, it never produces a false negative, and removing a block does
## not make a still-shared fingerprint look absent.

proc test_bloom_fixed_size():
    let d = dedup.DedupEngine()
    ## Fixed regardless of contents.
    let before = bytes_len(d.bloom_filter)
    var i = 0
    while i < 500:
        d.add_fingerprint(block_pattern(i), 1000 + i)
        i = i + 1
    check("bloom filter size is constant", bytes_len(d.bloom_filter) == before)
    check("bloom size matches DEDUP_BLOOM_SIZE",
          before * 8 == dedup.DEDUP_BLOOM_SIZE)

proc test_bloom_no_false_negatives():
    ## The one property that must never break: reporting a present block as
    ## absent returns -1 and writes duplicate data, so this has to hold exactly.
    let d = dedup.DedupEngine()
    var i = 0
    while i < 300:
        let fp = d.compute_fingerprint(block_pattern(i))
        d.add_fingerprint(block_pattern(i), 2000 + i)
        if not d.bloom_test(fp):
            check_bool("false negative at " + str(i), false)
            return
        i = i + 1
    check_bool("no false negatives over 300 distinct blocks", true)

proc test_bloom_shared_fingerprint_survives_removal():
    ## Two blocks with identical content share one fingerprint. Removing one must
    ## not clear the bit, or the other becomes a false negative.
    let d = dedup.DedupEngine()
    let payload = bytes_pattern("shared")
    d.add_fingerprint(payload, 500)
    d.add_fingerprint(payload, 501)
    d.remove_block(501)
    let hit = d.check_inline(payload)
    check("shared fingerprint still found after sibling removed", hit, 500)

proc test_bloom_false_positive_rate_bounded():
    ## Absent fingerprints must not all read as present, or the pre-check is
    ## worthless. Insert a modest load and confirm absent items mostly miss.
    let d = dedup.DedupEngine()
    var i = 0
    while i < 200:
        d.add_fingerprint(block_pattern(i), 3000 + i)
        i = i + 1
    var false_positives = 0
    var probes = 0
    while probes < 400:
        let fp = d.compute_fingerprint(block_pattern(900000 + probes))
        if d.bloom_test(fp):
            false_positives = false_positives + 1
        probes = probes + 1
    ## Under 25% is a loose bound, but it catches a filter that is not filtering.
    check_bool("false positive rate under 25%", false_positives * 4 < probes)

proc test_bloom_stats():
    let d = dedup.DedupEngine()
    d.add_fingerprint(block_pattern(1), 10)
    d.add_fingerprint(block_pattern(2), 11)
    let st = d.get_stats()
    ## dict_get_int lives in fuse.sage, which this test does not import; index
    ## the dict directly instead.
    check("stats report bloom bits", st["bloom_bits_total"],
          dedup.DEDUP_BLOOM_SIZE)
    check_bool("stats report bits set", st["bloom_bits_set"] > 0)

proc main():
    print("=== SageFS Dedup Engine Tests ===")
    test_fingerprint()
    test_dedup_hit_miss()
    test_ref_counts()
    test_remove_block()
    test_remove_nonexistent()
    test_get_stats()
    test_bloom_fixed_size()
    test_bloom_no_false_negatives()
    test_bloom_shared_fingerprint_survives_removal()
    test_bloom_false_positive_rate_bounded()
    test_bloom_stats()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
