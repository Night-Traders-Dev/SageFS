## SageFS Segment Manager & Segment Information Table (SIT)
##
## Core component of SageFS's log-structured storage layer, inspired by F2FS.
## Manages fixed-size segments (default 512 blocks = 2MB with 4K blocks), tracks
## per-segment valid block bitmaps, and implements multi-head logging with 6
## concurrent log zones for hot/warm/cold data and node separation.
##
## On-disk SIT entries are 72 bytes each, storing segment metadata including
## valid block count, segment type, modification time, and age for GC decisions.
##
## Key design decisions:
##   - Bitmap array (not packed bits) for simplicity and O(1) per-block operations
##   - Greedy + cost-benefit GC victim selection matching F2FS's dual policy
##   - Multi-head logging: 6 active segments (one per data/node temperature)
##   - Free segment list maintained eagerly for O(1) allocation fast-path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Number of blocks per segment (512 blocks × 4K = 2MB segments)
let BLOCKS_PER_SEGMENT: Int = 512

## Size in bytes of a serialized SIT entry on disk
let SIT_ENTRY_SIZE: Int = 72

## Maximum number of SIT entries (segments) the filesystem supports.
## At 2MB per segment, 65536 segments = 128 GiB maximum volume size.
let MAX_SIT_ENTRIES: Int = 65536

# ---------------------------------------------------------------------------
# Segment Type Enum
# ---------------------------------------------------------------------------

## Classifies segments by data temperature and node type.
## SageFS uses F2FS-style multi-head logging with 6 concurrent log zones,
## one for each segment type. This separation reduces GC overhead by
## grouping blocks with similar lifetimes together.
enum SegmentType:
    DataHot       # Frequently written data (journals, temp files)
    DataWarm      # Moderately active data (recent user writes)
    DataCold      # Rarely modified data (archives, media, old files)
    NodeHot       # Directory inodes, frequently updated node blocks
    NodeWarm      # File inodes (moderate update frequency)
    NodeCold      # Indirect node blocks (rarely updated)

# ---------------------------------------------------------------------------
# Segment Type Conversion Helpers
# ---------------------------------------------------------------------------

## Convert a segment type string to its integer representation.
## Accepts lowercase underscore-separated names matching the enum values.
##
## Args:
##   type_str: One of "data_hot", "data_warm", "data_cold",
##             "node_hot", "node_warm", "node_cold"
##
## Returns:
##   Integer 0-5 corresponding to the SegmentType enum, or -1 if invalid.
proc seg_type_to_int(type_str: String) -> Int:
    if type_str == "data_hot":
        return 0
    elif type_str == "data_warm":
        return 1
    elif type_str == "data_cold":
        return 2
    elif type_str == "node_hot":
        return 3
    elif type_str == "node_warm":
        return 4
    elif type_str == "node_cold":
        return 5
    else:
        return -1

## Convert a segment type integer to its string representation.
##
## Args:
##   type_int: Integer 0-5 corresponding to a SegmentType enum value.
##
## Returns:
##   Lowercase underscore-separated string name, or "unknown" if invalid.
proc seg_type_to_string(type_int: Int) -> String:
    if type_int == 0:
        return "data_hot"
    elif type_int == 1:
        return "data_warm"
    elif type_int == 2:
        return "data_cold"
    elif type_int == 3:
        return "node_hot"
    elif type_int == 4:
        return "node_warm"
    elif type_int == 5:
        return "node_cold"
    else:
        return "unknown"

# ---------------------------------------------------------------------------
# SIT Entry — One Per Segment
# ---------------------------------------------------------------------------

