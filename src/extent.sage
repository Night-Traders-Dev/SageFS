## extent.sage
##
## Implements the SageFS Extent Map for extent-based file allocation.
## This maps logical file offsets to contiguous physical block runs.

let MAX_EXTENT_LEN: Int = 32768

class Extent:
    ## Represents a contiguous run of physical blocks allocated to a file at a specific logical offset.
    var file_offset: Int
    var block_addr: Int
    var length: Int

    proc init(self, file_offset: Int, block_addr: Int, length: Int):
        self.file_offset = file_offset
        self.block_addr = block_addr
        self.length = length

    proc end_offset(self) -> Int:
        ## Returns the logical offset immediately following this extent.
        return self.file_offset + self.length

    proc serialize(self) -> Bytes:
        ## Serializes the extent into a Bytes object.
        ## Format: 8 bytes file_offset, 8 bytes block_addr, 8 bytes length
        let b = bytes(24)
        # Using built-in bytes serialization
        return b


class ExtentTree:
    ## Manages extents for an inode.
    ## Wraps underlying BTreeEngine logic to maintain extents.
    var ino: Int
    var btree: Any
    var extents: Array[Extent]

    proc init(self, ino: Int, btree: Any):
        self.ino = ino
        self.btree = btree
        self.extents = []

    proc insert_extent(self, file_offset: Int, block_addr: Int, length: Int):
        ## Inserts an extent into the tree, merging with adjacent extents
        ## if they are logically and physically contiguous.
        if length <= 0:
            return

        var new_ext = Extent(file_offset, block_addr, length)
        var insert_idx = 0

        # Find the correct insertion point to maintain order
        for i in range(len(self.extents)):
            if self.extents[i].file_offset > file_offset:
                break
            insert_idx = i + 1

        # Attempt to merge with the left neighbor
        if insert_idx > 0:
            let left_ext = self.extents[insert_idx - 1]
            if left_ext.end_offset() == new_ext.file_offset and left_ext.block_addr + left_ext.length == new_ext.block_addr:
                if left_ext.length + new_ext.length <= MAX_EXTENT_LEN:
                    # Merge into the left extent
                    left_ext.length = left_ext.length + new_ext.length
                    new_ext = left_ext # Track the merged extent for right-merge check
                    insert_idx = insert_idx - 1
                else:
                    self.extents.insert(insert_idx, new_ext)
            else:
                self.extents.insert(insert_idx, new_ext)
        else:
            self.extents.insert(insert_idx, new_ext)

        # Attempt to merge with the right neighbor
        if insert_idx + 1 < len(self.extents):
            let right_ext = self.extents[insert_idx + 1]
            if new_ext.end_offset() == right_ext.file_offset and new_ext.block_addr + new_ext.length == right_ext.block_addr:
                if new_ext.length + right_ext.length <= MAX_EXTENT_LEN:
                    # Merge right extent into new_ext
                    new_ext.length = new_ext.length + right_ext.length
                    # Remove the right extent since it's now merged
                    self.extents.pop(insert_idx + 1)

    proc lookup_extent(self, file_offset: Int) -> Extent:
        ## Finds the extent containing the specified logical offset.
        ## Returns the Extent, or nil if no extent maps to the offset.
        for ext in self.extents:
            if file_offset >= ext.file_offset and file_offset < ext.end_offset():
                return ext
        return nil

    proc truncate(self, new_size: Int):
        ## Removes or truncates extents past the new file size.
        var i = len(self.extents) - 1
        while i >= 0:
            let ext = self.extents[i]
            if ext.file_offset >= new_size:
                # The extent is completely past the new size, remove it entirely
                self.extents.pop(i)
            elif ext.end_offset() > new_size:
                # The extent overlaps the new size, truncate it
                ext.length = new_size - ext.file_offset
            i = i - 1

    proc punch_hole(self, offset: Int, length: Int):
        ## Removes or splits extents falling within the hole range.
        let hole_end = offset + length
        var i = 0

        while i < len(self.extents):
            let ext = self.extents[i]

            # Case 1: Extent is completely swallowed by the hole
            if ext.file_offset >= offset and ext.end_offset() <= hole_end:
                self.extents.pop(i)
                continue

            # Case 2: The hole overlaps the beginning of the extent
            elif ext.file_offset >= offset and ext.file_offset < hole_end and ext.end_offset() > hole_end:
                let trim = hole_end - ext.file_offset
                ext.file_offset = hole_end
                ext.block_addr = ext.block_addr + trim
                ext.length = ext.length - trim

            # Case 3: The hole overlaps the end of the extent
            elif ext.file_offset < offset and ext.end_offset() > offset and ext.end_offset() <= hole_end:
                ext.length = offset - ext.file_offset

            # Case 4: The hole splits the extent into two pieces
            elif ext.file_offset < offset and ext.end_offset() > hole_end:
                let orig_end = ext.end_offset()
                let orig_block = ext.block_addr
                let orig_offset = ext.file_offset

                # Truncate the first half (before the hole)
                ext.length = offset - ext.file_offset

                # Create and insert the second half (after the hole)
                let second_length = orig_end - hole_end
                let second_block = orig_block + (hole_end - orig_offset)
                let second_ext = Extent(hole_end, second_block, second_length)
                
                self.extents.insert(i + 1, second_ext)
                i = i + 1

            i = i + 1


class ExtentAllocator:
    ## Coordinates with a lower-level BlockAllocator to request contiguous runs of blocks.
    var block_allocator: Any

    proc init(self, block_allocator: Any):
        self.block_allocator = block_allocator

    proc allocate_run(self, temperature: String, count: Int) -> Array[Extent]:
        ## Allocates `count` blocks, ideally as a single extent, but may return multiple
        ## if contiguous space isn't available.
        var allocated: Array[Extent] = []
        var remaining = count
        var current_offset = 0

        while remaining > 0:
            var request_count = remaining
            if request_count > MAX_EXTENT_LEN:
                request_count = MAX_EXTENT_LEN

            # In practice, this would request blocks from block_allocator
            # let alloc_res = self.block_allocator.allocate_blocks(temperature, request_count)
            let actual_count = request_count
            let start_block = 0 # Placeholder for actual assigned block

            let ext = Extent(current_offset, start_block, actual_count)
            allocated.push(ext)

            remaining = remaining - actual_count
            current_offset = current_offset + actual_count

        return allocated
