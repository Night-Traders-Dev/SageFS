import btree

## extent.sage
##
## Implements the SageFS Extent Map for extent-based file allocation.
## This maps logical file offsets to contiguous physical block runs,
## backed by a B+ tree via BTreeEngine.

let MAX_EXTENT_LEN: Int = 32768
let EXTENT_ITEM: Int = 12

class Extent:
    ## Represents a contiguous run of physical blocks allocated to a file
    ## at a specific logical offset.

    proc init(self, file_offset: Int, block_addr: Int, length: Int):
        self.file_offset = file_offset
        self.block_addr = block_addr
        self.length = length

    proc end_offset(self) -> Int:
        return self.file_offset + self.length

    proc serialize(self) -> Bytes:
        ## Serializes the extent into a Bytes object.
        ## Format: 8 bytes file_offset, 8 bytes block_addr, 8 bytes length
        let b = bytes()
        for i in range(8):
            bytes_push(b, (self.file_offset >> (56 - i * 8)) & 0xFF)
        for i in range(8):
            bytes_push(b, (self.block_addr >> (56 - i * 8)) & 0xFF)
        for i in range(8):
            bytes_push(b, (self.length >> (56 - i * 8)) & 0xFF)
        return b


proc extent_from_bytes(data: Bytes) -> Extent:
    ## Deserializes a Bytes object into an Extent.
    if bytes_len(data) < 24:
        return nil
    var file_offset: Int = 0
    for i in range(8):
        file_offset = (file_offset << 8) | bytes_get(data, i)
    var block_addr: Int = 0
    for i in range(8):
        block_addr = (block_addr << 8) | bytes_get(data, 8 + i)
    var length: Int = 0
    for i in range(8):
        length = (length << 8) | bytes_get(data, 16 + i)
    return Extent(file_offset, block_addr, length)


class SearchGeResult:
    proc init(self, leaf: btree.BTreeNode, idx: Int):
        self.leaf = leaf
        self.idx = idx


