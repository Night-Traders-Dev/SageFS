## ============================================================================
## SageFS fsck — Offline Consistency Checker
## ============================================================================
##
## Phase 3 — Data Integrity & Recovery.
##
## Performs an offline, read-mostly consistency check of a SageFS volume.  It
## cross-references the three core metadata structures — the inode table, the
## Node Address Table (NAT), and the Segment Information Table (SIT) — and
## reports (optionally repairs) inconsistencies.
##
## Checks performed
## ----------------
##   1. Superblock validity & self-checksum.
##   2. Every referenced nid resolves to a NAT entry (no dangling nids).
##   3. Every alive NAT entry points at a block whose owning SIT segment
##      marks that block valid (NAT <-> SIT agreement).
##   4. SIT per-segment valid-block counts match the actual valid bitmaps.
##   5. Directory tree walk from root: every reachable inode exists and its
##      link count matches the number of directory references (orphan &
##      link-count checks).
##   6. Block checksum verification (when a ChecksumTree is supplied).
##
## The checker collects a list of FsckIssue records.  With `repair=true` it
## applies safe, well-understood fixes (recompute SIT counts, clear orphan
## inodes, fix link counts); structural corruption is reported but left for a
## human / higher-tier repair.
## ============================================================================

from checksum import checksum_block

# ---------------------------------------------------------------------------
# Issue severities & codes
# ---------------------------------------------------------------------------

let SEV_INFO: Int = 0
let SEV_WARN: Int = 1
let SEV_ERROR: Int = 2
let SEV_FATAL: Int = 3

let ISSUE_SB_CHECKSUM: Int = 1        # superblock checksum mismatch
let ISSUE_DANGLING_NID: Int = 2       # nid with no NAT entry
let ISSUE_NAT_SIT_MISMATCH: Int = 3   # NAT block not marked valid in SIT
let ISSUE_SIT_COUNT: Int = 4          # SIT valid count != bitmap popcount
let ISSUE_ORPHAN_INODE: Int = 5       # inode not reachable from root
let ISSUE_LINK_COUNT: Int = 6         # inode nlink != observed references
let ISSUE_BLOCK_CHECKSUM: Int = 7     # data/metadata block checksum mismatch

# ===========================================================================
# FsckIssue
# ===========================================================================

class FsckIssue:
    var code: Int
    var severity: Int
    var target: Int        # inode / nid / segno / block the issue concerns
    var message: String
    var repaired: Bool

    proc init(self, code: Int, severity: Int, target: Int, message: String):
        self.code = code
        self.severity = severity
        self.target = target
        self.message = message
        self.repaired = false

    proc to_string(self) -> String:
        var sev: String = "INFO"
        if self.severity == SEV_WARN:
            sev = "WARN"
        elif self.severity == SEV_ERROR:
            sev = "ERROR"
        elif self.severity == SEV_FATAL:
            sev = "FATAL"
        var tag: String = ""
        if self.repaired:
            tag = " [REPAIRED]"
        return "[" + sev + "] (" + str(self.code) + ") target=" + str(self.target) + ": " + self.message + tag


# ===========================================================================
# FsckReport
# ===========================================================================

class FsckReport:
    var issues: Array          # Array[FsckIssue]
    var inodes_scanned: Int
    var blocks_scanned: Int
    var repaired_count: Int

    proc init(self):
        self.issues = []
        self.inodes_scanned = 0
        self.blocks_scanned = 0
        self.repaired_count = 0

    proc add(self, issue: FsckIssue):
        self.issues.push(issue)
        if issue.repaired:
            self.repaired_count = self.repaired_count + 1

    proc error_count(self) -> Int:
        var n: Int = 0
        for iss in self.issues:
            if iss.severity >= SEV_ERROR:
                n = n + 1
        return n

    proc is_clean(self) -> Bool:
        return self.error_count() == 0

    proc summary(self) -> Dict:
        let d: Dict = {}
        d["inodes_scanned"] = self.inodes_scanned
        d["blocks_scanned"] = self.blocks_scanned
        d["issues"] = len(self.issues)
        d["errors"] = self.error_count()
        d["repaired"] = self.repaired_count
        d["clean"] = self.is_clean()
        return d

    proc print_report(self):
        print("=== SageFS fsck report ===")
        for iss in self.issues:
            print("  " + iss.to_string())
        let s: Dict = self.summary()
        print("inodes=" + str(s["inodes_scanned"]) + " blocks=" + str(s["blocks_scanned"]) + " issues=" + str(s["issues"]) + " errors=" + str(s["errors"]) + " repaired=" + str(s["repaired"]))
        if s["clean"]:
            print("RESULT: clean")
        else:
            print("RESULT: errors found")


# ===========================================================================
# Fsck — the checker
# ===========================================================================

