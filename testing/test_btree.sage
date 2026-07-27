import sys
import io
import math
import btree

let BTreeKey = btree.BTreeKey
let BTreeItem = btree.BTreeItem
let BTreePointer = btree.BTreePointer
let SplitResult = btree.SplitResult
let BTreeNode = btree.BTreeNode
let BTreeEngine = btree.BTreeEngine
let BTREE_NODE_SIZE = btree.BTREE_NODE_SIZE
let BTREE_MAX_KEYS = btree.BTREE_MAX_KEYS
let BTREE_MIN_KEYS = btree.BTREE_MIN_KEYS

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

proc check_bytes(name: String, got: Bytes, expected: Bytes):
    TESTS_RUN = TESTS_RUN + 1
    if bytes_equal(got, expected):
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        let got_str = bytes_to_string(got)
        let exp_str = bytes_to_string(expected)
        print("  FAIL  " + name + "  got=" + got_str + " expected=" + exp_str)

class MockAllocator:
    proc init(self):
        self.next_block = 1
        self.blocks = {}

    proc alloc_block(self) -> Int:
        let addr = self.next_block
        self.next_block = self.next_block + 1
        self.blocks[addr] = bytes()
        return addr

    proc read_block(self, addr: Int) -> Bytes:
        if dict_has(self.blocks, addr):
            return self.blocks[addr]
        return bytes()

    proc write_block(self, addr: Int, data: Bytes):
        self.blocks[addr] = data

    proc block_count(self) -> Int:
        return len(self.blocks)

proc make_key(offset: Int):
    return BTreeKey(1, 0, offset)

proc make_data(val: Int) -> Bytes:
    let s = "data_" + str(val)
    return bytes(s)

proc test_insert_search_single():
    print("Insert and search single key:")
    let alloc = MockAllocator()
    let tree = BTreeEngine(alloc, 0, 1)
    let key = make_key(42)
    let data = bytes("hello")
    tree.insert(key, data)
    let result = tree.search(key)
    check_bytes("single key search", result, bytes("hello"))
    check_int("root_block after insert", tree.root_block != 0, 1)

proc test_insert_search_multi():
    print("Insert and search multiple keys:")
    let alloc = MockAllocator()
    let tree = BTreeEngine(alloc, 0, 1)
    var i = 0
    while i < 50:
        tree.insert(make_key(i), make_data(i))
        i = i + 1
    var all_ok = true
    i = 0
    while i < 50:
        let expected = make_data(i)
        let result = tree.search(make_key(i))
        if not bytes_equal(result, expected):
            all_ok = false
        i = i + 1
    check_bool("all 50 keys found", all_ok, true)

proc test_delete_key():
    print("Delete a key and verify:")
    let alloc = MockAllocator()
    let tree = BTreeEngine(alloc, 0, 1)
    tree.insert(make_key(10), bytes("ten"))
    tree.insert(make_key(20), bytes("twenty"))
    tree.insert(make_key(30), bytes("thirty"))
    tree.delete(make_key(20))
    let result = tree.search(make_key(20))
    check_int("deleted key returns empty", bytes_len(result), 0)
    let r10 = tree.search(make_key(10))
    check_bytes("key 10 still exists", r10, bytes("ten"))
    let r30 = tree.search(make_key(30))
    check_bytes("key 30 still exists", r30, bytes("thirty"))

proc test_split():
    print("Split handling (insert more than BTREE_MAX_KEYS):")
    let alloc = MockAllocator()
    let tree = BTreeEngine(alloc, 0, 1)
    var i = 0
    while i < 200:
        tree.insert(make_key(i), make_data(i))
        i = i + 1
    var all_ok = true
    i = 0
    while i < 200:
        let expected = make_data(i)
        let result = tree.search(make_key(i))
        if not bytes_equal(result, expected):
            all_ok = false
        i = i + 1
    check_bool("all 200 keys found after split", all_ok, true)
    let root_node = tree.read_node(tree.root_block)
    check_bool("root is internal after split", root_node.is_leaf, false)
    check_int("root has 2 children", root_node.num_items, 2)

