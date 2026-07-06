import sys
import std.testing
import gc

proc test_gc():
    # Mock segment manager
    let sm = {}
    let collector = gc.GarbageCollector(sm, 10)
    assert.equal(collector.threshold, 10, "Threshold mismatch")
    
    let victim = collector.select_victim("greedy")
    assert.equal(victim, 0, "Victim stub failed")
    
    let res = collector.run_foreground()
    assert.equal(res, true, "Foreground GC failed")

proc main():
    test_gc()
    print "All gc tests passed!"

main()
