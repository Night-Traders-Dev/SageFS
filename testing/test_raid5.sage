## test_raid.sage — RAID5 stripe layout, byte parity, reconstruction, repair.

import raid
import fileio
import sys

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check(name: String, got, expected):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("    PASS  " + name)
    else:
        print("    FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc check_bool(name: String, cond: Bool):
    check(name, cond, true)

proc bytes_equal(a: Bytes, b: Bytes) -> Bool:
    if bytes_len(a) != bytes_len(b):
        return false
    var i: Int = 0
    while i < bytes_len(a):
        if a[i] != b[i]:
            return false
        i = i + 1
    return true

proc pattern(tag: Int, n: Int) -> Bytes:
    let b: Bytes = bytes(n)
    var i: Int = 0
    while i < n:
        b[i] = (tag * 37 + i * 11) & 0xFF
        i = i + 1
    return b

## --- byte-level XOR ------------------------------------------------------

proc test_xor_bytes():
    let a: Bytes = pattern(1, 16)
    let b: Bytes = pattern(2, 16)
    let x: Bytes = raid.xor_bytes(a, b)
    check("xor length preserved", bytes_len(x), 16)
    var i: Int = 0
    var ok: Bool = true
    while i < 16:
        if x[i] != (a[i] ^ b[i]):
            ok = false
        i = i + 1
    check_bool("xor is bytewise", ok)
    ## XOR is its own inverse -- the whole basis of reconstruction.
    check_bool("xor is an involution", bytes_equal(raid.xor_bytes(x, b), a))
    check_bool("xor of a block with itself is zero",
               bytes_equal(raid.xor_bytes(a, a), bytes(16)))

proc test_xor_width_mismatch():
    ## Different-width blocks cannot be XORed. Truncating to the shorter one
    ## would silently drop bytes, so this returns empty instead.
    check("mismatched widths yield empty", bytes_len(raid.xor_bytes(bytes(8), bytes(16))), 0)

proc test_parity_bytes():
    ## Parity over three blocks must equal the XOR of any two, which is exactly
    ## what lets a missing block be rebuilt from the survivors.
    let a: Bytes = pattern(1, 12)
    let b: Bytes = pattern(2, 12)
    let c: Bytes = pattern(3, 12)
    let p: Bytes = raid.parity_bytes([a, b, c])
    check("parity length", bytes_len(p), 12)
    let ab: Bytes = raid.xor_bytes(a, b)
    check_bool("parity recovers third block", bytes_equal(raid.xor_bytes(p, ab), c))
    check_bool("parity order does not matter", bytes_equal(raid.parity_bytes([c, a, b]), p))
    check("parity of nothing is empty", bytes_len(raid.parity_bytes([])), 0)

## --- stripe layout -------------------------------------------------------

proc make_array(n: Int, block_size: Int) -> raid.Raid5Array:
    var paths: Array = []
    var i: Int = 0
    while i < n:
        let p: String = "/tmp/sagefs_raid_test_" + str(i) + ".img"
        ## os here is the bare-metal library, which has no exists/remove.
        sys.exec("rm -f " + p)
        fileio.write_at(p, 0, bytes(block_size))
        push(paths, p)
        i = i + 1
    return raid.Raid5Array(paths, block_size)

proc test_parity_device_rotation():
    let r = make_array(4, 8)
    check_bool("4 devices usable", r.usable())
    check("data width is N-1", r.data_width, 3)
    ## The parity device must rotate: if it stayed put, one device would carry
    ## parity for every stripe and lose a quarter of its capacity to redundancy.
    var seen: Array = []
    var s: Int = 0
    var distinct: Int = 0
    while s < 4:
        let p: Int = r.parity_device(s)
        if not _seen_before(seen, p):
            distinct = distinct + 1
        push(seen, p)
        s = s + 1
    check("parity rotates across 4 stripes", distinct, 4)

proc _seen_before(arr: Array, v: Int) -> Bool:
    for x in arr:
        if x == v:
            return true
    return false

proc test_too_few_devices():
    ## Three is the minimum for RAID5: two would be mirroring.
    check_bool("2 devices rejected", not raid.Raid5Array(["/tmp/x", "/tmp/y"], 8).usable())

## --- write, read, reconstruct, repair -----------------------------------

proc test_stripe_roundtrip():
    let r = make_array(3, 32)
    let d0: Bytes = pattern(1, 32)
    let d1: Bytes = pattern(2, 32)
    check_bool("write_stripe succeeds", r.write_stripe(0, [d0, d1]))
    let got: Array = r.read_stripe(0, [])
    check("read returns data width", len(got), 2)
    if len(got) == 2:
        check_bool("data block 0 intact", bytes_equal(got[0], d0))
        check_bool("data block 1 intact", bytes_equal(got[1], d1))

proc test_reconstruct_each_failed_device():
    ## Every device in turn fails and must come back byte-identical.
    let r = make_array(4, 48)
    let data: Array = [pattern(1, 48), pattern(2, 48), pattern(3, 48)]
    check_bool("stripe written", r.write_stripe(5, data))
    var dev: Int = 0
    while dev < 4:
        let rec: Bytes = r.reconstruct(5, [dev])
        check_bool("device " + str(dev) + " reconstructs", bytes_len(rec) == 48)
        let pd: Int = r.parity_device(5)
        if dev == pd:
            check_bool("parity block recovered",
                       bytes_equal(rec, raid.parity_bytes(data)))
        else:
            var slot: Int = 0
            var expect: Bytes = bytes()
            var i: Int = 0
            while i < 4:
                if i != pd:
                    if i == dev:
                        expect = data[slot]
                    slot = slot + 1
                i = i + 1
            check_bool("data block recovered for device " + str(dev),
                       bytes_equal(rec, expect))
        dev = dev + 1

proc test_read_stripe_reconstructs_in_place():
    let r = make_array(3, 32)
    let d0: Bytes = pattern(7, 32)
    let d1: Bytes = pattern(8, 32)
    r.write_stripe(0, [d0, d1])
    ## Wipe the first data device the way a dead disk would: zeros on disk.
    let first: Int = 0
    fileio.write_at(r.paths[first], 0, bytes(32))
    let got: Array = r.read_stripe(0, [first])
    check("read still returns full width", len(got), 2)
    if len(got) == 2:
        check_bool("lost block reconstructed from parity", bytes_equal(got[0], d0))
        check_bool("surviving block still correct", bytes_equal(got[1], d1))

proc test_repair_on_read():
    let r = make_array(3, 32)
    let d0: Bytes = pattern(11, 32)
    let d1: Bytes = pattern(12, 32)
    r.write_stripe(2, [d0, d1])
    ## For stripe 2 on 3 devices the parity lives on device 0, so failing
    ## device 0 would recover parity rather than data. Fail a data device.
    let dead: Int = 1
    fileio.write_at(r.paths[dead], 2 * 32, bytes(32))
    check("read triggers a repair", r.repair_on_read(2, [dead]), 1)
    ## After repair the data is back on the device itself, so a read that trusts
    ## the disk rather than the parity must agree.
    let raw: Bytes = fileio.read_at(r.paths[dead], 2 * 32, 32)
    ## Device 1 carries the first data block, so the repair restores d0.
    check_bool("repaired block written back to disk", bytes_equal(raw, d0))

proc test_two_failures_refused():
    ## With one parity block, two dead devices in the same stripe cannot be
    ## rebuilt. Returning zeros would be silent corruption, so it must refuse.
    let r = make_array(3, 32)
    r.write_stripe(0, [pattern(1, 32), pattern(2, 32)])
    check("two failures reconstruct nothing", bytes_len(r.reconstruct(0, [0, 1])), 0)
    check("two-failure read refused", len(r.read_stripe(0, [0, 1])), 0)
    check("two-failure repair refused", r.repair_on_read(0, [0, 1]), 0)

proc test_repair_noop_when_healthy():
    let r = make_array(3, 32)
    r.write_stripe(0, [pattern(1, 32), pattern(2, 32)])
    ## Already-present data must not be counted as a repair.
    check("healthy stripe needs no repair", r.repair_on_read(0, [0]), 0)

proc test_multiple_stripes_independent():
    ## Repairing one stripe must not disturb its neighbours.
    let r = make_array(3, 16)
    var s: Int = 0
    while s < 4:
        r.write_stripe(s, [pattern(s * 3 + 1, 16), pattern(s * 3 + 2, 16)])
        s = s + 1
    fileio.write_at(r.paths[0], 1 * 16, bytes(16))
    check("neighbour stripe repaired", r.repair_on_read(1, [0]), 1)
    var s2: Int = 0
    var ok: Bool = true
    while s2 < 4:
        let got: Array = r.read_stripe(s2, [])
        if len(got) != 2:
            ok = false
        else:
            if not bytes_equal(got[0], pattern(s2 * 3 + 1, 16)):
                ok = false
            if not bytes_equal(got[1], pattern(s2 * 3 + 2, 16)):
                ok = false
        s2 = s2 + 1
    check_bool("all stripes correct after repair", ok)

proc test_write_rejects_wrong_count():
    let r = make_array(3, 32)
    ## A partial stripe must not be written: it would reconstruct to garbage.
    check_bool("too few blocks refused", not r.write_stripe(0, [pattern(1, 32)]))
    check_bool("too many blocks refused",
               not r.write_stripe(0, [pattern(1, 32), pattern(2, 32), pattern(3, 32)]))

proc cleanup():
    var i: Int = 0
    while i < 8:
        let p: String = "/tmp/sagefs_raid_test_" + str(i) + ".img"
        ## os here is the bare-metal library, which has no exists/remove.
        sys.exec("rm -f " + p)
        i = i + 1

proc main():
    print("=== SageFS RAID Tests ===")
    test_xor_bytes()
    test_xor_width_mismatch()
    test_parity_bytes()
    test_parity_device_rotation()
    test_too_few_devices()
    test_stripe_roundtrip()
    test_reconstruct_each_failed_device()
    test_read_stripe_reconstructs_in_place()
    test_repair_on_read()
    test_two_failures_refused()
    test_repair_noop_when_healthy()
    test_multiple_stripes_independent()
    test_write_rejects_wrong_count()
    cleanup()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