## Represents a single entry in the Segment Information Table.
##
## Each SIT entry tracks the state of one segment: which blocks are valid
## (contain live data), the segment's type/temperature classification, and
## metadata used by the garbage collector for victim selection.
##
## The valid_bitmap is stored as an array of integers (0 or 1) rather than
## packed bits for O(1) per-block operations and simplicity. On-disk
## serialization packs this into a compact 64-byte bitmap (512 bits).
##
## Fields:
##   segno        — Segment number (index into the SIT array)
##   valid_blocks — Count of valid (live) blocks in this segment
##   valid_bitmap — Per-block validity: 1 = valid/live, 0 = invalid/free
##   seg_type     — SegmentType value (0-5) classifying this segment
##   mtime        — Last modification timestamp (epoch seconds)
##   age          — Age metric for GC cost-benefit analysis (higher = older)
class SITEntry:
    ## Initialize a new SIT entry for the given segment number.
    ## All blocks start as invalid/free, with no type assigned.
    ##
    ## Args:
    ##   segno: The segment number this entry represents.
    proc init(self, segno: Int):
        self.segno = segno
        self.valid_blocks = 0
        self.seg_type = 0
        self.mtime = 0
        self.age = 0

        # Initialize the validity bitmap — all blocks start as free (0).
        # Using an array of ints for per-block O(1) access.
        self.valid_bitmap = []
        for i in range(BLOCKS_PER_SEGMENT):
            push(self.valid_bitmap, 0)

    ## Mark a block within this segment as valid (contains live data).
    ## Increments the valid block count and sets the bitmap bit.
    ##
    ## Args:
    ##   block_offset: Block index within the segment (0 to BLOCKS_PER_SEGMENT-1).
    ##
    ## Raises:
    ##   Error if block_offset is out of range.
    ##   Silently ignores if block is already valid (idempotent).
    proc mark_valid(self, block_offset: Int):
        if block_offset < 0 or block_offset >= BLOCKS_PER_SEGMENT:
            raise "SITEntry.mark_valid: block_offset " + str(block_offset) + " out of range [0, " + str(BLOCKS_PER_SEGMENT - 1) + "] for segment " + str(self.segno)

        # Only increment count if transitioning from invalid to valid
        if self.valid_bitmap[block_offset] == 0:
            self.valid_bitmap[block_offset] = 1
            self.valid_blocks = self.valid_blocks + 1

    ## Mark a block within this segment as invalid (data is stale/freed).
    ## Decrements the valid block count and clears the bitmap bit.
    ##
    ## Args:
    ##   block_offset: Block index within the segment (0 to BLOCKS_PER_SEGMENT-1).
    ##
    ## Raises:
    ##   Error if block_offset is out of range.
    ##   Silently ignores if block is already invalid (idempotent).
    proc mark_invalid(self, block_offset: Int):
        if block_offset < 0 or block_offset >= BLOCKS_PER_SEGMENT:
            raise "SITEntry.mark_invalid: block_offset " + str(block_offset) + " out of range [0, " + str(BLOCKS_PER_SEGMENT - 1) + "] for segment " + str(self.segno)

        # Only decrement count if transitioning from valid to invalid
        if self.valid_bitmap[block_offset] == 1:
            self.valid_bitmap[block_offset] = 0
            self.valid_blocks = self.valid_blocks - 1

    ## Check whether a specific block in this segment contains valid data.
    ##
    ## Args:
    ##   block_offset: Block index within the segment (0 to BLOCKS_PER_SEGMENT-1).
    ##
    ## Returns:
    ##   true if the block is valid, false if invalid or free.
    ##
    ## Raises:
    ##   Error if block_offset is out of range.
    proc is_valid(self, block_offset: Int) -> Bool:
        if block_offset < 0 or block_offset >= BLOCKS_PER_SEGMENT:
            raise "SITEntry.is_valid: block_offset " + str(block_offset) + " out of range for segment " + str(self.segno)
        return self.valid_bitmap[block_offset] == 1

    ## Check whether every block in this segment is valid (segment is full).
    ##
    ## Returns:
    ##   true if valid_blocks == BLOCKS_PER_SEGMENT.
    proc is_full(self) -> Bool:
        return self.valid_blocks == BLOCKS_PER_SEGMENT

    ## Check whether this segment has no valid blocks (completely free).
    ##
    ## Returns:
    ##   true if valid_blocks == 0.
    proc is_empty(self) -> Bool:
        return self.valid_blocks == 0

    ## Calculate the utilization percentage of this segment.
    ##
    ## Returns:
    ##   Integer percentage 0-100 representing the fraction of valid blocks.
    ##   Uses integer arithmetic: (valid_blocks * 100) / BLOCKS_PER_SEGMENT.
    proc utilization(self) -> Int:
        return int((self.valid_blocks * 100) / BLOCKS_PER_SEGMENT)

    ## Find the first free (invalid) block offset within this segment.
    ## Used by the allocator to find the next writable position.
    ##
    ## Returns:
    ##   Block offset (0 to BLOCKS_PER_SEGMENT-1) of the first free block,
    ##   or -1 if the segment is completely full.
    proc find_free_block(self) -> Int:
        # Linear scan — acceptable for 512-entry bitmap.
        # In a production kernel module this would use __builtin_ctz on
        # packed 64-bit words for O(1) per-word scanning.
        for i in range(BLOCKS_PER_SEGMENT):
            if self.valid_bitmap[i] == 0:
                return i
        return -1

    ## Serialize this SIT entry to a binary buffer for on-disk storage.
    ##
    ## On-disk format (72 bytes total):
    ##   Bytes  0-3:   segno         (4 bytes, little-endian int)
    ##   Bytes  4-7:   valid_blocks  (4 bytes, little-endian int)
    ##   Bytes  8-71:  valid_bitmap  (64 bytes = 512 bits, packed)
    ##
    ## Note: seg_type, mtime, and age are stored separately in the
    ## checkpoint area for atomic consistency. This matches F2FS's
    ## approach where SIT entries on disk store only block-level validity,
    ## and the segment summary area (SSA) carries additional metadata.
    ##
    ## Returns:
    ##   Bytes buffer of SIT_ENTRY_SIZE (72) bytes.
    proc serialize(self) -> Bytes:
        let buf: Bytes = bytes()
        var pad: Int = 0
        while pad < SIT_ENTRY_SIZE:
            bytes_push(buf, 0)
            pad = pad + 1

        # Write segno as 4 bytes, little-endian
        bytes_set(buf, 0, self.segno & 0xFF)
        bytes_set(buf, 1, (self.segno >> 8) & 0xFF)
        bytes_set(buf, 2, (self.segno >> 16) & 0xFF)
        bytes_set(buf, 3, (self.segno >> 24) & 0xFF)

        # Write valid_blocks as 4 bytes, little-endian
        bytes_set(buf, 4, self.valid_blocks & 0xFF)
        bytes_set(buf, 5, (self.valid_blocks >> 8) & 0xFF)
        bytes_set(buf, 6, (self.valid_blocks >> 16) & 0xFF)
        bytes_set(buf, 7, (self.valid_blocks >> 24) & 0xFF)

        # Pack valid_bitmap: 512 bits into 64 bytes.
        # Each byte stores 8 consecutive bitmap entries, LSB-first.
        for byte_idx in range(64):
            let packed_byte = 0
            for bit_idx in range(8):
                let bitmap_idx = byte_idx * 8 + bit_idx
                if bitmap_idx < BLOCKS_PER_SEGMENT:
                    if self.valid_bitmap[bitmap_idx] == 1:
                        packed_byte = packed_byte | (1 << bit_idx)
            bytes_set(buf, 8 + byte_idx, packed_byte)

        return buf

    ## Convert this SIT entry to a dictionary for inspection and debugging.
    ##
    ## Returns:
    ##   Dict with keys: segno, valid_blocks, seg_type, seg_type_name,
    ##   mtime, age, utilization_pct, is_full, is_empty.
    ##   Note: valid_bitmap is omitted for brevity — use is_valid() to
    ##   check individual blocks.
    proc to_dict(self) -> Dict:
        let result = {}
        result["segno"] = self.segno
        result["valid_blocks"] = self.valid_blocks
        result["seg_type"] = self.seg_type
        result["seg_type_name"] = seg_type_to_string(self.seg_type)
        result["mtime"] = self.mtime
        result["age"] = self.age
        result["utilization_pct"] = self.utilization()
        result["is_full"] = self.is_full()
        result["is_empty"] = self.is_empty()
        return result

