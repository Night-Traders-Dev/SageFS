import checksum

class DedupEngine:
    proc init(self):
        self.bloom_filter = {}
        self.fingerprints = {}
        
    proc check_inline(self, data: Bytes) -> Int:
        # return block addr if dedup match, else -1
        let fp = checksum.sha256_hash(data)
        if dict_has(self.fingerprints, fp):
            return self.fingerprints[fp]
        return -1
        
    proc add_fingerprint(self, data: Bytes, block_addr: Int):
        let fp = checksum.sha256_hash(data)
        self.fingerprints[fp] = block_addr
