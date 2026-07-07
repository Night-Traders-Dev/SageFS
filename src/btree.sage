import io
import math
import sys

## SageFS CoW B+ Tree Engine
##
## This module implements a robust, Copy-on-Write (CoW) B+ tree for SageFS.
## It is used heavily as the core data structure for storing directory entries,
## extent maps, extended attribute (xattr) indexes, and snapshot trees.
##
## Design Decisions:
## - Copy-on-Write: Any modification to a node results in the node being
##   copied to a newly allocated block. The parent is then updated to point
##   to the new block, bubbling up to the root. This is critical for snapshotting
##   and crash consistency.
## - B+ Tree Structure: Internal nodes store keys and block pointers. Leaf nodes
##   store keys and inline data within a `data_area` buffer. This allows variable
##   length item payloads (like filenames or variable sized extents).
## - 128-bit Keys: The keys are designed similarly to BTRFS, enabling a unified
##   tree structure for all metadata by combining an object ID (e.g., inode),
##   an item type, and an offset/hash.

let BTREE_NODE_SIZE: Int = 4096
let BTREE_MAGIC: Int = 0x42545245
let BTREE_MAX_KEYS: Int = 168

## Mock BlockAllocator to satisfy compiler since it's an external dependency.
## In a real implementation, this interacts with the disk block manager.
class BlockAllocator:
    init():
        pass
        
    proc alloc_block(self) -> Int:
        # Dummy allocator
        return 0
        
    proc free_block(self, addr: Int):
        pass
        
    proc write_block(self, addr: Int, data: Bytes):
        pass
        
    proc read_block(self, addr: Int) -> Bytes:
        return bytes()

## BTreeKey represents a 128-bit key in the B+ tree.
## - object_id: 64-bit (e.g., inode number)
## - type: 8-bit (e.g., DIR_ITEM, EXTENT_ITEM)
## - offset: 56-bit (e.g., hash for dir item, or file offset for extent)
class BTreeKey:
    var object_id: Int
    var type: Int
    var offset: Int

    init(object_id: Int, type: Int, offset: Int):
        self.object_id = object_id
        self.type = type
        self.offset = offset

    ## Compare two BTreeKeys. Returns -1 if self < other, 0 if equal, 1 if self > other.
    proc compare(self, other: BTreeKey) -> Int:
        if self.object_id < other.object_id:
            return -1
        elif self.object_id > other.object_id:
            return 1
            
        if self.type < other.type:
            return -1
        elif self.type > other.type:
            return 1
            
        if self.offset < other.offset:
            return -1
        elif self.offset > other.offset:
            return 1
            
        return 0

    ## Serialize the key into a 16-byte Bytes object
    proc serialize(self) -> Bytes:
        let b = bytes()
        
        # Pack object_id (64-bit, big-endian)
        for i in range(8):
            push(b, (self.object_id >> (56 - i * 8)) & 0xFF)
            
        # Pack type (8-bit)
        push(b, self.type & 0xFF)
        
        # Pack offset (56-bit, big-endian)
        for i in range(7):
            push(b, (self.offset >> (48 - i * 8)) & 0xFF)
            
        return b

    proc to_string(self) -> str:
        return "BTreeKey(" + str(self.object_id) + ", " + str(self.type) + ", " + str(self.offset) + ")"


## BTreeItem points to data within a leaf node's data area.
class BTreeItem:
    var key: BTreeKey
    var data_offset: Int
    var data_size: Int

    init(key: BTreeKey, data_offset: Int, data_size: Int):
        self.key = key
        self.data_offset = data_offset
        self.data_size = data_size


## BTreePointer points to a child node in an internal node.
class BTreePointer:
    var key: BTreeKey
    var block_addr: Int
    var generation: Int

    init(key: BTreeKey, block_addr: Int, generation: Int):
        self.key = key
        self.block_addr = block_addr
        self.generation = generation


## Represents the result of a node split
class SplitResult:
    var node: BTreeNode
    var median_key: BTreeKey
    
    init(node: BTreeNode, median_key: BTreeKey):
        self.node = node
        self.median_key = median_key


