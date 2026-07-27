## test_raid.sage — unit tests for the SageFS RAID engine

import raid
let RaidEngine = raid.RaidEngine
let RAID_0 = raid.RAID_0
let RAID_1 = raid.RAID_1
let RAID_5 = raid.RAID_5
let RAID_6 = raid.RAID_6
let RAID_10 = raid.RAID_10

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

proc check_float(name: String, got: Float, expected: Float):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc test_level_name():
    print("get_level_name:")
    let r0 = RaidEngine(RAID_0)
    check("RAID0 name", r0.get_level_name(), "RAID0")
    let r1 = RaidEngine(RAID_1)
    check("RAID1 name", r1.get_level_name(), "RAID1")
    let r5 = RaidEngine(RAID_5)
    check("RAID5 name", r5.get_level_name(), "RAID5")
    let r6 = RaidEngine(RAID_6)
    check("RAID6 name", r6.get_level_name(), "RAID6")
    let r10 = RaidEngine(RAID_10)
    check("RAID10 name", r10.get_level_name(), "RAID10")
    let r99 = RaidEngine(99)
    check("unknown level name", r99.get_level_name(), "none")

proc test_set_devices_raidd0():
    print("set_devices RAID0:")
    let engine = RaidEngine(RAID_0)
    engine.set_devices(4, 1000)
    check("RAID0 total_blocks", engine.total_blocks, 4000)
    check("RAID0 stripe_width", engine.stripe_width, 4)
    check("RAID0 devices count", len(engine.devices), 4)
    check_float("RAID0 efficiency", engine.get_storage_efficiency(), 1.0)

proc test_set_devices_raidd1():
    print("set_devices RAID1:")
    let engine = RaidEngine(RAID_1)
    engine.set_devices(3, 1000)
    check("RAID1 total_blocks", engine.total_blocks, 1000)
    check("RAID1 stripe_width", engine.stripe_width, 1)
    check_float("RAID1 efficiency", engine.get_storage_efficiency(), 1.0 / 3.0)

proc test_set_devices_raidd5():
    print("set_devices RAID5:")
    let engine = RaidEngine(RAID_5)
    engine.set_devices(4, 1000)
    check("RAID5 total_blocks", engine.total_blocks, 3000)
    check("RAID5 stripe_width", engine.stripe_width, 3)
    check_float("RAID5 efficiency", engine.get_storage_efficiency(), 0.75)

proc test_set_devices_raidd6():
    print("set_devices RAID6:")
    let engine = RaidEngine(RAID_6)
    engine.set_devices(5, 1000)
    check("RAID6 total_blocks", engine.total_blocks, 3000)
    check("RAID6 stripe_width", engine.stripe_width, 3)
    check_float("RAID6 efficiency", engine.get_storage_efficiency(), 0.6)

proc test_set_devices_raidd10():
    print("set_devices RAID10:")
    let engine = RaidEngine(RAID_10)
    engine.set_devices(4, 1000)
    check("RAID10 total_blocks", engine.total_blocks, 2000)
    check("RAID10 stripe_width", engine.stripe_width, 2)
    check_float("RAID10 efficiency", engine.get_storage_efficiency(), 0.5)

proc test_map_address_raidd0():
    print("map_address RAID0:")
    let engine = RaidEngine(RAID_0)
    engine.set_devices(4, 10000)
    let mapping = engine.map_address(0)
    check("RAID0 addr=0 device", mapping["device"], 0)
    check("RAID0 addr=0 device_block", mapping["device_block"], 0)
    check("RAID0 addr=0 stripe_width", mapping["stripe_width"], 4)

    let mapping2 = engine.map_address(65536)
    check("RAID0 addr=65536 device", mapping2["device"], 1)

proc test_map_address_raidd1():
    print("map_address RAID1:")
    let engine = RaidEngine(RAID_1)
    engine.set_devices(2, 10000)
    let mapping = engine.map_address(0)
    check("RAID1 addr=0 device", mapping["device"], 0)
    check_bool("RAID1 has mirror_devices", len(mapping["mirror_devices"]) > 0)

proc test_map_address_raidd5():
    print("map_address RAID5:")
    let engine = RaidEngine(RAID_5)
    engine.set_devices(4, 10000)
    let mapping = engine.map_address(0)
    check("RAID5 addr=0 data_device", mapping["data_device"], 0)
    check_bool("RAID5 has parity_device", dict_has(mapping, "parity_device"))

proc test_map_address_raidd6():
    print("map_address RAID6:")
    let engine = RaidEngine(RAID_6)
    engine.set_devices(5, 10000)
    let mapping = engine.map_address(0)
    check("RAID6 addr=0 data_device", mapping["data_device"], 0)
    check_bool("RAID6 has p_device", dict_has(mapping, "p_device"))
    check_bool("RAID6 has q_device", dict_has(mapping, "q_device"))

proc test_map_address_raidd10():
    print("map_address RAID10:")
    let engine = RaidEngine(RAID_10)
    engine.set_devices(4, 10000)
    let mapping = engine.map_address(0)
    check("RAID10 addr=0 device", mapping["device"], 0)
    check_bool("RAID10 has mirror", dict_has(mapping, "mirror"))

proc test_compute_parity():
    print("compute_parity:")
    let engine = RaidEngine(RAID_5)
    let parity = engine.compute_parity([1, 2, 3, 4])
    check("parity of 1,2,3,4", parity, 1 ^ 2 ^ 3 ^ 4)
    let parity2 = engine.compute_parity([0, 0, 0])
    check("parity of zeros", parity2, 0)

proc test_get_info():
    print("get_info:")
    let engine = RaidEngine(RAID_5)
    engine.set_devices(4, 5000)
    let info = engine.get_info()
    check("info level", info["level"], RAID_5)
    check("info level_name", info["level_name"], "RAID5")
    check("info device_count", info["device_count"], 4)
    check("info chunk_size", info["chunk_size"], 65536)
    check("info total_blocks", info["total_blocks"], 15000)

proc main():
    print("=== SageFS RAID Engine Tests ===")
    test_level_name()
    test_set_devices_raidd0()
    test_set_devices_raidd1()
    test_set_devices_raidd5()
    test_set_devices_raidd6()
    test_set_devices_raidd10()
    test_map_address_raidd0()
    test_map_address_raidd1()
    test_map_address_raidd5()
    test_map_address_raidd6()
    test_map_address_raidd10()
    test_compute_parity()
    test_get_info()
    print("")
    print("Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("ALL TESTS PASSED")
    else:
        print("SOME TESTS FAILED")

main()
