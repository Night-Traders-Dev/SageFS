## dir.sage — SageFS Directory Manager
##
## Manages directories, directory entries, and namespaces.
## Handles inline directories for small dirs and provides B-tree
## backing integration point for large directories.

let MAX_NAME_LEN: Int = 255
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

    proc deserialize(self, buf: Bytes) -> Bool:
        ## Populate from the on-disk directory format written by VFS._save_dir():
        ## a 2-byte little-endian entry count, then per entry
        ## ino(4 LE), name_len(2 LE), file_type(1), then name_len name bytes.
        ##
        ## This lives here so the format has exactly one decoder. It used to be
        ## inlined in VFS._decode_dir_data(), which meant the directory format
        ## was specified in two places -- and DirEntry.serialize() specified it
        ## a third time, with the fields in the opposite order (name_len before
        ## ino) and each entry zero-padded to a 16-byte DIR_ENTRY_SIZE. That
        ## encoder was never called, but it was wrong in a way that would have
        ## silently corrupted every directory had anything started using it:
        ## reading name_len from the ino field, and truncating any name longer
        ## than 9 bytes because the entry is padded to 16.
        ##
        ## Returns false if the buffer is truncated, and leaves self holding
        ## whatever was decoded before the damage, so a caller can tell that the
        ## directory did not fully decode instead of acting on a partial listing.
        self.inline_entries = {}
        if bytes_len(buf) < 2:
            return false
        let count: Int = bytes_get(buf, 0) | (bytes_get(buf, 1) << 8)
        var off: Int = 2
        var i: Int = 0
        while i < count:
            ## 7-byte header: ino(4) + name_len(2) + file_type(1).
            if off + 7 > bytes_len(buf):
                return false
            let entry_ino: Int = bytes_get(buf, off) | (bytes_get(buf, off + 1) << 8) | (bytes_get(buf, off + 2) << 16) | (bytes_get(buf, off + 3) << 24)
            let name_len: Int = bytes_get(buf, off + 4) | (bytes_get(buf, off + 5) << 8)
            let ftype: Int = bytes_get(buf, off + 6)
            off = off + 7
            if off + name_len > bytes_len(buf):
                return false
            var name_str: String = ""
            var j: Int = 0
            while j < name_len:
                name_str = name_str + chr(bytes_get(buf, off + j))
                j = j + 1
            self.add_entry(name_str, entry_ino, ftype)
            off = off + name_len
            i = i + 1
        return true

    proc count(self) -> Int:
        return len(dict_keys(self.inline_entries))
