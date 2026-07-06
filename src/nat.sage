## SageFS Node Address Table (NAT)
##
## The NAT is one of SageFS's key data structures, borrowed from F2FS. It maps
## logical node IDs (nids) to physical block addresses on disk. This indirection
## layer eliminates the "wandering tree" problem found in BTRFS:
##
##   In BTRFS, updating a leaf block triggers Copy-on-Write (CoW) of every
##   ancestor node up to the tree root, causing O(depth) write amplification.
##   With the NAT, each node has a fixed logical ID. When a node is rewritten
##   to a new physical location (log-structured), only the corresponding NAT
##   entry is updated — no parent nodes need modification.
##
## On-disk layout:
##   - NAT entries are packed into 4K blocks, 256 entries per block
##   - Each entry is 16 bytes: 8 bytes nid + 8 bytes block_addr
##   - A NAT journal in the checkpoint area caches hot/recent updates
##   - During checkpoint, journal entries are flushed to the NAT area
##
## Architecture:
##   NATEntry           — single nid → block_addr mapping with version tracking
##   NATJournal         — hot entry cache in the checkpoint area
##   NodeAddressTable   — main NAT with allocation, lookup, and update logic

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Size of a single NAT entry on disk in bytes (8 nid + 8 block_addr)
let NAT_ENTRY_SIZE = 16

## Number of NAT entries that fit in a single 4K filesystem block
let NAT_ENTRIES_PER_BLOCK = 256

## Sentinel value indicating an invalid or unused node ID
let NULL_NID = 0

## Sentinel value indicating an unmapped (free) block address
let NULL_ADDR = -1

## Reserved nid for the root inode — the top-level directory of the filesystem
let ROOT_INO_NID = 1

## Reserved nid for the node directory — indexes all node blocks on disk
let NODE_DIR_NID = 2

## Reserved nid for filesystem metadata nodes (e.g., xattr trees)
let META_NID = 3

## First nid available for user-created files and directories
let FIRST_USER_NID = 4

# ---------------------------------------------------------------------------
# Helper Functions
# ---------------------------------------------------------------------------

## Compute which NAT block on disk contains the entry for a given nid.
##
## NAT entries are stored sequentially starting at nat_start_blk.
## Each block holds NAT_ENTRIES_PER_BLOCK (256) entries, so the block
## index is simply floor(nid / 256) offset from the start.
##
## Args:
##   nid            — the logical node ID to locate
##   nat_start_blk  — the first block of the NAT area on disk
##
## Returns:
##   The absolute block number containing this nid's NAT entry
proc nid_to_nat_block(nid: Int, nat_start_blk: Int) -> Int:
    if nid < 0:
        raise "nid_to_nat_block: nid cannot be negative (" + str(nid) + ")"
    let block_offset = int(nid / NAT_ENTRIES_PER_BLOCK)
    return nat_start_blk + block_offset

## Compute the byte offset within a NAT block for a given nid.
##
## Each NAT entry is NAT_ENTRY_SIZE (16) bytes. The offset within
## the block is (nid % entries_per_block) * entry_size.
##
## Args:
##   nid — the logical node ID
##
## Returns:
##   Byte offset within the NAT block (0 to 4080)
proc nid_to_nat_offset(nid: Int) -> Int:
    if nid < 0:
        raise "nid_to_nat_offset: nid cannot be negative (" + str(nid) + ")"
    let index_in_block = nid % NAT_ENTRIES_PER_BLOCK
    return index_in_block * NAT_ENTRY_SIZE

# ---------------------------------------------------------------------------
# NATEntry
# ---------------------------------------------------------------------------

