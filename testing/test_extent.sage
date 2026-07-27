import sys
import std.testing
import btree
import extent

let BTREE_NODE_SIZE = 4096

class MockAllocator:
    proc init(self):
        self.blocks = []

    proc alloc_block(self) -> Int:
        let b = bytes()
        for _ in range(BTREE_NODE_SIZE):
            bytes_push(b, 0)
        push(self.blocks, b)
        return len(self.blocks) - 1

    proc read_block(self, addr: Int) -> Bytes:
        if addr < len(self.blocks):
            return self.blocks[addr]
        return bytes()

    proc write_block(self, addr: Int, data: Bytes):
        self.blocks[addr] = data


proc test_insert_and_lookup():
    let alloc = MockAllocator()
    let btree_eng = btree.BTreeEngine(alloc, 0, 1)
    let et = extent.ExtentTree(btree_eng)

    et.insert_extent(1, 0, 100, 50)
    let ext = et.lookup_extent(1, 0)
    assert.equal(ext.file_offset, 0, "Lookup offset 0")
    assert.equal(ext.block_addr, 100, "Lookup block 100")
    assert.equal(ext.length, 50, "Lookup length 50")

    let ext2 = et.lookup_extent(1, 25)
    assert.equal(ext2.file_offset, 0, "Lookup mid extent offset")
    assert.equal(ext2.block_addr, 100, "Lookup mid extent block")
    assert.equal(ext2.length, 50, "Lookup mid extent length")

    let ext3 = et.lookup_extent(1, 50)
    assert.equal(ext3, nil, "Lookup past extent should be nil")

    print "  PASS test_insert_and_lookup"


proc test_insert_multiple_and_range():
    let alloc = MockAllocator()
    let btree_eng = btree.BTreeEngine(alloc, 0, 1)
    let et = extent.ExtentTree(btree_eng)

    et.insert_extent(1, 0, 100, 50)
    et.insert_extent(1, 100, 300, 75)
    et.insert_extent(1, 200, 500, 25)

    let e0 = et.lookup_extent(1, 0)
    assert.equal(e0.length, 50, "First extent length")

    let e1 = et.lookup_extent(1, 120)
    assert.equal(e1.file_offset, 100, "Second extent offset")
    assert.equal(e1.block_addr, 300, "Second extent block")

    let e2 = et.lookup_extent(1, 210)
    assert.equal(e2.file_offset, 200, "Third extent offset")
    assert.equal(e2.length, 25, "Third extent length")

    let en = et.lookup_extent(1, 999)
    assert.equal(en, nil, "No extent at large offset")

    print "  PASS test_insert_multiple_and_range"


proc test_merge_adjacent_extents():
    let alloc = MockAllocator()
    let btree_eng = btree.BTreeEngine(alloc, 0, 1)
    let et = extent.ExtentTree(btree_eng)

    et.insert_extent(1, 0, 100, 50)
    et.insert_extent(1, 50, 150, 50)

    let ext = et.lookup_extent(1, 0)
    assert.equal(ext.file_offset, 0, "Merged extent offset")
    assert.equal(ext.block_addr, 100, "Merged extent block")
    assert.equal(ext.length, 100, "Merged extent length")

    let ext2 = et.lookup_extent(1, 75)
    assert.equal(ext2.file_offset, 0, "Merged mid offset")
    assert.equal(ext2.length, 100, "Merged mid length")

    let ext3 = et.lookup_extent(1, 100)
    assert.equal(ext3, nil, "Beyond merged extent")

    print "  PASS test_merge_adjacent_extents"


proc test_no_merge_when_not_physically_contiguous():
    let alloc = MockAllocator()
    let btree_eng = btree.BTreeEngine(alloc, 0, 1)
    let et = extent.ExtentTree(btree_eng)

    et.insert_extent(1, 0, 100, 50)
    et.insert_extent(1, 50, 999, 50)

    let e1 = et.lookup_extent(1, 0)
    assert.equal(e1.block_addr, 100, "First extent unmerged")

    let e2 = et.lookup_extent(1, 60)
    assert.equal(e2.block_addr, 999, "Second extent unmerged")

    print "  PASS test_no_merge_when_not_physically_contiguous"


