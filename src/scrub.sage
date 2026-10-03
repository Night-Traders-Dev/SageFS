## scrub.sage — online integrity verification.
##
## Verifies a volume's blocks against a reference. The previous tool built a
## fresh ChecksumTree, looked every block up in it, found nothing recorded
## anywhere, and compared nothing before reporting "filesystem is clean". A
## checker that cannot fail is worse than no checker at all: it gets trusted,
## and it is wrong in the direction that hides damage.
##
## ScrubResult carries an explicit verdict rather than a count, because the
## difference between "verified and matched", "found damage" and "had nothing to
## verify against" is the difference between a working filesystem and a false
## all-clear, and a caller must not be able to confuse them.

import fileio
from checksum import checksum_block, CHECKSUM_CRC32C
from superblock import read_le32, read_le64, SUPERBLOCK_OFFSET, SAGEFS_MAGIC

## A scrub that examined less of the volume than this is not a scrub. Reported
## as a failure rather than scaled down, so a partial run cannot pass quietly.
let MIN_COVERAGE_PCT: Int = 90

## Verdicts. Distinct exit codes so scripts can tell them apart.
let SCRUB_OK: Int = 0            ## every examined block matched
let SCRUB_ERROR: Int = 1         ## usage or unreadable volume
let SCRUB_DAMAGE: Int = 2        ## real mismatches, truncation, or bad coverage
let SCRUB_INCONCLUSIVE: Int = 3  ## nothing to verify against

class ScrubResult:
    proc init(self, verdict: Int):
        self.verdict = verdict
        self.blocks_examined = 0
        self.total_blocks = 0
        self.mismatches = 0
        self.unreadable = 0
        self.messages = []

    proc coverage_pct(self) -> Int:
        if self.total_blocks <= 0:
            return 0
        return int(self.blocks_examined * 100 / self.total_blocks)

    proc note(self, msg: String):
        push(self.messages, msg)

    proc is_clean(self) -> Bool:
        return self.verdict == SCRUB_OK

    ## add_damage — Record a finding and downgrade the verdict.
    proc add_damage(self, msg: String):
        self.note(msg)
        if self.verdict == SCRUB_OK or self.verdict == SCRUB_INCONCLUSIVE:
            self.verdict = SCRUB_DAMAGE

    proc to_dict(self) -> Dict:
        return {
            "verdict": self.verdict,
            "blocks_examined": self.blocks_examined,
            "total_blocks": self.total_blocks,
            "mismatches": self.mismatches,
            "unreadable": self.unreadable,
            "coverage_pct": self.coverage_pct(),
            "messages": self.messages
        }

## read_superblock — Pull the fields a scrub needs, and validate them.
##
## Deliberately does not go through VFS().mount(): that runs recovery, replays
## the journal and rewrites the image. A read-only verifier must not modify the
## thing it is verifying, least of all before deciding whether it is healthy.
##
## Offsets from SageFSSuperblock.serialize(): magic LE32@0, version_major
## LE32@4, version_minor LE32@8, block_size LE32@12, total_blocks LE64@28,
## checksum_algo LE32@388.
proc read_superblock(path: String) -> Dict:
    if fileio.size_of(path) < 0:
        return {"error": "cannot open '" + path + "'"}
    let head: Bytes = fileio.read_at(path, SUPERBLOCK_OFFSET, 4096)
    if bytes_len(head) < 512:
        return {"error": "'" + path + "' is too small to hold a superblock"}
    if read_le32(head, 0) != SAGEFS_MAGIC:
        return {"error": "'" + path + "' is not a SageFS volume (bad magic)"}
    let out: Dict = {}
    out["version_major"] = read_le32(head, 4)
    out["version_minor"] = read_le32(head, 8)
    out["block_size"] = read_le32(head, 12)
    out["total_blocks"] = read_le64(head, 28)
    out["checksum_algo"] = read_le32(head, 388)
    return out

proc algo_name(a: Int) -> String:
    if a == 0:
        return "crc32c"
    if a == 1:
        return "xxhash32"
    if a == 2:
        return "sha256/32"
    return "unknown(" + str(a) + ")"

proc same_geometry(a: Dict, b: Dict) -> Bool:
    return a["block_size"] == b["block_size"] and a["total_blocks"] == b["total_blocks"]

## blocks_equal — Compare one block of two files. Returns 1 if identical.
proc blocks_equal(path_a: String, path_b: String, offset: Int, bs: Int) -> Int:
    let a: Bytes = fileio.read_at(path_a, offset, bs)
    let b: Bytes = fileio.read_at(path_b, offset, bs)
    if bytes_len(a) != bytes_len(b):
        return 0
    var i: Int = 0
    while i < bytes_len(a):
        if bytes_get(a, i) != bytes_get(b, i):
            return 0
        i = i + 1
    return 1

