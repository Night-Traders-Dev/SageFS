## xattr.sage — SageFS Extended Attributes
##
## Stores name-value pairs of extended attributes.
## Supports inline storage within inodes and external block storage.

let XATTR_INLINE_MAX: Int = 512

class XAttrManager:
    proc init(self):
        self.inline_xattrs = {}
        self.xattr_count = 0

    proc set_xattr(self, ino: Int, name: String, value: Bytes) -> Bool:
        if len(name) == 0:
            return false
        if len(name) > 255:
            return false
        let key = str(ino) + ":" + name
        self.inline_xattrs[key] = value
        self.xattr_count = self.xattr_count + 1
        return true

    proc get_xattr(self, ino: Int, name: String) -> Bytes:
        let key = str(ino) + ":" + name
        if dict_has(self.inline_xattrs, key):
            return self.inline_xattrs[key]
        return bytes()

    proc remove_xattr(self, ino: Int, name: String) -> Bool:
        let key = str(ino) + ":" + name
        if dict_has(self.inline_xattrs, key):
            dict_delete(self.inline_xattrs, key)
            self.xattr_count = self.xattr_count - 1
            return true
        return false

    proc list_xattrs(self, ino: Int) -> Array:
        var result = []
        let prefix = str(ino) + ":"
        for key in dict_keys(self.inline_xattrs):
            if len(key) > len(prefix):
                var prefix_match = true
                for i in range(len(prefix)):
                    if key[i] != prefix[i]:
                        prefix_match = false
                        break
                if prefix_match:
                    let name = slice(key, len(prefix), len(key))
                    push(result, name)
        return result

    proc total_size(self, ino: Int) -> Int:
        var total = 0
        let names = self.list_xattrs(ino)
        for name in names:
            let key = str(ino) + ":" + name
            if dict_has(self.inline_xattrs, key):
                total = total + len(name) + bytes_len(self.inline_xattrs[key])
        return total

    proc clear_all(self, ino: Int):
        let names = self.list_xattrs(ino)
        for name in names:
            let key = str(ino) + ":" + name
            dict_delete(self.inline_xattrs, key)
