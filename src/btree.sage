import io
import math
import sys

let BTREE_NODE_SIZE: Int = 4096
let BTREE_MAGIC: Int = 0x42545245
let BTREE_MAX_KEYS: Int = 84
let BTREE_MIN_KEYS: Int = 42

proc write_le32(buf: Bytes, val: Int):
    bytes_push(buf, val & 0xFF)
    bytes_push(buf, (val >> 8) & 0xFF)
    bytes_push(buf, (val >> 16) & 0xFF)
    bytes_push(buf, (val >> 24) & 0xFF)

proc write_le64(buf: Bytes, val: Int):
    for i in range(8):
        bytes_push(buf, (val >> (i * 8)) & 0xFF)

proc write_be32(buf: Bytes, val: Int):
    bytes_push(buf, (val >> 24) & 0xFF)
    bytes_push(buf, (val >> 16) & 0xFF)
    bytes_push(buf, (val >> 8) & 0xFF)
    bytes_push(buf, val & 0xFF)

proc write_key(buf: Bytes, key):
    for i in range(8):
        bytes_push(buf, (key.object_id >> (56 - i * 8)) & 0xFF)
    bytes_push(buf, key.type & 0xFF)
    for i in range(7):
        bytes_push(buf, (key.offset >> (48 - i * 8)) & 0xFF)

proc read_le32(buf: Bytes, off: Int) -> Int:
    let b0 = bytes_get(buf, off)
    let b1 = bytes_get(buf, off + 1)
    let b2 = bytes_get(buf, off + 2)
    let b3 = bytes_get(buf, off + 3)
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)

proc read_le64(buf: Bytes, off: Int) -> Int:
    var val = 0
    for i in range(8):
        val = val | (bytes_get(buf, off + i) << (i * 8))
    return val

proc read_be32(buf: Bytes, off: Int) -> Int:
    let b0 = bytes_get(buf, off)
    let b1 = bytes_get(buf, off + 1)
    let b2 = bytes_get(buf, off + 2)
    let b3 = bytes_get(buf, off + 3)
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3

proc read_key(buf: Bytes, off: Int):
    var object_id = 0
    for i in range(8):
        object_id = object_id | (bytes_get(buf, off + i) << (56 - i * 8))
    let type_val = bytes_get(buf, off + 8)
    var off_val = 0
    for i in range(7):
        off_val = off_val | (bytes_get(buf, off + 9 + i) << (48 - i * 8))
    return BTreeKey(object_id, type_val, off_val)

class BTreeKey:
    proc init(self, object_id: Int, type: Int, offset: Int):
        self.object_id = object_id
        self.type = type
        self.offset = offset

    proc compare(self, other) -> Int:
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

    proc serialize(self) -> Bytes:
        let b = bytes()
        for i in range(8):
            bytes_push(b, (self.object_id >> (56 - i * 8)) & 0xFF)
        bytes_push(b, self.type & 0xFF)
        for i in range(7):
            bytes_push(b, (self.offset >> (48 - i * 8)) & 0xFF)
        return b

    proc to_string(self) -> String:
        return "BTreeKey(" + str(self.object_id) + ", " + str(self.type) + ", " + str(self.offset) + ")"

class BTreeItem:
    proc init(self, key, data_offset: Int, data_size: Int):
        self.key = key
        self.data_offset = data_offset
        self.data_size = data_size

class BTreePointer:
    proc init(self, key, block_addr: Int, generation: Int):
        self.key = key
        self.block_addr = block_addr
        self.generation = generation

class SplitResult:
    proc init(self, node, median_key):
        self.node = node
        self.median_key = median_key

