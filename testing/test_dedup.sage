import sys
import std.testing
import dedup

proc test_dedup():
    let engine = dedup.DedupEngine()
    let data = bytes()
    
    engine.add_fingerprint(data, 42)
    let match = engine.check_inline(data)
    
    assert.equal(match, 42, "Dedup check failed")

proc main():
    test_dedup()
    print "All dedup tests passed!"

main()