proc test_truncate():
    let alloc = MockAllocator()
    let btree_eng = btree.BTreeEngine(alloc, 0, 1)
    let et = extent.ExtentTree(btree_eng)

    et.insert_extent(1, 0, 100, 200)
    et.truncate(1, 80)

    let e = et.lookup_extent(1, 50)
    assert.equal(e.file_offset, 0, "Truncated extent offset")
    assert.equal(e.length, 80, "Truncated extent length")

    let en = et.lookup_extent(1, 80)
    assert.equal(en, nil, "Past truncation point")

    print "  PASS test_truncate"


proc test_truncate_removes_past_extents():
    let alloc = MockAllocator()
    let btree_eng = btree.BTreeEngine(alloc, 0, 1)
    let et = extent.ExtentTree(btree_eng)

    et.insert_extent(1, 0, 100, 50)
    et.insert_extent(1, 100, 300, 50)
    et.truncate(1, 60)

    let e1 = et.lookup_extent(1, 0)
    assert.equal(e1.length, 50, "First extent unchanged")

    let e2 = et.lookup_extent(1, 100)
    assert.equal(e2, nil, "Second extent removed")

    print "  PASS test_truncate_removes_past_extents"


proc test_punch_hole_middle():
    let alloc = MockAllocator()
    let btree_eng = btree.BTreeEngine(alloc, 0, 1)
    let et = extent.ExtentTree(btree_eng)

    # One extent covering [0, 200)
    et.insert_extent(1, 0, 1000, 200)

    # Punch [75, 125), should split into [0,75) and [125,200)
    et.punch_hole(1, 75, 50)

    let e1 = et.lookup_extent(1, 0)
    assert.equal(e1.file_offset, 0, "Left split offset")
    assert.equal(e1.block_addr, 1000, "Left split block")
    assert.equal(e1.length, 75, "Left split length")

    let e2 = et.lookup_extent(1, 150)
    assert.equal(e2.file_offset, 125, "Right split offset")
    assert.equal(e2.block_addr, 1000 + 125, "Right split block")
    assert.equal(e2.length, 75, "Right split length")

    let e_mid = et.lookup_extent(1, 100)
    assert.equal(e_mid, nil, "Hole should be empty")

    print "  PASS test_punch_hole_middle"


proc test_punch_hole_start():
    let alloc = MockAllocator()
    let btree_eng = btree.BTreeEngine(alloc, 0, 1)
    let et = extent.ExtentTree(btree_eng)

    et.insert_extent(1, 0, 500, 100)
    # Punch [0, 30) — should trim the start
    et.punch_hole(1, 0, 30)

    let e = et.lookup_extent(1, 30)
    assert.equal(e.file_offset, 30, "Trimmed start offset")
    assert.equal(e.block_addr, 530, "Trimmed start block")
    assert.equal(e.length, 70, "Trimmed start length")

    let en = et.lookup_extent(1, 0)
    assert.equal(en, nil, "Hole at start")

    print "  PASS test_punch_hole_start"


proc test_punch_hole_end():
    let alloc = MockAllocator()
    let btree_eng = btree.BTreeEngine(alloc, 0, 1)
    let et = extent.ExtentTree(btree_eng)

    et.insert_extent(1, 0, 500, 100)
    # Punch [70, 100) — should trim the end
    et.punch_hole(1, 70, 30)

    let e = et.lookup_extent(1, 50)
    assert.equal(e.file_offset, 0, "Trimmed end offset")
    assert.equal(e.length, 70, "Trimmed end length")

    let en = et.lookup_extent(1, 70)
    assert.equal(en, nil, "Hole at end")

    print "  PASS test_punch_hole_end"