## A single Node Address Table entry mapping a logical node ID to its
## physical block address on disk.
##
## Each node in SageFS (inodes, indirect blocks, xattr nodes) is assigned
## a unique nid at creation time. The NATEntry tracks:
##   - nid:        the logical node ID (immutable once assigned)
##   - block_addr: the current physical block address (-1 if free/unmapped)
##   - version:    monotonically increasing counter, bumped on every update
##                 (used for snapshot consistency — a snapshot records the
##                 version at creation time and can identify stale entries)
##   - is_dirty:   true if this entry has been modified since the last
##                 checkpoint flush to disk
class NATEntry:

    ## Create a new NAT entry for the given node ID.
    ## The entry starts unmapped (block_addr = NULL_ADDR) at version 0.
    proc init(self, nid: Int):
        if nid < 0:
            raise "NATEntry: nid cannot be negative (" + str(nid) + ")"
        self.nid = nid
        self.block_addr = NULL_ADDR
        self.version = 0
        self.is_dirty = false

    ## Check whether this node is currently mapped to a physical block.
    ##
    ## A node is "alive" if its block_addr is not NULL_ADDR (-1).
    ## Dead/free nodes have been invalidated and their nid returned to
    ## the free pool for reuse.
    ##
    ## Returns:
    ##   true if the node has a valid physical mapping
    proc is_alive(self) -> Bool:
        return self.block_addr != NULL_ADDR

    ## Update the physical mapping for this node.
    ##
    ## Called when a node is written to a new physical location during
    ## log-structured allocation. The version counter is incremented to
    ## allow snapshot consistency checks, and the entry is marked dirty
    ## so it will be persisted at the next checkpoint.
    ##
    ## Args:
    ##   new_block_addr — the new physical block address (must be >= 0)
    proc update(self, new_block_addr: Int):
        if new_block_addr < 0:
            raise "NATEntry.update: block_addr cannot be negative (" + str(new_block_addr) + ")"
        self.block_addr = new_block_addr
        self.version = self.version + 1
        self.is_dirty = true

    ## Invalidate this NAT entry, marking the node as unmapped.
    ##
    ## Called when a node is deleted (e.g., inode unlink reaches zero
    ## references). Sets block_addr to NULL_ADDR and marks dirty.
    ## The nid can then be returned to the free pool for reuse.
    proc invalidate(self):
        self.block_addr = NULL_ADDR
        self.version = self.version + 1
        self.is_dirty = true

    ## Serialize this NAT entry to a 16-byte binary representation
    ## suitable for writing to disk.
    ##
    ## Layout (little-endian):
    ##   Bytes  0-7:  nid        (64-bit integer)
    ##   Bytes  8-15: block_addr (64-bit signed integer)
    ##
    ## Note: version and is_dirty are runtime-only fields and are NOT
    ## persisted. The version is reconstructed from checkpoint metadata,
    ## and is_dirty is reset after each checkpoint flush.
    ##
    ## Returns:
    ##   A 16-byte Bytes buffer
    proc serialize(self) -> Bytes:
        let buf = bytes(nil, NAT_ENTRY_SIZE)
        # Write nid as 8 bytes (little-endian)
        let nid_val = self.nid
        for i in range(8):
            bytes_set(buf, i, (nid_val >> (i * 8)) & 0xFF)
        # Write block_addr as 8 bytes (little-endian, signed)
        # For NULL_ADDR (-1), all bytes will be 0xFF (two's complement)
        let addr_val = self.block_addr
        for i in range(8):
            bytes_set(buf, 8 + i, (addr_val >> (i * 8)) & 0xFF)
        return buf

    ## Convert this entry to a dictionary for debugging and inspection.
    ##
    ## Returns:
    ##   Dict with keys: "nid", "block_addr", "version", "is_dirty", "alive"
    proc to_dict(self) -> Dict:
        return {
            "nid": self.nid,
            "block_addr": self.block_addr,
            "version": self.version,
            "is_dirty": self.is_dirty,
            "alive": self.is_alive()
        }

    ## String representation for debugging output.
    proc __str__(self) -> String:
        let status = "ALIVE"
        if not self.is_alive():
            status = "FREE"
        return "NATEntry(nid=" + str(self.nid) + ", blk=" + str(self.block_addr) + ", v=" + str(self.version) + ", " + status + ")"

# ---------------------------------------------------------------------------
# NATJournal
# ---------------------------------------------------------------------------

