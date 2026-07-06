class CacheManager:
    proc init(self, max_size: Int):
        self.max_size = max_size
        self.entries = {}
        
    proc get(self, key: String) -> Bytes:
        if dict_has(self.entries, key):
            return self.entries[key]
        return bytes()
        
    proc put(self, key: String, data: Bytes):
        self.entries[key] = data
        
    proc invalidate(self, key: String):
        if dict_has(self.entries, key):
            dict_delete(self.entries, key)
