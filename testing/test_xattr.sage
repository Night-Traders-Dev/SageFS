import sys
import std.testing
import xattr

proc test_xattr():
    let mgr = xattr.XAttrManager(nil)
    
    let res1 = mgr.set_xattr(42, "user.test", bytes_from_string("hello"))
    assert.equal(res1, true, "Set xattr failed")
    
    let val = mgr.get_xattr(42, "user.test")
    assert.not_equal(val, nil, "Get xattr failed")
    
    let res2 = mgr.remove_xattr(42, "user.test")
    assert.equal(res2, true, "Remove xattr failed")

proc main():
    test_xattr()
    print "All xattr tests passed!"

main()