# ---------------------------------------------------------------------------
# Segment Manager — Manages All Segments
# ---------------------------------------------------------------------------

## Central manager for all segments in the SageFS main area.
##
## Responsibilities:
##   - Maintains the Segment Information Table (array of SITEntry objects)
##   - Manages the free segment list for fast allocation
##   - Implements multi-head logging with 6 current segments (one per type)
##   - Provides block allocation with automatic segment rotation
##   - Supports GC victim selection via greedy and cost-benefit policies
##   - Translates segment-relative addresses to absolute physical blocks
##
## The segment manager is the performance-critical allocation hot path.
## All data and metadata writes flow through allocate_block() which selects
## the appropriate log head based on data temperature.
##
## Fields:
##   total_segments  — Number of segments in the main area
##   sit_entries     — Array of SITEntry objects indexed by segment number
##   free_segments   — List of segment numbers with zero valid blocks
##   current_segments — Dict mapping segment type string to active segment
##                      number for each of the 6 multi-head log zones
##   block_size      — Filesystem block size in bytes (typically 4096)
##   main_start_blk  — Absolute block address where the main area begins
class SegmentManager:
    ## Initialize the segment manager for a filesystem.
    ##
    ## Creates SIT entries for all segments and populates the free list.
    ## All segments start as free. The caller should subsequently call
    ## allocate_segment() for each of the 6 log types to set up the
    ## initial multi-head logging state.
    ##
    ## Args:
    ##   total_segments: Number of segments in the main area. Must be
    ##                   positive and <= MAX_SIT_ENTRIES.
    ##   block_size:     Block size in bytes (e.g. 4096).
    ##   main_start_blk: Absolute block number where main area starts.
    ##
    ## Raises:
    ##   Error if total_segments exceeds MAX_SIT_ENTRIES or is non-positive.
    proc init(self, total_segments: Int, block_size: Int, main_start_blk: Int):
        if total_segments <= 0:
            raise "SegmentManager: total_segments must be positive, got " + str(total_segments)
        if total_segments > MAX_SIT_ENTRIES:
            raise "SegmentManager: total_segments " + str(total_segments) + " exceeds MAX_SIT_ENTRIES " + str(MAX_SIT_ENTRIES)

        self.total_segments = total_segments
        self.blocks_per_segment = BLOCKS_PER_SEGMENT
        self.block_size = block_size
        self.main_start_blk = main_start_blk

        # Initialize SIT entries — one per segment
        self.sit_entries = []
        for i in range(total_segments):
            let entry = SITEntry(i)
            push(self.sit_entries, entry)

        # All segments start free
        self.free_segments = []
        for i in range(total_segments):
            push(self.free_segments, i)

        # Current active segments for each log type.
        # Initially nil (no segment assigned) — caller must allocate.
        # Uses string keys matching seg_type_to_string output.
        self.current_segments = {
            "data_hot": -1,
            "data_warm": -1,
            "data_cold": -1,
            "node_hot": -1,
            "node_warm": -1,
            "node_cold": -1
        }

    ## Retrieve the SIT entry for a given segment number.
    ##
    ## Args:
    ##   segno: Segment number (0 to total_segments-1).
    ##
    ## Returns:
    ##   The SITEntry object for the requested segment.
    ##
    ## Raises:
    ##   Error if segno is out of range.
    proc get_entry(self, segno: Int) -> SITEntry:
        if segno < 0 or segno >= self.total_segments:
            raise "SegmentManager.get_entry: segno " + str(segno) + " out of range [0, " + str(self.total_segments - 1) + "]"
        return self.sit_entries[segno]

    ## Allocate a new segment from the free list and assign it as the
    ## current active segment for the given type.
    ##
    ## This implements the segment rotation part of multi-head logging.
    ## When the current segment for a log type fills up, this method is
    ## called to grab a fresh segment from the free pool.
    ##
    ## Args:
    ##   seg_type_str: Segment type string (e.g. "data_hot", "node_cold").
    ##
    ## Returns:
    ##   Segment number of the newly allocated segment, or -1 if no
    ##   free segments are available (filesystem is full).
    proc allocate_segment(self, seg_type_str: String) -> Int:
        let type_int = seg_type_to_int(seg_type_str)
        if type_int == -1:
            raise "SegmentManager.allocate_segment: invalid segment type '" + seg_type_str + "'"

        # Check for available free segments
        if len(self.free_segments) == 0:
            return -1

        # Pop the first free segment (FIFO policy).
        # A more sophisticated allocator might use wear-leveling or
        # locality-aware selection, but FIFO provides good baseline
        # distribution across the device.
        let segno = self.free_segments[0]
        # Remove from free list — rebuild without the first element
        let new_free = []
        for i in range(1, len(self.free_segments)):
            push(new_free, self.free_segments[i])
        self.free_segments = new_free

        # Configure the segment's type
        let entry = self.sit_entries[segno]
        entry.seg_type = type_int

        # Set as the current segment for this log type
        self.current_segments[seg_type_str] = segno

        return segno

    ## Allocate a single block from the current segment for the given type.
    ##
    ## This is the primary allocation entry point for all data and metadata
    ## writes. It finds a free block in the current segment for the
    ## specified log type. If the current segment is full (or not yet
    ## assigned), it automatically allocates a new segment.
    ##
    ## Args:
    ##   seg_type_str: Segment type string indicating which log head to use.
    ##
    ## Returns:
    ##   Dict with keys:
    ##     "segno"        — Segment number containing the allocated block
    ##     "block_offset" — Offset within the segment (0 to 511)
    ##     "physical_blk" — Absolute block address on disk
    ##   Returns nil if allocation fails (no free segments available).
    proc allocate_block(self, seg_type_str: String) -> Dict:
        let type_int = seg_type_to_int(seg_type_str)
        if type_int == -1:
            raise "SegmentManager.allocate_block: invalid segment type '" + seg_type_str + "'"

        # Get current segment for this type, or allocate one if needed
        let current_segno = self.current_segments[seg_type_str]

        if current_segno == -1:
            # No current segment assigned — allocate the first one
            current_segno = self.allocate_segment(seg_type_str)
            if current_segno == -1:
                return nil
        else:
            # Check if current segment is full
            let current_entry = self.sit_entries[current_segno]
            if current_entry.is_full():
                # Current segment exhausted — rotate to a new one
                current_segno = self.allocate_segment(seg_type_str)
                if current_segno == -1:
                    return nil

        # Find a free block within the current segment
        let entry = self.sit_entries[current_segno]
        let block_offset = entry.find_free_block()

        if block_offset == -1:
            # Should not happen if is_full() check is correct, but handle
            # defensively. Try allocating a new segment.
            current_segno = self.allocate_segment(seg_type_str)
            if current_segno == -1:
                return nil
            entry = self.sit_entries[current_segno]
            block_offset = entry.find_free_block()
            if block_offset == -1:
                # Newly allocated segment has no free blocks — corruption
                raise "SegmentManager.allocate_block: newly allocated segment " + str(current_segno) + " has no free blocks"

        # Mark the block as valid
        entry.mark_valid(block_offset)

        # Compute absolute physical block address
        let physical_blk = self.get_physical_block(current_segno, block_offset)

        let result = {}
        result["segno"] = current_segno
        result["block_offset"] = block_offset
        result["physical_blk"] = physical_blk
        return result

    ## Free an entire segment, marking all its blocks as invalid.
    ##
    ## This is typically called by the garbage collector after it has
    ## relocated all valid blocks out of a victim segment. The segment
    ## is returned to the free list for reuse.
    ##
    ## Args:
    ##   segno: Segment number to free.
    ##
    ## Raises:
    ##   Error if segno is out of range.
    proc free_segment(self, segno: Int):
        if segno < 0 or segno >= self.total_segments:
            raise "SegmentManager.free_segment: segno " + str(segno) + " out of range"

        let entry = self.sit_entries[segno]

        # Clear all valid bits and reset the count
        for i in range(BLOCKS_PER_SEGMENT):
            entry.valid_bitmap[i] = 0
        entry.valid_blocks = 0

        # Reset metadata
        entry.mtime = 0
        entry.age = 0

        # Add back to the free list if not already present.
        # Guard against double-free by checking membership.
        if not array_contains(self.free_segments, segno):
            push(self.free_segments, segno)

        # If this segment was the current segment for any log type,
        # clear that assignment so the next allocation will pick a new one.
        let type_keys = dict_keys(self.current_segments)
        for key in type_keys:
            if self.current_segments[key] == segno:
                self.current_segments[key] = -1

    ## Invalidate a specific block within a segment.
    ##
    ## Called when data is overwritten or deleted. The old block location
    ## is marked invalid so the GC knows it can reclaim the space. This
    ## is the fundamental operation that makes log-structured FS work:
    ## old data is never overwritten in place, just invalidated.
    ##
    ## Args:
    ##   segno:        Segment number containing the block.
    ##   block_offset: Block offset within the segment.
    ##
    ## Raises:
    ##   Error if segno or block_offset is out of range.
    proc invalidate_block(self, segno: Int, block_offset: Int):
        if segno < 0 or segno >= self.total_segments:
            raise "SegmentManager.invalidate_block: segno " + str(segno) + " out of range"

        let entry = self.sit_entries[segno]
        entry.mark_invalid(block_offset)

        # If the segment just became completely empty, add to free list.
        # This enables immediate reuse without waiting for GC.
        if entry.is_empty():
            if not array_contains(self.free_segments, segno):
                push(self.free_segments, segno)

    ## Convert a segment-relative block address to an absolute physical
    ## block address on disk.
    ##
    ## Physical layout:
    ##   physical_blk = main_start_blk + (segno * BLOCKS_PER_SEGMENT) + block_offset
    ##
    ## Args:
    ##   segno:        Segment number.
    ##   block_offset: Block offset within the segment.
    ##
    ## Returns:
    ##   Absolute block number on the storage device.
    ##
    ## Raises:
    ##   Error if segno or block_offset is out of range.
    proc get_physical_block(self, segno: Int, block_offset: Int) -> Int:
        if segno < 0 or segno >= self.total_segments:
            raise "SegmentManager.get_physical_block: segno " + str(segno) + " out of range"
        if block_offset < 0 or block_offset >= BLOCKS_PER_SEGMENT:
            raise "SegmentManager.get_physical_block: block_offset " + str(block_offset) + " out of range"

        return self.main_start_blk + (segno * BLOCKS_PER_SEGMENT) + block_offset

    ## Return the number of free (completely empty) segments.
    ##
    ## Returns:
    ##   Count of segments with zero valid blocks.
    proc free_segment_count(self) -> Int:
        return len(self.free_segments)

    ## Return the number of dirty segments (partially valid).
    ##
    ## A dirty segment has some valid blocks and some invalid blocks,
    ## making it a potential candidate for garbage collection. Segments
    ## that are completely full or completely empty are not dirty.
    ##
    ## Returns:
    ##   Count of segments where 0 < valid_blocks < BLOCKS_PER_SEGMENT.
    proc dirty_segment_count(self) -> Int:
        var count = 0
        for i in range(self.total_segments):
            let entry = self.sit_entries[i]
            if entry.valid_blocks > 0 and entry.valid_blocks < BLOCKS_PER_SEGMENT:
                count = count + 1
        return count

    ## Find the best GC victim using the greedy policy.
    ##
    ## Greedy selection picks the segment with the fewest valid blocks
    ## (but at least one — empty segments are already free). This
    ## minimizes the number of valid blocks that must be relocated,
    ## reducing GC write amplification.
    ##
    ## This is F2FS's foreground GC policy, used when free space is
    ## critically low and we need to reclaim segments quickly.
    ##
    ## Returns:
    ##   Segment number of the best victim, or -1 if no candidates exist.
    proc get_victim_greedy(self) -> Int:
        let best_segno = -1
        let best_valid = BLOCKS_PER_SEGMENT + 1  # Sentinel: higher than any real value

        for i in range(self.total_segments):
            let entry = self.sit_entries[i]
            # Candidate must have some valid blocks (not empty) and not be full.
            # Empty segments are already in the free list — no GC needed.
            # We also skip current active segments to avoid conflicts.
            if entry.valid_blocks > 0 and entry.valid_blocks < BLOCKS_PER_SEGMENT:
                # Skip segments that are currently active log heads
                let is_current = false
                let type_keys = dict_keys(self.current_segments)
                for key in type_keys:
                    if self.current_segments[key] == i:
                        is_current = true
                        break

                if not is_current:
                    if entry.valid_blocks < best_valid:
                        best_valid = entry.valid_blocks
                        best_segno = i

        return best_segno

    ## Find the best GC victim using the cost-benefit policy.
    ##
    ## Cost-benefit analysis considers both the utilization (how many
    ## valid blocks must be moved) and the age of the segment (how long
    ## since it was last modified). Older segments with more invalid
    ## blocks are preferred because:
    ##   - They are less likely to have their remaining valid blocks
    ##     invalidated naturally (reducing unnecessary moves)
    ##   - Moving fewer blocks is always cheaper
    ##
    ## Score formula (from F2FS):
    ##   score = age * (1 - u) / (1 + u)
    ##   where u = utilization as a fraction (0.0 to 1.0)
    ##
    ## Higher score = better victim. This balances reclamation cost
    ## against the benefit of freeing the segment.
    ##
    ## This is F2FS's background GC policy, used during idle periods
    ## for long-term space optimization.
    ##
    ## Returns:
    ##   Segment number of the best victim, or -1 if no candidates exist.
    proc get_victim_cost_benefit(self) -> Int:
        let best_segno = -1
        let best_score = -1

        for i in range(self.total_segments):
            let entry = self.sit_entries[i]
            # Same candidate criteria as greedy
            if entry.valid_blocks > 0 and entry.valid_blocks < BLOCKS_PER_SEGMENT:
                # Skip currently active segments
                let is_current = false
                let type_keys = dict_keys(self.current_segments)
                for key in type_keys:
                    if self.current_segments[key] == i:
                        is_current = true
                        break

                if not is_current:
                    # Compute utilization as percentage (0-100)
                    let util_pct = entry.utilization()

                    # Cost-benefit score: age * (100 - util) / (100 + util)
                    # Using integer arithmetic scaled by 100 to avoid floating point.
                    # Denominator is always > 0 (util_pct >= 0, so 100 + util_pct >= 100).
                    let age_factor = entry.age
                    if age_factor < 1:
                        age_factor = 1  # Minimum age of 1 to give new segments some score

                    let score = (age_factor * (100 - util_pct)) / (100 + util_pct)

                    if score > best_score:
                        best_score = score
                        best_segno = i

        return best_segno

    ## Get all segment numbers of a given type.
    ##
    ## Useful for type-specific GC or statistics gathering.
    ##
    ## Args:
    ##   seg_type_str: Segment type string (e.g. "data_hot").
    ##
    ## Returns:
    ##   Array of segment numbers that are classified as the given type
    ##   and have at least one valid block.
    proc get_segments_by_type(self, seg_type_str: String) -> Array:
        ## If "all" is passed, return every segment with at least one valid block.
        if seg_type_str == "all":
            let result = []
            for i in range(self.total_segments):
                let entry = self.sit_entries[i]
                if entry.valid_blocks > 0:
                    push(result, i)
            return result

        let type_int = seg_type_to_int(seg_type_str)
        if type_int == -1:
            raise "SegmentManager.get_segments_by_type: invalid type '" + seg_type_str + "'"

        let result = []
        for i in range(self.total_segments):
            let entry = self.sit_entries[i]
            if entry.seg_type == type_int and entry.valid_blocks > 0:
                push(result, i)
        return result

    ## Generate a summary of the segment manager's current state.
    ##
    ## Returns:
    ##   Dict with keys:
    ##     "total_segments"   — Total number of segments
    ##     "free_segments"    — Number of completely free segments
    ##     "used_segments"    — Number of segments with any valid blocks
    ##     "dirty_segments"   — Number of partially valid segments (GC candidates)
    ##     "full_segments"    — Number of completely full segments
    ##     "utilization_pct"  — Overall volume utilization percentage
    ##     "total_valid_blocks" — Sum of valid blocks across all segments
    ##     "total_blocks"     — Total blocks in the main area
    ##     "segments_by_type" — Dict mapping type names to counts
    ##     "current_segments" — Dict mapping type names to current segment numbers
    proc summary(self) -> Dict:
        let total_valid = 0
        let used_count = 0
        let dirty_count = 0
        let full_count = 0

        # Per-type counters
        let type_counts = {
            "data_hot": 0,
            "data_warm": 0,
            "data_cold": 0,
            "node_hot": 0,
            "node_warm": 0,
            "node_cold": 0
        }

        for i in range(self.total_segments):
            let entry = self.sit_entries[i]
            total_valid = total_valid + entry.valid_blocks

            if entry.valid_blocks > 0:
                used_count = used_count + 1
                let type_name = seg_type_to_string(entry.seg_type)
                if dict_has(type_counts, type_name):
                    type_counts[type_name] = type_counts[type_name] + 1

                if entry.valid_blocks < BLOCKS_PER_SEGMENT:
                    dirty_count = dirty_count + 1
                else:
                    full_count = full_count + 1

        let total_blocks = self.total_segments * BLOCKS_PER_SEGMENT
        let utilization_pct = 0
        if total_blocks > 0:
            utilization_pct = int((total_valid * 100) / total_blocks)

        let result = {}
        result["total_segments"] = self.total_segments
        result["free_segments"] = len(self.free_segments)
        result["used_segments"] = used_count
        result["dirty_segments"] = dirty_count
        result["full_segments"] = full_count
        result["utilization_pct"] = utilization_pct
        result["total_valid_blocks"] = total_valid
        result["total_blocks"] = total_blocks
        result["segments_by_type"] = type_counts
        result["current_segments"] = self.current_segments
        return result

    ## Given an absolute physical block number, compute which segment it
    ## belongs to and its offset within that segment.
    ##
    ## Args:
    ##   physical_blk: Absolute physical block address.
    ##
    ## Returns:
    ##   Dict with keys:
    ##     "segno"        — segment number containing the block
    ##     "block_offset" — offset of the block within the segment
    proc get_block_location(self, physical_blk: Int) -> Dict:
        let relative_blk = physical_blk - self.main_start_blk
        let segno = int(relative_blk / self.blocks_per_segment)
        let block_offset = relative_blk % self.blocks_per_segment
        let result = {}
        result["segno"] = segno
        result["block_offset"] = block_offset
        return result

    ## Return the percentage of free segments relative to the total.
    ##
    ## Returns:
    ##   Integer percentage 0-100: (free_segments / total_segments) * 100.
    proc free_segment_percent(self) -> Int:
        if self.total_segments <= 0:
            return 0
        return int((len(self.free_segments) * 100) / self.total_segments)
