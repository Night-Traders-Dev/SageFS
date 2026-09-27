class GarbageCollector:
    proc init(self, segment_manager, allocator):
        self.sm = segment_manager
        self.allocator = allocator
        self.foreground_runs = 0
        self.background_runs = 0
        self.blocks_moved = 0
        self.segments_freed = 0
        self.segments_refused = 0

    proc select_victim(self, policy: String) -> Int:
        if policy == "greedy":
            return self.sm.get_victim_greedy()
        elif policy == "cost-benefit":
            return self.sm.get_victim_cost_benefit()
        return -1

    ## Reclaim a segment by relocating its live blocks elsewhere, then freeing it.
    ##
    ## Relocation is NOT implemented, and this now refuses rather than pretending.
    ## It used to walk the validity bitmap, increment a counter for each valid
    ## block, and then call free_segment() -- which clears the bitmap and returns
    ## the segment to the free list. Every live block in it was discarded, and
    ## `blocks_moved` was incremented for data that had not been moved anywhere.
    ## docs/gc.md described the intended behaviour, which is why this read as a
    ## working collector.
    ##
    ## Doing it properly needs to know which inode owns each block, so its
    ## mapping can be rewritten after the copy. There is no way to ask that
    ## question today: NodeAddressTable can look up a nid's block and update a
    ## nid's block, but has no block -> nid index, and the extent tree -- which
    ## is what actually locates file data -- is not persisted at all. Copying
    ## bytes to a new block under those conditions would produce a filesystem
    ## that neither finds its old data nor its new copy.
    ##
    ## So: refuse, and say why. A collector that declines to run is a bug; one
    ## that deletes live data is a catastrophe.
    proc do_gc(self, seg_id: Int) -> Bool:
        if seg_id < 0:
            return false
        let entry = self.sm.get_entry(seg_id)
        if entry == nil:
            return false

        var live = 0
        var i = 0
        while i < self.sm.blocks_per_segment:
            if entry.is_valid(i):
                live = live + 1
            i = i + 1

        if live > 0:
            self.segments_refused = self.segments_refused + 1
            return false

        ## Entirely invalid: nothing to lose, so reclaiming it is safe.
        self.sm.free_segment(seg_id)
        self.segments_freed = self.segments_freed + 1
        return true

    ## How many blocks in `seg_id` currently hold live data.
    proc count_live_blocks(self, seg_id: Int) -> Int:
        let entry = self.sm.get_entry(seg_id)
        if entry == nil:
            return 0
        var live = 0
        var i = 0
        while i < self.sm.blocks_per_segment:
            if entry.is_valid(i):
                live = live + 1
            i = i + 1
        return live

    ## Note: with relocation unimplemented these return false in practice, since
    ## every candidate segment still holds live data. `needs_gc` can therefore
    ## report true while nothing can be reclaimed -- that is the honest state,
    ## and the alternative was reporting progress it was not making.
    proc run_foreground(self) -> Bool:
        let free_pct = self.sm.free_segment_percent()
        if free_pct >= 5:
            return false
        self.foreground_runs = self.foreground_runs + 1
        let victim = self.select_victim("greedy")
        if victim >= 0:
            return self.do_gc(victim)
        return false

    proc run_background(self) -> Bool:
        let free_pct = self.sm.free_segment_percent()
        if free_pct >= 20:
            return false
        self.background_runs = self.background_runs + 1
        let victim = self.select_victim("cost-benefit")
        if victim >= 0:
            return self.do_gc(victim)
        return false

    proc needs_gc(self) -> Bool:
        let free_pct = self.sm.free_segment_percent()
        return free_pct < 20

    proc needs_urgent_gc(self) -> Bool:
        let free_pct = self.sm.free_segment_percent()
        return free_pct < 5

    proc get_stats(self) -> Dict:
        return {
            "foreground_runs": self.foreground_runs,
            "background_runs": self.background_runs,
            "blocks_moved": self.blocks_moved,
            "segments_freed": self.segments_freed,
            "segments_refused": self.segments_refused
        }
