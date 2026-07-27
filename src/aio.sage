class IORequest:
    proc init(self, req_id: Int, lba: Int, data: Bytes, op: String, priority: Int):
        self.req_id = req_id
        self.lba = lba
        self.data = data
        self.op = op
        self.priority = priority
        self.completed = false
        self.error = false

class AsyncIOEngine:
    proc init(self):
        self.submission_queue = [[], [], []]
        self.completion_queue = []
        self.next_req_id = 1
        self.total_reads = 0
        self.total_writes = 0
        self.bytes_read = 0
        self.bytes_written = 0
        self.read_ahead_enabled = true
        self.write_back_enabled = true

    proc submit_read(self, lba: Int, length: Int, priority: Int) -> Int:
        let req = IORequest(self.next_req_id, lba, bytes(), "read", priority)
        self.next_req_id = self.next_req_id + 1
        push(self.submission_queue[priority], req)
        self.total_reads = self.total_reads + 1
        self.bytes_read = self.bytes_read + length
        return req.req_id

    proc submit_write(self, lba: Int, data: Bytes, priority: Int) -> Int:
        let req = IORequest(self.next_req_id, lba, data, "write", priority)
        self.next_req_id = self.next_req_id + 1
        push(self.submission_queue[priority], req)
        self.total_writes = self.total_writes + 1
        self.bytes_written = self.bytes_written + bytes_len(data)
        return req.req_id

    proc poll(self) -> Int:
        var completed = 0
        for priority in range(3):
            var remaining = []
            for req in self.submission_queue[priority]:
                req.completed = true
                push(self.completion_queue, req)
                completed = completed + 1
            self.submission_queue[priority] = []
        return completed

    proc get_completions(self) -> Array:
        var result = []
        for req in self.completion_queue:
            push(result, req)
        self.completion_queue = []
        return result

    proc pending_count(self) -> Int:
        var count = 0
        for priority in range(3):
            count = count + len(self.submission_queue[priority])
        return count

    proc get_stats(self) -> Dict:
        return {
            "total_reads": self.total_reads,
            "total_writes": self.total_writes,
            "bytes_read": self.bytes_read,
            "bytes_written": self.bytes_written,
            "pending": self.pending_count(),
            "read_ahead": self.read_ahead_enabled,
            "write_back": self.write_back_enabled
        }
