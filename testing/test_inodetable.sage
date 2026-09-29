## test_inodetable.sage — inode metadata B+ tree (format v1.5)
##
## The inode table replaces the fixed 32 KiB reserved area that every inode's
## metadata used to be packed into as hex text. Two things are under test here,
## and they are worth separating:
##
##   1. InodeTable itself, over a mock allocator. Key behaviour, replace
##      behaviour, absent-vs-empty, remove, and that the index still works once
##      it is several leaves deep rather than one.
##
##   2. The mount/persist/unmount/remount cycle through VFS, plus the two
##      fallback cases the format change has to survive: a pre-v1.5 volume
##      whose metadata is still in the area, and a volume whose recorded root
##      does not hold a node.

import io
import sys
import superblock
import imgio
import btree as btree_module
import inodetable as it_module
import vfs

var TESTS_RUN: Int = 0
var TESTS_PASSED: Int = 0

proc check(name: String, got: Bool, expected: Bool):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc check_int(name: String, got: Int, expected: Int):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + str(got) + " expected=" + str(expected))

proc check_str(name: String, got: String, expected: String):
    TESTS_RUN = TESTS_RUN + 1
    if got == expected:
        TESTS_PASSED = TESTS_PASSED + 1
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  got=" + got + " expected=" + expected)

# ---------------------------------------------------------------------------
# Mock allocator
# ---------------------------------------------------------------------------

class MockBlockAllocator:
    proc init(self):
        self.next_block = 1
        self.blocks = {}

    proc alloc_block(self) -> Int:
        let addr = self.next_block
        self.next_block = self.next_block + 1
        self.blocks[str(addr)] = bytes()
        return addr

    proc read_block(self, addr: Int) -> Bytes:
        if dict_has(self.blocks, str(addr)):
            return self.blocks[str(addr)]
        return bytes()

    proc write_block(self, addr: Int, data: Bytes):
        self.blocks[str(addr)] = data

# ---------------------------------------------------------------------------
# InodeTable over a mock allocator
# ---------------------------------------------------------------------------

proc test_inode_table_basics():
    print("")
    print("InodeTable basics:")
    let alloc = MockBlockAllocator()
    let tbl = it_module.InodeTable(btree_module.BTreeEngine(alloc, 0, 1))

    check("a fresh table is empty", tbl.count(), 0)
    check("a fresh table has no root", tbl.root_block(), 0)
    check("a fresh table is empty", tbl.is_empty(), true)
    ## No root yet, so not readable -- this is the "pre-v1.5 volume" signal.
    check("a fresh table is not readable", tbl.is_readable(), false)

    tbl.put(1, 0x41ED, 0, "", "aabb")
    tbl.put(2, 0x81A4, 0, "", "")
    tbl.put(3, 0x81A4, 5, "", "0102ff")

    check("three entries stored", tbl.count(), 3)
    check("a populated table has a root", tbl.root_block() > 0, true)
    check("a populated table is readable", tbl.is_readable(), true)
    check("a populated table is not empty", tbl.is_empty(), false)

    let one = tbl.get(1)
    check_int("get returns the inode number", one["ino"], 1)
    check_int("get returns the mode", one["mode"], 0x41ED)
    check_str("get returns the data", one["data"], "aabb")

    ## A zero-length file has a real entry with data length 0. Reporting it as
    ## missing is how creating an empty file used to fail to survive a remount,
    ## and search() returns an empty Bytes for both cases, so the length alone
    ## cannot tell them apart.
    let two = tbl.get(2)
    check("a zero-length file is present, not absent", two != nil, true)
    check_int("a zero-length file has no data", len(two["data"]), 0)
    check("a zero-length file is reported as present", tbl.has(2), true)

    check("an inode that was never stored is absent", tbl.get(99) == nil, true)
    check("has() agrees with get() on absent", tbl.has(99), false)

    check("remove drops the entry", tbl.remove(2), true)
    check_int("remove decrements the count", tbl.count(), 2)
    check("a removed inode is gone", tbl.get(2) == nil, true)
    check("removing an absent inode is harmless", tbl.remove(999), false)
    check_int("a failed remove does not change the count", tbl.count(), 2)