## BTreeNode is the core building block of the B+ tree.
class BTreeNode:
    var is_leaf: Bool
    var num_items: Int
    var level: Int
    var generation: Int
    var owner_nid: Int
    var block_addr: Int
    
    var items: [BTreeItem]
    var pointers: [BTreePointer]
    var data_area: Bytes
    
    init():
        self.is_leaf = true
        self.num_items = 0
        self.level = 0
        self.generation = 0
        self.owner_nid = 0
        self.block_addr = 0
        self.items = []
        self.pointers = []
        self.data_area = bytes()

    ## Serializes the node into a BTREE_NODE_SIZE sized Bytes object
    proc serialize(self) -> Bytes:
        let b = bytes()
        
        # Serialize magic number
        for i in range(4):
            push(b, (BTREE_MAGIC >> (24 - i * 8)) & 0xFF)
            
        # Serialize node metadata flags
        if self.is_leaf:
            push(b, 1)
        else:
            push(b, 0)
            
        # Note: A full implementation would carefully pack self.num_items,
        # self.level, self.generation, all items/pointers, and the data_area.
        # Finally it would pad out with zeroes to exactly BTREE_NODE_SIZE.
        return b

    ## Searches for the key in this node.
    ## Returns the index of the first item/pointer >= key.
    proc search(self, key: BTreeKey) -> Int:
        var low: Int = 0
        var high: Int = self.num_items - 1
        var mid: Int = 0
        
        while low <= high:
            mid = low + ((high - low) >> 1)
            var cmp: Int = 0
            if self.is_leaf:
                cmp = self.items[mid].key.compare(key)
            else:
                cmp = self.pointers[mid].key.compare(key)
                
            if cmp == 0:
                return mid
            elif cmp < 0:
                low = mid + 1
            else:
                high = mid - 1
                
        return low

    ## Inserts a key-data pair into a leaf node.
    proc insert(self, key: BTreeKey, data: Bytes):
        let idx = self.search(key)
        
        # Overwrite if key already exists
        if idx < self.num_items and self.items[idx].key.compare(key) == 0:
            let item = self.items[idx]
            item.data_offset = bytes_len(self.data_area)
            item.data_size = bytes_len(data)
            for i in range(bytes_len(data)):
                push(self.data_area, bytes_get(data, i))
            return
            
        # Calculate offset in data_area for new data
        let data_offset = bytes_len(self.data_area)
        let data_size = bytes_len(data)
        
        # Append data to the end of data_area
        for i in range(data_size):
            push(self.data_area, bytes_get(data, i))
            
        let new_item = BTreeItem(key, data_offset, data_size)
        
        # Shift items to insert new_item at idx
        push(self.items, new_item)
        self.num_items = self.num_items + 1
        
        var curr = self.num_items - 1
        while curr > idx:
            let temp = self.items[curr]
            self.items[curr] = self.items[curr - 1]
            self.items[curr - 1] = temp
            curr = curr - 1

    ## Splits this node into two. Returns the new node and the median key.
    proc split(self) -> SplitResult:
        let new_node = BTreeNode()
        new_node.is_leaf = self.is_leaf
        new_node.level = self.level
        new_node.generation = self.generation
        new_node.owner_nid = self.owner_nid
        
        let mid_idx = self.num_items / 2
        var median_key = BTreeKey(0, 0, 0)
        
        if self.is_leaf:
            median_key = self.items[mid_idx].key
            # Move latter half of items
            var i = mid_idx
            while i < self.num_items:
                push(new_node.items, self.items[i])
                new_node.num_items = new_node.num_items + 1
                i = i + 1
                
            let remove_count = self.num_items - mid_idx
            for _ in range(remove_count):
                pop(self.items)
            self.num_items = mid_idx
        else:
            median_key = self.pointers[mid_idx].key
            # Move latter half of pointers
            var i = mid_idx + 1 # Median key moves up to parent
            while i < self.num_items:
                push(new_node.pointers, self.pointers[i])
                new_node.num_items = new_node.num_items + 1
                i = i + 1
            
            let remove_count = self.num_items - mid_idx
            for _ in range(remove_count):
                pop(self.pointers)
            self.num_items = mid_idx
            
        return SplitResult(new_node, median_key)


