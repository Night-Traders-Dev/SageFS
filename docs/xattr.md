# Extended Attributes (xattr)
**Module:** [`src/xattr.sage`](../src/xattr.sage) · **Phase:** 4 (Advanced) · **Status:** ✅ Implemented

## Purpose
Supports attaching arbitrary metadata (key/value pairs) to files and directories. Useful for ACLs, SELinux contexts, capabilities, and user metadata.

## Details
- Small xattrs are stored inline in the inode to save a block allocation.
- Large xattrs spill over into dedicated xattr blocks or a B+ tree index.

## API
- `get_xattr(ino, name) -> Bytes`
- `set_xattr(ino, name, value) -> Bool`
- `remove_xattr(ino, name) -> Bool`
- `list_xattrs(ino) -> Array`

## Related
[inode.md](inode.md)
