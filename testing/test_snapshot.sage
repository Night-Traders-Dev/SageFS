import sys
import std.testing
import snapshot

proc test_snapshot():
    # Mock superblock
    let sb = {}
    let engine = snapshot.SnapshotEngine(sb)
    
    let subvol = engine.create_subvolume("root")
    assert.equal(subvol.name, "root", "Subvolume name mismatch")
    
    let snap = engine.create_snapshot("root", "snap1")
    assert.equal(snap.name, "snap1", "Snapshot name mismatch")
    
    let deleted = engine.delete_snapshot("root", "snap1")
    assert.equal(deleted, true, "Delete snapshot failed")

proc main():
    test_snapshot()
    print "All snapshot tests passed!"

main()
