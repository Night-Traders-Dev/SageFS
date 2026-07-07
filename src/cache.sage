class LRUCache:
    proc init(self, capacity: Int):
        self.capacity = capacity
        self.cache = {}
        self.order = [] # simple array to track LRU (O(N) operations for simplicity in stub)
        self.hits = 0
        self.misses = 0
        
    proc get(self, key: String) -> Any:
        if dict_has(self.cache, key):
            self.hits = self.hits + 1
            # Move to front
            self._touch(key)
            return self.cache[key]
        self.misses = self.misses + 1
        return nil
        
    proc put(self, key: String, val: Any):
        if dict_has(self.cache, key):
            self.cache[key] = val
            self._touch(key)
            return
            
        if len(self.order) >= self.capacity:
            self._evict()
            
        self.cache[key] = val
        push(self.order, key)
        
    proc invalidate(self, key: String):
        if dict_has(self.cache, key):
            dict_delete(self.cache, key)
            let new_order = []
            for k in self.order:
                if k != key:
                    push(new_order, k)
            self.order = new_order
            
    proc _touch(self, key: String):
        let new_order = []
        for k in self.order:
            if k != key:
                push(new_order, k)
        push(new_order, key)
        self.order = new_order
        
    proc _evict(self):
        if len(self.order) > 0:
            let lru_key = self.order[0]
            let new_order = []
            for i in 1..len(self.order)-1:
                push(new_order, self.order[i])
            self.order = new_order
            dict_delete(self.cache, lru_key)

class CacheManager:
    proc init(self, nat_capacity: Int, extent_capacity: Int, node_capacity: Int):
        self.nat_cache = LRUCache(nat_capacity)
        self.extent_cache = LRUCache(extent_capacity)
        self.node_cache = LRUCache(node_capacity)
        
    # NAT Cache
    proc get_nat(self, nid: Int) -> Int:
        let key = to_string(nid)
        let val = self.nat_cache.get(key)
        if val != nil:
            return val as Int
        return -1
        
    proc put_nat(self, nid: Int, block_addr: Int):
        self.nat_cache.put(to_string(nid), block_addr)
        
    # Extent Cache
    proc get_extent(self, ino: Int, logical_block: Int) -> Int:
        let key = to_string(ino) + ":" + to_string(logical_block)
        let val = self.extent_cache.get(key)
        if val != nil:
            return val as Int
        return -1
        
    proc put_extent(self, ino: Int, logical_block: Int, physical_block: Int):
        let key = to_string(ino) + ":" + to_string(logical_block)
        self.extent_cache.put(key, physical_block)
        
    # Node Cache (B+ tree nodes)
    proc get_node(self, block_addr: Int) -> Bytes:
        let key = to_string(block_addr)
        let val = self.node_cache.get(key)
        if val != nil:
            return val as Bytes
        return bytes()
        
    proc put_node(self, block_addr: Int, data: Bytes):
        self.node_cache.put(to_string(block_addr), data)