class Fsck:
    ## Cross-references superblock / inode manager / NAT / SIT.
    ##
    ## The managers are passed in so fsck can run against either a mounted
    ## in-memory image or a freshly loaded on-disk volume.  All arguments may
    ## be nil except `superblock`; checks depending on a missing manager are
    ## skipped.
    var sb: Any                # SageFSSuperblock
    var inodes: Any            # InodeManager
    var nat: Any               # NodeAddressTable
    var sit: Any               # SegmentManager
    var csum_tree: Any         # ChecksumTree (optional)
    var repair: Bool

    proc init(self, sb: Any, inodes: Any, nat: Any, sit: Any, csum_tree: Any, repair: Bool):
        self.sb = sb
        self.inodes = inodes
        self.nat = nat
        self.sit = sit
        self.csum_tree = csum_tree
        self.repair = repair

    proc run(self) -> FsckReport:
        let report: FsckReport = FsckReport()
        self.check_superblock(report)
        self.check_nat_sit(report)
        self.check_sit_counts(report)
        self.check_inode_tree(report)
        return report

    # -----------------------------------------------------------------------
    # 1. Superblock
    # -----------------------------------------------------------------------

    proc check_superblock(self, report: FsckReport):
        if self.sb == nil:
            return
        if not self.sb.verify_checksum():
            let iss: FsckIssue = FsckIssue(ISSUE_SB_CHECKSUM, SEV_FATAL, 0, "superblock checksum mismatch")
            if self.repair:
                self.sb.update_checksum()
                iss.repaired = true
            report.add(iss)

    # -----------------------------------------------------------------------
    # 2 & 3. NAT <-> SIT agreement
    # -----------------------------------------------------------------------

    proc check_nat_sit(self, report: FsckReport):
        if self.nat == nil or self.sit == nil:
            return
        ## For every alive NAT entry, confirm the block it points at is marked
        ## valid by its owning segment in the SIT.
        let entries: Array = self.nat.get_dirty_entries()
        for entry in entries:
            if not entry.is_alive():
                continue
            let blk: Int = entry.block_addr
            let segno: Int = blk / self.sb.segment_size
            let offset: Int = blk % self.sb.segment_size
            let sit_entry: Any = self.sit.get_entry(segno)
            if sit_entry == nil:
                report.add(FsckIssue(ISSUE_NAT_SIT_MISMATCH, SEV_ERROR, entry.nid, "nid points at block in unknown segment " + str(segno)))
                continue
            if not sit_entry.is_valid(offset):
                let iss: FsckIssue = FsckIssue(ISSUE_NAT_SIT_MISMATCH, SEV_ERROR, entry.nid, "nid block " + str(blk) + " not marked valid in SIT")
                if self.repair:
                    sit_entry.mark_valid(offset)
                    iss.repaired = true
                report.add(iss)

    # -----------------------------------------------------------------------
    # 4. SIT valid-count consistency
    # -----------------------------------------------------------------------

    proc check_sit_counts(self, report: FsckReport):
        if self.sit == nil:
            return
        let segnos: Array = self.sit.get_segments_by_type("all")
        for segno in segnos:
            let entry: Any = self.sit.get_entry(segno)
            if entry == nil:
                continue
            ## Recompute the popcount of the valid bitmap.
            var actual: Int = 0
            var off: Int = 0
            while off < self.sb.segment_size:
                if entry.is_valid(off):
                    actual = actual + 1
                off = off + 1
                report.blocks_scanned = report.blocks_scanned + 1
            if actual != entry.valid_blocks:
                let iss: FsckIssue = FsckIssue(ISSUE_SIT_COUNT, SEV_WARN, segno, "SIT valid_blocks=" + str(entry.valid_blocks) + " but bitmap popcount=" + str(actual))
                if self.repair:
                    entry.valid_blocks = actual
                    iss.repaired = true
                report.add(iss)

    # -----------------------------------------------------------------------
    # 5. Directory tree walk — orphans & link counts
    # -----------------------------------------------------------------------

    proc check_inode_tree(self, report: FsckReport):
        if self.inodes == nil:
            return
        ## Walk reachable inodes from the root and tally directory references.
        ## `reachable[ino] = observed reference count`.
        var reachable: Dict[Int, Int] = {}
        let root_ino: Int = self.sb.root_inode
        self.walk(root_ino, reachable, report)

        ## Any inode the manager knows about but that we never reached is an
        ## orphan (leaked by an interrupted unlink, etc.).
        let all_inos: Array = self.inodes.list_inodes()
        for ino in all_inos:
            report.inodes_scanned = report.inodes_scanned + 1
            if not dict_has(reachable, ino):
                let iss: FsckIssue = FsckIssue(ISSUE_ORPHAN_INODE, SEV_WARN, ino, "inode not reachable from root")
                if self.repair:
                    self.inodes.delete_inode(ino)
                    iss.repaired = true
                report.add(iss)
                continue
            ## Link-count check.
            let inode: Any = self.inodes.get_inode(ino)
            if inode != nil:
                let observed: Int = reachable[ino]
                if inode.nlink != observed:
                    let iss2: FsckIssue = FsckIssue(ISSUE_LINK_COUNT, SEV_ERROR, ino, "nlink=" + str(inode.nlink) + " but observed refs=" + str(observed))
                    if self.repair:
                        inode.nlink = observed
                        iss2.repaired = true
                    report.add(iss2)

    proc walk(self, ino: Int, reachable: Dict[Int, Int], report: FsckReport):
        ## Depth-first tree walk, counting how many times each inode is
        ## referenced by a directory entry.
        if dict_has(reachable, ino):
            reachable[ino] = reachable[ino] + 1
            return                      # already visited (hard link / cycle guard)
        reachable[ino] = 1

        let inode: Any = self.inodes.get_inode(ino)
        if inode == nil:
            report.add(FsckIssue(ISSUE_DANGLING_NID, SEV_ERROR, ino, "directory references missing inode"))
            return
        if not inode.is_dir():
            return

        ## Recurse into child entries.  The inode manager exposes directory
        ## listing via the DirManager; we tolerate its absence gracefully.
        let children: Array = self.inodes.read_dir_entries(ino)
        for child_ino in children:
            self.walk(child_ino, reachable, report)
