class GarbageCollector:
    proc init(self, segment_manager, allocator):
        self.sm = segment_manager
        self.allocator = allocator
        self.foreground_runs = 0
        self.background_runs = 0
        self.blocks_moved = 0
        self.segments_freed = 0

    proc select_victim(self, policy: String) -> Int:
        if policy == "greedy":
            return self.sm.get_victim_greedy()
        elif policy == "cost-benefit":
            return self.sm.get_victim_cost_benefit()
        return -1

    proc do_gc(self, seg_id: Int) -> Bool:
        if seg_id < 0:
            return false
        let entry = self.sm.get_entry(seg_id)
        if entry == nil:
            return false
        var i = 0
        while i < self.sm.blocks_per_segment:
            if entry.is_valid(i):
                let phys_blk = self.sm.get_physical_block(seg_id, i)
                self.blocks_moved = self.blocks_moved + 1
            i = i + 1
        self.sm.free_segment(seg_id)
        self.segments_freed = self.segments_freed + 1
        return true

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
            "segments_freed": self.segments_freed
        }