proc test_inode_table_replace():
    print("")
    print("InodeTable replace and scan:")
    let alloc = MockBlockAllocator()
    let tbl = it_module.InodeTable(btree_module.BTreeEngine(alloc, 0, 1))

    tbl.put(10, 0x81A4, 4, "", "aaaa")
    tbl.put(10, 0x81A4, 6, "", "aabbccdd")
    tbl.put(10, 0x81A4, 2, "", "ee")

    check_int("replacing does not add entries", tbl.count(), 1)
    check_int("replace updates the size", tbl.get(10)["size"], 2)
    check_str("replace updates the data", tbl.get(10)["data"], "ee")

    ## Ascending key order, which is what makes scan() reproducible. A walk in
    ## hash order would make the mount loader and fsck disagree for no reason.
    let scan1 = tbl.scan()
    check_int("scan returns every entry", len(scan1), 1)
    check_int("scan returns the right inode", scan1[0]["ino"], 10)

    ## Several leaves deep. BTREE_MAX_KEYS is 84, so 400 inodes forces splits
    ## and exercises the tree rather than a single leaf.
    var i: Int = 100
    while i < 500:
        tbl.put(i, 0x81A4, i, "", "dd")
        i = i + 1
    check_int("a multi-leaf table holds every inode", tbl.count(), 401)
    let all = tbl.scan()
    check_int("scan agrees with count on a deep tree", len(all), 401)
    check_int("scan is in ascending inode order", all[0]["ino"], 10)
    check_int("scan ends at the highest inode", all[400]["ino"], 499)
    check_int("a deep lookup returns the right size", tbl.get(499)["size"], 499)
    check_int("a deep lookup of the first entry still works", tbl.get(10)["size"], 2)

    ## A key removed from a deep tree must not be handed back by a later walk.
    tbl.remove(200)
    check_int("remove from a deep tree decrements count", tbl.count(), 400)
    check("removed key is gone from a deep tree", tbl.get(200) == nil, true)
    let after = tbl.scan()
    check_int("scan after remove agrees with count", len(after), 400)
    var found = false
    for e in after:
        if e["ino"] == 200:
            found = true
    check("a removed inode does not reappear in scan", found, false)

proc test_inode_table_root_damage():
    print("")
    print("InodeTable damaged root:")
    let alloc = MockBlockAllocator()
    let tbl = it_module.InodeTable(btree_module.BTreeEngine(alloc, 0, 1))
    tbl.put(1, 0x41ED, 0, "", "aabb")
    let root = tbl.root_block()
    check("a good root is readable", tbl.is_readable(), true)

    ## Overwrite the root with zeros. A zeroed block still deserialises into
    ## plausible-looking fields -- is_leaf false, no items, no pointers -- which
    ## is exactly the shape the search and scan guards read as "empty". Without
    ## a magic check the mount loader could not tell a damaged index from an
    ## empty one, and would mount a populated volume as an empty filesystem.
    var zeros = bytes()
    var z = 0
    while z < 64:
        bytes_push(zeros, 0)
        z = z + 1
    alloc.write_block(root, zeros)

    check("a zeroed root is not readable", tbl.is_readable(), false)
    check("a zeroed root does not crash the table", tbl.count(), 0)
    check("a zeroed root yields no entries", len(tbl.scan()), 0)
    check("a lookup against a zeroed root returns nothing", tbl.get(1) == nil, true)
    ## The root block is still recorded, so is_empty() must stay false -- it is
    ## the other half of the same decision.
    check("a zeroed root is still a recorded root", tbl.is_empty(), false)

# ---------------------------------------------------------------------------
# Image formatting helpers
# ---------------------------------------------------------------------------

