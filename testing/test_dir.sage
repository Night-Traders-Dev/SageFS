import dir

var TESTS_RUN = 0
var TESTS_PASSED = 0

proc check(name: String, cond: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if cond:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name)

proc test_add_lookup():
    let dm = dir.DirManager()
    let ok = dm.add_entry("hello.txt", 100, dir.DT_REG)
    check("add_entry succeeds", ok)
    let ino = dm.lookup("hello.txt")
    check("lookup returns 100", ino == 100)
    let missing = dm.lookup("nonexistent")
    check("missing lookup returns -1", missing == -1)

proc test_add_duplicate():
    let dm = dir.DirManager()
    dm.add_entry("file.txt", 1, dir.DT_REG)
    let dup = dm.add_entry("file.txt", 2, dir.DT_REG)
    check("duplicate add_entry fails", not dup)

proc test_remove():
    let dm = dir.DirManager()
    dm.add_entry("a.txt", 1, dir.DT_REG)
    let removed = dm.remove_entry("a.txt")
    check("remove succeeds", removed)
    let lookup = dm.lookup("a.txt")
    check("removed entry not found", lookup == -1)

proc test_read_dir():
    let dm = dir.DirManager()
    dm.add_entry("a.txt", 1, dir.DT_REG)
    dm.add_entry("b.txt", 2, dir.DT_REG)
    dm.add_entry("subdir", 3, dir.DT_DIR)
    let entries = dm.read_dir()
    check("read_dir returns 3 entries", len(entries) == 3)
    var found_a = false
    var found_b = false
    var found_subdir = false
    for e in entries:
        if e.name == "a.txt":
            found_a = true
        if e.name == "b.txt":
            found_b = true
        if e.name == "subdir":
            found_subdir = true
    check("finds a.txt", found_a)
    check("finds b.txt", found_b)
    check("finds subdir", found_subdir)

proc test_rename():
    let dm = dir.DirManager()
    dm.add_entry("old.txt", 42, dir.DT_REG)
    let ok = dm.rename("old.txt", "new.txt")
    check("rename succeeds", ok)
    let old_lookup = dm.lookup("old.txt")
    check("old name gone after rename", old_lookup == -1)
    let new_lookup = dm.lookup("new.txt")
    check("new name points to same inode", new_lookup == 42)

proc test_empty_name():
    let dm = dir.DirManager()
    let ok = dm.add_entry("", 1, dir.DT_REG)
    check("empty name rejected", not ok)

proc test_long_name():
    let dm = dir.DirManager()
    var long_name = ""
    for i in range(300):
        long_name = long_name + "x"
    let ok = dm.add_entry(long_name, 1, dir.DT_REG)
    check("long name (>255) rejected", not ok)

proc test_max_inline():
    let dm = dir.DirManager()
    var all_ok = true
    for i in range(dir.MAX_INLINE_DENTRIES):
        let name = "file_" + str(i)
        let ok = dm.add_entry(name, i, dir.DT_REG)
        if not ok:
            all_ok = false
            break
    check("add up to MAX_INLINE_DENTRIES", all_ok)
    let overflow = dm.add_entry("overflow", 999, dir.DT_REG)
    check("reject beyond MAX_INLINE_DENTRIES", not overflow)

proc test_is_empty():
    let dm = dir.DirManager()
    check("new dir is empty", dm.is_empty())
    dm.add_entry("file", 1, dir.DT_REG)
    check("dir with entries not empty", not dm.is_empty())

proc main():
    print("=== SageFS Directory Tests ===")
    test_add_lookup()
    test_add_duplicate()
    test_remove()
    test_read_dir()
    test_rename()
    test_empty_name()
    test_long_name()
    test_max_inline()
    test_is_empty()
    print("\nResults: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
