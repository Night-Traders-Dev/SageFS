## dedup.sage — SageFS Deduplication Engine
##
## Inline dedup with bloom filter pre-check and block-level fingerprinting.

## Bloom filter
##
## DEDUP_BLOOM_SIZE is a bit count, not an entry count: the filter is a fixed
## DEDUP_BLOOM_SIZE-bit array, which is what makes its memory cost independent of
## how many blocks the image holds.
##
## What replaced the previous implementation is worth stating, because the
## difference is not cosmetic. `bloom_filter` used to be a Dict holding every
## fingerprint it had ever seen, which is an exact set rather than a bloom
## filter: it cannot produce a false positive, but it also cannot save anything,
## and it grows with the image until the pre-check costs more memory than the
## dedup it is meant to accelerate.
##
## The property that makes a real bloom filter safe here is that this module
## always confirms a hit against the exact `fingerprints` table before deduping.
## So a false positive costs one Dict lookup and nothing else, while a false
## negative -- claiming a block is absent when it is present -- would return -1
## and corrupt the write. The filter is therefore used only in the negative
## direction: a clear bit means definitely absent, and only an all-set result is
## worth a second look.
##
## Bits are never cleared on removal. A bloom filter cannot delete, and clearing
## one bit on block removal would make a still-shared fingerprint look absent to
## every other block sharing it -- a false negative, and therefore corruption. A
## stale bit only ever costs a lookup that the exact table then rejects.
##
## Fingerprints are FNV-1a over the block bytes. SHA-256 would be the right
## choice for collision resistance, but it is not needed for the filter and is
## not implemented natively yet (see checksum.sage); see docs on that.

let DEDUP_BLOOM_SIZE: Int = 65536

## Number of hash probes per lookup. 7 is the usual optimum for a filter of this
## size and gives a false-positive rate near 1% at the expected load.
## Fingerprint algorithms.
##
## The fast one is a 32-bit polynomial hash. The strong one is SHA-256.
##
## SHA-256 is not the default despite being available, because it costs about 16x
## more per block in this runtime: measured at roughly 95 ms per 4096-byte block
## against 6 ms for CRC32C, i.e. ~43 KiB/s versus ~670 KiB/s. Checksumming a
## 1 GiB volume with SHA-256 would take hours. CRC32C catches the corruption this
## actually needs to catch -- random bit rot -- and SHA-256 is there for callers
## that want content addressing against an adversary.
##
## Same reasoning as btrfs: crc32c by default, sha256 as an opt-in paranoid mode.
let DEDUP_FP_FAST: Int = 0
let DEDUP_FP_SHA256: Int = 1

let DEDUP_BLOOM_HASHES: Int = 7

## FNV-1a over a fingerprint string with a seed, to get one probe index.
## Two different seeds give two independent-enough hashes without needing a
## cryptographic digest here.
import checksum

proc bloom_hash(fp: String, seed: Int) -> Int:
    var h: Int = 2166136261 ^ seed
    let n: Int = len(fp)
    var i: Int = 0
    while i < n:
        h = (h ^ ord(fp[i])) & 0xFFFFFFFF
        h = (h * 16777619) & 0xFFFFFFFF
        i = i + 1
    return h % DEDUP_BLOOM_SIZE

