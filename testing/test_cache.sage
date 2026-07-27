import sys
import cache

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

proc bytes_equal(a: Bytes, b: Bytes) -> Bool:
    if bytes_len(a) != bytes_len(b):
        return false
    for i in range(bytes_len(a)):
        if bytes_get(a, i) != bytes_get(b, i):
            return false
    return true

proc test_lru_init():
    let lru = cache.LRUCache(5)
    check_int("capacity set", lru.capacity, 5)
    check_int("size 0 on init", lru.size(), 0)
    check_int("hit_rate 0", lru.hits, 0)

proc test_lru_put_get():
    let lru = cache.LRUCache(5)
    lru.put("a", 10)
    lru.put("b", 20)
    check_int("get a returns 10", lru.get("a"), 10)
    check_int("get b returns 20", lru.get("b"), 20)
    check_int("size 2", lru.size(), 2)

proc test_lru_miss():
    let lru = cache.LRUCache(5)
    let val = lru.get("nonexistent")
    check_bool("miss returns nil", val == nil, true)
    check_int("misses incremented", lru.misses, 1)

proc test_lru_eviction():
    let lru = cache.LRUCache(2)
    lru.put("a", 1)
    lru.put("b", 2)
    lru.get("a")
    lru.put("c", 3)

    let b_val = lru.get("b")
    check_bool("b evicted (lru)", b_val == nil, true)
    check_int("a still present", lru.get("a"), 1)
    check_int("c present", lru.get("c"), 3)
    check_int("size stays 2", lru.size(), 2)

proc test_lru_update_existing():
    let lru = cache.LRUCache(3)
    lru.put("x", 100)
    lru.put("x", 200)
    check_int("updated value", lru.get("x"), 200)
    check_int("size unchanged after update", lru.size(), 1)

proc test_lru_invalidate():
    let lru = cache.LRUCache(5)
    lru.put("a", 1)
    lru.put("b", 2)
    lru.put("c", 3)
    lru.invalidate("b")
    check_bool("b invalidated", lru.get("b") == nil, true)
    check_int("a still present", lru.get("a"), 1)
    check_int("size 2 after invalidation", lru.size(), 2)

proc test_lru_clear():
    let lru = cache.LRUCache(5)
    lru.put("a", 1)
    lru.put("b", 2)
    lru.get("a")
    lru.get("nonexistent")
    lru.clear()
    check_int("size 0 after clear", lru.size(), 0)
    check_int("hits reset", lru.hits, 0)
    check_int("misses reset", lru.misses, 0)

proc test_lru_touch_updates_order():
    let lru = cache.LRUCache(3)
    lru.put("a", 1)
    lru.put("b", 2)
    lru.put("c", 3)
    lru.get("a")
    lru.put("d", 4)
    check_bool("b evicted (a touched)", lru.get("b") == nil, true)
    check_int("a present", lru.get("a"), 1)
    check_int("c present", lru.get("c"), 3)
    check_int("d present", lru.get("d"), 4)

proc test_cache_manager_init():
    let mgr = cache.CacheManager(10, 20, 30)
    check_int("nat cache capacity", mgr.nat_cache.capacity, 10)
    check_int("extent cache capacity", mgr.extent_cache.capacity, 20)
    check_int("node cache capacity", mgr.node_cache.capacity, 30)

proc test_cache_manager_nat():
    let mgr = cache.CacheManager(5, 5, 5)
    mgr.put_nat(100, 4000)
    mgr.put_nat(200, 5000)
    check_int("nat get 100", mgr.get_nat(100), 4000)
    check_int("nat get 200", mgr.get_nat(200), 5000)
    check_int("nat miss 300", mgr.get_nat(300), -1)
    mgr.invalidate_nat(100)
    check_int("nat invalidated", mgr.get_nat(100), -1)

proc test_cache_manager_extent():
    let mgr = cache.CacheManager(5, 5, 5)
    mgr.put_extent(1, 0, 8000)
    mgr.put_extent(1, 100, 9000)
    check_int("extent get (1,0)", mgr.get_extent(1, 0), 8000)
    check_int("extent get (1,100)", mgr.get_extent(1, 100), 9000)
    check_int("extent miss", mgr.get_extent(1, 999), -1)
    mgr.invalidate_extent(1, 0)
    check_int("extent invalidated", mgr.get_extent(1, 0), -1)

proc test_cache_manager_node():
    let mgr = cache.CacheManager(5, 5, 5)
    let data = bytes("block data")
    mgr.put_node(9000, data)
    let res = mgr.get_node(9000)
    check_int("node get correct length", bytes_len(res), 10)
    let empty = mgr.get_node(9999)
    check_int("node miss returns empty bytes", bytes_len(empty), 0)
    mgr.invalidate_node(9000)
    let after_inval = mgr.get_node(9000)
    check_int("node invalidated", bytes_len(after_inval), 0)

proc test_cache_manager_clear_all():
    let mgr = cache.CacheManager(5, 5, 5)
    mgr.put_nat(1, 100)
    mgr.put_extent(1, 0, 200)
    mgr.put_node(300, bytes("x"))
    mgr.clear_all()
    check_int("nat cleared", mgr.get_nat(1), -1)
    check_int("extent cleared", mgr.get_extent(1, 0), -1)
    check_int("node cleared", bytes_len(mgr.get_node(300)), 0)

proc test_cache_manager_get_stats():
    let mgr = cache.CacheManager(10, 10, 10)
    mgr.put_nat(1, 100)
    mgr.get_nat(1)
    mgr.get_nat(999)
    mgr.put_extent(1, 0, 500)
    let stats = mgr.get_stats()
    check_int("stats nat size", stats["nat"]["size"], 1)
    check_int("stats extent size", stats["extent"]["size"], 1)
    check_int("stats node size", stats["node"]["size"], 0)

proc test_lru_evict_empty():
    let lru = cache.LRUCache(0)
    lru.put("a", 1)
    check_bool("no capacity means no storage", lru.get("a") == nil, true)

proc main():
    print("=== Cache Module Tests ===")
    test_lru_init()
    test_lru_put_get()
    test_lru_miss()
    test_lru_eviction()
    test_lru_update_existing()
    test_lru_invalidate()
    test_lru_clear()
    test_lru_touch_updates_order()
    test_cache_manager_init()
    test_cache_manager_nat()
    test_cache_manager_extent()
    test_cache_manager_node()
    test_cache_manager_clear_all()
    test_cache_manager_get_stats()
    test_lru_evict_empty()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
