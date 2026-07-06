import sys
import std.testing
import snapshot

proc test_snapshot():
    # Mock superblock
    let sb = {}
    let engine = snapshot.SnapshotEngine(sb)
    
    let subvol = engine.create_subvolume("root", 12345)
    assert.equal(subvol.name, "root", "Subvolume name mismatch")
    assert.equal(subvol.root_block, 12345, "Subvolume root mismatch")
    
    let snap = engine.create_snapshot("root", "snap1", 1600000000)
    assert.not_equal(snap, nil, "Snapshot creation failed")
    assert.equal(snap.name, "snap1", "Snapshot name mismatch")
    assert.equal(snap.root_block, 12345, "Snapshot root block mismatch")
    assert.equal(snap.creation_time, 1600000000, "Snapshot creation time mismatch")
    
    let deleted = engine.delete_snapshot("root", "snap1")
    assert.equal(deleted, true, "Delete snapshot failed")
    
    let deleted_again = engine.delete_snapshot("root", "snap1")
    assert.equal(deleted_again, false, "Delete snapshot again should fail")

proc main():
    test_snapshot()
    print "All snapshot tests passed!"

main()
