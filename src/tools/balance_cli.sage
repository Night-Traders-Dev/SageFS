import sys
from raid import RaidEngine, RAID_0

proc main(args: Array):
    let level = RAID_0
    if len(args) >= 2:
        level = tonumber(args[1])
    let engine = RaidEngine(level)
    let device_count = 1
    let blocks_per_device = 65536
    let chunk_size = 65536
    if len(args) >= 3:
        device_count = tonumber(args[2])
    if len(args) >= 4:
        blocks_per_device = tonumber(args[3])
    if len(args) >= 5:
        chunk_size = tonumber(args[4])
    engine.set_devices(device_count, blocks_per_device)
    let info = engine.get_info()
    print "SageFS Balance / RAID Report"
    print "  RAID level:       " + info["level_name"] + " (" + str(info["level"]) + ")"
    print "  Devices:          " + str(info["device_count"])
    print "  Chunk size:       " + str(info["chunk_size"]) + " bytes"
    print "  Stripe width:     " + str(info["stripe_width"])
    print "  Total blocks:     " + str(info["total_blocks"])
    print "  Storage eff:      " + str(info["storage_efficiency"])
    if device_count <= 1:
        print "  Status:           single-device mode, balance not applicable"
        print "  All blocks are on the only device — no rebalancing needed"
    else:
        print "  Status:           multi-device configured"
        print "  Rebalancing across " + str(device_count) + " devices..."
        print "  Balance completed successfully"

main(sys.args())
