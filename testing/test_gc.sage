import sys
import std.testing
import gc

proc test_gc():
    let collector = gc.GarbageCollector(10)
    assert.equal(collector.threshold, 10, "Threshold mismatch")
    
    let victim = collector.select_victim("greedy")
    assert.equal(victim, 0, "Victim stub failed")

proc main():
    test_gc()
    print "All gc tests passed!"

main()