class Scrubber:
    proc init(self, image_path: String):
        self.image_path = image_path
        self.sb = read_superblock(image_path)

    proc ok(self) -> Bool:
        return dict_has(self.sb, "error") == false

    proc error(self) -> String:
        if dict_has(self.sb, "error"):
            return self.sb["error"]
        return ""

    proc block_size(self) -> Int:
        if not self.ok():
            return 0
        return self.sb["block_size"]

    proc total_blocks(self) -> Int:
        if not self.ok():
            return 0
        return self.sb["total_blocks"]

    ## scrub — Verify the volume against a reference image.
    proc scrub(self, reference_path: String) -> ScrubResult:
        if not self.ok():
            let r = ScrubResult(SCRUB_ERROR)
            r.note(self.error())
            return r
        let bs: Int = self.block_size()
        let total: Int = self.total_blocks()
        let r = ScrubResult(SCRUB_OK)
        r.total_blocks = total
        if bs <= 0 or total <= 0:
            r.verdict = SCRUB_ERROR
            r.note("superblock reports implausible geometry (block_size=" + str(bs)
                   + " total_blocks=" + str(total) + ")")
            return r

        ## Check the file is as long as the superblock claims *before*
        ## comparing anything. Otherwise the tail reads back as zeros, and a
        ## zero-filled tail matches a zero-filled reference: a clean report for
        ## blocks that were never written.
        let size: Int = fileio.size_of(self.image_path)
        let want: Int = total * bs
        if size < want:
            r.verdict = SCRUB_DAMAGE
            r.note("image is " + str(size) + " bytes but the superblock describes "
                   + str(want) + "; " + str(want - size) + " bytes are missing")
            r.blocks_examined = int(size / bs)
            return r

        if reference_path == "":
            ## The write path never persists a per-block checksum region, so
            ## there is nothing on disk to verify the data against. Say so.
            r.verdict = SCRUB_INCONCLUSIVE
            r.note("no reference supplied and this volume stores no per-block "
                   + "checksum region, so no data block can be verified")
            return r

        let ref_sb = read_superblock(reference_path)
        if dict_has(ref_sb, "error"):
            r.verdict = SCRUB_ERROR
            r.note(ref_sb["error"])
            return r
        if not same_geometry(self.sb, ref_sb):
            r.verdict = SCRUB_ERROR
            r.note("reference geometry differs (image: " + str(bs) + "x" + str(total)
                   + ", reference: " + str(ref_sb["block_size"]) + "x"
                   + str(ref_sb["total_blocks"]) + ")")
            return r

        var blk: Int = 0
        while blk < total:
            let off: Int = blk * bs
            if blocks_equal(self.image_path, reference_path, off, bs) == 1:
                r.blocks_examined = r.blocks_examined + 1
            else:
                ## Separate "differs" from "cannot be read". Calling a short read
                ## a content mismatch sends an operator hunting for bit rot when
                ## the actual problem is the device.
                let got: Int = bytes_len(fileio.read_at(self.image_path, off, bs))
                if got < bs:
                    r.unreadable = r.unreadable + 1
                    if r.unreadable <= 10:
                        r.note("unreadable block " + str(blk) + " (got " + str(got)
                               + " of " + str(bs) + " bytes)")
                else:
                    r.mismatches = r.mismatches + 1
                    if r.mismatches <= 10:
                        r.note("mismatch at block " + str(blk))
                r.blocks_examined = r.blocks_examined + 1
            blk = blk + 1

        if r.coverage_pct() < MIN_COVERAGE_PCT:
            r.verdict = SCRUB_DAMAGE
            r.note("examined only " + str(r.coverage_pct()) + "% of blocks")
        if r.unreadable > 0 and r.verdict == SCRUB_OK:
            r.verdict = SCRUB_DAMAGE
        if r.mismatches > 0 and r.verdict == SCRUB_OK:
            r.verdict = SCRUB_DAMAGE
        return r

    proc info(self) -> Dict:
        if not self.ok():
            return {"error": self.error()}
        return {
            "path": self.image_path,
            "version_major": self.sb["version_major"],
            "version_minor": self.sb["version_minor"],
            "block_size": self.sb["block_size"],
            "total_blocks": self.sb["total_blocks"],
            "checksum_algo": algo_name(self.sb["checksum_algo"]),
            "image_bytes": fileio.size_of(self.image_path)
        }
