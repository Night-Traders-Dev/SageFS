class AsyncIOEngine:
    proc init(self):
        self.queues = {}
        
    proc submit_read(self, lba: Int) -> Int:
        return 0
        
    proc submit_write(self, lba: Int, data: Bytes) -> Int:
        return 0
        
    proc poll(self) -> Bool:
        return true