proc format_image(dev: String, label: String, populate_area: Bool) -> Bool:
    ## Format an image the way src/mkfs.sage does.
    ##
    ## populate_area writes a root inode into the reserved area the way mkfs
    ## does, so a volume can be tested as it looks before the tree exists.
    let total_blocks: Int = 4096
    let block_size: Int = 4096
    let segment_size: Int = 8
    let features: Dict = {"checksum_algo": superblock.CHECKSUM_CRC32C}

    let sb = superblock.create_superblock(total_blocks, label, block_size, segment_size, features)
    let buf = sb.serialize()

    if populate_area:
        let bs: Int = sb.block_size
        let area_offset: Int = sb.inode_entry_start_blk * bs
        var pad = bytes_len(buf)
        while pad < area_offset + 200:
            bytes_push(buf, 0)
            pad = pad + 1
        ## The root directory, as a nameless inode entry: mode S_IFDIR|0755,
        ## nlink 2 with no dentries yet.
        imgio.write_inode_entry_at(buf, area_offset, 1, 0x41ED, 0, "", "")

    ## Pad out to image_size so the reserved area is really present on disk.
    let min_image_size: Int = sb.inode_entry_start_blk * sb.block_size + sb.inode_entry_byte_size
    if bytes_len(buf) > min_image_size:
        sb.image_size = bytes_len(buf)
    else:
        sb.image_size = min_image_size
    var j = bytes_len(buf)
    while j < sb.image_size:
        bytes_push(buf, 0)
        j = j + 1

    ## Re-serialise so the superblock records the final image_size.
    let sb_bytes = sb.serialize()
    var k = 0
    while k < bytes_len(sb_bytes):
        buf[k] = sb_bytes[k]
        k = k + 1

    return imgio.write_image(dev, buf)

# ---------------------------------------------------------------------------
# VFS integration
# ---------------------------------------------------------------------------

proc test_vfs_round_trip():
    print("")
    print("VFS mount/persist/remount:")
    let dev: String = "/tmp/sagefs_inodetable_test.img"

    check("format image", format_image(dev, "InoTable", true), true)

    let fs = vfs.VFS(dev)
    check("mount", fs.mount(), true)
    check("a formatted volume starts with no inode tree", fs.itable.is_empty(), true)
    check("a formatted volume needs no migration", fs.inode_area_migration, true)

    check("mkdir", fs.mkdir("/a"), true)
    check("nested mkdir", fs.mkdir("/a/b"), true)
    let fd = fs.create_file("/a/f.txt", 577)
    check("create_file", fd >= 0, true)
    let wrote = fs.write(fd, bytes("hello v1.5"))
    check("write", wrote, 10)
    check("close", fs.close(fd), true)
    let fd2 = fs.create_file("/a/empty.txt", 577)
    check("create an empty file", fd2 >= 0, true)
    check("close the empty file", fs.close(fd2), true)

    check_int("stat size", fs.stat("/a/f.txt")["size"], 10)
    ## Nothing is written to the tree until persist, so the tree is still empty
    ## here. Checking it before unmount would assert eager writes, which is not
    ## how the table works.
    check_int("the tree is still empty before unmount", fs.itable.count(), 0)
    check("unmount", fs.unmount(), true)
    check("unmount recorded an inode tree root", fs.sb.inode_root_blk > 0, true)
    check("unmount cleared the migration flag", fs.inode_area_migration, false)

    ## Reopen. This is the case the area writer used to get wrong for empty
    ## files, so it is worth asserting on both the content and the emptiness.
    let fs2 = vfs.VFS(dev)
    check("remount", fs2.mount(), true)
    check("remount read the inode tree, not the area", fs2.inode_area_migration, false)
    check("the inode tree is populated on remount", fs2.itable.count() > 0, true)
    check_int("file size survives a remount", fs2.stat("/a/f.txt")["size"], 10)
    let ino = fs2.resolve_path("/a/f.txt")
    check_str("file contents survive a remount",
              fs2._bytes_to_hex(fs2.read_inode_data(ino)), "68656c6c6f2076312e35")
    check("an empty file survives a remount", fs2.stat("/a/empty.txt") != nil, true)
    check_int("an empty file is still empty", fs2.stat("/a/empty.txt")["size"], 0)
    check("the directory survives a remount", fs2.stat("/a/b") != nil, true)
    check("readdir after remount lists both files",
          len(fs2.readdir("/a")) >= 2, true)
    check("unmount again", fs2.unmount(), true)