## Hot NAT entry cache stored in the checkpoint area.
##
## The NAT journal provides a write-ahead buffer for frequently updated
## NAT entries. Instead of updating the on-disk NAT area directly (which
## would cause random writes), changes accumulate in the journal. During
## checkpoint, the journal entries are flushed to the NAT area in a batch,
## converting random writes to sequential ones.
##
## Design rationale:
##   - F2FS stores a small NAT journal (up to ~480 entries) directly inside
##     the checkpoint pack. SageFS follows this approach with a configurable
##     max_entries limit (default 512).
##   - When the journal is full, it must be flushed before new entries can
##     be added. This triggers a partial NAT writeback.
##   - On recovery, the journal is replayed on top of the on-disk NAT to
##     reconstruct the latest state.
class NATJournal:

    ## Create a new NAT journal with the given capacity.
    ##
    ## Args:
    ##   max_entries — maximum number of entries the journal can hold
    ##                 before requiring a flush (default: 512)
    proc init(self, max_entries: Int):
        if max_entries <= 0:
            raise "NATJournal: max_entries must be positive (" + str(max_entries) + ")"
        self.entries = {}
        self.max_entries = max_entries

    ## Add or update an entry in the journal.
    ##
    ## If the nid already exists in the journal, it is replaced (updated).
    ## If the journal is full and the nid is new, returns false to signal
    ## the caller should flush the journal first.
    ##
    ## Args:
    ##   entry — the NATEntry to add/update
    ##
    ## Returns:
    ##   true if the entry was successfully added/updated
    ##   false if the journal is full and cannot accept new entries
    proc add(self, entry: NATEntry) -> Bool:
        let key = str(entry.nid)
        # Allow updates to existing entries even when full
        if dict_has(self.entries, key):
            self.entries[key] = entry
            return true
        # Reject new entries when at capacity
        if self.is_full():
            return false
        self.entries[key] = entry
        return true

    ## Look up an entry in the journal by nid.
    ##
    ## The journal is checked BEFORE the main NAT table during lookups,
    ## because it contains the most recent (potentially uncommitted) state.
    ##
    ## Args:
    ##   nid — the logical node ID to look up
    ##
    ## Returns:
    ##   The NATEntry if found in the journal, or nil if not present
    proc get(self, nid: Int) -> NATEntry:
        let key = str(nid)
        if dict_has(self.entries, key):
            return self.entries[key]
        return nil

    ## Remove an entry from the journal.
    ##
    ## Called when an entry is flushed to the main NAT table or when
    ## a nid is freed and the journal entry is no longer needed.
    ##
    ## Args:
    ##   nid — the logical node ID to remove from the journal
    proc remove(self, nid: Int):
        let key = str(nid)
        if dict_has(self.entries, key):
            dict_delete(self.entries, key)

    ## Check whether the journal has reached its capacity limit.
    ##
    ## Returns:
    ##   true if the number of entries equals max_entries
    proc is_full(self) -> Bool:
        return len(dict_keys(self.entries)) >= self.max_entries

    ## Flush all entries from the journal and return them as an array.
    ##
    ## This is called during checkpoint to move journal entries into the
    ## on-disk NAT area. The journal is cleared after flushing.
    ##
    ## Returns:
    ##   Array of all NATEntry objects that were in the journal
    proc flush(self) -> Array:
        let result = []
        let keys = dict_keys(self.entries)
        for key in keys:
            push(result, self.entries[key])
        self.entries = {}
        return result

    ## Get the current number of entries in the journal.
    ##
    ## Returns:
    ##   The number of cached NAT entries
    proc count(self) -> Int:
        return len(dict_keys(self.entries))

    ## Convert the journal to a dictionary for debugging.
    ##
    ## Returns:
    ##   Dict with "count", "max_entries", "is_full", and "entries" (array of entry dicts)
    proc to_dict(self) -> Dict:
        let entry_list = []
        let keys = dict_keys(self.entries)
        for key in keys:
            push(entry_list, self.entries[key].to_dict())
        return {
            "count": self.count(),
            "max_entries": self.max_entries,
            "is_full": self.is_full(),
            "entries": entry_list
        }

# ---------------------------------------------------------------------------
# NodeAddressTable
# ---------------------------------------------------------------------------

