## test_xattr.sage — unit tests for the SageFS extended attributes

import xattr
let XAttrManager = xattr.XAttrManager

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

proc check_bytes(name: String, got: Bytes, expected: Bytes):
    TESTS_RUN = TESTS_RUN + 1
    var is_match = bytes_len(got) == bytes_len(expected)
    if is_match:
        for i in range(bytes_len(got)):
            if bytes_get(got, i) != bytes_get(expected, i):
                is_match = false
    if is_match:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name)

proc test_set_get():
    print("set/get xattr:")
    let mgr = XAttrManager()
    var val = bytes("hello")
    let ok = mgr.set_xattr(1, "user.test", val)
    check_bool("set success", ok)
    let got = mgr.get_xattr(1, "user.test")
    check_bytes("get matches", got, val)

    let missing = mgr.get_xattr(1, "user.nonexistent")
    check("get missing length", bytes_len(missing), 0)

proc test_remove():
    print("remove xattr:")
    let mgr = XAttrManager()
    mgr.set_xattr(1, "user.temp", bytes("temp"))
    let removed = mgr.remove_xattr(1, "user.temp")
    check_bool("remove success", removed)
    let removed_again = mgr.remove_xattr(1, "user.temp")
    check_bool("remove again fails", removed_again == false)

proc test_list():
    print("list xattrs:")
    let mgr = XAttrManager()
    let empty = mgr.list_xattrs(1)
    check("list empty", len(empty), 0)

    mgr.set_xattr(1, "user.a", bytes("1"))
    mgr.set_xattr(1, "user.b", bytes("2"))
    mgr.set_xattr(2, "user.c", bytes("3"))
    let list1 = mgr.list_xattrs(1)
    check("list ino=1 count", len(list1), 2)
    let list2 = mgr.list_xattrs(2)
    check("list ino=2 count", len(list2), 1)

proc test_total_size():
    print("total_size:")
    let mgr = XAttrManager()
    mgr.set_xattr(1, "user.k1", bytes("12345"))
    mgr.set_xattr(1, "user.k2", bytes("ab"))
    let size = mgr.total_size(1)
    let name_len = len("user.k1") + len("user.k2")
    let val_len = 5 + 2
    check("total size matches", size, name_len + val_len)

    let zero = mgr.total_size(99)
    check("total size for missing ino", zero, 0)

proc test_clear_all():
    print("clear_all:")
    let mgr = XAttrManager()
    mgr.set_xattr(1, "user.x", bytes("value1"))
    mgr.set_xattr(1, "user.y", bytes("value2"))
    mgr.set_xattr(1, "user.z", bytes("value3"))
    check("before clear count", len(mgr.list_xattrs(1)), 3)
    mgr.clear_all(1)
    check("after clear count", len(mgr.list_xattrs(1)), 0)

    let got = mgr.get_xattr(1, "user.x")
    check("after clear, get returns empty", bytes_len(got), 0)

proc test_empty_name():
    print("empty name rejected:")
    let mgr = XAttrManager()
    let ok = mgr.set_xattr(1, "", bytes("val"))
    check_bool("empty name returns false", ok == false)

proc test_long_name():
    print("long name rejected (>255):")
    let mgr = XAttrManager()
    var long_name = ""
    for i in range(260):
        long_name = long_name + "a"
    let ok = mgr.set_xattr(1, long_name, bytes("val"))
    check_bool("long name returns false", ok == false)

proc test_multiple_inodes():
    print("multiple inodes isolation:")
    let mgr = XAttrManager()
    var v1 = bytes()
    bytes_push(v1, 10)
    var v2 = bytes()
    bytes_push(v2, 20)
    mgr.set_xattr(10, "user.common", v1)
    mgr.set_xattr(20, "user.common", v2)
    let got10 = mgr.get_xattr(10, "user.common")
    let got20 = mgr.get_xattr(20, "user.common")
    check_bool("different inodes have different first bytes", bytes_get(got10, 0) != bytes_get(got20, 0))

proc main():
    print("=== SageFS Extended Attributes Tests ===")
    test_set_get()
    test_remove()
    test_list()
    test_total_size()
    test_clear_all()
    test_empty_name()
    test_long_name()
    test_multiple_inodes()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