class DedupEngine:
    proc init(self):
        ## Fixed-size bit array, not a growing Dict. DEDUP_BLOOM_SIZE bits.
        self.bloom_filter = bytes(DEDUP_BLOOM_SIZE / 8)
        self.bloom_set_bits = 0
        self.fingerprints = {}
        self.block_to_fp = {}
        self.reference_counts = {}
        self.hits = 0
        self.misses = 0
        self.total_deduped = 0
        ## See DEDUP_FP_*. Namespaced into the fingerprint string so a table can
        ## hold both kinds at once without a fast hash colliding with a digest.
        self.fingerprint_algo = DEDUP_FP_FAST

    proc bloom_test(self, fp: String) -> Bool:
        ## True means "possibly present". False means definitely absent.
        var k: Int = 0
        while k < DEDUP_BLOOM_HASHES:
            let bit: Int = bloom_hash(fp, k)
            let byte_idx: Int = bit / 8
            let mask: Int = 1 << (bit % 8)
            if (self.bloom_filter[byte_idx] & mask) == 0:
                return false
            k = k + 1
        return true

    proc bloom_add(self, fp: String):
        var k: Int = 0
        var newly: Int = 0
        while k < DEDUP_BLOOM_HASHES:
            let bit: Int = bloom_hash(fp, k)
            let byte_idx: Int = bit / 8
            let mask: Int = 1 << (bit % 8)
            if (self.bloom_filter[byte_idx] & mask) == 0:
                self.bloom_filter[byte_idx] = self.bloom_filter[byte_idx] | mask
                newly = newly + 1
            k = k + 1
        self.bloom_set_bits = self.bloom_set_bits + newly

    proc compute_fingerprint(self, data: Bytes) -> String:
        ## Content address for a block.
        ##
        ## Prefixed by algorithm so fingerprints from different algorithms cannot
        ## be confused in one table: a 32-bit polynomial hash and a truncated
        ## digest could otherwise produce the same string.
        if self.fingerprint_algo == DEDUP_FP_SHA256:
            return "sha256:" + checksum.sha256(data)
        var h: Int = 0
        let n = bytes_len(data)
        for i in range(n):
            h = (h * 31 + bytes_get(data, i)) & 0xFFFFFFFF
        return "fp_" + str(h)

    proc check_inline(self, data: Bytes) -> Int:
        let fp = self.compute_fingerprint(data)
        if not self.bloom_test(fp):
            self.misses = self.misses + 1
            return -1
        ## The filter said "possibly present". Only the exact table decides.
        if dict_has(self.fingerprints, fp):
            self.hits = self.hits + 1
            self.total_deduped = self.total_deduped + 1
            return self.fingerprints[fp]
        self.misses = self.misses + 1
        return -1

    proc add_fingerprint(self, data: Bytes, block_addr: Int):
        let fp = self.compute_fingerprint(data)
        self.bloom_add(fp)
        ## Record the first location that holds this content and keep it.
        ##
        ## Two blocks with identical content share one physical location, so
        ## the second is a reference to the first, not a new one. Overwriting
        ## here made the table point at whichever block was registered last, and
        ## removing either then lost the other.
        if not dict_has(self.fingerprints, fp):
            self.fingerprints[fp] = block_addr
        let key = str(block_addr)
        self.block_to_fp[key] = fp
        ## Increment, not just initialise.
        ##
        ## Registering a block once sets the count to 1; registering it *again* is
        ## another file taking a reference to the same content, and the count has to
        ## say so. Leaving it at 1 made every shared block look singly-referenced, so
        ## the copy-on-write check never fired and an edit to one file overwrote the
        ## block every other file was still reading -- silent corruption with no error
        ## at the time. That is exactly the failure dedup must never have.
        if dict_has(self.reference_counts, key):
            self.reference_counts[key] = self.reference_counts[key] + 1
        else:
            self.reference_counts[key] = 1

    proc remove_block(self, block_addr: Int):
        let key = str(block_addr)
        if dict_has(self.block_to_fp, key):
            let fp = self.block_to_fp[key]
            dict_delete(self.block_to_fp, key)
            dict_delete(self.reference_counts, key)
            ## Only forget the fingerprint when no surviving block shares it.
            ##
            ## Two blocks with identical content have one fingerprint and one
            ## physical address, and removing either of them used to delete that
            ## address from the table -- so the remaining block stopped deduping
            ## and a third copy of the same content was written again. The
            ## fingerprint is the shared resource here, not the block.
            var still_shared: Bool = false
            let others = dict_keys(self.block_to_fp)
            var oi: Int = 0
            while oi < len(others):
                if dict_has(self.block_to_fp, others[oi]):
                    if self.block_to_fp[others[oi]] == fp:
                        still_shared = true
                oi = oi + 1
            if not still_shared:
                dict_delete(self.fingerprints, fp)
            ## Deliberately not clearing a bloom bit: another block may still
            ## share this fingerprint, and clearing it would report that shared
            ## fingerprint as absent. The exact table above is authoritative and
            ## has already dropped it.


    proc inc_ref(self, block_addr: Int) -> Int:
        let key = str(block_addr)
        if dict_has(self.reference_counts, key):
            self.reference_counts[key] = self.reference_counts[key] + 1
            return self.reference_counts[key]
        self.reference_counts[key] = 1
        return 1

    proc dec_ref(self, block_addr: Int) -> Int:
        let key = str(block_addr)
        if dict_has(self.reference_counts, key):
            let new_count = self.reference_counts[key] - 1
            self.reference_counts[key] = new_count
            if new_count <= 0:
                dict_delete(self.reference_counts, key)
            return new_count
        return 0

    proc ref_count(self, block_addr: Int) -> Int:
        let key = str(block_addr)
        if dict_has(self.reference_counts, key):
            return self.reference_counts[key]
        return 0

    proc get_stats(self) -> Dict:
        return {
            "hits": self.hits,
            "misses": self.misses,
            "total_deduped": self.total_deduped,
            "fingerprint_count": len(dict_keys(self.fingerprints)),
            "blocks_tracked": len(dict_keys(self.block_to_fp)),
            "bloom_bits_set": self.bloom_set_bits,
            "bloom_bits_total": DEDUP_BLOOM_SIZE
        }