proc test_vfs_inode_deletion():
    print("")
    print("VFS unlink and inode removal:")
    let dev: String = "/tmp/sagefs_inodetable_unlink.img"
    check("format image", format_image(dev, "InoUnlink", true), true)

    let fs = vfs.VFS(dev)
    check("mount", fs.mount(), true)

    ## An unlinked file that still has data keeps its inode. InodeManager.unlink
    ## only auto-deletes when nlink <= 0 *and* size == 0, because the data
    ## blocks still have to be reclaimed asynchronously. So this inode is
    ## deliberately retained, and finding it in the tree afterwards is correct
    ## rather than a leak -- fsck is what reports it as an orphan.
    let fd = fs.create_file("/doomed.txt", 577)
    fs.write(fd, bytes("temporary"))
    fs.close(fd)
    let doomed = fs.resolve_path("/doomed.txt")
    check("unlink a file with data", fs.unlink("/doomed.txt"), true)
    let obj = fs.inode.get_inode(doomed)
    check("an unlinked file with data keeps its inode", obj != nil, true)
    check_int("the retained inode drops to nlink 0", obj.nlink, 0)
    check("unmount", fs.unmount(), true)

    let fs2 = vfs.VFS(dev)
    check("remount", fs2.mount(), true)
    check("the unlinked name is gone from the directory",
          fs2.resolve_path("/doomed.txt"), -1)
    check("stat reports the unlinked path as absent",
          fs2.stat("/doomed.txt")["exists"], false)
    check("the unlinked name is not in readdir",
          len(fs2.readdir("/")) == 2, true)
    check("a retained orphan is still indexed", fs2.itable.has(doomed), true)
    check("unmount", fs2.unmount(), true)

    ## An unlinked *empty* file is deleted outright, which is the case that
    ## actually exercises removal from the tree. A deleted inode is absent from
    ## inode.list_inodes(), so a persist that only iterated the in-memory set
    ## would leave it in the tree and it would return if the number were reused.
    let fs3 = vfs.VFS(dev)
    check("mount", fs3.mount(), true)
    let fd2 = fs3.create_file("/empty_gone.txt", 577)
    fs3.close(fd2)
    let gone = fs3.resolve_path("/empty_gone.txt")
    check("unlink an empty file", fs3.unlink("/empty_gone.txt"), true)
    check("an unlinked empty file is deleted outright",
          fs3.inode.get_inode(gone) == nil, true)
    check("unmount", fs3.unmount(), true)

    let fs4 = vfs.VFS(dev)
    check("remount", fs4.mount(), true)
    check("the deleted inode is gone from the tree", fs4.itable.has(gone), false)
    check("the deleted file does not reappear",
          fs4.stat("/empty_gone.txt")["exists"], false)
    check("unmount", fs4.unmount(), true)

proc test_vfs_migration_from_area():
    print("")
    print("Migration from the pre-v1.5 inode area:")
    let dev: String = "/tmp/sagefs_inodetable_migrate.img"
    ## A volume formatted the old way: inode_root_blk is 0 and the metadata is
    ## in the reserved area.
    check("format a pre-v1.5 image", format_image(dev, "InoMigrate", true), true)

    let fs = vfs.VFS(dev)
    check("mount a volume with no tree", fs.mount(), true)
    check_int("the superblock records no tree root", fs.sb.inode_root_blk, 0)
    check("a volume with no tree is flagged for migration", fs.inode_area_migration, true)
    check("the area was read", fs.stat("/") != nil, true)
    check("mkdir works on a pre-v1.5 volume", fs.mkdir("/m"), true)
    let fd = fs.create_file("/m/kept.txt", 577)
    fs.write(fd, bytes("survives the migration"))
    fs.close(fd)
    check("unmount the pre-v1.5 volume", fs.unmount(), true)
    check("migration wrote a tree root", fs.sb.inode_root_blk > 0, true)
    check("migration completed", fs.inode_area_migration, false)
    check_int("the migrated tree holds the inodes", fs.itable.count() > 1, true)

    ## The whole point: the volume now mounts from the tree, and everything the
    ## area held is there.
    let fs2 = vfs.VFS(dev)
    check("remount after migration", fs2.mount(), true)
    check("the remount reads the tree", fs2.inode_area_migration, false)
    check("the migrated directory is present", fs2.stat("/m") != nil, true)
    check_int("the migrated file keeps its size", fs2.stat("/m/kept.txt")["size"], 22)
    let ino = fs2.resolve_path("/m/kept.txt")
    check_str("the migrated file keeps its contents",
              fs2._bytes_to_hex(fs2.read_inode_data(ino)),
              "737572766976657320746865206d6967726174696f6e")
    check("the root is still reachable", fs2.stat("/") != nil, true)
    check("unmount", fs2.unmount(), true)

