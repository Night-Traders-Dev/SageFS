import sys
import std.testing
import cache

proc test_lru_cache():
    let lru = cache.LRUCache(2)
    lru.put("A", 1)
    lru.put("B", 2)
    
    assert.equal(lru.get("A"), 1, "Should get A")
    lru.put("C", 3) # Should evict B since A was touched
    
    assert.equal(lru.get("B"), nil, "B should be evicted")
    assert.equal(lru.get("C"), 3, "Should get C")
    assert.equal(lru.get("A"), 1, "Should still have A")

proc test_cache_manager():
    let mgr = cache.CacheManager(10, 10, 10)
    
    # NAT
    mgr.put_nat(100, 4000)
    assert.equal(mgr.get_nat(100), 4000, "NAT get failed")
    assert.equal(mgr.get_nat(101), -1, "NAT miss failed")
    
    # Extent
    mgr.put_extent(50, 0, 8000)
    assert.equal(mgr.get_extent(50, 0), 8000, "Extent get failed")
    assert.equal(mgr.get_extent(50, 1), -1, "Extent miss failed")
    
    # Node
    let data = bytes("node data")
    mgr.put_node(9000, data)
    let res = mgr.get_node(9000)
    assert.equal(len(res), 9, "Node get failed")

proc main():
    test_lru_cache()
    test_cache_manager()
    print "All cache tests passed!"

main()
