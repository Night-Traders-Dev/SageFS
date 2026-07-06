class RaidEngine:
    proc init(self, level: Int):
        self.level = level # 0, 1, 5, 6, 10
        self.devices = []
        
    proc add_device(self, dev_path: String):
        push(self.devices, dev_path)
        
    proc read_block(self, lba: Int) -> Bytes:
        return bytes()
        
    proc write_block(self, lba: Int, data: Bytes):
        pass
        
    proc scrub(self) -> Bool:
        return true
