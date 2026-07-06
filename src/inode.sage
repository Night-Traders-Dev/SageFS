## =============================================================================
## SageFS Inode Manager
## =============================================================================
##
## Core metadata structure for files and directories in SageFS.
##
## Design philosophy:
##   - F2FS-style inline data: small files (up to ~3.4 KiB) are stored directly
##     inside the inode block, eliminating an extra block read for tiny files.
##   - BTRFS-style generation numbers: each inode carries a monotonically
##     increasing generation counter used for snapshot consistency and stale
##     reference detection.
##   - Each inode occupies exactly one 4 KiB block and is addressed by a
##     Node ID (nid) managed through the Node Address Table (NAT).
##
## On-disk layout (4096 bytes):
##   [ fixed metadata | direct block pointers | inline data / dentries ]
##
## =============================================================================

import io
import sys
import crypto.hash

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

## Size of a single inode block in bytes.
let INODE_SIZE: Int = 4096

## Maximum bytes available for inline data storage within the inode block.
## This accommodates ~3.4 KiB of small-file content without extra blocks.
let INLINE_DATA_MAX: Int = 3400

## Maximum number of directory entries that can be stored inline.
let INLINE_DENTRY_MAX: Int = 200

## Number of direct block pointers per inode.  Each pointer is a 32-bit
## block address, giving ~3.6 MiB of directly-addressed data per inode
## before falling back to indirect pointers.
let MAX_DIRECT_PTRS: Int = 923

## Reserved inode number for the filesystem root directory.
let ROOT_INO: Int = 1

# -----------------------------------------------------------------------------
# File type constants (upper bits of the mode field, POSIX-compatible)
# -----------------------------------------------------------------------------

## Regular file
let S_IFREG: Int = 0x8000

## Directory
let S_IFDIR: Int = 0x4000

## Symbolic link
let S_IFLNK: Int = 0xA000

## FIFO (named pipe)
let S_IFIFO: Int = 0x1000

## Unix domain socket
let S_IFSOCK: Int = 0xC000

## Block device
let S_IFBLK: Int = 0x6000

## Character device
let S_IFCHR: Int = 0x2000

## Bitmask to extract the file type from the mode field.
let S_IFMT: Int = 0xF000

# -----------------------------------------------------------------------------
# Inode flag constants (bitfield stored in the flags field)
# -----------------------------------------------------------------------------

## File content is stored inline within the inode block itself.
let INODE_FLAG_INLINE_DATA: Int = 0x0001

## Directory entries are stored inline within the inode block.
let INODE_FLAG_INLINE_DENTRY: Int = 0x0002

## File data is transparently compressed (e.g., LZ4 or ZSTD).
let INODE_FLAG_COMPRESSED: Int = 0x0004

## File data is encrypted at rest.
let INODE_FLAG_ENCRYPTED: Int = 0x0008

## Inode is immutable — no modifications permitted.
let INODE_FLAG_IMMUTABLE: Int = 0x0010

## Inode is append-only — existing data cannot be overwritten.
let INODE_FLAG_APPEND_ONLY: Int = 0x0020

## Exclude from filesystem dumps / backups.
let INODE_FLAG_NODUMP: Int = 0x0040

## Do not update access time on read operations.
let INODE_FLAG_NOATIME: Int = 0x0080


# =============================================================================
# SageFSInode
# =============================================================================

