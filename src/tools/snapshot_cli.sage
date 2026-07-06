proc cmd_create(subvol: String, snap: String) -> Bool:
    print "Created snapshot " + snap + " in " + subvol
    return true
proc cmd_delete(subvol: String, snap: String) -> Bool:
    print "Deleted snapshot " + snap
    return true
proc main(args: Array):
    if len(args) > 2 and args[1] == "create":
        cmd_create("root", args[2])
    print "Snapshot CLI completed"