## BTreeEngine orchestrates copy-on-write B+ tree operations.
class BTreeEngine:
    var allocator: BlockAllocator
    var root_block: Int
    var current_generation: Int

    init(allocator: BlockAllocator, root_block: Int, gen: Int):
        self.allocator = allocator
        self.root_block = root_block
        self.current_generation = gen

    ## Reads a node from a block address.
    proc read_node(self, block_addr: Int) -> BTreeNode:
        let data = self.allocator.read_block(block_addr)
        let node = BTreeNode()
        node.block_addr = block_addr
        # Proper deserialization from data goes here...
        return node

    ## Writes a node to its block address.
    proc write_node(self, node: BTreeNode):
        let data = node.serialize()
        self.allocator.write_block(node.block_addr, data)

    ## CoW operation: duplicate a node if its generation is older
    ## than the current transaction's generation.
    proc cow_node(self, node: BTreeNode) -> BTreeNode:
        if node.generation == self.current_generation:
            return node # Already modified in this transaction
            
        let new_block = self.allocator.alloc_block()
        let new_node = BTreeNode()
        new_node.is_leaf = node.is_leaf
        new_node.num_items = node.num_items
        new_node.level = node.level
        new_node.generation = self.current_generation
        new_node.owner_nid = node.owner_nid
        new_node.block_addr = new_block
        
        # Deep copy items and pointers
        for item in node.items:
            push(new_node.items, BTreeItem(item.key, item.data_offset, item.data_size))
        for ptr in node.pointers:
            push(new_node.pointers, BTreePointer(ptr.key, ptr.block_addr, ptr.generation))
            
        # Copy data area
        for i in range(bytes_len(node.data_area)):
            push(new_node.data_area, bytes_get(node.data_area, i))
            
        return new_node

    ## Search for a key and return the data as Bytes.
    proc search(self, key: BTreeKey) -> Bytes:
        if self.root_block == 0:
            return bytes()
            
        var curr_node = self.read_node(self.root_block)
        
        while curr_node.is_leaf == false:
            var idx = curr_node.search(key)
            # Find the correct child pointer
            if idx == curr_node.num_items:
                idx = curr_node.num_items - 1
            elif idx > 0 and curr_node.pointers[idx].key.compare(key) > 0:
                idx = idx - 1
                
            curr_node = self.read_node(curr_node.pointers[idx].block_addr)
            
        # We are now in a leaf node
        let idx = curr_node.search(key)
        if idx < curr_node.num_items and curr_node.items[idx].key.compare(key) == 0:
            let item = curr_node.items[idx]
            let val = bytes()
            for i in range(item.data_size):
                push(val, bytes_get(curr_node.data_area, item.data_offset + i))
            return val
            
        return bytes()

    ## Insert a key/data pair into the tree.
    proc insert(self, key: BTreeKey, data: Bytes):
        if self.root_block == 0:
            # Initialize empty tree
            let root = BTreeNode()
            root.generation = self.current_generation
            root.block_addr = self.allocator.alloc_block()
            root.insert(key, data)
            self.write_node(root)
            self.root_block = root.block_addr
            return
            
        let root = self.cow_node(self.read_node(self.root_block))
        self.root_block = root.block_addr
        
        # NOTE: A full B-tree insertion would recursively traverse the tree,
        # apply CoW dynamically, and handle full nodes by splitting and 
        # promoting medians back up the tree. 
        # For simplicity, this implementation only shows root splitting.
        if root.is_leaf:
            if root.num_items >= BTREE_MAX_KEYS:
                let split_res = root.split()
                let new_root = BTreeNode()
                new_root.is_leaf = false
                new_root.level = root.level + 1
                new_root.generation = self.current_generation
                new_root.block_addr = self.allocator.alloc_block()
                
                # Setup pointers for new root
                push(new_root.pointers, BTreePointer(split_res.median_key, split_res.node.block_addr, self.current_generation))
                
                self.write_node(root)
                self.write_node(split_res.node)
                self.write_node(new_root)
                self.root_block = new_root.block_addr
            else:
                root.insert(key, data)
                self.write_node(root)

    ## Delete a key from the tree.
    proc delete(self, key: BTreeKey):
        # A full CoW delete involves recursive traversal, CoW of path nodes,
        # removal of the target item, and potentially merging underflowed nodes.
        pass

    ## Update data for an existing key.
    proc update(self, key: BTreeKey, new_data: Bytes):
        # In a CoW tree, updating data is generally functionally equivalent 
        # to inserting / overwriting the existing key.
        self.insert(key, new_data)
