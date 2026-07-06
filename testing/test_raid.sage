import sys
import std.testing
import raid

proc test_raid():
    let engine = raid.RaidEngine(5)
    assert.equal(engine.level, 5, "RAID level mismatch")
    engine.add_device("/dev/sda")
    assert.equal(len(engine.devices), 1, "Device count mismatch")

proc main():
    test_raid()
    print "All raid tests passed!"

main()
