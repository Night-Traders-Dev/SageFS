## dir.sage — SageFS Directory Manager
##
## Manages directories, directory entries, and namespaces.
## Handles inline directories for small dirs and provides B-tree
## backing integration point for large directories.

let MAX_NAME_LEN: Int = 255
let DIR_ENTRY_SIZE: Int = 16
let MAX_INLINE_DENTRIES: Int = 200

let DT_UNKNOWN: Int = 0
let DT_FIFO: Int = 1
let DT_CHR: Int = 2
let DT_DIR: Int = 4
let DT_BLK: Int = 6
let DT_REG: Int = 8
let DT_LNK: Int = 10
let DT_SOCK: Int = 12

class DirEntry:
    proc init(self, name: String, ino: Int, file_type: Int):
        self.name = name
        self.ino = ino
        self.file_type = file_type

    proc serialize(self) -> Bytes:
        let buf = bytes()
        let name_bytes = bytes(self.name)
        let name_len = bytes_len(name_bytes)
        bytes_push(buf, name_len & 0xFF)
        bytes_push(buf, (name_len >> 8) & 0xFF)
        bytes_push(buf, self.ino & 0xFF)
        bytes_push(buf, (self.ino >> 8) & 0xFF)
        bytes_push(buf, (self.ino >> 16) & 0xFF)
        bytes_push(buf, (self.ino >> 24) & 0xFF)
        bytes_push(buf, self.file_type & 0xFF)
        for i in range(name_len):
            bytes_push(buf, bytes_get(name_bytes, i))
        while bytes_len(buf) < DIR_ENTRY_SIZE:
            bytes_push(buf, 0)
        return buf

    proc to_string(self) -> String:
        return self.name

class DirManager:
    proc init(self):
        self.inline_entries = {}

    proc hash_filename(self, name: String) -> Int:
        var h: Int = 2166136261
        for i in range(len(name)):
            h = (h ^ ord(name[i])) * 16777619
            h = h & 0xFFFFFFFF
        return h

    proc add_entry(self, name: String, ino: Int, file_type: Int) -> Bool:
        if len(name) > MAX_NAME_LEN:
            return false
        if len(name) == 0:
            return false
        if dict_has(self.inline_entries, name):
            return false
        if len(dict_keys(self.inline_entries)) >= MAX_INLINE_DENTRIES:
            return false
        self.inline_entries[name] = DirEntry(name, ino, file_type)
        return true

    proc remove_entry(self, name: String) -> Bool:
        if not dict_has(self.inline_entries, name):
            return false
        dict_delete(self.inline_entries, name)
        return true

    proc lookup(self, name: String) -> Int:
        if not dict_has(self.inline_entries, name):
            return -1
        let entry = self.inline_entries[name]
        return entry.ino

    proc read_dir(self) -> Array:
        var result = []
        let keys = dict_keys(self.inline_entries)
        for k in keys:
            push(result, self.inline_entries[k])
        return result

    proc is_empty(self) -> Bool:
        return len(dict_keys(self.inline_entries)) == 0

    proc rename(self, old_name: String, new_name: String) -> Bool:
        if not dict_has(self.inline_entries, old_name):
            return false
        if dict_has(self.inline_entries, new_name):
            return false
        let entry = self.inline_entries[old_name]
        dict_delete(self.inline_entries, old_name)
        self.inline_entries[new_name] = DirEntry(new_name, entry.ino, entry.file_type)
        return true

    proc count(self) -> Int:
        return len(dict_keys(self.inline_entries))
