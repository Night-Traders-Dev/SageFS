import sys
from snapshot import SnapshotEngine

proc cmd_create(engine: SnapshotEngine, subvol: String, snap: String) -> Bool:
    let result = engine.create_snapshot(subvol, snap, clock())
    if result != nil:
        print "Created snapshot '" + snap + "' for subvolume '" + subvol + "'"
        return true
    print "Failed: subvolume '" + subvol + "' not found"
    return false

proc cmd_delete(engine: SnapshotEngine, subvol: String, snap: String) -> Bool:
    let ok = engine.delete_snapshot(subvol, snap)
    if ok:
        print "Deleted snapshot '" + snap + "' from subvolume '" + subvol + "'"
    else:
        print "Failed: snapshot '" + snap + "' not found in subvolume '" + subvol + "'"
    return ok

proc cmd_list(engine: SnapshotEngine, subvol: String):
    let snaps = engine.list_snapshots(subvol)
    if len(snaps) == 0:
        print "No snapshots for subvolume '" + subvol + "'"
        return
    print "Snapshots for subvolume '" + subvol + "':"
    for s in snaps:
        print "  " + s.name + "  root_block=" + str(s.root_block) + "  created=" + str(s.creation_time)

proc main(args: Array):
    if len(args) < 2:
        print "Usage: snapshot_cli.sage <command> [args]"
        print "Commands:"
        print "  create <subvol> <snap>   Create a snapshot"
        print "  delete <subvol> <snap>   Delete a snapshot"
        print "  list <subvol>            List snapshots for a subvolume"
        return
    let engine = SnapshotEngine()
    let cmd = args[1]
    if cmd == "create" and len(args) >= 4:
        cmd_create(engine, args[2], args[3])
    elif cmd == "delete" and len(args) >= 4:
        cmd_delete(engine, args[2], args[3])
    elif cmd == "list" and len(args) >= 3:
        cmd_list(engine, args[2])
    else:
        print "Unknown command or missing arguments"

main(sys.args())
