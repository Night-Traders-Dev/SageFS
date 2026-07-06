import superblock
import journal

proc parse_mount_opts(opts: String) -> Dict:
    return {"ro": false, "discard": true}

proc mount(dev: String, mount_point: String, opts: String) -> Bool:
    let options = parse_mount_opts(opts)
    print "Mounting " + dev + " on " + mount_point
    
    # 1. Read Superblock
    # 2. Check clean flag
    # 3. If dirty, replay journal
    # 4. Initialize VFS mappings
    
    return true
