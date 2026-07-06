## SageFS Block Allocator
##
## The allocator is the central coordination layer that ties together the
## Segment Manager (SIT) and the Node Address Table (NAT) to provide a
## unified block allocation interface for all of SageFS.
##
## Design principles:
##   - Log-structured allocation: new writes always append to the tail of
##     the active log segment for the appropriate data temperature.
##   - Multi-head logging: 6 active log heads (3 data temps × 2 node types)
##     to separate hot/warm/cold data and reduce GC overhead.
##   - Pre-allocation caching: blocks are pre-allocated in batches to amortize
##     the cost of segment manager lookups on sequential write workloads.
##   - Temperature-aware placement: data is classified as hot/warm/cold based
##     on access frequency and age heuristics, then routed to the appropriate
##     log head for optimal GC behavior.
##
## File: src/allocator.sage

import segment
import nat

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Allocation completed successfully
let ALLOC_SUCCESS = 0

## No free space available for allocation
let ALLOC_NO_SPACE = -1

## Internal allocation error (segment or NAT failure)
let ALLOC_ERROR = -2

## Free segment percentage threshold for urgent (foreground) GC.
## When free segments drop below this percentage the filesystem must
## trigger synchronous garbage collection before any new allocation
## can proceed — this prevents deadlocks from complete space exhaustion.
let GC_THRESHOLD_URGENT = 5

## Free segment percentage threshold for background GC.
## When free segments fall below this level, the background GC daemon
## should wake up and start reclaiming segments proactively before the
## filesystem reaches the urgent threshold.
let GC_THRESHOLD_NORMAL = 20

## Number of blocks to pre-allocate into cache for sequential writes.
## Pre-allocation amortizes the per-block overhead of consulting the
## segment manager and reduces lock contention on the active segment head.
let PREALLOCATE_BLOCKS = 64

# ---------------------------------------------------------------------------
# DataTemperature enum
# ---------------------------------------------------------------------------

## Data temperature classification for multi-head log allocation.
##
## SageFS separates writes into three temperature tiers (borrowed from F2FS).
## Each tier gets its own active log segment so that data with similar
## lifetimes is co-located, dramatically improving GC efficiency:
##   - Hot:  frequently written, short-lived (journals, metadata, temp files)
##   - Warm: moderately active (recent user data, working set)
##   - Cold: rarely modified (archives, media, old backups)
enum DataTemperature:
    Hot
    Warm
    Cold

# ---------------------------------------------------------------------------
# AllocationResult class
# ---------------------------------------------------------------------------

## Result of a single block allocation attempt.
##
## Encapsulates both the success/failure status and all the addressing
## information needed by callers: the logical node ID (nid), the physical
## block address, the segment number, and the offset within that segment.
##
## On failure (ALLOC_NO_SPACE or ALLOC_ERROR), the addressing fields are
## set to -1 to make misuse obvious during debugging.
class AllocationResult:
    ## Create an AllocationResult with the given status code.
    ## Addressing fields default to -1 (invalid) and must be set by
    ## the allocator on successful allocation.
    proc init(self, status: Int):
        self.status = status
        self.nid = -1
        self.physical_blk = -1
        self.segno = -1
        self.block_offset = -1

    ## Returns true if the allocation succeeded.
    proc is_success(self) -> Bool:
        return self.status == ALLOC_SUCCESS

    ## Serialize the allocation result to a dictionary for logging,
    ## checkpoint persistence, or debugging output.
    proc to_dict(self) -> Dict:
        let d = {}
        d["status"] = self.status
        d["nid"] = self.nid
        d["physical_blk"] = self.physical_blk
        d["segno"] = self.segno
        d["block_offset"] = self.block_offset
        return d

# ---------------------------------------------------------------------------
# Helper: map temperature string to segment type
# ---------------------------------------------------------------------------

## Map a human-readable temperature string and node flag to the internal
## segment type identifier used by the Segment Manager.
##
## The segment manager maintains 6 active log heads identified by type:
##   data_hot, data_warm, data_cold   (for file data blocks)
##   node_hot, node_warm, node_cold   (for inode/indirect node blocks)
##
## Args:
##   temp    — temperature string: "hot", "warm", or "cold"
##   is_node — true for node blocks, false for data blocks
##
## Returns:
##   Segment type string, e.g. "data_hot" or "node_cold".
##   Returns "data_warm" as a safe default for unrecognized temperatures.
proc map_temperature_to_seg_type(temp: String, is_node: Bool) -> String:
    let prefix = "data_"
    if is_node:
        prefix = "node_"

    match temp:
        case "hot":
            return prefix + "hot"
        case "warm":
            return prefix + "warm"
        case "cold":
            return prefix + "cold"
        default:
            # Default to warm — it is the middle ground and least likely
            # to cause pathological GC behavior if classification is wrong.
            return prefix + "warm"

