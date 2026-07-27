import sys
import segment
import gc as gc_module

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check_int(name: String, got: Int, expected: Int):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc check_bool(name: String, got: Bool, expected: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc test_gc_init():
    let sm = segment.SegmentManager(100, 4096, 1000)
    let collector = gc_module.GarbageCollector(sm, nil)
    check_int("foreground_runs init", collector.foreground_runs, 0)
    check_int("background_runs init", collector.background_runs, 0)
    check_int("blocks_moved init", collector.blocks_moved, 0)
    check_int("segments_freed init", collector.segments_freed, 0)

proc make_dirty_segment(sm, seg_type: String) -> Int:
    sm.allocate_segment(seg_type)
    let segno = sm.current_segments[seg_type]
    sm.allocate_block(seg_type)
    sm.allocate_block(seg_type)
    sm.allocate_block(seg_type)
    sm.invalidate_block(segno, 0)
    sm.allocate_segment(seg_type)
    return segno

proc test_select_victim_greedy():
    let sm = segment.SegmentManager(100, 4096, 1000)
    let collector = gc_module.GarbageCollector(sm, nil)

    let victim = collector.select_victim("greedy")
    check_int("no dirty segs greedy", victim, -1)

    let segno = make_dirty_segment(sm, "data_warm")

    let victim2 = collector.select_victim("greedy")
    check_bool("found dirty victim greedy", victim2 >= 0, true)

proc test_select_victim_cost_benefit():
    let sm = segment.SegmentManager(100, 4096, 1000)
    let collector = gc_module.GarbageCollector(sm, nil)

    let victim = collector.select_victim("cost-benefit")
    check_int("no dirty segs cb", victim, -1)

    let segno = make_dirty_segment(sm, "data_cold")

    let entry = sm.get_entry(segno)
    entry.age = 100

    let victim2 = collector.select_victim("cost-benefit")
    check_bool("found dirty victim cb", victim2 >= 0, true)

proc test_do_gc():
    let sm = segment.SegmentManager(100, 4096, 1000)
    let collector = gc_module.GarbageCollector(sm, nil)

    sm.allocate_segment("data_warm")
    let segno = sm.current_segments["data_warm"]

    sm.allocate_block("data_warm")
    sm.allocate_block("data_warm")

    let entry = sm.get_entry(segno)
    check_int("segment has 2 valid", entry.valid_blocks, 2)

    let orig_free = sm.free_segment_count()

    let result = collector.do_gc(segno)
    check_bool("gc succeeded", result, true)
    check_int("segments_freed", collector.segments_freed, 1)
    check_int("blocks_moved", collector.blocks_moved, 2)
    check_int("free count inc", sm.free_segment_count(), orig_free + 1)

    let result2 = collector.do_gc(-1)
    check_bool("neg segno", result2, false)

proc test_run_foreground():
    let sm = segment.SegmentManager(100, 4096, 1000)
    let collector = gc_module.GarbageCollector(sm, nil)

    let idle = collector.run_foreground()
    check_bool("foreground idle @ 100% free", idle, false)
    check_int("foreground_runs stays 0", collector.foreground_runs, 0)

proc test_run_background():
    let sm = segment.SegmentManager(100, 4096, 1000)
    let collector = gc_module.GarbageCollector(sm, nil)

    let idle = collector.run_background()
    check_bool("background idle @ 100% free", idle, false)

proc test_needs_gc():
    let sm = segment.SegmentManager(100, 4096, 1000)
    let collector = gc_module.GarbageCollector(sm, nil)

    let needed = collector.needs_gc()
    check_bool("no gc needed @ 100% free", needed, false)

proc test_needs_urgent_gc():
    let sm = segment.SegmentManager(100, 4096, 1000)
    let collector = gc_module.GarbageCollector(sm, nil)

    let urgent = collector.needs_urgent_gc()
    check_bool("no urgent gc @ 100% free", urgent, false)

proc test_get_stats():
    let sm = segment.SegmentManager(100, 4096, 1000)
    let collector = gc_module.GarbageCollector(sm, nil)

    let stats = collector.get_stats()
    check_int("stats foreground_runs", stats["foreground_runs"], 0)
    check_int("stats background_runs", stats["background_runs"], 0)
    check_int("stats blocks_moved", stats["blocks_moved"], 0)
    check_int("stats segments_freed", stats["segments_freed"], 0)

proc test_select_victim_unknown_policy():
    let sm = segment.SegmentManager(100, 4096, 1000)
    let collector = gc_module.GarbageCollector(sm, nil)

    let victim = collector.select_victim("unknown")
    check_int("unknown policy", victim, -1)

proc main():
    print("=== GC Module Tests ===")
    test_gc_init()
    test_select_victim_greedy()
    test_select_victim_cost_benefit()
    test_do_gc()
    test_run_foreground()
    test_run_background()
    test_needs_gc()
    test_needs_urgent_gc()
    test_get_stats()
    test_select_victim_unknown_policy()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
