## test_snapshot.sage — unit tests for the SageFS snapshot engine

import snapshot
let SnapshotEngine = snapshot.SnapshotEngine

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check(name: String, got: Int, expected: Int):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc check_bool(name: String, got: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if got:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name)

proc check_not_nil(name: String, got):
    TESTS_RUN = TESTS_RUN + 1
    if got != nil:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name)

proc check_nil(name: String, got):
    TESTS_RUN = TESTS_RUN + 1
    if got == nil:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name)

proc test_subvolume_lifecycle():
    print("Subvolume lifecycle:")
    let engine = SnapshotEngine()
    let subvol = engine.create_subvolume("root", 1000)
    check_not_nil("create subvolume", subvol)
    check("subvol name", subvol.name, "root")
    check("subvol root_block", subvol.root_block, 1000)
    check("subvol id", subvol.id, 1)
    check("subvol generation", subvol.generation, 1)

    let got = engine.get_subvolume("root")
    check_not_nil("get subvolume", got)

    let missing = engine.get_subvolume("nonexistent")
    check_nil("get missing subvolume", missing)

    let deleted = engine.delete_subvolume("root")
    check_bool("delete subvolume", deleted)

    let not_found = engine.delete_subvolume("root")
    check_bool("delete deleted subvolume", not_found == false)

proc test_snapshot_lifecycle():
    print("Snapshot lifecycle:")
    let engine = SnapshotEngine()
    let subvol = engine.create_subvolume("data", 2000)

    let snap = engine.create_snapshot("data", "snap_v1", 1000000)
    check_not_nil("create snapshot", snap)
    check("snap name", snap.name, "snap_v1")
    check("snap root_block", snap.root_block, 2000)
    check("snap subvol_id", snap.subvol_id, 1)
    check("snap creation_time", snap.creation_time, 1000000)
    check("snap generation", snap.generation, 1)

    let got = subvol.get_snapshot("snap_v1")
    check_not_nil("get snapshot", got)

    let missing = subvol.get_snapshot("nosuch")
    check_nil("get missing snapshot", missing)

    let deleted = engine.delete_snapshot("data", "snap_v1")
    check_bool("delete snapshot", deleted)

    let del_again = engine.delete_snapshot("data", "snap_v1")
    check_bool("delete again fails", del_again == false)

proc test_snapshot_count():
    print("Snapshot count:")
    let engine = SnapshotEngine()
    let subvol = engine.create_subvolume("logs", 3000)
    check("initial count", subvol.snapshot_count(), 0)

    subvol.create_snapshot("s1", 100)
    subvol.create_snapshot("s2", 200)
    subvol.create_snapshot("s3", 300)
    check("after 3 snapshots", subvol.snapshot_count(), 3)

    subvol.delete_snapshot("s2")
    check("after delete", subvol.snapshot_count(), 2)

proc test_snapshot_diff():
    print("Snapshot diff:")
    let engine = SnapshotEngine()
    let subvol = engine.create_subvolume("diff_test", 5000)

    subvol.create_snapshot("before", 1000)
    subvol.create_snapshot("after", 2000)

    let diff = engine.diff_snapshots("diff_test", "before", "after")
    check("diff subvolume", diff["subvolume"], "diff_test")
    check("diff snap1", diff["snap1"], "before")
    check("diff snap2", diff["snap2"], "after")
    check("diff snap1_root", diff["snap1_root"], 5000)
    check("diff snap2_root", diff["snap2_root"], 5000)

    let missing_subvol = engine.diff_snapshots("nope", "a", "b")
    check("diff missing subvol", len(dict_keys(missing_subvol)), 0)

    let missing_snap = engine.diff_snapshots("diff_test", "x", "y")
    check("diff missing snaps", len(dict_keys(missing_snap)), 0)

proc test_list_operations():
    print("List operations:")
    let engine = SnapshotEngine()

    let subvols_before = engine.list_subvolumes()
    check("list empty", len(subvols_before), 0)

    engine.create_subvolume("a", 10)
    engine.create_subvolume("b", 20)
    engine.create_subvolume("c", 30)
    let subvols = engine.list_subvolumes()
    check("list 3 subvols", len(subvols), 3)

    let snaps_empty = engine.list_snapshots("a")
    check("list snaps empty", len(snaps_empty), 0)

    engine.create_snapshot("a", "s1", 50)
    engine.create_snapshot("a", "s2", 60)
    let snaps = engine.list_snapshots("a")
    check("list 2 snapshots", len(snaps), 2)

    let no_subvol = engine.list_snapshots("z")
    check("list missing subvol", len(no_subvol), 0)

proc test_generation():
    print("Generation tracking:")
    let engine = SnapshotEngine()
    let g1 = engine.get_generation()
    let g2 = engine.get_generation()
    let g3 = engine.get_generation()
    check("gen monotonic 1", g2, g1 + 1)
    check("gen monotonic 2", g3, g2 + 1)

proc test_subvolume_to_dict():
    print("Subvolume to_dict:")
    let engine = SnapshotEngine()
    let subvol = engine.create_subvolume("test", 42)
    subvol.create_snapshot("s1", 100)
    let d = subvol.to_dict()
    check("dict id", d["id"], 1)
    check("dict name", d["name"], "test")
    check("dict root_block", d["root_block"], 42)
    check("dict snap_count", d["snapshot_count"], 1)

proc test_snapshot_to_dict():
    print("Snapshot to_dict:")
    let engine = SnapshotEngine()
    let subvol = engine.create_subvolume("test", 42)
    let snap = subvol.create_snapshot("my_snap", 999)
    let d = snap.to_dict()
    check("snap dict name", d["name"], "my_snap")
    check("snap dict root", d["root_block"], 42)
    check("snap dict time", d["creation_time"], 999)

proc main():
    print("=== SageFS Snapshot Engine Tests ===")
    test_subvolume_lifecycle()
    test_snapshot_lifecycle()
    test_snapshot_count()
    test_snapshot_diff()
    test_list_operations()
    test_generation()
    test_subvolume_to_dict()
    test_snapshot_to_dict()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