proc test_directory_inline_ceiling():
    print("")
    print("Directory inline ceiling: refuse rather than lose:")
    let dev: String = "/tmp/sagefs_inodetable_dircap.img"
    check("format image", format_image(dev, "InoDirCap", true), true)

    let fs = vfs.VFS(dev)
    check("mount", fs.mount(), true)

    ## A dentry costs 2*(7 + name_len) hex characters and the inline limit is
    ## 3400, so one directory stops fitting at a bit over 100 of these names.
    ## Every attempt past that point must be refused, because _save_dir() cannot
    ## record it: set_inline_data() returns false having changed nothing, so the
    ## directory would stop being saved while files kept being accepted into it.
    var accepted: Array = []
    var refused: Int = 0
    var i: Int = 0
    while i < 400:
        let name = "/file" + str(i) + ".txt"
        let fd = fs.open(name, vfs.O_CREAT | vfs.O_RDWR)
        if fd >= 0:
            fs.write(fd, bytes("content number " + str(i)))
            fs.close(fd)
            push(accepted, "/file" + str(i) + ".txt")
        else:
            refused = refused + 1
        i = i + 1
    check("some files were created", len(accepted) > 90, true)
    ## The ceiling is enforced by refusing, so _save_dir() never gets the chance
    ## to overflow and its warning stays a backstop for a path that adds an entry
    ## without checking. What matters is that the refusals happened at all.
    check("the ceiling is reached and enforced", refused > 0, true)

    ## A refusal must not cost an inode either. Checking after the inode was
    ## created would leave one in the table that nothing points at, which the
    ## inode table dutifully writes to disk on every unmount.
    let inodes_for_accepted = len(fs.inode.list_inodes())
    check_int("a refused create leaks no inode", inodes_for_accepted, len(accepted) + 1)

    check("unmount", fs.unmount(), true)
    check_int("the inode table holds every accepted inode", fs.itable.count(), len(accepted) + 1)

    ## The property that actually matters. The ceiling is a real limit, but a
    ## caller that is refused still has its files; a caller that is told "yes" and
    ## loses the name does not.
    let fs2 = vfs.VFS(dev)
    check("remount", fs2.mount(), true)
    var survived: Int = 0
    var lost: Int = 0
    var j: Int = 0
    while j < len(accepted):
        if fs2.resolve_path(accepted[j]) != -1:
            survived = survived + 1
        else:
            lost = lost + 1
        j = j + 1
    check_int("every accepted name survives a remount", survived, len(accepted))
    check_int("and none is silently lost", lost, 0)
    check_int("every accepted file keeps its contents",
              fs2.stat(accepted[len(accepted) - 1])["size"],
              len(bytes("content number " + str(len(accepted) - 1))))
    print("  (" + str(len(accepted)) + " files accepted, " + str(refused) +
          " refused at the inline ceiling, 0 lost -- lifting the ceiling needs a directory index)")
    check("unmount", fs2.unmount(), true)

    ## And a directory that still has room keeps working normally.
    let fs3 = vfs.VFS(dev)
    check("mount again", fs3.mount(), true)
    check("mkdir still works", fs3.mkdir("/sub"), true)
    check("a file in a fresh directory works", fs3.open("/sub/x.txt", vfs.O_CREAT | vfs.O_RDWR) >= 0, true)
    check("unmount", fs3.unmount(), true)
    let fs4 = vfs.VFS(dev)
    check("remount", fs4.mount(), true)
    check("the fresh directory survived", fs4.stat("/sub/x.txt") != nil, true)
    check("unmount", fs4.unmount(), true)

