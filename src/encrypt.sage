class EncryptionLayer:
    proc init(self, master_key: String):
        self.master_key = master_key
        
    proc encrypt_data(self, data: Bytes, inode_key: String) -> Bytes:
        return data
        
    proc decrypt_data(self, data: Bytes, inode_key: String) -> Bytes:
        return data
        
    proc encrypt_filename(self, name: String) -> String:
        return name
