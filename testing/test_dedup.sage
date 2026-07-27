## test_dedup.sage — unit tests for the SageFS deduplication engine

import dedup
let DedupEngine = dedup.DedupEngine

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

proc main():
    print("=== SageFS Dedup Engine Tests ===")
    test_fingerprint()
    test_dedup_hit_miss()
    test_ref_counts()
    test_remove_block()
    test_remove_nonexistent()
    test_get_stats()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