proc test_merge():
    print("Merge/rebalance on delete:")
    let alloc = MockAllocator()
    let tree = BTreeEngine(alloc, 0, 1)
    var i = 0
    while i < 200:
        tree.insert(make_key(i), make_data(i))
        i = i + 1
    var j = 85
    while j < 170:
        tree.delete(make_key(j))
        j = j + 1
    var remaining_ok = true
    j = 0
    while j < 85:
        let expected = make_data(j)
        let result = tree.search(make_key(j))
        if not bytes_equal(result, expected):
            remaining_ok = false
        j = j + 1
    check_bool("keys 0-84 still exist after merge", remaining_ok, true)
    j = 170
    while j < 200:
        let expected = make_data(j)
        let result = tree.search(make_key(j))
        if not bytes_equal(result, expected):
            remaining_ok = false
        j = j + 1
    check_bool("keys 170-199 still exist after merge", remaining_ok, true)
    var not_found_ok = true
    j = 85
    while j < 170:
        let result = tree.search(make_key(j))
        if bytes_len(result) != 0:
            not_found_ok = false
        j = j + 1
    check_bool("deleted keys 85-169 not found", not_found_ok, true)
    let root_node = tree.read_node(tree.root_block)
    check_bool("root is leaf after merge/shrink", root_node.is_leaf, true)

proc test_serialization():
    print("Serialization round-trip:")
    let alloc = MockAllocator()
    let tree = BTreeEngine(alloc, 0, 1)
    var i = 0
    while i < 30:
        tree.insert(make_key(i), make_data(i))
        i = i + 1
    let root_node = tree.read_node(tree.root_block)
    let serialized = root_node.serialize()
    check_int("serialized size", bytes_len(serialized), 4096)

    let loaded = BTreeNode()
    loaded.block_addr = root_node.block_addr
    loaded.deserialize(serialized)
    check_int("deserialized num_items", loaded.num_items, root_node.num_items)
    check_bool("deserialized is_leaf", loaded.is_leaf, root_node.is_leaf)
    check_int("deserialized level", loaded.level, root_node.level)
    check_int("deserialized generation", loaded.generation, root_node.generation)

    var all_match = true
    i = 0
    while i < 30:
        let expected = make_data(i)
        let result = tree.search(make_key(i))
        if not bytes_equal(result, expected):
            all_match = false
        i = i + 1
    check_bool("data intact after serialize round-trip", all_match, true)

proc test_cow():
    print("CoW behavior (generation tracking):")
    let alloc = MockAllocator()
    let tree1 = BTreeEngine(alloc, 0, 1)
    tree1.insert(make_key(1), bytes("gen1"))
    let root1_block = tree1.root_block
    let root1_node = tree1.read_node(root1_block)
    check_int("root generation = 1", root1_node.generation, 1)

    let tree2 = BTreeEngine(alloc, root1_block, 2)
    tree2.insert(make_key(2), bytes("gen2"))
    let root2_block = tree2.root_block
    check_int("root_block changed after CoW", root2_block != root1_block, 1)
    let root2_node = tree2.read_node(root2_block)
    check_int("new root generation = 2", root2_node.generation, 2)

    let result_gen1 = tree1.search(make_key(1))
    check_bytes("gen1 tree still has key 1", result_gen1, bytes("gen1"))
    let result_gen1_empty = tree1.search(make_key(2))
    check_int("gen1 tree does not have key 2", bytes_len(result_gen1_empty), 0)

    let result_gen2_1 = tree2.search(make_key(1))
    check_bytes("gen2 tree has key 1 (original)", result_gen2_1, bytes("gen1"))
    let result_gen2_2 = tree2.search(make_key(2))
    check_bytes("gen2 tree has key 2 (new)", result_gen2_2, bytes("gen2"))

proc main():
    print("=== SageFS B+ Tree Engine Tests ===")
    test_insert_search_single()
    test_insert_search_multi()
    test_delete_key()
    test_split()
    test_merge()
    test_serialization()
    test_cow()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