class SageFSInode:
    ## Represents a single SageFS inode — the fundamental on-disk metadata
    ## structure for every file, directory, symlink, and special node in the
    ## filesystem.
    ##
    ## Fields:
    ##   ino          — unique inode number (filesystem-wide identity)
    ##   nid          — Node Address Table ID (physical location mapping)
    ##   mode         — file type (upper bits) | permission bits (lower 12 bits)
    ##   uid          — owner user ID
    ##   gid          — owner group ID
    ##   size         — logical file size in bytes
    ##   blocks       — number of 4 KiB blocks allocated to this inode
    ##   atime        — last access timestamp (seconds since epoch)
    ##   mtime        — last modification timestamp
    ##   ctime        — last metadata change timestamp
    ##   crtime       — creation (birth) timestamp
    ##   nlink        — hard link count
    ##   flags        — inode feature flags (inline, compressed, encrypted, …)
    ##   generation   — monotonic generation number for snapshot consistency
    ##   xattr_nid    — NID of the extended-attribute block (0 = none)
    ##   inline_data  — small-file content stored directly in the inode
    ##   direct_ptrs  — array of MAX_DIRECT_PTRS block addresses (-1 = free)
    ##   indirect_ptr — block address of the single-indirect pointer block
    ##   dbl_indirect_ptr — block address of the double-indirect pointer block
    ##   checksum     — CRC32 integrity checksum over the inode contents

    proc init(self, ino: Int, nid: Int, mode: Int):
        ## Construct a new inode with the given number, NAT ID, and mode.
        ##
        ## Timestamps are initialised to the current wall-clock time.
        ## All block pointers default to -1 (unallocated).
        let now: Int = clock()

        self.ino = ino
        self.nid = nid
        self.mode = mode

        ## Ownership — caller is expected to set these after creation.
        self.uid = 0
        self.gid = 0

        ## Size accounting
        self.size = 0
        self.blocks = 0

        ## Timestamps
        self.atime = now
        self.mtime = now
        self.ctime = now
        self.crtime = now

        ## Link count — directories start with 2 (self + parent "..")
        self.nlink = 1

        ## Feature flags
        self.flags = 0

        ## BTRFS-style generation for snapshot consistency
        self.generation = 0

        ## Extended attributes stored in a separate NAT-addressed block
        self.xattr_nid = 0

        ## Inline data buffer — empty until explicitly populated
        self.inline_data = ""

        ## Direct block pointers — initialise all 923 slots to -1 (free)
        self.direct_ptrs = []
        var i: Int = 0
        while i < MAX_DIRECT_PTRS:
            push(self.direct_ptrs, -1)
            i = i + 1

        ## Single- and double-indirect pointers (unallocated)
        self.indirect_ptr = -1
        self.dbl_indirect_ptr = -1

        ## Integrity checksum — computed lazily via update_checksum()
        self.checksum = 0

    # -------------------------------------------------------------------------
    # Type queries
    # -------------------------------------------------------------------------

    proc is_file(self) -> Bool:
        ## Return true if this inode represents a regular file.
        return (self.mode & S_IFMT) == S_IFREG

    proc is_dir(self) -> Bool:
        ## Return true if this inode represents a directory.
        return (self.mode & S_IFMT) == S_IFDIR

    proc is_symlink(self) -> Bool:
        ## Return true if this inode represents a symbolic link.
        return (self.mode & S_IFMT) == S_IFLNK

    # -------------------------------------------------------------------------
    # Flag queries and manipulation
    # -------------------------------------------------------------------------

    proc is_inline(self) -> Bool:
        ## Return true if inline data storage is active for this inode.
        return self.has_flag(INODE_FLAG_INLINE_DATA)

    proc has_inline_dentry(self) -> Bool:
        ## Return true if directory entries are stored inline.
        return self.has_flag(INODE_FLAG_INLINE_DENTRY)

    proc is_compressed(self) -> Bool:
        ## Return true if this inode's data is transparently compressed.
        return self.has_flag(INODE_FLAG_COMPRESSED)

    proc is_encrypted(self) -> Bool:
        ## Return true if this inode's data is encrypted at rest.
        return self.has_flag(INODE_FLAG_ENCRYPTED)

    proc set_flag(self, flag: Int):
        ## Set a feature flag on this inode (bitwise OR).
        self.flags = self.flags | flag

    proc clear_flag(self, flag: Int):
        ## Clear a feature flag on this inode (bitwise AND NOT).
        self.flags = self.flags & (~flag)

    proc has_flag(self, flag: Int) -> Bool:
        ## Test whether a specific feature flag is set.
        return (self.flags & flag) != 0

    # -------------------------------------------------------------------------
    # Inline data management
    # -------------------------------------------------------------------------

    proc set_inline_data(self, data: String) -> Bool:
        ## Store data inline within the inode block.
        ##
        ## Returns true on success.  Returns false if the data exceeds
        ## INLINE_DATA_MAX bytes — the caller must fall back to regular
        ## block allocation in that case.
        if len(data) > INLINE_DATA_MAX:
            return false

        self.inline_data = data
        self.size = len(data)
        self.set_flag(INODE_FLAG_INLINE_DATA)
        return true

    proc get_inline_data(self) -> String:
        ## Retrieve the inline data buffer.
        ##
        ## Returns an empty string if no inline data is stored.
        return self.inline_data

    proc clear_inline_data(self):
        ## Remove all inline data and clear the inline-data flag.
        ##
        ## Typically called when a file outgrows the inline threshold and
        ## its content is migrated to regular data blocks.
        self.inline_data = ""
        self.clear_flag(INODE_FLAG_INLINE_DATA)

    # -------------------------------------------------------------------------
    # Block pointer management
    # -------------------------------------------------------------------------

    proc add_block_ptr(self, block_addr: Int) -> Int:
        ## Append a block address to the first free slot in the direct
        ## pointer array.
        ##
        ## Returns the slot index on success, or -1 if all MAX_DIRECT_PTRS
        ## slots are occupied (caller should allocate an indirect block).
        var idx: Int = 0
        while idx < MAX_DIRECT_PTRS:
            if self.direct_ptrs[idx] == -1:
                self.direct_ptrs[idx] = block_addr
                self.blocks = self.blocks + 1
                return idx
            idx = idx + 1
        return -1

    proc get_block_ptr(self, index: Int) -> Int:
        ## Return the block address stored at the given direct-pointer
        ## index, or -1 if the index is out of range.
        if index < 0:
            return -1
        if index >= MAX_DIRECT_PTRS:
            return -1
        return self.direct_ptrs[index]

    proc remove_block_ptr(self, index: Int):
        ## Free the direct block pointer at the given index by resetting
        ## it to -1 (unallocated sentinel).
        if index >= 0:
            if index < MAX_DIRECT_PTRS:
                if self.direct_ptrs[index] != -1:
                    self.direct_ptrs[index] = -1
                    self.blocks = self.blocks - 1

    proc count_block_ptrs(self) -> Int:
        ## Count the number of allocated (non-free) direct block pointers.
        var count: Int = 0
        var idx: Int = 0
        while idx < MAX_DIRECT_PTRS:
            if self.direct_ptrs[idx] != -1:
                count = count + 1
            idx = idx + 1
        return count

    # -------------------------------------------------------------------------
    # Timestamp management
    # -------------------------------------------------------------------------

    proc update_times(self, access: Bool, modify: Bool, change: Bool):
        ## Selectively update inode timestamps to the current wall-clock
        ## time.
        ##
        ## Parameters:
        ##   access — update atime (last read)
        ##   modify — update mtime (last data write)
        ##   change — update ctime (last metadata change)
        ##
        ## The NOATIME flag is respected: if set, atime updates are
        ## silently skipped even when `access` is true.
        let now: Int = clock()

        if access:
            if not self.has_flag(INODE_FLAG_NOATIME):
                self.atime = now

        if modify:
            self.mtime = now

        if change:
            self.ctime = now

    # -------------------------------------------------------------------------
    # Checksum (integrity)
    # -------------------------------------------------------------------------

    proc compute_checksum(self) -> Int:
        ## Compute a CRC32 checksum over the inode's critical metadata
        ## fields.  The checksum itself is excluded from the computation
        ## to avoid circularity.
        ##
        ## The input string is a deterministic concatenation of every
        ## metadata field that must be protected against silent corruption.
        var data_str: String = ""
        data_str = data_str + str(self.ino) + ":"
        data_str = data_str + str(self.nid) + ":"
        data_str = data_str + str(self.mode) + ":"
        data_str = data_str + str(self.uid) + ":"
        data_str = data_str + str(self.gid) + ":"
        data_str = data_str + str(self.size) + ":"
        data_str = data_str + str(self.blocks) + ":"
        data_str = data_str + str(self.atime) + ":"
        data_str = data_str + str(self.mtime) + ":"
        data_str = data_str + str(self.ctime) + ":"
        data_str = data_str + str(self.crtime) + ":"
        data_str = data_str + str(self.nlink) + ":"
        data_str = data_str + str(self.flags) + ":"
        data_str = data_str + str(self.generation) + ":"
        data_str = data_str + str(self.xattr_nid) + ":"
        data_str = data_str + str(self.indirect_ptr) + ":"
        data_str = data_str + str(self.dbl_indirect_ptr) + ":"
        data_str = data_str + self.inline_data

        return crc32(data_str)

    proc update_checksum(self):
        ## Recompute and store the CRC32 checksum.
        ## Must be called before writing the inode to disk.
        self.checksum = self.compute_checksum()

    proc verify_checksum(self) -> Bool:
        ## Verify the stored checksum against a freshly computed one.
        ## Returns true if the inode data is consistent.
        return self.checksum == self.compute_checksum()

    # -------------------------------------------------------------------------
    # Serialisation
    # -------------------------------------------------------------------------

    proc serialize(self) -> Bytes:
        ## Serialize the inode into a fixed-size INODE_SIZE (4096) byte
        ## buffer suitable for writing to disk.
        ##
        ## Layout (simplified — actual field widths would be defined by
        ## the on-disk format specification):
        ##   Bytes 0–695:   fixed metadata fields as colon-delimited text
        ##   Bytes 696+:    inline data (if present), zero-padded to 4096
        ##
        ## A production implementation would use packed binary encoding;
        ## this text-based approach prioritises debuggability during early
        ## development.
        var header: String = ""
        header = header + str(self.ino) + ":"
        header = header + str(self.nid) + ":"
        header = header + str(self.mode) + ":"
        header = header + str(self.uid) + ":"
        header = header + str(self.gid) + ":"
        header = header + str(self.size) + ":"
        header = header + str(self.blocks) + ":"
        header = header + str(self.atime) + ":"
        header = header + str(self.mtime) + ":"
        header = header + str(self.ctime) + ":"
        header = header + str(self.crtime) + ":"
        header = header + str(self.nlink) + ":"
        header = header + str(self.flags) + ":"
        header = header + str(self.generation) + ":"
        header = header + str(self.xattr_nid) + ":"
        header = header + str(self.indirect_ptr) + ":"
        header = header + str(self.dbl_indirect_ptr) + ":"
        header = header + str(self.checksum) + ":"
        header = header + self.inline_data

        ## Build the output buffer and zero-pad to exactly INODE_SIZE bytes
        var buf: Bytes = bytes(header)
        while bytes_len(buf) < INODE_SIZE:
            bytes_push(buf, 0)

        return buf

    # -------------------------------------------------------------------------
    # Dictionary / string representations
    # -------------------------------------------------------------------------

    proc to_dict(self) -> Dict:
        ## Return a dictionary representation of the inode's metadata.
        ## Useful for debugging, FUSE stat replies, and JSON serialisation.
        let d: Dict = {}
        d["ino"] = self.ino
        d["nid"] = self.nid
        d["mode"] = self.mode
        d["uid"] = self.uid
        d["gid"] = self.gid
        d["size"] = self.size
        d["blocks"] = self.blocks
        d["atime"] = self.atime
        d["mtime"] = self.mtime
        d["ctime"] = self.ctime
        d["crtime"] = self.crtime
        d["nlink"] = self.nlink
        d["flags"] = self.flags
        d["generation"] = self.generation
        d["xattr_nid"] = self.xattr_nid
        d["inline"] = self.is_inline()
        d["indirect_ptr"] = self.indirect_ptr
        d["dbl_indirect_ptr"] = self.dbl_indirect_ptr
        d["block_ptrs_used"] = self.count_block_ptrs()
        d["checksum"] = self.checksum
        return d

    proc to_string(self) -> String:
        ## Return a human-readable summary string for diagnostic output.
        var s: String = "SageFSInode("
        s = s + "ino=" + str(self.ino)
        s = s + ", nid=" + str(self.nid)

        ## Decode file type for readability
        let ftype: Int = self.mode & S_IFMT
        if ftype == S_IFREG:
            s = s + ", type=REG"
        elif ftype == S_IFDIR:
            s = s + ", type=DIR"
        elif ftype == S_IFLNK:
            s = s + ", type=LNK"
        elif ftype == S_IFIFO:
            s = s + ", type=FIFO"
        elif ftype == S_IFSOCK:
            s = s + ", type=SOCK"
        elif ftype == S_IFBLK:
            s = s + ", type=BLK"
        elif ftype == S_IFCHR:
            s = s + ", type=CHR"
        else:
            s = s + ", type=UNK"

        s = s + ", size=" + str(self.size)
        s = s + ", nlink=" + str(self.nlink)
        s = s + ", blocks=" + str(self.blocks)
        s = s + ", gen=" + str(self.generation)

        ## Summarise active flags
        var flag_list: String = ""
        if self.is_inline():
            flag_list = flag_list + "INLINE "
        if self.has_inline_dentry():
            flag_list = flag_list + "INLINE_DENTRY "
        if self.is_compressed():
            flag_list = flag_list + "COMPRESSED "
        if self.is_encrypted():
            flag_list = flag_list + "ENCRYPTED "
        if self.has_flag(INODE_FLAG_IMMUTABLE):
            flag_list = flag_list + "IMMUTABLE "
        if self.has_flag(INODE_FLAG_APPEND_ONLY):
            flag_list = flag_list + "APPEND_ONLY "
        if self.has_flag(INODE_FLAG_NOATIME):
            flag_list = flag_list + "NOATIME "

        if len(flag_list) > 0:
            s = s + ", flags=[" + flag_list + "]"

        s = s + ")"
        return s