class BTreeNode:
    proc init(self):
        self.is_leaf = true
        self.num_items = 0
        self.level = 0
        self.generation = 0
        self.owner_nid = 0
        self.block_addr = 0
        self.items = []
        self.pointers = []
        self.data_area = bytes()

    proc serialize(self) -> Bytes:
        let b = bytes()
        write_be32(b, BTREE_MAGIC)
        if self.is_leaf:
            bytes_push(b, 1)
        else:
            bytes_push(b, 0)
        write_le32(b, self.level)
        write_le64(b, self.generation)
        write_le64(b, self.owner_nid)
        write_le32(b, self.num_items)
        write_le32(b, bytes_len(self.data_area))
        for _ in range(7):
            bytes_push(b, 0)

        if self.is_leaf:
            for i in range(self.num_items):
                let item = self.items[i]
                write_key(b, item.key)
                write_le32(b, item.data_offset)
                write_le32(b, item.data_size)
            for i in range(bytes_len(self.data_area)):
                bytes_push(b, bytes_get(self.data_area, i))
        else:
            for i in range(self.num_items):
                let ptr = self.pointers[i]
                write_key(b, ptr.key)
                write_le64(b, ptr.block_addr)
                write_le64(b, ptr.generation)

        while bytes_len(b) < BTREE_NODE_SIZE:
            bytes_push(b, 0)
        return b

    proc deserialize(self, data: Bytes):
        let magic = read_be32(data, 0)
        let flags = bytes_get(data, 4)
        self.is_leaf = (flags & 1) != 0
        self.level = read_le32(data, 5)
        self.generation = read_le64(data, 9)
        self.owner_nid = read_le64(data, 17)
        self.num_items = read_le32(data, 25)
        let data_area_len = read_le32(data, 29)

        self.items = []
        self.pointers = []
        self.data_area = bytes()

        var off = 40
        if self.is_leaf:
            for i in range(self.num_items):
                let key = read_key(data, off)
                let data_off = read_le32(data, off + 16)
                let data_sz = read_le32(data, off + 20)
                push(self.items, BTreeItem(key, data_off, data_sz))
                off = off + 24
            for i in range(data_area_len):
                bytes_push(self.data_area, bytes_get(data, off + i))
        else:
            for i in range(self.num_items):
                let key = read_key(data, off)
                let block_addr = read_le64(data, off + 16)
                let gen = read_le64(data, off + 24)
                push(self.pointers, BTreePointer(key, block_addr, gen))
                off = off + 32

    ## Rebuild data_area by copying each item's data sequentially,
    ## updating data_offset values to match the compacted layout.
    proc compact_data_area(self):
        if not self.is_leaf:
            return
        if self.num_items == 0:
            self.data_area = bytes()
            return
        let new_data = bytes()
        for i in range(self.num_items):
            let item = self.items[i]
            let old_off = item.data_offset
            let old_sz = item.data_size
            item.data_offset = bytes_len(new_data)
            for j in range(old_sz):
                bytes_push(new_data, bytes_get(self.data_area, old_off + j))
        self.data_area = new_data

    proc search(self, key) -> Int:
        var low: Int = 0
        var high: Int = self.num_items - 1

        while low <= high:
            let mid = low + ((high - low) >> 1)
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

    proc insert(self, key, data: Bytes):
        let idx = self.search(key)

        if idx < self.num_items and self.items[idx].key.compare(key) == 0:
            let item = self.items[idx]
            item.data_offset = bytes_len(self.data_area)
            item.data_size = bytes_len(data)
            for i in range(bytes_len(data)):
                bytes_push(self.data_area, bytes_get(data, i))
            return

        let data_offset = bytes_len(self.data_area)
        let data_size = bytes_len(data)

        for i in range(data_size):
            bytes_push(self.data_area, bytes_get(data, i))

        let new_item = BTreeItem(key, data_offset, data_size)
        push(self.items, new_item)
        self.num_items = self.num_items + 1

        var curr = self.num_items - 1
        while curr > idx:
            let temp = self.items[curr]
            self.items[curr] = self.items[curr - 1]
            self.items[curr - 1] = temp
            curr = curr - 1

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
            var i = mid_idx
            while i < self.num_items:
                push(new_node.items, self.items[i])
                new_node.num_items = new_node.num_items + 1
                i = i + 1

            let remove_count = self.num_items - mid_idx
            for _ in range(remove_count):
                pop(self.items)
            self.num_items = mid_idx

            var new_data = bytes()
            for i in range(new_node.num_items):
                let item = new_node.items[i]
                let old_off = item.data_offset
                let old_sz = item.data_size
                item.data_offset = bytes_len(new_data)
                for j in range(old_sz):
                    bytes_push(new_data, bytes_get(self.data_area, old_off + j))
            new_node.data_area = new_data
        else:
            median_key = self.pointers[mid_idx].key
            var i = mid_idx
            while i < self.num_items:
                push(new_node.pointers, self.pointers[i])
                new_node.num_items = new_node.num_items + 1
                i = i + 1

            let remove_count = self.num_items - mid_idx
            for _ in range(remove_count):
                pop(self.pointers)
            self.num_items = mid_idx

        # Compact the original (left) node's data_area (leaf nodes only)
        if self.is_leaf:
            var left_data = bytes()
            for i in range(self.num_items):
                let item = self.items[i]
                let old_off = item.data_offset
                let old_sz = item.data_size
                item.data_offset = bytes_len(left_data)
                for j in range(old_sz):
                    bytes_push(left_data, bytes_get(self.data_area, old_off + j))
            self.data_area = left_data

        return SplitResult(new_node, median_key)