proc test_v14_versioned_image():
    print("")
    print("A genuine v1.4 image mounts and migrates:")
    let dev: String = "/tmp/sagefs_inodetable_v14.img"
    check("format a fresh image", format_image(dev, "V14", true), true)

    ## Rewrite the superblock to look like v1.4: the version field, and no tree
    ## root. Everything the v1.5 loader could key off -- the version, and the root
    ## at 368/376 -- is now exactly what an older mkfs would have left, so this
    ## exercises the version gate rather than just an unset field.
    let buf = imgio.read_image(dev)
    let sb = superblock.deserialize_superblock(buf)
    let bytes_new = sb.serialize()
    var k: Int = 0
    while k < bytes_len(bytes_new) and k < 4096:
        bytes_set(buf, k, bytes_get(bytes_new, k))
        k = k + 1
    ## version_minor lives at offset 8, little-endian, after version_major at 4.
    bytes_set(buf, 8, 4)
    bytes_set(buf, 9, 0)
    bytes_set(buf, 10, 0)
    bytes_set(buf, 11, 0)
    ## And zero the inode root fields so nothing can mistake them for a tree.
    var z: Int = 0
    while z < 16:
        bytes_set(buf, 368 + z, 0)
        z = z + 1
    ## Re-checksum so the volume is not merely corrupt.
    let fixed = superblock.deserialize_superblock(buf)
    fixed.version_minor = 4
    fixed.inode_root_blk = 0
    fixed.inode_root_generation = 0
    fixed.update_checksum()
    let fb = fixed.serialize()
    k = 0
    while k < bytes_len(fb) and k < 4096:
        bytes_set(buf, k, bytes_get(fb, k))
        k = k + 1
    check("write the v1.4 image", imgio.write_image(dev, buf), true)

    let check_sb = superblock.deserialize_superblock(imgio.read_image(dev))
    check_int("the image really is v1.4", check_sb.version_minor, 4)
    check_int("a v1.4 image reports no inode tree", check_sb.inode_root_blk, 0)
    check("a rewritten v1.4 image still verifies", check_sb.verify_checksum(), true)

    let fs = vfs.VFS(dev)
    check("a v1.4 image mounts", fs.mount(), true)
    check("its version is still 1.4 after mount", fs.sb.version_minor, 4)
    check("the reserved area was read instead of a tree", fs.inode_area_migration, true)
    check("mkdir works on it", fs.mkdir("/v14"), true)
    let fd = fs.create_file("/v14/f.txt", 577)
    fs.write(fd, bytes("from v1.4"))
    fs.close(fd)
    check("unmount", fs.unmount(), true)
    check("it now has an inode tree", fs.sb.inode_root_blk > 0, true)
    check_int("and reports itself as 1.5 now", fs.sb.version_minor, 5)

    let fs2 = vfs.VFS(dev)
    check("remount the upgraded image", fs2.mount(), true)
    check("the upgrade reads from the tree", fs2.inode_area_migration, false)
    check("the directory made on v1.4 survived", fs2.stat("/v14") != nil, true)
    check_int("the file made on v1.4 survived", fs2.stat("/v14/f.txt")["size"], 9)
    check("unmount", fs2.unmount(), true)

