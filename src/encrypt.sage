## encrypt.sage — SageFS Encryption Layer
##
## Per-file AES-256-XTS encryption (simulated).
## Filename encryption via AES-256-CTS (simulated).
## Key derivation from passphrase.

let ENCRYPT_NONE: Int = 0
let ENCRYPT_AES256_XTS: Int = 1

class EncryptionLayer:
    proc init(self, master_key: String):
        self.master_key = master_key
        self.algorithm = ENCRYPT_AES256_XTS
        self.filename_algorithm = "AES-256-CTS"
        self.inode_keys = {}
        self.encrypted_count = 0

    proc derive_inode_key(self, ino: Int, salt: String) -> String:
        let key_id = str(ino) + ":" + salt
        if not dict_has(self.inode_keys, key_id):
            var key = ""
            let base = hash(self.master_key + "_" + str(ino) + "_" + salt)
            for i in range(32):
                let nibble = (base >> (i * 4)) & 0x0F
                key = key + str(nibble)
            self.inode_keys[key_id] = key
        return self.inode_keys[key_id]

    proc encrypt_data(self, data: Bytes, ino: Int) -> Bytes:
        if self.algorithm == ENCRYPT_NONE:
            return data
        let key = self.derive_inode_key(ino, "data")
        var result = bytes()
        let n = bytes_len(data)
        bytes_push(result, self.algorithm & 0xFF)
        for i in range(n):
            let key_byte = ord(key[i % len(key)])
            bytes_push(result, bytes_get(data, i) ^ key_byte)
        self.encrypted_count = self.encrypted_count + 1
        return result

    proc decrypt_data(self, data: Bytes, ino: Int) -> Bytes:
        if bytes_len(data) == 0:
            return data
        let algo = bytes_get(data, 0)
        if algo == ENCRYPT_NONE:
            var result = bytes()
            for i in range(1, bytes_len(data)):
                bytes_push(result, bytes_get(data, i))
            return result
        let key = self.derive_inode_key(ino, "data")
        var result = bytes()
        let n = bytes_len(data) - 1
        for i in range(n):
            let key_byte = ord(key[i % len(key)])
            bytes_push(result, bytes_get(data, 1 + i) ^ key_byte)
        return result

    proc encrypt_filename(self, name: String, dir_ino: Int) -> String:
        let key = self.derive_inode_key(dir_ino, "filename")
        var result = ""
        for i in range(len(name)):
            let key_char = key[i % len(key)]
            let encrypted_char = ord(name[i]) ^ ord(key_char)
            result = result + chr(encrypted_char)
        return result

    proc decrypt_filename(self, encrypted_name: String, dir_ino: Int) -> String:
        let key = self.derive_inode_key(dir_ino, "filename")
        var result = ""
        for i in range(len(encrypted_name)):
            let key_char = key[i % len(key)]
            let decrypted_char = ord(encrypted_name[i]) ^ ord(key_char)
            result = result + chr(decrypted_char)
        return result

    proc get_stats(self) -> Dict:
        return {
            "algorithm": self.algorithm,
            "encrypted_inodes": self.encrypted_count,
            "inode_keys_cached": len(dict_keys(self.inode_keys))
        }
