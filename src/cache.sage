class LRUCache:
    proc init(self, capacity: Int):
        self.capacity = capacity
        self.cache = {}
        self.order = []
        self.hits = 0
        self.misses = 0

    proc get(self, key: String) -> Any:
        if dict_has(self.cache, key):
            self.hits = self.hits + 1
            self._touch(key)
            return self.cache[key]
        self.misses = self.misses + 1
        return nil

    proc put(self, key: String, val: Any):
        if self.capacity <= 0:
            return
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
            var new_order = []
            for k in self.order:
                if k != key:
                    push(new_order, k)
            self.order = new_order

    proc clear(self):
        self.cache = {}
        self.order = []
        self.hits = 0
        self.misses = 0

    proc size(self) -> Int:
        return len(self.order)

    proc hit_rate(self) -> Int:
        let total = self.hits + self.misses
        if total == 0:
            return 0
        return int((self.hits * 100) / total)

    proc _touch(self, key: String):
        var new_order = []
        for k in self.order:
            if k != key:
                push(new_order, k)
        push(new_order, key)
        self.order = new_order

    proc _evict(self):
        if len(self.order) > 0:
            let lru_key = self.order[0]
            var new_order = []
            for i in range(1, len(self.order)):
                push(new_order, self.order[i])
            self.order = new_order
            dict_delete(self.cache, lru_key)

class CacheManager:
    proc init(self, nat_capacity: Int, extent_capacity: Int, node_capacity: Int):
        self.nat_cache = LRUCache(nat_capacity)
        self.extent_cache = LRUCache(extent_capacity)
        self.node_cache = LRUCache(node_capacity)

    proc get_nat(self, nid: Int) -> Int:
        let val = self.nat_cache.get(str(nid))
        if val != nil:
            return val
        return -1

    proc put_nat(self, nid: Int, block_addr: Int):
        self.nat_cache.put(str(nid), block_addr)

    proc invalidate_nat(self, nid: Int):
        self.nat_cache.invalidate(str(nid))

    proc get_extent(self, ino: Int, logical_block: Int) -> Int:
        let key = str(ino) + ":" + str(logical_block)
        let val = self.extent_cache.get(key)
        if val != nil:
            return val
        return -1

    proc put_extent(self, ino: Int, logical_block: Int, physical_block: Int):
        let key = str(ino) + ":" + str(logical_block)
        self.extent_cache.put(key, physical_block)

    proc invalidate_extent(self, ino: Int, logical_block: Int):
        let key = str(ino) + ":" + str(logical_block)
        self.extent_cache.invalidate(key)

    proc get_node(self, block_addr: Int) -> Bytes:
        let val = self.node_cache.get(str(block_addr))
        if val != nil:
            return val
        return bytes()

    proc put_node(self, block_addr: Int, data: Bytes):
        self.node_cache.put(str(block_addr), data)

    proc invalidate_node(self, block_addr: Int):
        self.node_cache.invalidate(str(block_addr))

    proc clear_all(self):
        self.nat_cache.clear()
        self.extent_cache.clear()
        self.node_cache.clear()

    proc get_stats(self) -> Dict:
        return {
            "nat": {"size": self.nat_cache.size(), "hit_rate": self.nat_cache.hit_rate()},
            "extent": {"size": self.extent_cache.size(), "hit_rate": self.extent_cache.hit_rate()},
            "node": {"size": self.node_cache.size(), "hit_rate": self.node_cache.hit_rate()}
        }
