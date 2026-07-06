import sys
import std.testing
import cache

proc test_cache():
    let mgr = cache.CacheManager(1024)
    mgr.put("test", bytes())
    let res = mgr.get("test")
    assert.not_equal(res, nil, "Cache get failed")

proc main():
    test_cache()
    print "All cache tests passed!"

main()