class BTreeEngine:
    proc init(self, allocator, root_block: Int, gen: Int):
        self.allocator = allocator
        self.root_block = root_block
        self.current_generation = gen

    proc read_node(self, block_addr: Int):
        let data = self.allocator.read_block(block_addr)
        let node = BTreeNode()
        node.block_addr = block_addr
        node.deserialize(data)
        return node

    proc write_node(self, node):
        let data = node.serialize()
        self.allocator.write_block(node.block_addr, data)

    proc cow_node(self, node):
        if node.generation == self.current_generation:
            return node

        let new_block = self.allocator.alloc_block()
        let new_node = BTreeNode()
        new_node.is_leaf = node.is_leaf
        new_node.num_items = node.num_items
        new_node.level = node.level
        new_node.generation = self.current_generation
        new_node.owner_nid = node.owner_nid
        new_node.block_addr = new_block

        for item in node.items:
            push(new_node.items, BTreeItem(item.key, item.data_offset, item.data_size))
        for ptr in node.pointers:
            push(new_node.pointers, BTreePointer(ptr.key, ptr.block_addr, ptr.generation))

        for i in range(bytes_len(node.data_area)):
            bytes_push(new_node.data_area, bytes_get(node.data_area, i))

        return new_node

    proc search(self, key) -> Bytes:
        if self.root_block == 0:
            return bytes()

        var curr_node = self.read_node(self.root_block)

        while curr_node.is_leaf == false:
            var idx = curr_node.search(key)
            if idx == curr_node.num_items:
                idx = curr_node.num_items - 1
            elif idx > 0 and curr_node.pointers[idx].key.compare(key) > 0:
                idx = idx - 1
            curr_node = self.read_node(curr_node.pointers[idx].block_addr)

        let idx = curr_node.search(key)
        if idx < curr_node.num_items and curr_node.items[idx].key.compare(key) == 0:
            let item = curr_node.items[idx]
            let val = bytes()
            for i in range(item.data_size):
                bytes_push(val, bytes_get(curr_node.data_area, item.data_offset + i))
            return val

        return bytes()

    proc insert(self, key, data: Bytes):
        if self.root_block == 0:
            let root = BTreeNode()
            root.generation = self.current_generation
            root.block_addr = self.allocator.alloc_block()
            root.insert(key, data)
            self.write_node(root)
            self.root_block = root.block_addr
            return

        var path = []
        var current = self.cow_node(self.read_node(self.root_block))
        self.root_block = current.block_addr

        while not current.is_leaf:
            let idx = current.search(key)
            var child_idx = idx
            if child_idx == current.num_items:
                child_idx = child_idx - 1
            elif child_idx > 0 and current.pointers[child_idx].key.compare(key) > 0:
                child_idx = child_idx - 1
            push(path, [current, child_idx])

            let child = self.cow_node(self.read_node(current.pointers[child_idx].block_addr))
            current.pointers[child_idx].block_addr = child.block_addr
            current.pointers[child_idx].generation = child.generation
            current = child

        current.insert(key, data)

        while current.num_items > BTREE_MAX_KEYS:
            let split = current.split()
            split.node.block_addr = self.allocator.alloc_block()
            self.write_node(current)
            self.write_node(split.node)

            if len(path) == 0:
                let new_root = BTreeNode()
                new_root.is_leaf = false
                new_root.level = current.level + 1
                new_root.generation = self.current_generation
                new_root.block_addr = self.allocator.alloc_block()
                push(new_root.pointers, BTreePointer(BTreeKey(0, 0, 0), current.block_addr, self.current_generation))
                push(new_root.pointers, BTreePointer(split.median_key, split.node.block_addr, self.current_generation))
                new_root.num_items = 2
                self.write_node(new_root)
                self.root_block = new_root.block_addr
                return

            let p_info = pop(path)
            let parent = p_info[0]
            let insert_at = p_info[1] + 1

            let old_count = parent.num_items
            push(parent.pointers, parent.pointers[old_count - 1])
            var k = old_count - 1
            while k >= insert_at:
                parent.pointers[k + 1] = parent.pointers[k]
                k = k - 1
            parent.pointers[insert_at] = BTreePointer(split.median_key, split.node.block_addr, self.current_generation)
            parent.num_items = old_count + 1

            current = parent

        self.write_node(current)
        while len(path) > 0:
            let p_info = pop(path)
            self.write_node(p_info[0])

    proc delete(self, key):
        if self.root_block == 0:
            return

        var path = []
        var current = self.cow_node(self.read_node(self.root_block))
        self.root_block = current.block_addr

        while not current.is_leaf:
            let idx = current.search(key)
            var child_idx = idx
            if child_idx == current.num_items:
                child_idx = child_idx - 1
            elif child_idx > 0 and current.pointers[child_idx].key.compare(key) > 0:
                child_idx = child_idx - 1
            push(path, [current, child_idx])

            let child = self.cow_node(self.read_node(current.pointers[child_idx].block_addr))
            current.pointers[child_idx].block_addr = child.block_addr
            current.pointers[child_idx].generation = child.generation
            current = child

        let item_idx = current.search(key)
        if item_idx >= current.num_items or current.items[item_idx].key.compare(key) != 0:
            self.write_node(current)
            while len(path) > 0:
                let p_info = pop(path)
                self.write_node(p_info[0])
            return

        var j = item_idx
        while j < current.num_items - 1:
            current.items[j] = current.items[j + 1]
            j = j + 1
        pop(current.items)
        current.num_items = current.num_items - 1
        current.compact_data_area()
        self.write_node(current)

        while current.num_items < BTREE_MIN_KEYS and len(path) > 0:
            let p_info = pop(path)
            let parent = p_info[0]
            let child_idx = p_info[1]

            let left_idx = child_idx - 1
            let right_idx = child_idx + 1

            var left_sib = nil
            var right_sib = nil

            if left_idx >= 0:
                left_sib = self.cow_node(self.read_node(parent.pointers[left_idx].block_addr))
            if right_idx < parent.num_items:
                right_sib = self.cow_node(self.read_node(parent.pointers[right_idx].block_addr))

            current = self.cow_node(self.read_node(parent.pointers[child_idx].block_addr))

            var handled = false

            if not handled and left_sib != nil and left_sib.num_items > BTREE_MIN_KEYS:
                if current.is_leaf:
                    let mover = left_sib.items[left_sib.num_items - 1]
                    pop(left_sib.items)
                    left_sib.num_items = left_sib.num_items - 1
                    push(current.items, mover)
                    var kk = current.num_items - 1
                    while kk > 0:
                        let tmp = current.items[kk]
                        current.items[kk] = current.items[kk - 1]
                        current.items[kk - 1] = tmp
                        kk = kk - 1
                    current.num_items = current.num_items + 1
                    parent.pointers[child_idx].key = mover.key
                else:
                    let mover = left_sib.pointers[left_sib.num_items - 1]
                    pop(left_sib.pointers)
                    left_sib.num_items = left_sib.num_items - 1
                    push(current.pointers, mover)
                    var kk = current.num_items - 1
                    while kk > 0:
                        let tmp = current.pointers[kk]
                        current.pointers[kk] = current.pointers[kk - 1]
                        current.pointers[kk - 1] = tmp
                        kk = kk - 1
                    current.num_items = current.num_items + 1
                    parent.pointers[child_idx].key = mover.key
                handled = true

            if not handled and right_sib != nil and right_sib.num_items > BTREE_MIN_KEYS:
                if current.is_leaf:
                    let mover = right_sib.items[0]
                    var kk = 0
                    while kk < right_sib.num_items - 1:
                        right_sib.items[kk] = right_sib.items[kk + 1]
                        kk = kk + 1
                    pop(right_sib.items)
                    right_sib.num_items = right_sib.num_items - 1
                    push(current.items, mover)
                    current.num_items = current.num_items + 1
                    parent.pointers[right_idx].key = right_sib.items[0].key
                else:
                    let mover = right_sib.pointers[0]
                    var kk = 0
                    while kk < right_sib.num_items - 1:
                        right_sib.pointers[kk] = right_sib.pointers[kk + 1]
                        kk = kk + 1
                    pop(right_sib.pointers)
                    right_sib.num_items = right_sib.num_items - 1
                    push(current.pointers, mover)
                    current.num_items = current.num_items + 1
                    parent.pointers[right_idx].key = right_sib.pointers[0].key
                handled = true

            if not handled:
                if left_sib != nil:
                    for item in current.items:
                        push(left_sib.items, item)
                    left_sib.num_items = left_sib.num_items + current.num_items
                    var kk = child_idx
                    while kk < parent.num_items - 1:
                        parent.pointers[kk] = parent.pointers[kk + 1]
                        kk = kk + 1
                    pop(parent.pointers)
                    parent.num_items = parent.num_items - 1
                    current = left_sib
                else:
                    for item in right_sib.items:
                        push(current.items, item)
                    current.num_items = current.num_items + right_sib.num_items
                    var kk = right_idx
                    while kk < parent.num_items - 1:
                        parent.pointers[kk] = parent.pointers[kk + 1]
                        kk = kk + 1
                    pop(parent.pointers)
                    parent.num_items = parent.num_items - 1

            self.write_node(current)
            if left_sib != nil:
                self.write_node(left_sib)
            if right_sib != nil:
                self.write_node(right_sib)

            current = parent

        while len(path) > 0:
            let p_info = pop(path)
            self.write_node(p_info[0])

        if not current.is_leaf:
            if current.num_items == 0:
                self.root_block = 0
            elif current.num_items == 1:
                self.root_block = current.pointers[0].block_addr

    proc update(self, key, new_data: Bytes):
        self.insert(key, new_data)