## The main Node Address Table for SageFS.
##
## The NAT is the central indirection layer between logical node IDs and
## physical block addresses. Every node in the filesystem (inodes, indirect
## blocks, xattr nodes, directory entry blocks) is assigned a unique nid.
## The NAT maps each nid to its current physical location on disk.
##
## Key benefits:
##   1. **Eliminates wandering tree**: When a node is written to a new
##      physical block (log-structured CoW), only the NAT entry changes.
##      Parent nodes in the B+ tree do NOT need to be updated, saving
##      O(tree_depth) writes per update.
##
##   2. **Enables efficient GC**: The garbage collector can relocate valid
##      blocks to new segments and simply update the NAT. No tree traversal
##      is needed to fix parent pointers.
##
##   3. **Simplifies snapshots**: Snapshot consistency is maintained through
##      version numbers on NAT entries. A snapshot records the NAT version
##      at creation time.
##
## Architecture:
##   - `entries`: The main in-memory NAT table (dict mapping nid string -> NATEntry)
##   - `journal`: Hot entry cache for recent updates (flushed at checkpoint)
##   - `free_nids`: Pre-allocated pool of available nids for fast allocation
##   - `next_nid`: Counter for generating new nids when the free pool is empty
##
## Lookup order: journal first, then main table. This ensures the most
## recent mapping is always returned, even if the main table hasn't been
## updated yet.
class NodeAddressTable:

    ## Initialize the Node Address Table.
    ##
    ## Args:
    ##   nat_start_blk   — the first block of the NAT area on disk
    ##   total_nat_blocks — total number of blocks allocated to the NAT area
    proc init(self, nat_start_blk: Int, total_nat_blocks: Int):
        if nat_start_blk < 0:
            raise "NodeAddressTable: nat_start_blk cannot be negative"
        if total_nat_blocks <= 0:
            raise "NodeAddressTable: total_nat_blocks must be positive"

        ## Main entry table: maps str(nid) -> NATEntry
        self.entries = {}

        ## Pool of pre-allocated free nids for fast allocation
        self.free_nids = []

        ## Next nid to allocate when the free pool is exhausted.
        ## Starts at FIRST_USER_NID because nids 1-3 are reserved.
        self.next_nid = FIRST_USER_NID

        ## Hot entry journal (checkpoint-area cache)
        self.journal = NATJournal(512)

        ## Starting block of the NAT area on disk
        self.nat_start_blk = nat_start_blk

        ## Total blocks allocated for the NAT area
        self.total_nat_blocks = total_nat_blocks

        ## Number of dirty (uncommitted) entries in the main table
        self.dirty_count = 0

        # Pre-register reserved nids so they are tracked in the table
        self._init_reserved_nids()

    ## Initialize entries for reserved node IDs (root inode, node dir, meta).
    ##
    ## These nids are always present in the NAT and must not be allocated
    ## to user nodes. They start unmapped and will be assigned physical
    ## blocks during mkfs or mount.
    proc _init_reserved_nids(self):
        # ROOT_INO_NID (1) — root directory inode
        let root_entry = NATEntry(ROOT_INO_NID)
        self.entries[str(ROOT_INO_NID)] = root_entry

        # NODE_DIR_NID (2) — node directory index
        let node_dir_entry = NATEntry(NODE_DIR_NID)
        self.entries[str(NODE_DIR_NID)] = node_dir_entry

        # META_NID (3) — filesystem metadata
        let meta_entry = NATEntry(META_NID)
        self.entries[str(META_NID)] = meta_entry

    ## Allocate a new node ID and create its NAT entry.
    ##
    ## Allocation strategy:
    ##   1. If the free_nids pool has available nids, pop one (O(1))
    ##   2. Otherwise, use next_nid and increment it
    ##
    ## The returned nid is guaranteed to be unique and not currently in use.
    ## A fresh NATEntry is created in the main table with block_addr = NULL_ADDR.
    ## The caller must subsequently call update() to assign a physical block
    ## once the node is written to disk.
    ##
    ## Returns:
    ##   A new, unique node ID
    ##
    ## Raises:
    ##   Error if the NAT area capacity is exceeded
    proc allocate_nid(self) -> Int:
        var nid = NULL_NID

        # Strategy 1: reuse a freed nid from the pool
        if len(self.free_nids) > 0:
            nid = pop(self.free_nids)
        else:
            # Strategy 2: allocate a fresh nid
            # Check capacity: max nids = total_nat_blocks * entries_per_block
            let max_nids = self.total_nat_blocks * NAT_ENTRIES_PER_BLOCK
            if self.next_nid >= max_nids:
                raise "NodeAddressTable.allocate_nid: NAT capacity exhausted (max " + str(max_nids) + " nids)"
            nid = self.next_nid
            self.next_nid = self.next_nid + 1

        # Create a new entry for this nid
        let entry = NATEntry(nid)
        entry.is_dirty = true
        self.entries[str(nid)] = entry
        self.dirty_count = self.dirty_count + 1
        return nid

    ## Free a node ID, invalidating its mapping and returning it to the pool.
    ##
    ## The entry's block_addr is set to NULL_ADDR and the nid is pushed
    ## onto the free_nids pool for future reuse. This prevents nid space
    ## exhaustion in long-running filesystems with many create/delete cycles.
    ##
    ## Guards against:
    ##   - Freeing NULL_NID (always invalid)
    ##   - Freeing reserved nids (ROOT_INO_NID, NODE_DIR_NID, META_NID)
    ##   - Double-free (nid already in free pool)
    ##   - Freeing non-existent nids
    ##
    ## Args:
    ##   nid — the node ID to free
    proc free_nid(self, nid: Int):
        # Guard: cannot free the null nid
        if nid == NULL_NID:
            raise "NodeAddressTable.free_nid: cannot free NULL_NID (0)"

        # Guard: cannot free reserved nids
        if nid == ROOT_INO_NID or nid == NODE_DIR_NID or nid == META_NID:
            raise "NodeAddressTable.free_nid: cannot free reserved nid " + str(nid)

        let key = str(nid)

        # Guard: nid must exist in the table
        if not dict_has(self.entries, key):
            raise "NodeAddressTable.free_nid: nid " + str(nid) + " does not exist"

        # Guard: prevent double-free
        if array_contains(self.free_nids, nid):
            raise "NodeAddressTable.free_nid: nid " + str(nid) + " is already free (double-free)"

        let entry = self.entries[key]

        # If the entry was dirty before invalidation, don't double-count
        let was_dirty = entry.is_dirty

        # Invalidate the mapping
        entry.invalidate()

        # Update dirty count
        if not was_dirty:
            self.dirty_count = self.dirty_count + 1

        # Also remove from journal if present
        self.journal.remove(nid)

        # Return the nid to the free pool
        push(self.free_nids, nid)

    ## Look up the physical block address for a given node ID.
    ##
    ## Lookup order:
    ##   1. Check the NAT journal first (most recent updates)
    ##   2. Fall back to the main NAT table
    ##   3. Return NULL_ADDR if the nid is not found anywhere
    ##
    ## This two-level lookup ensures that uncommitted journal updates
    ## are visible to the rest of the filesystem, maintaining consistency
    ## between checkpoint intervals.
    ##
    ## Args:
    ##   nid — the logical node ID to look up
    ##
    ## Returns:
    ##   The physical block address, or NULL_ADDR (-1) if unmapped
    proc lookup(self, nid: Int) -> Int:
        if nid == NULL_NID:
            return NULL_ADDR

        # Level 1: check journal (most recent state)
        let journal_entry = self.journal.get(nid)
        if journal_entry != nil:
            return journal_entry.block_addr

        # Level 2: check main table
        let key = str(nid)
        if dict_has(self.entries, key):
            return self.entries[key].block_addr

        # Not found
        return NULL_ADDR

    ## Update the physical mapping for a node ID.
    ##
    ## The update is first attempted in the journal (hot cache). If the
    ## journal is full, it is flushed to the main table before retrying.
    ## This ensures that updates always succeed and the most recent
    ## mapping is captured in the journal for efficient checkpoint writes.
    ##
    ## If the nid does not exist in the main table, a new entry is created.
    ## This handles the case where allocate_nid() was called but the node
    ## hasn't been persisted yet.
    ##
    ## Args:
    ##   nid        — the logical node ID to update
    ##   block_addr — the new physical block address
    proc update(self, nid: Int, block_addr: Int):
        if nid == NULL_NID:
            raise "NodeAddressTable.update: cannot update NULL_NID (0)"
        if block_addr < 0:
            raise "NodeAddressTable.update: block_addr cannot be negative (" + str(block_addr) + ")"

        let key = str(nid)

        # Ensure the entry exists in the main table
        if not dict_has(self.entries, key):
            let new_entry = NATEntry(nid)
            self.entries[key] = new_entry

        # Update the main table entry
        let entry = self.entries[key]
        let was_dirty = entry.is_dirty
        entry.update(block_addr)
        if not was_dirty:
            self.dirty_count = self.dirty_count + 1

        # Try to add to journal for fast checkpoint recovery
        let journal_entry = NATEntry(nid)
        journal_entry.block_addr = block_addr
        journal_entry.version = entry.version
        journal_entry.is_dirty = true

        let added = self.journal.add(journal_entry)
        if not added:
            # Journal full — flush it to main table, then retry
            self.flush_journal()
            # Retry the journal add (should succeed now that journal is empty)
            let retry_entry = NATEntry(nid)
            retry_entry.block_addr = block_addr
            retry_entry.version = entry.version
            retry_entry.is_dirty = true
            self.journal.add(retry_entry)

    ## Apply multiple NAT mapping updates in a single batch.
    ##
    ## This is more efficient than individual update() calls when the
    ## segment manager needs to update many entries at once (e.g., after
    ## GC relocates valid blocks in a victim segment).
    ##
    ## Args:
    ##   updates — array of dicts, each with "nid" (Int) and "block_addr" (Int) keys
    ##
    ## Example:
    ##   nat.batch_update([
    ##       {"nid": 10, "block_addr": 5000},
    ##       {"nid": 15, "block_addr": 5001},
    ##       {"nid": 22, "block_addr": 5002}
    ##   ])
    proc batch_update(self, updates: Array):
        if len(updates) == 0:
            return

        # Pre-flush journal if the batch might overflow it
        let journal_remaining = self.journal.max_entries - self.journal.count()
        if len(updates) > journal_remaining:
            self.flush_journal()

        for update_dict in updates:
            if not dict_has(update_dict, "nid"):
                raise "NodeAddressTable.batch_update: missing 'nid' key in update dict"
            if not dict_has(update_dict, "block_addr"):
                raise "NodeAddressTable.batch_update: missing 'block_addr' key in update dict"
            let nid = update_dict["nid"]
            let block_addr = update_dict["block_addr"]
            self.update(nid, block_addr)

    ## Retrieve the full NATEntry for a given node ID.
    ##
    ## Unlike lookup() which returns only the block address, this returns
    ## the entire entry object including version and dirty state. Useful
    ## for the checkpoint manager and fsck.
    ##
    ## Checks journal first, then main table.
    ##
    ## Args:
    ##   nid — the logical node ID
    ##
    ## Returns:
    ##   The NATEntry object, or nil if the nid does not exist
    proc get_entry(self, nid: Int) -> NATEntry:
        if nid == NULL_NID:
            return nil

        # Check journal first
        let journal_entry = self.journal.get(nid)
        if journal_entry != nil:
            return journal_entry

        # Check main table
        let key = str(nid)
        if dict_has(self.entries, key):
            return self.entries[key]

        return nil

    ## Collect all dirty (modified) entries from the main table.
    ##
    ## Called by the checkpoint manager to determine which NAT entries
    ## need to be written to disk. Only entries with is_dirty == true
    ## are included.
    ##
    ## Note: this does NOT include journal entries. Call flush_journal()
    ## first to move journal entries into the main table if you need
    ## a complete picture.
    ##
    ## Returns:
    ##   Array of NATEntry objects with is_dirty == true
    proc get_dirty_entries(self) -> Array:
        let dirty = []
        let keys = dict_keys(self.entries)
        for key in keys:
            let entry = self.entries[key]
            if entry.is_dirty:
                push(dirty, entry)
        return dirty

    ## Flush all journal entries into the main NAT table.
    ##
    ## Each journal entry's block_addr and version are applied to the
    ## corresponding main table entry. If the main table doesn't have
    ## an entry for a journaled nid, one is created.
    ##
    ## This is called:
    ##   - When the journal is full and needs to accept new entries
    ##   - During checkpoint, before writing dirty entries to disk
    ##   - During recovery, to replay the journal on top of the on-disk NAT
    proc flush_journal(self):
        let flushed = self.journal.flush()
        for journal_entry in flushed:
            let key = str(journal_entry.nid)
            if dict_has(self.entries, key):
                let main_entry = self.entries[key]
                # Only apply if journal version is newer
                if journal_entry.version >= main_entry.version:
                    let was_dirty = main_entry.is_dirty
                    main_entry.block_addr = journal_entry.block_addr
                    main_entry.version = journal_entry.version
                    main_entry.is_dirty = true
                    if not was_dirty:
                        self.dirty_count = self.dirty_count + 1
            else:
                # New entry from journal — create in main table
                let new_entry = NATEntry(journal_entry.nid)
                new_entry.block_addr = journal_entry.block_addr
                new_entry.version = journal_entry.version
                new_entry.is_dirty = true
                self.entries[key] = new_entry
                self.dirty_count = self.dirty_count + 1

    ## Mark all dirty entries as clean after a successful checkpoint.
    ##
    ## Called by the checkpoint manager after all dirty NAT entries have
    ## been written to the on-disk NAT area. Resets is_dirty to false
    ## and zeroes the dirty count.
    ##
    ## The journal is also flushed to ensure no stale entries remain.
    ## After checkpoint, the journal starts empty and only new updates
    ## will be journaled.
    proc checkpoint(self):
        # First, ensure journal entries are in the main table
        self.flush_journal()

        # Clear dirty flags on all entries
        let keys = dict_keys(self.entries)
        for key in keys:
            self.entries[key].is_dirty = false

        self.dirty_count = 0

    ## Pre-fill the free nid pool for fast allocation.
    ##
    ## Generates `count` sequential nids starting from next_nid and
    ## pushes them onto the free_nids pool. This amortizes the cost
    ## of nid allocation over many operations — the allocator can pop
    ## from the pool in O(1) instead of scanning.
    ##
    ## Called during mount or when the free pool runs low.
    ##
    ## Args:
    ##   count — number of nids to pre-generate
    proc prefill_free_nids(self, count: Int):
        if count <= 0:
            return

        let max_nids = self.total_nat_blocks * NAT_ENTRIES_PER_BLOCK
        var generated = 0

        while generated < count:
            if self.next_nid >= max_nids:
                # Cannot generate more — NAT space exhausted
                break
            push(self.free_nids, self.next_nid)
            self.next_nid = self.next_nid + 1
            generated = generated + 1

    ## Get statistics about the NAT's current state.
    ##
    ## Returns:
    ##   Dict with keys:
    ##     "total_entries"   — number of entries in the main table
    ##     "alive_entries"   — number of entries with valid mappings
    ##     "free_nids_count" — size of the pre-allocated free pool
    ##     "dirty_count"     — number of dirty (uncommitted) entries
    ##     "journal_count"   — number of entries in the journal
    ##     "next_nid"        — the next nid that would be allocated
    ##     "nat_start_blk"   — starting block of NAT area
    ##     "total_nat_blocks"— total blocks in NAT area
    ##     "max_capacity"    — maximum nids the NAT can hold
    proc stats(self) -> Dict:
        let total = len(dict_keys(self.entries))
        var alive = 0
        let keys = dict_keys(self.entries)
        for key in keys:
            if self.entries[key].is_alive():
                alive = alive + 1
        return {
            "total_entries": total,
            "alive_entries": alive,
            "free_nids_count": len(self.free_nids),
            "dirty_count": self.dirty_count,
            "journal_count": self.journal.count(),
            "next_nid": self.next_nid,
            "nat_start_blk": self.nat_start_blk,
            "total_nat_blocks": self.total_nat_blocks,
            "max_capacity": self.total_nat_blocks * NAT_ENTRIES_PER_BLOCK
        }

    ## Human-readable string summary of the NAT for debugging.
    ##
    ## Returns:
    ##   Multi-line string with NAT statistics and entry details
    proc to_string(self) -> String:
        let s = self.stats()
        var result = "=== NodeAddressTable ===\n"
        result = result + "  NAT area:       block " + str(s["nat_start_blk"]) + " — " + str(s["nat_start_blk"] + s["total_nat_blocks"] - 1) + "\n"
        result = result + "  Max capacity:   " + str(s["max_capacity"]) + " nids\n"
        result = result + "  Total entries:  " + str(s["total_entries"]) + "\n"
        result = result + "  Alive entries:  " + str(s["alive_entries"]) + "\n"
        result = result + "  Dirty entries:  " + str(s["dirty_count"]) + "\n"
        result = result + "  Journal count:  " + str(s["journal_count"]) + "\n"
        result = result + "  Free pool size: " + str(s["free_nids_count"]) + "\n"
        result = result + "  Next NID:       " + str(s["next_nid"]) + "\n"

        # Show first few entries for quick inspection
        let keys = dict_keys(self.entries)
        let show_count = len(keys)
        if show_count > 16:
            show_count = 16
        if show_count > 0:
            result = result + "  Entries (first " + str(show_count) + "):\n"
            for i in range(show_count):
                let entry = self.entries[keys[i]]
                result = result + "    " + str(entry) + "\n"
            if len(keys) > 16:
                result = result + "    ... and " + str(len(keys) - 16) + " more\n"

        return result
