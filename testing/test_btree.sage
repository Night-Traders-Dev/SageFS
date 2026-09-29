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
        ## Truncate to one block, the way VFS._write_block does.
        ##
        ## It copies at most bs bytes into the image, so a node that serializes
        ## past the block size loses everything beyond it. This mock used to keep
        ## the whole buffer, which made it *more* forgiving than the real
        ## allocator and hid the size-split bug completely: an oversized node was
        ## written whole here, so every key still read back and the test for it
        ## passed with the fix reverted. A mock that is more tolerant than the
        ## thing it stands in for cannot catch that class of bug.
        let n = bytes_len(data)
        if n <= BTREE_NODE_SIZE:
            self.blocks[addr] = data
            return
        let cut = bytes()
        var i: Int = 0
        while i < BTREE_NODE_SIZE:
            bytes_push(cut, bytes_get(data, i))
            i = i + 1
        self.blocks[addr] = cut

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
    check_bool("root_block after insert", tree.root_block != 0, true)

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
    ## 200 keys against an 84-key node limit needs more than two leaves, so the
    ## old "expect 2 children" was simply wrong. Assert the invariant that
    ## actually matters: the root is internal, and no leaf exceeds the limit.
    var leaves_ok = true
    if root_node.num_items < 2:
        leaves_ok = false
    var li = 0
    while li < root_node.num_items:
        let leaf = tree.read_node(root_node.pointers[li].block_addr)
        if not leaf.is_leaf or leaf.num_items > BTREE_MAX_KEYS:
            leaves_ok = false
        li = li + 1
    check_bool("root internal and no leaf over BTREE_MAX_KEYS", leaves_ok, true)

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
    ## The root cannot become a leaf here: 115 keys survive the delete and a
    ## single node holds at most BTREE_MAX_KEYS (84). What the merge should
    ## achieve is collapsing the root's children, from 4 before the deletes to
    ## 2 after -- that is the rebalance actually working.
    let root_node = tree.read_node(tree.root_block)
    check_bool("root is still internal (115 keys > BTREE_MAX_KEYS)", root_node.is_leaf, false)
    check_int("root shrank to 2 children after merge", root_node.num_items, 2)

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
    check_bool("root_block changed after CoW", root2_block != root1_block, true)
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

proc check_count(name: String, got, want):
    TESTS_RUN = TESTS_RUN + 1
    if got == want:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(want))

proc test_scan():
    print("")
    print("Scan and count:")
    let alloc = MockAllocator()

    ## An empty tree must report empty rather than trying to read a root.
    let empty_tree = BTreeEngine(alloc, 0, 1)
    check_count("empty tree scans to nothing", len(empty_tree.scan()), 0)
    check_count("empty tree counts zero", empty_tree.count(), 0)

    ## A single leaf. This is the case that would also pass with a scan that only
    ## ever looked at the root, so it is a floor and not evidence of anything.
    let one = BTreeEngine(alloc, 0, 1)
    one.insert(make_key(7), make_data(7))
    check_count("single leaf count", one.count(), 1)
    check_count("single leaf scan length", len(one.scan()), 1)
    check_bytes("single leaf value", one.scan()[0]["data"], make_data(7))

    ## Enough keys to force a split, so the scan has to descend through an
    ## internal node and visit more than one leaf. BTREE_MAX_KEYS is 84.
    let many = BTreeEngine(alloc, 0, 1)
    var i: Int = 0
    var expected: Int = 0
    while i < 200:
        many.insert(make_key(i), make_data(i))
        expected = expected + 1
        i = i + 1
    check_count("200-key tree counts every key", many.count(), expected)
    let rows = many.scan()
    check_count("200-key scan returns every key", len(rows), expected)

    ## Ascending key order, with each value still attached to its own key.
    var ordered = true
    var paired = true
    var j: Int = 0
    while j < len(rows):
        if rows[j]["key"].offset != j:
            ordered = false
        if not bytes_equal(rows[j]["data"], make_data(j)):
            paired = false
        j = j + 1
    check_count("scan is in ascending key order", ordered, true)
    check_count("each value stays with its key", paired, true)

    ## A reopen against the same allocator must see the same set, which is the
    ## closest stand-in here for reading a saved image back.
    let reopened = BTreeEngine(alloc, many.root_block, many.current_generation)
    check_count("reopened tree counts the same", reopened.count(), expected)
    check_count("reopened scan matches", len(reopened.scan()), expected)
    check_bytes("reopened value readable", reopened.search(make_key(99)), make_data(99))

    ## Deletions must show up in both.
    var k: Int = 0
    while k < 200:
        many.delete(make_key(k))
        expected = expected - 1
        k = k + 1
    check_count("count after deleting every key", many.count(), 0)
    check_count("scan after deleting every key", len(many.scan()), 0)