# ---------------------------------------------------------------------------
# BlockAllocator class
# ---------------------------------------------------------------------------

## The BlockAllocator is the single entry point for all block allocation and
## deallocation in SageFS.
##
## It coordinates between two lower-level subsystems:
##   1. SegmentManager — owns the physical block space, manages the SIT bitmap,
##      and tracks which segments are free/active/full.
##   2. NodeAddressTable (NAT) — provides the logical-to-physical indirection
##      layer that eliminates the wandering-tree problem.
##
## Allocation flow for a data write:
##   1. Caller requests a block at a given temperature (hot/warm/cold).
##   2. Allocator maps temperature to a segment type (e.g. "data_hot").
##   3. Check pre-allocation cache; if a cached block is available, use it.
##   4. Otherwise, ask SegmentManager for the next free block in the active
##      log segment for that type.
##   5. Allocate a fresh node ID (nid) from the NAT.
##   6. Record the nid → physical_block mapping in the NAT.
##   7. Return an AllocationResult with all addressing information.
##
## Deallocation flow:
##   1. Caller provides the nid to free.
##   2. Allocator looks up the physical address via NAT.
##   3. Computes segment number and block offset from the physical address.
##   4. Marks the block as invalid in the SegmentManager's SIT.
##   5. Frees the nid in the NAT for reuse.
class BlockAllocator:
    ## Initialize the block allocator.
    ##
    ## Args:
    ##   seg_mgr      — reference to the SegmentManager instance
    ##   nat_table    — reference to the NodeAddressTable instance
    ##   block_size   — filesystem block size in bytes (e.g. 4096)
    ##   total_blocks — total number of allocatable blocks in the main area
    proc init(self, seg_mgr, nat_table, block_size: Int, total_blocks: Int):
        self.seg_mgr = seg_mgr
        self.nat_table = nat_table
        self.block_size = block_size
        self.total_blocks = total_blocks
        self.allocated_blocks = 0

        ## Pre-allocation cache: maps segment type string to an array of
        ## physical block addresses that have been reserved from the segment
        ## manager but not yet assigned to any nid. This allows sequential
        ## writes to skip the segment manager entirely for most blocks.
        self.prealloc_cache = {}

        ## Allocation statistics for monitoring and tuning.
        self.stats_writes = 0
        self.stats_reads = 0

    # -------------------------------------------------------------------
    # Core allocation methods
    # -------------------------------------------------------------------

    ## Allocate a single data block at the given temperature.
    ##
    ## This is the primary allocation path for file data writes. The
    ## temperature determines which of the three data log heads is used:
    ##   "hot"  → data_hot  (journals, frequently-rewritten data)
    ##   "warm" → data_warm (typical user file data)
    ##   "cold" → data_cold (archival, media, infrequently-modified data)
    ##
    ## Returns an AllocationResult. Callers MUST check is_success() before
    ## using the addressing fields.
    proc allocate_data_block(self, temperature: String) -> AllocationResult:
        let seg_type = map_temperature_to_seg_type(temperature, false)
        return self._allocate_block(seg_type)

    ## Allocate a single node block at the given temperature.
    ##
    ## Node blocks hold inodes and indirect block pointers. They are
    ## separated from data blocks in the log to prevent node updates
    ## from invalidating data segments (which would increase GC work).
    ##
    ## Temperature mapping:
    ##   "hot"  → node_hot  (directory inodes, frequently-updated nodes)
    ##   "warm" → node_warm (file inodes)
    ##   "cold" → node_cold (indirect block pointers)
    proc allocate_node_block(self, temperature: String) -> AllocationResult:
        let seg_type = map_temperature_to_seg_type(temperature, true)
        return self._allocate_block(seg_type)

    ## Allocate a metadata block.
    ##
    ## Metadata blocks (checkpoints, NAT/SIT journal entries, B+ tree
    ## root nodes) are always placed in the node_hot segment because they
    ## are small, frequently updated, and critical for crash recovery.
    ## Keeping them in the hottest log head ensures they are co-located
    ## with other short-lived metadata and easily reclaimed by GC.
    proc allocate_meta_block(self) -> AllocationResult:
        return self._allocate_block("node_hot")

    ## Internal allocation workhorse shared by all public allocate_* methods.
    ##
    ## Steps:
    ##   1. Try to get a pre-allocated block from cache.
    ##   2. If cache miss, request a block from the segment manager.
    ##   3. Allocate a nid from the NAT.
    ##   4. Record the nid → physical mapping in the NAT.
    ##   5. Build and return the AllocationResult.
    proc _allocate_block(self, seg_type: String) -> AllocationResult:
        # Step 1: Check pre-allocation cache for a fast-path block
        let cached = self.get_preallocated(seg_type)
        var physical_blk = -1

        if cached != nil:
            physical_blk = cached["physical_blk"]
        else:
            # Step 2: Request a fresh block from the segment manager.
            # allocate_block() returns a dict with physical_blk, segno,
            # block_offset — or nil on failure.
            try:
                let alloc = self.seg_mgr.allocate_block(seg_type)
                if alloc == nil:
                    return AllocationResult(ALLOC_NO_SPACE)
                physical_blk = alloc["physical_blk"]
            catch e:
                # Segment manager failure — disk full or internal error
                let err_result = AllocationResult(ALLOC_ERROR)
                return err_result

        # Step 3: Allocate a logical node ID from the NAT
        var nid = -1
        try:
            nid = self.nat_table.allocate_nid()
            if nid < 0:
                # NAT is exhausted — extremely unlikely unless the nid space
                # is smaller than the block space, but handle it gracefully.
                return AllocationResult(ALLOC_NO_SPACE)
        catch e:
            return AllocationResult(ALLOC_ERROR)

        # Step 4: Record the mapping in the NAT
        try:
            self.nat_table.set_mapping(nid, physical_blk)
        catch e:
            # Roll back: if we can't record the mapping, the nid and block
            # are leaked unless we release them. Best-effort cleanup.
            try:
                self.nat_table.free_nid(nid)
            catch inner_e:
                # Ignore cleanup failure — will be recovered by fsck
                pass
            return AllocationResult(ALLOC_ERROR)

        # Step 5: Compute segment number and offset for the result.
        # The segment manager knows its own geometry, so we ask it to
        # decompose the physical address.
        var segno = -1
        var block_offset = -1
        try:
            let loc = self.seg_mgr.get_block_location(physical_blk)
            if loc != nil:
                segno = loc["segno"]
                block_offset = loc["block_offset"]
        catch e:
            # Non-fatal: we have the allocation, just can't decompose
            # the address. This should never happen but we degrade
            # gracefully rather than failing the allocation.
            pass

        # Build the successful result
        let result = AllocationResult(ALLOC_SUCCESS)
        result.nid = nid
        result.physical_blk = physical_blk
        result.segno = segno
        result.block_offset = block_offset

        # Update bookkeeping
        self.allocated_blocks = self.allocated_blocks + 1
        self.stats_writes = self.stats_writes + 1

        return result

    # -------------------------------------------------------------------
    # Deallocation
    # -------------------------------------------------------------------

    ## Free a previously allocated block by its logical node ID.
    ##
    ## This invalidates the block in the segment manager (so GC knows it
    ## can be reclaimed) and releases the nid back to the NAT free pool.
    ##
    ## Args:
    ##   nid — the logical node ID returned by a prior allocation
    ##
    ## Returns:
    ##   true if the block was successfully freed, false on error.
    proc free_block(self, nid: Int) -> Bool:
        # Step 1: Look up the physical address via NAT
        var physical_blk = -1
        try:
            physical_blk = self.nat_table.get_physical(nid)
            if physical_blk < 0:
                # nid not found in NAT — double-free or corruption
                return false
        catch e:
            return false

        # Step 2: Compute segment number and block offset
        var segno = -1
        var block_offset = -1
        try:
            let loc = self.seg_mgr.get_block_location(physical_blk)
            if loc == nil:
                return false
            segno = loc["segno"]
            block_offset = loc["block_offset"]
        catch e:
            return false

        # Step 3: Invalidate the block in the segment manager's SIT.
        # This decrements the valid block count for the segment, making
        # it a better candidate for GC victim selection.
        try:
            self.seg_mgr.invalidate_block(segno, block_offset)
        catch e:
            return false

        # Step 4: Free the nid in the NAT for reuse
        try:
            self.nat_table.free_nid(nid)
        catch e:
            # The block is already invalidated in SIT but the nid is
            # leaked. fsck will detect and reclaim orphaned nids.
            return false

        # Update bookkeeping
        if self.allocated_blocks > 0:
            self.allocated_blocks = self.allocated_blocks - 1

        return true

    # -------------------------------------------------------------------
    # Batch allocation
    # -------------------------------------------------------------------

    ## Allocate multiple blocks at once for sequential write workloads.
    ##
    ## Sequential writes (e.g. large file copies, database bulk loads)
    ## benefit from batch allocation because:
    ##   1. Blocks are guaranteed to be in the same or adjacent segments,
    ##      maximizing sequential layout on disk.
    ##   2. Per-block overhead (lock acquisition, free-list scan) is
    ##      amortized across the batch.
    ##   3. The pre-allocation cache is replenished in one shot.
    ##
    ## If allocation fails partway through, the successfully allocated
    ## blocks are still returned — the caller is responsible for freeing
    ## them if it cannot use a partial result.
    ##
    ## Args:
    ##   count       — number of blocks to allocate
    ##   temperature — "hot", "warm", or "cold"
    ##   is_node     — true for node blocks, false for data blocks
    ##
    ## Returns:
    ##   Array of AllocationResult objects. Array length may be less than
    ##   count if space is exhausted.
    proc batch_allocate(self, count: Int, temperature: String, is_node: Bool) -> Array:
        let results = []
        let seg_type = map_temperature_to_seg_type(temperature, is_node)

        # Pre-fill the cache if it doesn't have enough blocks for this batch.
        # This is an optimization: a single preallocate call is cheaper than
        # count individual segment manager calls.
        let cached_count = self._cache_size(seg_type)
        if cached_count < count:
            let deficit = count - cached_count
            self.preallocate(seg_type, deficit)

        # Allocate blocks one at a time, pulling from the (now warm) cache
        for i in range(count):
            var result = nil
            if is_node:
                result = self.allocate_node_block(temperature)
            else:
                result = self.allocate_data_block(temperature)

            push(results, result)

            # Stop early if we've run out of space
            if not result.is_success():
                break

        return results

    # -------------------------------------------------------------------
    # Address lookup
    # -------------------------------------------------------------------

    ## Look up the physical block address for a given logical node ID.
    ##
    ## This is the read-path equivalent of allocation: given a nid stored
    ## in an inode's block pointer or directory entry, resolve it to the
    ## physical block address needed for I/O.
    ##
    ## Args:
    ##   nid — logical node ID to resolve
    ##
    ## Returns:
    ##   Physical block address (>= 0) on success, -1 if not found.
    proc lookup_physical(self, nid: Int) -> Int:
        self.stats_reads = self.stats_reads + 1
        try:
            let physical = self.nat_table.get_physical(nid)
            return physical
        catch e:
            return -1

    # -------------------------------------------------------------------
    # GC threshold checks
    # -------------------------------------------------------------------

    ## Check if the filesystem needs background garbage collection.
    ##
    ## Returns true when the percentage of free segments drops below
    ## GC_THRESHOLD_NORMAL (20%). The background GC daemon should poll
    ## this periodically and start reclaiming segments when it returns true.
    proc needs_gc(self) -> Bool:
        try:
            let free_pct = self.seg_mgr.free_segment_percent()
            return free_pct < GC_THRESHOLD_NORMAL
        catch e:
            # If we can't determine free space, assume GC is needed
            # as a safety measure to prevent space exhaustion.
            return true

    ## Check if the filesystem needs urgent (foreground) garbage collection.
    ##
    ## Returns true when free segments drop below GC_THRESHOLD_URGENT (5%).
    ## At this level, new allocations should block until GC frees at least
    ## one segment. This is the last line of defense before ENOSPC.
    proc needs_urgent_gc(self) -> Bool:
        try:
            let free_pct = self.seg_mgr.free_segment_percent()
            return free_pct < GC_THRESHOLD_URGENT
        catch e:
            return true

    # -------------------------------------------------------------------
    # Space accounting
    # -------------------------------------------------------------------

    ## Return the total number of free (unallocated) blocks available.
    ##
    ## This is an approximation: it includes blocks in free segments that
    ## haven't been opened yet, plus remaining blocks in active segments.
    ## It does NOT include blocks that are invalid but not yet reclaimed
    ## by GC — those will become available after the next GC cycle.
    proc space_available(self) -> Int:
        if self.total_blocks <= 0:
            return 0
        let free = self.total_blocks - self.allocated_blocks
        if free < 0:
            return 0
        return free

    ## Return the block utilization as a percentage (0–100).
    ##
    ## A utilization of 100% means every block is allocated (though some
    ## may be invalid and reclaimable by GC). Values above ~80% indicate
    ## that background GC should be running to maintain write performance.
    proc utilization(self) -> Int:
        if self.total_blocks <= 0:
            return 0
        let pct = (self.allocated_blocks * 100) / self.total_blocks
        if pct > 100:
            return 100
        if pct < 0:
            return 0
        return pct

    # -------------------------------------------------------------------
    # Temperature classification heuristic
    # -------------------------------------------------------------------

    ## Classify data temperature based on access frequency and age.
    ##
    ## This heuristic is used by upper layers (inode manager, extent
    ## allocator) to decide which log head to write to. The classification
    ## directly impacts GC efficiency — good classification means data
    ## with similar lifetimes is grouped together, so entire segments
    ## become reclaimable at once.
    ##
    ## Heuristic:
    ##   - Hot:  access_count >= 10 AND age <= 60    (frequent + recent)
    ##   - Cold: access_count <= 2  AND age >= 3600  (rare + old)
    ##   - Warm: everything else                     (moderate activity)
    ##
    ## Args:
    ##   access_count — number of read/write accesses since last GC epoch
    ##   age          — seconds since last modification
    ##
    ## Returns:
    ##   "hot", "warm", or "cold"
    proc classify_temperature(self, access_count: Int, age: Int) -> String:
        # Hot: heavily accessed data that was recently written.
        # This data is likely to be overwritten soon, so placing it in
        # the hot segment means its blocks will be invalidated quickly,
        # making the segment easy to reclaim.
        if access_count >= 10 and age <= 60:
            return "hot"

        # Cold: data that hasn't been touched in a long time and is
        # rarely accessed. It will probably sit unchanged for a long
        # time, so placing it in the cold segment prevents it from
        # interfering with GC of more active segments.
        if access_count <= 2 and age >= 3600:
            return "cold"

        # Warm: the default bucket for data with moderate activity.
        # This is the most common classification for typical user files.
        return "warm"

    # -------------------------------------------------------------------
    # Pre-allocation cache
    # -------------------------------------------------------------------

    ## Pre-allocate blocks into the cache for fast subsequent allocation.
    ##
    ## This is called ahead of large sequential writes (e.g. when the VFS
    ## layer detects a streaming write pattern) or by batch_allocate() to
    ## fill the cache before iterating.
    ##
    ## Pre-allocated blocks are reserved in the segment manager (they
    ## count as used in the SIT) but have not yet been assigned a nid.
    ## They are stored as dicts with physical_blk, segno, and block_offset.
    ##
    ## Args:
    ##   seg_type — segment type string (e.g. "data_hot")
    ##   count    — number of blocks to pre-allocate
    proc preallocate(self, seg_type: String, count: Int):
        if not dict_has(self.prealloc_cache, seg_type):
            self.prealloc_cache[seg_type] = []

        var allocated = 0
        while allocated < count:
            try:
                let alloc = self.seg_mgr.allocate_block(seg_type)
                if alloc == nil:
                    # No more space — stop pre-allocating
                    break
                push(self.prealloc_cache[seg_type], alloc)
                allocated = allocated + 1
            catch e:
                # Segment manager error — stop pre-allocating but don't
                # fail; we may already have some blocks cached.
                break

    ## Get one pre-allocated block from the cache for the given segment type.
    ##
    ## Returns a dict with physical_blk/segno/block_offset on success,
    ## or nil if the cache is empty for this segment type.
    proc get_preallocated(self, seg_type: String) -> Dict:
        if not dict_has(self.prealloc_cache, seg_type):
            return nil

        let cache = self.prealloc_cache[seg_type]
        if len(cache) == 0:
            return nil

        # Pop from the end of the array (O(1) removal)
        let block = pop(cache)
        return block

    ## Return the number of cached blocks for a given segment type.
    ## Internal helper for batch_allocate().
    proc _cache_size(self, seg_type: String) -> Int:
        if not dict_has(self.prealloc_cache, seg_type):
            return 0
        return len(self.prealloc_cache[seg_type])

    # -------------------------------------------------------------------
    # Statistics and summary
    # -------------------------------------------------------------------

    ## Return a summary dictionary with current allocator state and stats.
    ##
    ## This is used by the sagefs-stats CLI tool and by the checkpoint
    ## manager to persist allocator state across mounts.
    proc summary(self) -> Dict:
        let s = {}
        s["block_size"] = self.block_size
        s["total_blocks"] = self.total_blocks
        s["allocated_blocks"] = self.allocated_blocks
        s["free_blocks"] = self.space_available()
        s["utilization_pct"] = self.utilization()
        s["stats_writes"] = self.stats_writes
        s["stats_reads"] = self.stats_reads
        s["needs_gc"] = self.needs_gc()
        s["needs_urgent_gc"] = self.needs_urgent_gc()

        # Summarize pre-allocation cache state
        let cache_summary = {}
        let cache_keys = dict_keys(self.prealloc_cache)
        for key in cache_keys:
            cache_summary[key] = len(self.prealloc_cache[key])
        s["prealloc_cache"] = cache_summary

        return s