class ExtentTree:
    ## Manages extents for an inode using a B+ tree backed by BTreeEngine.
    ## Extents are keyed by BTreeKey(ino, EXTENT_ITEM, file_offset).

    proc init(self, tree_engine: btree.BTreeEngine):
        self.btree = tree_engine

    ## Build a BTreeKey for an extent at the given inode and file offset.
    proc _key(self, ino: Int, offset: Int) -> btree.BTreeKey:
        return btree.BTreeKey(ino, EXTENT_ITEM, offset)

    ## Read item data from a leaf node's data_area.
    proc _read_data(self, leaf: btree.BTreeNode, item: btree.BTreeItem) -> Bytes:
        let val = bytes()
        for i in range(item.data_size):
            bytes_push(val, bytes_get(leaf.data_area, item.data_offset + i))
        return val

    ## Find the first leaf item with key >= given key.
    ## Returns SearchGeResult or nil. Traverses the tree with path tracking
    ## to scan across leaf boundaries.
    proc _search_ge(self, key: btree.BTreeKey):
        if self.btree.root_block == 0:
            return nil

        var path = []

        var node = self.btree.read_node(self.btree.root_block)
        while not node.is_leaf:
            var idx = node.search(key)
            if idx >= node.num_items:
                idx = node.num_items - 1
            elif idx > 0 and node.pointers[idx].key.compare(key) > 0:
                idx = idx - 1
            push(path, [node, idx])
            node = self.btree.read_node(node.pointers[idx].block_addr)

        let idx = node.search(key)
        if idx < node.num_items:
            return SearchGeResult(node, idx)

        # Key >= all items in this leaf. Walk up the path to
        # find the next leaf with any items.
        while len(path) > 0:
            let entry = pop(path)
            let parent = entry[0]
            let child_idx = entry[1]
            var next_c = child_idx + 1
            while next_c < parent.num_items:
                var next_node = self.btree.read_node(parent.pointers[next_c].block_addr)
                while not next_node.is_leaf:
                    next_node = self.btree.read_node(next_node.pointers[0].block_addr)
                if next_node.num_items > 0:
                    return SearchGeResult(next_node, 0)
                next_c = next_c + 1

        return nil

    ## Collect all extents for the given inode.
    proc _collect_extents(self, ino: Int):
        var result = []
        var cur_offset: Int = 0

        while true:
            let sgr = self._search_ge(self._key(ino, cur_offset))
            if sgr == nil:
                break
            let leaf = sgr.leaf
            let idx = sgr.idx

            let item = leaf.items[idx]
            if item.key.object_id != ino or item.key.type != EXTENT_ITEM:
                break

            let ext = extent_from_bytes(self._read_data(leaf, item))
            push(result, ext)

            let next_off = ext.end_offset()
            if next_off <= cur_offset:
                cur_offset = cur_offset + 1
            else:
                cur_offset = next_off

        return result

    ## Delete all extents for the given inode from the B-tree.
    proc _delete_extents(self, ino: Int):
        var keys = []
        var cur_offset: Int = 0
        while true:
            let sgr = self._search_ge(self._key(ino, cur_offset))
            if sgr == nil:
                break
            let leaf = sgr.leaf
            let idx = sgr.idx
            let item = leaf.items[idx]
            if item.key.object_id != ino or item.key.type != EXTENT_ITEM:
                break
            push(keys, item.key)
            let ext = extent_from_bytes(self._read_data(leaf, item))
            let next_off = ext.end_offset()
            if next_off <= cur_offset:
                cur_offset = cur_offset + 1
            else:
                cur_offset = next_off

        for k in keys:
            self.btree.delete(k)

    ## Insert an extent, merging with physically and logically
    ## adjacent extents where possible.
    proc insert_extent(self, ino: Int, file_offset: Int, block_addr: Int, length: Int):
        if length <= 0:
            return
        if length > MAX_EXTENT_LEN:
            length = MAX_EXTENT_LEN

        # Delete any existing extent at the exact file_offset
        let existing_key = self._key(ino, file_offset)
        self.btree.delete(existing_key)

        # Find and try left merge
        var merge_left = false
        let left_ge = self._search_ge(self._key(ino, file_offset))
        if left_ge != nil:
            let leaf = left_ge.leaf
            let idx = left_ge.idx
            # Check item just before the found position
            if idx > 0:
                let prev_item = leaf.items[idx - 1]
                if prev_item.key.object_id == ino and prev_item.key.type == EXTENT_ITEM:
                    let left_ext = extent_from_bytes(self._read_data(leaf, prev_item))
                    if left_ext.end_offset() == file_offset and left_ext.block_addr + left_ext.length == block_addr:
                        if left_ext.length + length <= MAX_EXTENT_LEN:
                            self.btree.delete(self._key(ino, left_ext.file_offset))
                            file_offset = left_ext.file_offset
                            block_addr = left_ext.block_addr
                            length = left_ext.length + length
                            merge_left = true
            # Check item at found position for right merge
            if not merge_left and idx < leaf.num_items:
                let item = leaf.items[idx]
                if item.key.object_id == ino and item.key.type == EXTENT_ITEM:
                    let right_ext = extent_from_bytes(self._read_data(leaf, item))
                    if right_ext.file_offset > file_offset:
                        if file_offset + length == right_ext.file_offset and block_addr + length == right_ext.block_addr:
                            if length + right_ext.length <= MAX_EXTENT_LEN:
                                self.btree.delete(self._key(ino, right_ext.file_offset))
                                length = length + right_ext.length

        # Also try right merge if no left merge was found above
        if not merge_left:
            let right_ge = self._search_ge(self._key(ino, file_offset))
            if right_ge != nil:
                let leaf = right_ge.leaf
                let idx = right_ge.idx
                if idx < leaf.num_items:
                    let item = leaf.items[idx]
                    if item.key.object_id == ino and item.key.type == EXTENT_ITEM:
                        let right_ext = extent_from_bytes(self._read_data(leaf, item))
                        if right_ext.file_offset > file_offset:
                            if file_offset + length == right_ext.file_offset and block_addr + length == right_ext.block_addr:
                                if length + right_ext.length <= MAX_EXTENT_LEN:
                                    self.btree.delete(self._key(ino, right_ext.file_offset))
                                    length = length + right_ext.length

        # Insert the (possibly merged) extent
        let new_key = self._key(ino, file_offset)
        let new_ext = Extent(file_offset, block_addr, length)
        self.btree.insert(new_key, new_ext.serialize())

    ## Look up the extent containing the given logical file offset.
    ## Returns the Extent, or nil if no extent maps to the offset.
    proc lookup_extent(self, ino: Int, file_offset: Int) -> Extent:
        let sgr = self._search_ge(self._key(ino, file_offset))
        if sgr == nil:
            return nil
        let leaf = sgr.leaf
        let idx = sgr.idx

        # Check the item at idx (first extent with start >= file_offset)
        if idx < leaf.num_items:
            let item = leaf.items[idx]
            if item.key.object_id == ino and item.key.type == EXTENT_ITEM:
                let ext = extent_from_bytes(self._read_data(leaf, item))
                if ext.file_offset <= file_offset and ext.end_offset() > file_offset:
                    return ext

        # Check the previous extent (starts before file_offset)
        if idx > 0:
            let prev_item = leaf.items[idx - 1]
            if prev_item.key.object_id == ino and prev_item.key.type == EXTENT_ITEM:
                let prev_ext = extent_from_bytes(self._read_data(leaf, prev_item))
                if prev_ext.file_offset <= file_offset and prev_ext.end_offset() > file_offset:
                    return prev_ext

        return nil

    ## Truncate extents to a new smaller file size.
    ## Removes extents past new_size and truncates any straddling extent.
    proc truncate(self, ino: Int, new_size: Int):
        var extents = self._collect_extents(ino)
        var result = []
        for e in extents:
            if e.file_offset >= new_size:
                continue
            if e.end_offset() > new_size:
                e.length = new_size - e.file_offset
            push(result, e)
        self._write_extents(ino, result)

    ## Punch a hole (deallocate blocks) in the extent map for the
    ## given range. Splits extents if the hole falls in the middle.
    proc punch_hole(self, ino: Int, offset: Int, length: Int):
        if length <= 0:
            return
        let hole_end = offset + length
        var extents = self._collect_extents(ino)
        var result = []

        for e in extents:
            # Case 1: Extent completely swallowed by the hole
            if e.file_offset >= offset and e.end_offset() <= hole_end:
                continue
            # Case 2: Hole overlaps the beginning of the extent
            elif e.file_offset >= offset and e.file_offset < hole_end and e.end_offset() > hole_end:
                let trim = hole_end - e.file_offset
                e.file_offset = hole_end
                e.block_addr = e.block_addr + trim
                e.length = e.length - trim
                push(result, e)
            # Case 3: Hole overlaps the end of the extent
            elif e.file_offset < offset and e.end_offset() > offset and e.end_offset() <= hole_end:
                e.length = offset - e.file_offset
                push(result, e)
            # Case 4: Hole splits the extent into two pieces
            elif e.file_offset < offset and e.end_offset() > hole_end:
                let orig_end = e.end_offset()
                let orig_block = e.block_addr
                let orig_off = e.file_offset
                # First piece (before the hole)
                e.length = offset - e.file_offset
                push(result, e)
                # Second piece (after the hole)
                let second_length = orig_end - hole_end
                let second_block = orig_block + (hole_end - orig_off)
                push(result, Extent(hole_end, second_block, second_length))
            else:
                push(result, e)

        self._write_extents(ino, result)


class ExtentAllocator:
    ## Coordinates with a lower-level BlockAllocator to request
    ## contiguous runs of blocks for file data.

    proc init(self, block_allocator: Any):
        self.block_allocator = block_allocator

    proc allocate_run(self, temperature: String, count: Int):
        ## Allocates `count` blocks, ideally as a single extent, but may
        ## return multiple if contiguous space isn't available.
        var allocated: Array[Extent] = []
        var remaining = count
        var current_offset = 0

        while remaining > 0:
            var request_count = remaining
            if request_count > MAX_EXTENT_LEN:
                request_count = MAX_EXTENT_LEN

            let alloc_res = self.block_allocator.allocate_data_block(temperature)
            if not alloc_res.is_success():
                break

            let actual_count = 1
            let start_block = alloc_res.physical_blk

            let ext = Extent(current_offset, start_block, actual_count)
            push(allocated, ext)

            remaining = remaining - actual_count
            current_offset = current_offset + actual_count

        return allocated