# =============================================================================
# InodeManager
# =============================================================================

class InodeManager:
    ## Central manager for inode lifecycle within a SageFS instance.
    ##
    ## Responsibilities:
    ##   - Inode allocation and deallocation with inode-number recycling
    ##   - Integration with the Node Address Table (NAT) for NID management
    ##   - Dirty-inode tracking for efficient checkpoint writes
    ##   - Root directory bootstrapping
    ##
    ## The manager maintains an in-memory inode table (Dict keyed by
    ## stringified ino) which acts as the inode cache.  Dirty tracking
    ## allows the checkpoint subsystem to flush only modified inodes.

    proc init(self, nat_table):
        ## Initialise the inode manager.
        ##
        ## Parameters:
        ##   nat_table — reference to the filesystem's NAT instance, which
        ##               must expose allocate_nid() and free_nid(nid) methods.

        ## In-memory inode table: str(ino) -> SageFSInode
        self.inodes = {}

        ## NAT integration for NID allocation / deallocation
        self.nat_table = nat_table

        ## Next inode number to assign (starts at 2; ROOT_INO = 1 is reserved)
        self.next_ino = 2

        ## Pool of recycled inode numbers available for reuse
        self.free_inos = []

        ## Dirty set: str(ino) -> true for inodes modified since last checkpoint
        self.dirty_inodes = {}

    # -------------------------------------------------------------------------
    # Inode allocation
    # -------------------------------------------------------------------------

    proc create_inode(self, mode: Int, uid: Int, gid: Int) -> SageFSInode:
        ## Allocate a new inode with the given mode, owner, and group.
        ##
        ## Steps:
        ##   1. Obtain an inode number (reuse from free pool, or increment)
        ##   2. Allocate a NID from the NAT for physical addressing
        ##   3. Construct the SageFSInode, populate ownership fields
        ##   4. Insert into the inode table and mark dirty
        ##
        ## Returns the newly created inode.
        var ino: Int = 0

        ## Prefer recycled inode numbers to keep the number space compact
        if len(self.free_inos) > 0:
            ino = pop(self.free_inos)
        else:
            ino = self.next_ino
            self.next_ino = self.next_ino + 1

        ## Obtain a NAT node ID for this inode's physical location
        let nid: Int = self.nat_table.allocate_nid()

        ## Construct the inode
        let inode: SageFSInode = SageFSInode(ino, nid, mode)
        inode.uid = uid
        inode.gid = gid

        ## If this is a directory, start with nlink=2 (self "." + parent "..")
        if inode.is_dir():
            inode.nlink = 2
            inode.set_flag(INODE_FLAG_INLINE_DENTRY)

        ## Register in the inode table and mark dirty for next checkpoint
        let key: String = str(ino)
        self.inodes[key] = inode
        self.dirty_inodes[key] = true

        return inode

    proc create_root(self) -> SageFSInode:
        ## Bootstrap the root directory inode (ino=1).
        ##
        ## The root inode is special:
        ##   - Always uses ROOT_INO (1)
        ##   - Mode = S_IFDIR | 0o755 (rwxr-xr-x)
        ##   - nlink = 2 (for "." and "..")
        ##   - Inline dentry flag is set by default
        ##
        ## This method must be called exactly once during mkfs.
        let nid: Int = self.nat_table.allocate_nid()

        ## 0o755 = 0x1ED in hexadecimal = 493 decimal
        let root_mode: Int = S_IFDIR | 493

        let root: SageFSInode = SageFSInode(ROOT_INO, nid, root_mode)
        root.nlink = 2
        root.set_flag(INODE_FLAG_INLINE_DENTRY)

        let key: String = str(ROOT_INO)
        self.inodes[key] = root
        self.dirty_inodes[key] = true

        ## Ensure next_ino never collides with the root
        if self.next_ino <= ROOT_INO:
            self.next_ino = ROOT_INO + 1

        return root

    # -------------------------------------------------------------------------
    # Lookup
    # -------------------------------------------------------------------------

    proc get_inode(self, ino: Int) -> SageFSInode:
        ## Look up an inode by its inode number.
        ##
        ## Returns the SageFSInode if found, or nil if the inode does not
        ## exist in the in-memory table.
        let key: String = str(ino)
        if dict_has(self.inodes, key):
            return self.inodes[key]
        return nil

    # -------------------------------------------------------------------------
    # Deletion
    # -------------------------------------------------------------------------

    proc delete_inode(self, ino: Int) -> Bool:
        ## Remove an inode from the filesystem entirely.
        ##
        ## Steps:
        ##   1. Look up the inode; return false if not found
        ##   2. Free the NID back to the NAT
        ##   3. Remove from the inode table and dirty set
        ##   4. Add the inode number to the free pool for recycling
        ##
        ## Returns true on success, false if the inode was not found.
        let key: String = str(ino)

        if not dict_has(self.inodes, key):
            return false

        let inode: SageFSInode = self.inodes[key]

        ## Return the NID to the NAT free pool
        self.nat_table.free_nid(inode.nid)

        ## Remove from tables
        dict_delete(self.inodes, key)
        if dict_has(self.dirty_inodes, key):
            dict_delete(self.dirty_inodes, key)

        ## Recycle the inode number
        push(self.free_inos, ino)

        return true

    # -------------------------------------------------------------------------
    # Dirty tracking
    # -------------------------------------------------------------------------

    proc update_inode(self, ino: Int):
        ## Mark an inode as dirty (modified since last checkpoint).
        ##
        ## Must be called after any mutation to inode metadata or data
        ## pointers.  The checkpoint subsystem uses the dirty set to
        ## determine which inodes need to be flushed to stable storage.
        let key: String = str(ino)
        if dict_has(self.inodes, key):
            self.dirty_inodes[key] = true

    proc get_dirty_inodes(self) -> Array:
        ## Return an array of all inodes that have been modified since the
        ## last checkpoint.
        ##
        ## The checkpoint writer iterates this list, serialises each inode,
        ## and writes the blocks to their NAT-mapped physical locations.
        var result: Array = []
        let keys: Array = dict_keys(self.dirty_inodes)
        var i: Int = 0
        while i < len(keys):
            let key: String = keys[i]
            if dict_has(self.inodes, key):
                push(result, self.inodes[key])
            i = i + 1
        return result

    proc checkpoint(self):
        ## Clear the dirty set after a successful checkpoint write.
        ##
        ## Called by the checkpoint manager once all dirty inodes have been
        ## safely persisted to disk.  After this call, get_dirty_inodes()
        ## returns an empty list until new mutations occur.
        self.dirty_inodes = {}

    # -------------------------------------------------------------------------
    # Link management
    # -------------------------------------------------------------------------

    proc link(self, ino: Int):
        ## Increment the hard link count for an inode.
        ##
        ## Called when a new directory entry (hard link) is created that
        ## points to this inode.
        let key: String = str(ino)
        if dict_has(self.inodes, key):
            let inode: SageFSInode = self.inodes[key]
            inode.nlink = inode.nlink + 1
            inode.update_times(false, false, true)
            self.dirty_inodes[key] = true

    proc unlink(self, ino: Int) -> Bool:
        ## Decrement the hard link count for an inode.
        ##
        ## If nlink reaches zero AND the file size is also zero (no data
        ## blocks to reclaim asynchronously), the inode is immediately
        ## deleted.  Otherwise, the inode persists until the last reference
        ## is released (e.g., by a still-open file descriptor or truncate).
        ##
        ## Returns true if the inode was fully deleted, false if it still
        ## exists (either not found, or nlink/size > 0).
        let key: String = str(ino)

        if not dict_has(self.inodes, key):
            return false

        let inode: SageFSInode = self.inodes[key]
        inode.nlink = inode.nlink - 1
        inode.update_times(false, false, true)
        self.dirty_inodes[key] = true

        ## Auto-delete when fully unreferenced and empty
        if inode.nlink <= 0:
            if inode.size == 0:
                self.delete_inode(ino)
                return true

        return false

    # -------------------------------------------------------------------------
    # Statistics
    # -------------------------------------------------------------------------

    proc count(self) -> Int:
        ## Return the total number of inodes currently in the table.
        return len(dict_keys(self.inodes))

    proc stats(self) -> Dict:
        ## Return a summary dictionary of inode manager state.
        ##
        ## Keys:
        ##   total          — number of inodes in the table
        ##   dirty          — number of inodes pending checkpoint flush
        ##   free_pool_size — number of recycled inode numbers available
        let s: Dict = {}
        s["total"] = self.count()
        s["dirty"] = len(dict_keys(self.dirty_inodes))
        s["free_pool_size"] = len(self.free_inos)
        return s
