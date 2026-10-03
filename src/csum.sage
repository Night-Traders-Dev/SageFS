## csum.sage — the on-disk per-block checksum region.
##
## One LE32 checksum per data block, packed at the end of the image:
##
##   entry for block b lives at byte  csum_start_blk * block_size + b * 4
##
## A zero entry means "untracked", which matches ChecksumTree.lookup()'s
## CHECKSUM_NONE sentinel -- so an unwritten block and a block whose checksum
## legitimately hashes to zero are indistinguishable. That is a real (if tiny)
## hole: CRC32C of some 4096-byte block will be zero about once in 2^32 blocks.
## It errs toward reporting a healthy block as untracked rather than the reverse,
## which is the safe direction: no false alarms, one missed detection in four
## billion.
##
## Why this exists at all: scrub used to compare every block against a checksum
## it had just derived from that same block, so it could not fail. Verifying a
## volume with no external reference requires the expected checksums to be on
## disk, and nothing was writing them.
##
## The region sits after the data rather than before it so that adding it did not
## shift nat_start/sit_start/ssa_start/main_start, every one of which is an
## absolute block number that existing volumes already have on disk.

from checksum import checksum_block, ChecksumTree, CHECKSUM_NONE

## Bytes per entry. LE32.
let CSUM_REGION_ENTRY: Int = 4

## How many region blocks are needed to hold one entry per data block.
proc region_blocks_for(data_blocks: Int, block_size: Int) -> Int:
    if data_blocks <= 0 or block_size <= 0:
        return 0
    ## Ceiling division, without float rounding at the boundary.
    let need: Int = data_blocks * CSUM_REGION_ENTRY
    return int((need + block_size - 1) / block_size)

class CsumRegion:
    ## Reads and writes the checksum region of one image.
    ##
    ## `buf` is the whole image held in memory. SageFS already keeps the volume
    ## in memory (that is the 100 MiB ceiling mount is blocked on), so writing an
    ## entry is a store into the same buffer the block itself went into, and both
    ## reach disk on the same flush. Keeping them in one buffer is what makes the
    ## entry and the block it describes impossible to desynchronise.

    proc init(self, buf: Bytes, block_size: Int, start_blk: Int, region_blocks: Int):
        self.buf = buf
        self.block_size = block_size
        self.start_blk = start_blk
        self.region_blocks = region_blocks

    proc present(self) -> Bool:
        return self.start_blk > 0 and self.region_blocks > 0

    proc start_byte(self) -> Int:
        return self.start_blk * self.block_size

    ## entries_fit — Whether the region can actually hold `data_blocks` entries.
    ##
    ## Checked rather than assumed: a region sized for fewer entries than there
    ## are blocks would silently checksum only a prefix of the volume, and scrub
    ## would report full coverage over a fraction of the disk.
    proc entries_fit(self, data_blocks: Int) -> Bool:
        if not self.present():
            return false
        return region_blocks_for(data_blocks, self.block_size) <= self.region_blocks

    proc byte_offset(self, block: Int) -> Int:
        return self.start_byte() + block * CSUM_REGION_ENTRY

    ## get — Expected checksum for a block, or CHECKSUM_NONE if untracked.
    proc get(self, block: Int) -> Int:
        ## Guard on present() first, not just on bounds. An absent region has
        ## start_blk == 0, so byte_offset() returns a perfectly in-range offset
        ## into the start of the image -- and set() would write an entry over the
        ## superblock. Bounds alone do not catch a region that does not exist.
        if not self.present():
            return CHECKSUM_NONE
        let off: Int = self.byte_offset(block)
        if off < 0 or off + CSUM_REGION_ENTRY > bytes_len(self.buf):
            return CHECKSUM_NONE
        return read_le32_at(self.buf, off)

    ## set — Record a block's checksum.
    proc set(self, block: Int, checksum: Int):
        if not self.present():
            return
        let off: Int = self.byte_offset(block)
        if off < 0 or off + CSUM_REGION_ENTRY > bytes_len(self.buf):
            return
        write_le32_at(self.buf, off, checksum & 0xFFFFFFFF)

    ## record — Compute and store the checksum of a block already written to buf.
    proc record(self, block: Int, algo: Int):
        if not self.present():
            return
        let bs: Int = self.block_size
        let off: Int = block * bs
        if off < 0 or off + bs > bytes_len(self.buf):
            return
        self.set(block, checksum_block(csum_slice(self.buf, off, off + bs), algo))

    ## verify — Compare a block's contents against its recorded checksum.
    ## Returns "ok", "mismatch", or "untracked".
    proc verify(self, block: Int, algo: Int) -> String:
        if not self.present():
            return "untracked"
        let expected: Int = self.get(block)
        if expected == CHECKSUM_NONE:
            return "untracked"
        let bs: Int = self.block_size
        let off: Int = block * bs
        if off < 0 or off + bs > bytes_len(self.buf):
            return "unreadable"
        if checksum_block(csum_slice(self.buf, off, off + bs), algo) == expected:
            return "ok"
        return "mismatch"

    ## load_tree — Materialise the region into a ChecksumTree.
    ## Used by fsck, which already speaks in trees.
    proc load_tree(self, data_blocks: Int, algo: Int) -> ChecksumTree:
        let t = ChecksumTree(algo)
        if not self.present():
            return t
        var b: Int = 0
        while b < data_blocks:
            let v: Int = self.get(b)
            if v != CHECKSUM_NONE:
                t.record_value(b, v)
            b = b + 1
        return t

    ## stats — Summary for tools and tests.
    proc stats(self, data_blocks: Int) -> Dict:
        var tracked: Int = 0
        var b: Int = 0
        while b < data_blocks:
            if self.get(b) != CHECKSUM_NONE:
                tracked = tracked + 1
            b = b + 1
        return {
            "present": self.present(),
            "start_blk": self.start_blk,
            "region_blocks": self.region_blocks,
            "data_blocks": data_blocks,
            "tracked": tracked,
            "fits": self.entries_fit(data_blocks)
        }

## slice — A Bytes covering buf[start, end).
##
## Hand-rolled rather than using csum_slice(), which returns an array of numbers here:
## the result indexes correctly but bytes_len() on it is 0, so checksum_block()
## would hash an empty block and every entry would agree with nothing.
proc csum_slice(buf: Bytes, start: Int, end: Int) -> Bytes:
    let n: Int = bytes_len(buf)
    var a: Int = start
    var b: Int = end
    if a < 0:
        a = 0
    if b > n:
        b = n
    if b <= a:
        return bytes()
    var out: Bytes = bytes(b - a)
    var i: Int = 0
    while i < b - a:
        out[i] = buf[a + i]
        i = i + 1
    return out

proc read_le32_at(buf: Bytes, off: Int) -> Int:
    return bytes_get(buf, off) | (bytes_get(buf, off + 1) << 8) | (bytes_get(buf, off + 2) << 16) | (bytes_get(buf, off + 3) << 24)

proc write_le32_at(buf: Bytes, off: Int, v: Int):
    bytes_set(buf, off, v & 0xFF)
    bytes_set(buf, off + 1, (v >> 8) & 0xFF)
    bytes_set(buf, off + 2, (v >> 16) & 0xFF)
    bytes_set(buf, off + 3, (v >> 24) & 0xFF)