proc check_nodes_fit(tree, addr: Int, oversized: Int, checked: Int):
    let node = tree.read_node(addr)
    checked = checked + 1
    if bytes_len(node.serialize()) > BTREE_NODE_SIZE:
        oversized = oversized + 1
    if not node.is_leaf:
        var i: Int = 0
        while i < len(node.pointers):
            check_nodes_fit(tree, node.pointers[i].block_addr, oversized, checked)
            i = i + 1

proc make_blob(n: Int) -> Bytes:
    let b = bytes()
    var i: Int = 0
    while i < n:
        bytes_push(b, 65 + (i % 26))
        i = i + 1
    return b

proc test_split_on_serialized_size():
    print("")
    print("Split on serialized size, not just key count:")
    let alloc = MockAllocator()
    let tree = BTreeEngine(alloc, 0, 1)

    ## One large value among many small ones. A leaf's serialized size is its
    ## header plus 32 bytes per item plus its data area, so this node passes
    ## BTREE_MAX_KEYS and still outgrows BTREE_NODE_SIZE.
    ##
    ## It used to be written anyway, and the allocator's write_block copies at
    ## most one block -- so the node was silently truncated, losing the tail of
    ## the item records and the data area. Nothing reported it: count() read the
    ## key count out of the surviving header and reported every key present, while
    ## search() returned nothing for the ones whose bytes had been dropped. A
    ## root directory's dentry blob is a value big enough to do this, which is
    ## how the inode table turned it up; extent values are too small to.
    ## 41 keys whose values total ~9 KB between them: comfortable under
    ## BTREE_MAX_KEYS keys, comfortably over one block of bytes.
    tree.insert(make_key(1), make_blob(1100))
    var i: Int = 2
    while i <= 41:
        tree.insert(make_key(i), make_blob(200))
        i = i + 1

    check_int("a large-value tree holds every key", tree.count(), 41)
    check_int("and scan agrees", len(tree.scan()), 41)

    ## Every node the tree can reach must fit a block, or writing it loses data.
    var oversized: Int = 0
    var checked: Int = 0
    check_nodes_fit(tree, tree.root_block, oversized, checked)
    check("the tree has nodes to check", checked > 0, true)
    check_int("no reachable node exceeds a block", oversized, 0)

    ## And the keys whose records fell past the boundary last time are readable.
    var missing: Int = 0
    var k: Int = 1
    while k <= 41:
        if bytes_len(tree.search(make_key(k))) == 0:
            missing = missing + 1
        k = k + 1
    check_int("no key is lost to truncation", missing, 0)
    check_bytes("the large value survives intact", tree.search(make_key(1)), make_blob(1100))

    ## The same after a remount, which is where it showed up: every node CoWs, so
    ## the oversized leaf is re-serialised and truncated again.
    let tree2 = BTreeEngine(alloc, tree.root_block, tree.current_generation + 1)
    check_int("a remounted large-value tree holds every key", tree2.count(), 41)
    missing = 0
    k = 1
    while k <= 41:
        if bytes_len(tree2.search(make_key(k))) == 0:
            missing = missing + 1
        k = k + 1
    check_int("no key is lost on remount", missing, 0)

    ## Replacing every value, as unmount does, must not drift back over the limit.
    k = 1
    while k <= 41:
        if k == 1:
            tree2.insert(make_key(k), make_blob(1100))
        else:
            tree2.insert(make_key(k), make_blob(200))
        k = k + 1
    oversized = 0
    checked = 0
    check_nodes_fit(tree2, tree2.root_block, oversized, checked)
    check_int("replacing every value keeps every node in a block", oversized, 0)
    check_int("replacing every value keeps every key", tree2.count(), 41)
    missing = 0
    k = 1
    while k <= 41:
        if bytes_len(tree2.search(make_key(k))) == 0:
            missing = missing + 1
        k = k + 1
    check_int("no key is lost after replacing every value", missing, 0)