proc test_different_inodes_independent():
    let alloc = MockAllocator()
    let btree_eng = btree.BTreeEngine(alloc, 0, 1)
    let et = extent.ExtentTree(btree_eng)

    et.insert_extent(1, 0, 100, 50)
    et.insert_extent(2, 0, 999, 25)

    let e1 = et.lookup_extent(1, 0)
    assert.equal(e1.block_addr, 100, "Inode 1 block")

    let e2 = et.lookup_extent(2, 0)
    assert.equal(e2.block_addr, 999, "Inode 2 block")

    let en = et.lookup_extent(1, 100)
    assert.equal(en, nil, "No cross-contamination")

    print "  PASS test_different_inodes_independent"


proc test_serialization_roundtrip():
    let alloc = MockAllocator()
    let btree_eng = btree.BTreeEngine(alloc, 0, 1)
    let et1 = extent.ExtentTree(btree_eng)

    et1.insert_extent(1, 0, 100, 50)
    et1.insert_extent(1, 100, 300, 75)
    et1.insert_extent(1, 200, 500, 25)

    # Simulate remount: create a fresh BTreeEngine reading the same allocator
    let btree_eng2 = btree.BTreeEngine(alloc, btree_eng.root_block, 2)
    let et2 = extent.ExtentTree(btree_eng2)

    let e1 = et2.lookup_extent(1, 0)
    assert.equal(e1.file_offset, 0, "Roundtrip offset 0")
    assert.equal(e1.block_addr, 100, "Roundtrip block 0")
    assert.equal(e1.length, 50, "Roundtrip length 0")

    let e2 = et2.lookup_extent(1, 150)
    assert.equal(e2.file_offset, 100, "Roundtrip offset 100")
    assert.equal(e2.block_addr, 300, "Roundtrip block 100")
    assert.equal(e2.length, 75, "Roundtrip length 100")

    let e3 = et2.lookup_extent(1, 210)
    assert.equal(e3.file_offset, 200, "Roundtrip offset 200")
    assert.equal(e3.length, 25, "Roundtrip length 200")

    print "  PASS test_serialization_roundtrip"


proc test_insert_single_past_max_len():
    let alloc = MockAllocator()
    let btree_eng = btree.BTreeEngine(alloc, 0, 1)
    let et = extent.ExtentTree(btree_eng)

    et.insert_extent(1, 0, 100, 50000)
    let e = et.lookup_extent(1, 0)
    assert.equal(e.length, 32768, "Capped at MAX_EXTENT_LEN")

    print "  PASS test_insert_single_past_max_len"


proc test_merge_up_to_max_len():
    let alloc = MockAllocator()
    let btree_eng = btree.BTreeEngine(alloc, 0, 1)
    let et = extent.ExtentTree(btree_eng)

    # Insert two 16000-block extents that should merge to under MAX
    et.insert_extent(1, 0, 100, 16000)
    et.insert_extent(1, 16000, 16100, 16000)
    let e = et.lookup_extent(1, 0)
    assert.equal(e.length, 32000, "Merged within MAX")

    # Insert a third that would push past MAX — should NOT merge
    et.insert_extent(1, 32000, 32100, 16000)
    let e1 = et.lookup_extent(1, 0)
    assert.equal(e1.length, 32000, "First extent capped at 32000")
    let e2 = et.lookup_extent(1, 32000)
    assert.equal(e2.length, 16000, "Third extent not merged")

    print "  PASS test_merge_up_to_max_len"


proc main():
    print "Running extent tests..."
    test_insert_and_lookup()
    test_insert_multiple_and_range()
    test_merge_adjacent_extents()
    test_no_merge_when_not_physically_contiguous()
    test_truncate()
    test_truncate_removes_past_extents()
    test_punch_hole_middle()
    test_punch_hole_start()
    test_punch_hole_end()
    test_different_inodes_independent()
    test_serialization_roundtrip()
    test_insert_single_past_max_len()
    test_merge_up_to_max_len()
    print "ALL TESTS PASSED"

main()