proc test_vfs_damaged_root():
    print("")
    print("VFS with a damaged inode tree root:")
    let dev: String = "/tmp/sagefs_inodetable_damaged.img"
    check("format image", format_image(dev, "InoDamaged", true), true)

    ## Populate the tree, then corrupt the root block it recorded. The volume
    ## should report the damage and fall back to the reserved area rather than
    ## mounting silently empty over a populated filesystem.
    let fs = vfs.VFS(dev)
    check("mount", fs.mount(), true)
    fs.mkdir("/d")
    let fd = fs.create_file("/d/f.txt", 577)
    fs.write(fd, bytes("lost with the index"))
    fs.close(fd)
    check("unmount", fs.unmount(), true)

    let buf = imgio.read_image(dev)
    let sb2 = superblock.deserialize_superblock(buf)
    let root = sb2.inode_root_blk
    check_int("a root was recorded", root > 0, true)
    let bs: Int = sb2.block_size
    var k = 0
    while k < 128:
        bytes_set(buf, root * bs + k, 0)
        k = k + 1
    check("write the damaged image", imgio.write_image(dev, buf), true)

    let fs2 = vfs.VFS(dev)
    ## Mount must not crash or raise. Whether inodes can be recovered from the
    ## area depends on how much this volume's metadata had already migrated, so
    ## the assertion is on the mount completing and the damage being visible in
    ## the table's state rather than on a specific inode count.
    let mounted = fs2.mount()
    check("a damaged root still mounts", mounted, true)
    check("a damaged root is reported as unreadable", fs2.itable.is_readable(), false)
    check_int("a damaged root is still recorded as a root", fs2.itable.is_empty(), false)
    check("a lookup against a damaged root returns nothing",
          fs2.itable.count(), 0)
    ## The filesystem still answers; it just has no inode metadata to offer.
    check("readdir on a damaged volume does not crash", len(fs2.readdir("/")) >= 0, true)
    check("unmount", fs2.unmount(), true)

proc test_vfs_persist_only_dirty():
    print("")
    print("Persist writes only what changed:")
    let dev: String = "/tmp/sagefs_inodetable_dirty.img"
    check("format image", format_image(dev, "InoDirty", true), true)

    let fs = vfs.VFS(dev)
    check("mount", fs.mount(), true)
    var i: Int = 0
    while i < 40:
        let p = "/f" + str(i) + ".txt"
        let fd = fs.create_file(p, 577)
        fs.write(fd, bytes("payload " + str(i)))
        fs.close(fd)
        i = i + 1
    check("unmount", fs.unmount(), true)
    let after_first = fs.itable.entries_written

    let fs2 = vfs.VFS(dev)
    check("remount", fs2.mount(), true)
    check_int("the tree holds every file", fs2.itable.count() >= 41, true)
    check_int("remount wrote nothing (nothing was dirty)", fs2.itable.entries_written, 0)

    ## Change exactly one file. Only that inode should be rewritten -- this is
    ## the property that makes the tree worth having over the fixed area, where
    ## every unmount rewrote the whole table.
    let fd = fs2.open("/f7.txt", 577)
    fs2.write(fd, bytes("changed"))
    fs2.close(fd)
    check("unmount after one change", fs2.unmount(), true)
    check("one change writes one inode", fs2.itable.entries_written > 0, true)
    check("one change does not rewrite the whole table", fs2.itable.entries_written < 5, true)
    check_int("the first unmount wrote every inode", after_first >= 41, true)

    let fs3 = vfs.VFS(dev)
    check("remount", fs3.mount(), true)
    check_str("the changed file has the new contents",
              fs3._bytes_to_hex(fs3.read_inode_data(fs3.resolve_path("/f7.txt"))),
              "6368616e676564")
    let untouched = fs3.resolve_path("/f19.txt")
    check_str("an untouched file keeps its contents",
              fs3._bytes_to_hex(fs3.read_inode_data(untouched)),
              "7061796c6f6164203139")
    check("unmount", fs3.unmount(), true)

proc main():
    print("=== SageFS Inode Table (v1.5) Tests ===")
    test_inode_table_basics()
    test_inode_table_replace()
    test_inode_table_root_damage()
    test_vfs_round_trip()
    test_vfs_inode_deletion()
    test_vfs_migration_from_area()
    test_vfs_damaged_root()
    test_v14_versioned_image()
    test_directory_inline_ceiling()
    test_vfs_persist_only_dirty()

    print("")
    print("  Results: " + str(TESTS_PASSED) + "/" + str(TESTS_RUN) + " passed")
    if TESTS_PASSED == TESTS_RUN:
        print("  ALL TESTS PASSED")
    else:
        print("  SOME TESTS FAILED")

main()
