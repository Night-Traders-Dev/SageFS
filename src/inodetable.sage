## inodetable.sage — SageFS inode metadata index (format v1.5)
##
## Before v1.5 every inode's metadata was written as hex text into a single
## fixed 32 KiB area carved out of the reserved blocks (inode_entry_start_blk 8,
## 8 blocks). That capped the filesystem at whatever fit in 32 KiB, and
## _persist_all() had to know it was about to run out and drop inodes on the
## floor. This moves that metadata into a B+ tree instead, which is the first
## half of the hybrid design: F2FS keeps its fixed-layout, allocation-tuned data
## side, and everything indexed goes into independent CoW B+ trees.
##
## The tree is *separate* from the extent tree -- its own root, its own
## generation, its own blocks. That is not incidental. A shared root would make
## the inode table and the extent map share a CoW generation, so writing one
## inode would copy the whole extent map too, and O(1) snapshot cloning would
## need the other two cloned trees as well. Separate roots are also what makes
## an inode-only snapshot possible.
##
## Values are the same entries the area held, in the same 16-byte-header
## little-endian layout, via imgio.encode_inode_entry(). The codec is shared
## deliberately: the area and the tree must be byte-identical per entry so a
## volume can be migrated without rewriting every entry, and so the fallback
## path below is not a second parser.
##
## Inodes are keyed by inode number alone (type 0, offset 0). The key has room
## for (object_id, type, offset) because the same tree class indexes extents and
## will index xattrs; the unused fields stay zero rather than being repurposed,
## so a future type gets its own keyspace instead of colliding with these.

import btree as btree_module
import imgio

## Key type reserved for plain inode metadata. Distinct from the extent key
## type so the two indexes can never collide if they are ever merged.
let INODE_KEY_TYPE: Int = 0

class InodeTable:
    proc init(self, btree):
        ## `btree` is a btree_module.BTreeEngine. It is injected rather than
        ## constructed here so the caller owns the root and generation, and so
        ## the extent tree and the inode tree can be told apart by which engine
        ## they hold. A BTreeEngine with root_block == 0 is an empty tree and
        ## allocates its root on first insert, so a fresh volume and a remount
        ## need no separate case.
        self.btree = btree
        self.entries_written = 0
        self.entries_read = 0
        ## Generation the engine was opened at, before the lazy bump below.
        self.opened_generation = btree.current_generation
        self.writable = false

    proc ensure_writable(self):
        ## Advance the CoW generation, but only when something is about to change.
        ##
        ## Opening the engine at generation + 1 -- which is what the extent tree
        ## does, and what this did at first -- makes every node in the table stale
        ## the moment the tree is touched, so a full CoW of the inode table is
        ## copied out on every mount that writes anything. That is expensive, and
        ## here it was also destructive: the NAT is not persisted across mounts,
        ## so block allocation restarts each session and a metadata block handed
        ## out after a remount can collide with a block an earlier session was
        ## using for file data. Copying the whole table is enough allocations to
        ## hit that, and the collision overwrote a file's extents with tree
        ## nodes -- the file kept its length and lost its contents.
        ##
        ## Bumping on the first mutation instead means a mount that changes
        ## nothing allocates nothing, and one that changes a few inodes copies
        ## only the paths to them. CoW isolation is unchanged: the bump still
        ## happens before any node is modified, so no node at the old generation
        ## is written in place.
        if self.writable:
            return
        self.btree.current_generation = self.opened_generation + 1
        self.writable = true

    proc key_for(self, ino: Int):
        return btree_module.BTreeKey(ino, INODE_KEY_TYPE, 0)

    proc put(self, ino: Int, mode: Int, size: Int, name: String, data: String) -> Bool:
        ## Store (or replace) one inode's metadata.
        ##
        ## A zero-length file is still written. A previous version of the area
        ## writer skipped empty entries, so truncate-to-0 and creating an empty
        ## file left nothing behind and the file did not survive a remount.
        ## BTreeEngine.insert replaces an existing value in place, so this is
        ## also the update path -- writing the same ino twice does not grow the
        ## tree.
        self.ensure_writable()
        let payload = imgio.encode_inode_entry(ino, mode, size, name, data)
        self.btree.insert(self.key_for(ino), payload)
        self.entries_written = self.entries_written + 1
        return true

    proc get(self, ino: Int) -> Dict:
        ## Read one inode's metadata, or nil if it is not in the tree.
        ##
        ## An absent key and a present-but-empty key are different things: a
        ## zero-length file has a real entry with a 0 data length, and must not
        ## be reported as missing. BTreeEngine.search returns an empty Bytes for
        ## both, so the length alone cannot tell them apart.
        let raw = self.btree.search(self.key_for(ino))
        if bytes_len(raw) == 0:
            return nil
        self.entries_read = self.entries_read + 1
        return imgio.decode_inode_entry(raw, 0)

    proc has(self, ino: Int) -> Bool:
        return self.get(ino) != nil

    proc remove(self, ino: Int) -> Bool:
        ## Drop an inode from the index. A deleted inode must be removed rather
        ## than merely left unreachable from a directory, or it stays in the
        ## tree forever and comes back if the number is ever reused.
        ##
        ## BTreeEngine.delete() reports nothing, so presence is checked first in
        ## order to answer whether there was anything to remove.
        self.ensure_writable()
        let present = self.has(ino)
        self.btree.delete(self.key_for(ino))
        return present

    proc scan(self) -> Array:
        ## Every inode in the tree, in ascending inode-number order.
        ##
        ## Returns decoded entries. This is what the mount loader and fsck walk,
        ## so it has to enumerate in key order to be reproducible; a hash-order
        ## walk would make the two disagree for no good reason.
        var out: Array = []
        let pairs = self.btree.scan()
        for pair in pairs:
            let raw = pair["data"]
            if bytes_len(raw) == 0:
                continue
            push(out, imgio.decode_inode_entry(raw, 0))
        self.entries_read = self.entries_read + len(out)
        return out

    proc count(self) -> Int:
        return self.btree.count()

    proc root_block(self) -> Int:
        ## Where the tree lives, for the superblock. Zero means the tree is
        ## still empty and nothing has been allocated for it.
        return self.btree.root_block

    proc generation(self) -> Int:
        return self.btree.current_generation

    proc save_root(self, superblock):
        ## Record the tree's current location in the superblock. Called before
        ## the superblock is serialised, since that is what reaches the disk.
        superblock.inode_root_blk = self.btree.root_block
        superblock.inode_root_generation = self.btree.current_generation

    proc is_empty(self) -> Bool:
        ## True when nothing has ever been written. Used to decide whether a
        ## corrupt root can safely fall back to the legacy area.
        return self.btree.root_block == 0

    proc is_readable(self) -> Bool:
        ## True when the tree has a root and the root block really holds a node.
        ##
        ## This is the check the mount loader uses to tell "no tree yet, read the
        ## legacy area" (root_block 0) from "a tree is here and I trust it". A
        ## corrupt root is reported as not readable, so the loader falls back to
        ## the area rather than mounting an empty filesystem over a populated one
        ## without saying so.
        return self.btree.root_is_readable()

    proc clear(self):
        ## Reset to an empty tree. Only for tests and for a deliberate
        ## migration that has already copied every entry out.
        self.btree = btree_module.BTreeEngine(self.btree.allocator, 0, 1)
        self.entries_written = 0
        self.entries_read = 0

    proc to_string(self) -> String:
        let head = "InodeTable(root=" + str(self.root_block())
        let mid = ", gen=" + str(self.generation())
        return head + mid + ", count=" + str(self.count()) + ")"