proc test_insert_into_damaged_root():
    print("")
    print("Insert into a damaged root:")
    let alloc = MockAllocator()
    let tree = BTreeEngine(alloc, 0, 1)
    tree.insert(make_key(1), make_data(1))
    let root_blk: Int = tree.root_block()
    check("a one-key tree has a root", root_blk > 0, true)

    var zeros = bytes()
    var z: Int = 0
    while z < 64:
        bytes_push(zeros, 0)
        z = z + 1
    alloc.write_block(root_blk, zeros)

    check("a zeroed root is not readable", tree.root_is_readable(), false)
    ## search() and scan() already read such a root as empty, so insert() had to
    ## agree. It did not: the descent into a node with no items and no pointers
    ## put the child index at -1 and dereferenced pointers[-1], so the first write
    ## after a damaged root took the filesystem down -- which for the inode table
    ## meant unmount crashed on exactly the volume that needed recovering.
    tree.insert(make_key(2), make_data(2))
    check("a write after a damaged root does not crash", true, true)
    check("the damaged index is rebuilt as a usable tree", tree.root_is_readable(), true)
    check_bytes("the new key is readable", tree.search(make_key(2)), make_data(2))
    check("the old root is remembered for debugging", tree.damaged_root_block == root_blk, true)

proc test_update_does_not_grow_data_area():
    print("")
    print("Replacing a value reclaims the old bytes:")
    let alloc = MockAllocator()
    let tree = BTreeEngine(alloc, 0, 1)
    let key = make_key(42)
    ## 28 bytes, not make_data()'s 6: 500 replacements of a 6-byte value is only
    ## 3000 bytes and still fits in a node, which would leave the node-size
    ## assertion below passing no matter what the code did. At 28 bytes the
    ## unfixed behaviour reaches 14000, so the check has something to catch.
    let payload = bytes("aaaaaaaaaaaaaaaaaaaaaaaaaaaa")

    ## Replacing a value appends the new bytes and repoints the item. Nothing
    ## used to reclaim the old ones -- compact_data_area() was only called from
    ## delete() -- so a repeatedly-updated key grew its leaf's data area without
    ## bound. Values still read back correctly throughout, because the item
    ## points at the newest bytes, so the only symptom was the data area
    ## outgrowing BTREE_NODE_SIZE and the node becoming unserializable.
    var i: Int = 0
    while i < 500:
        tree.insert(key, payload)
        i = i + 1

    let leaf = tree.read_node(tree.root_block)
    check_count("repeated updates keep one item, not 500", leaf.num_items, 1)
    check_count("data area stays inside a node", bytes_len(leaf.data_area) <= BTREE_NODE_SIZE, true)

    ## Without the reclaim this is 14000 bytes and the serialized node is 14064 --
    ## 3.4x the block, written straight through the end of it.
    check_count("serialized node still fits a block", bytes_len(leaf.serialize()) <= BTREE_NODE_SIZE, true)
    check_count("data area is bounded, not merely legal", bytes_len(leaf.data_area) < 200, true)
    check_bytes("value survives 500 replacements", tree.search(key), payload)

    ## A key that is genuinely new must still be appended, not replaced.
    tree.insert(make_key(43), make_data(2))
    let leaf2 = tree.read_node(tree.root_block)
    check_count("a new key still appends", leaf2.num_items, 2)
    check_count("first key still readable", bytes_len(tree.search(make_key(42))), bytes_len(payload))
    check_bytes("second key readable", tree.search(make_key(43)), make_data(2))

proc main():
    print("=== SageFS B+ Tree Engine Tests ===")
    test_insert_search_single()
    test_insert_search_multi()
    test_delete_key()
    test_split()
    test_merge()
    test_serialization()
    test_cow()
    test_scan()
    test_update_does_not_grow_data_area()
    test_split_on_serialized_size()
    test_insert_into_damaged_root()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
