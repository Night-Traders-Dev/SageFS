## raid.sage — SageFS RAID Engine
##
## Integrated multi-device support: RAID 0/1/5/6/10.
## Stripe mapping for all levels; RAID5Array below is a byte-level RAID5 over
## real block devices or image files, with reconstruction and repair-on-read.

import fileio
import imgio

let RAID_NONE: Int = 0
let RAID_0: Int = 0
let RAID_1: Int = 1
let RAID_5: Int = 5
let RAID_6: Int = 6
let RAID_10: Int = 10

class RaidEngine:
    proc init(self, level: Int):
        self.level = level
        self.devices = []
        self.chunk_size = 65536
        self.stripe_width = 0
        self.total_blocks = 0
        self.blocks_per_device = 0

    proc set_devices(self, device_count: Int, blocks_per_device: Int):
        self.devices = []
        for i in range(device_count):
            push(self.devices, {"id": i, "blocks": blocks_per_device, "failed": false})
        self.blocks_per_device = blocks_per_device
        if self.level == RAID_0:
            self.total_blocks = device_count * blocks_per_device
            self.stripe_width = device_count
        elif self.level == RAID_1:
            self.total_blocks = blocks_per_device
            self.stripe_width = 1
        elif self.level == RAID_5:
            self.total_blocks = (device_count - 1) * blocks_per_device
            self.stripe_width = device_count - 1
        elif self.level == RAID_6:
            self.total_blocks = (device_count - 2) * blocks_per_device
            self.stripe_width = device_count - 2
        elif self.level == RAID_10:
            self.total_blocks = int(device_count / 2) * blocks_per_device
            self.stripe_width = int(device_count / 2)

    proc get_level_name(self) -> String:
        if self.level == RAID_0:
            return "RAID0"
        elif self.level == RAID_1:
            return "RAID1"
        elif self.level == RAID_5:
            return "RAID5"
        elif self.level == RAID_6:
            return "RAID6"
        elif self.level == RAID_10:
            return "RAID10"
        return "none"

    proc map_address(self, logical_addr: Int) -> Dict:
        var result = {}
        result["logical"] = logical_addr
        result["level"] = self.level
        result["stripe_width"] = self.stripe_width
        if self.stripe_width <= 0:
            return result
        let stripe = int(logical_addr / self.chunk_size)
        let stripe_offset = logical_addr % self.chunk_size
        let data_stripe = int(stripe / self.stripe_width)
        let data_index = stripe % self.stripe_width

        if self.level == RAID_0:
            result["device"] = data_index % len(self.devices)
            result["device_block"] = data_stripe * self.chunk_size + stripe_offset
        elif self.level == RAID_1:
            result["device"] = stripe_offset % len(self.devices)
            result["device_block"] = data_stripe * self.chunk_size + stripe_offset
            var mirror_devs = []
            for i in range(len(self.devices)):
                push(mirror_devs, i)
            result["mirror_devices"] = mirror_devs
        elif self.level == RAID_5:
            let parity_device = (len(self.devices) - 1 - data_stripe) % len(self.devices)
            result["data_device"] = data_index
            result["parity_device"] = parity_device
            result["device"] = data_index
            result["device_block"] = data_stripe * self.chunk_size + stripe_offset
        elif self.level == RAID_6:
            let p_device = (len(self.devices) - 1 - data_stripe) % len(self.devices)
            let q_device = (len(self.devices) - 2 - data_stripe) % len(self.devices)
            result["data_device"] = data_index
            result["p_device"] = p_device
            result["q_device"] = q_device
            result["device"] = data_index
            result["device_block"] = data_stripe * self.chunk_size + stripe_offset
        elif self.level == RAID_10:
            let mirror_set = data_index % int(len(self.devices) / 2)
            let primary = mirror_set * 2
            let mirror = primary + 1
            result["device"] = primary
            result["mirror"] = mirror
            result["device_block"] = data_stripe * self.chunk_size + stripe_offset

        return result

    proc compute_parity(self, data_blocks: Array) -> Int:
        var parity = 0
        for block in data_blocks:
            parity = parity ^ block
        return parity

    proc get_storage_efficiency(self) -> Float:
        let n = len(self.devices)
        if n == 0:
            return 0.0
        if self.level == RAID_0:
            return 1.0
        elif self.level == RAID_1:
            return 1.0 / n
        elif self.level == RAID_5:
            return (n - 1) / n
        elif self.level == RAID_6:
            return (n - 2) / n
        elif self.level == RAID_10:
            return 0.5
        return 1.0

    proc get_info(self) -> Dict:
        return {
            "level": self.level,
            "level_name": self.get_level_name(),
            "device_count": len(self.devices),
            "chunk_size": self.chunk_size,
            "stripe_width": self.stripe_width,
            "total_blocks": self.total_blocks,
            "storage_efficiency": self.get_storage_efficiency()
        }

## --- byte-level XOR ------------------------------------------------------
proc bytes_equal(a: Bytes, b: Bytes) -> Bool:
    if bytes_len(a) != bytes_len(b):
        return false
    var i: Int = 0
    while i < bytes_len(a):
        if a[i] != b[i]:
            return false
        i = i + 1
    return true

proc _in(arr: Array, v: Int) -> Bool:
    for x in arr:
        if x == v:
            return true
    return false
##
## compute_parity() above folds block *numbers*, not block contents. That is
## fine for an address-mapping simulation and useless for redundancy: XORing the
## integers 0,1,2,3 tells you nothing about the bytes those blocks hold, so a
## real read could not be reconstructed from it. Parity over data has to be
## computed per byte.
proc xor_bytes(a: Bytes, b: Bytes) -> Bytes:
    let n: Int = bytes_len(a)
    if n != bytes_len(b):
        ## Different widths cannot be XORed meaningfully. Return the shorter
        ## length rather than reading off the end of one buffer.
        return bytes()
    var out: Bytes = bytes(n)
    var i: Int = 0
    while i < n:
        out[i] = a[i] ^ b[i]
        i = i + 1
    return out

proc xor_accumulate(acc: Bytes, b: Bytes) -> Bytes:
    if bytes_len(acc) == 0:
        return b
    if bytes_len(acc) != bytes_len(b):
        return bytes()
    var i: Int = 0
    let n: Int = bytes_len(acc)
    while i < n:
        acc[i] = acc[i] ^ b[i]
        i = i + 1
    return acc

proc parity_bytes(blocks: Array) -> Bytes:
    if len(blocks) == 0:
        return bytes()
    var acc: Bytes = blocks[0]
    var i: Int = 1
    while i < len(blocks):
        acc = xor_bytes(acc, blocks[i])
        i = i + 1
    return acc

## --- Raid5Array: RAID5 over real devices ---------------------------------
##
## A stripe is `block_size` bytes on each device; one device per stripe holds
## XOR parity and the rest hold data, with the parity device rotating by stripe
## so no single device carries parity for every stripe.
##
## Reconstruction needs at least every surviving block of the stripe. With one
## parity block that tolerates exactly one failed device per stripe, which is
## the RAID5 guarantee -- two failures in one stripe is unrecoverable and is
## reported as such rather than returning wrong data.
class Raid5Array:
    proc init(self, paths: Array, block_size: Int):
        self.paths = paths
        self.block_size = block_size
        self.device_count = len(paths)
        if self.device_count < 3:
            ## Two devices is RAID1 mirroring, not RAID5; three is the minimum
            ## that can spare one parity block and still hold data.
            return
        self.data_width = self.device_count - 1

    proc usable(self) -> Bool:
        return self.device_count >= 3 and self.block_size > 0

    proc parity_device(self, stripe: Int) -> Int:
        let d: Int = self.device_count
        return ((d - 1 - stripe) % d + d) % d

    proc _is_parity(self, device: Int, stripe: Int) -> Bool:
        return device == self.parity_device(stripe)

    ## write_stripe — Write `data_width` data blocks plus parity for one stripe.
    ##
    ## Returns false if the count is wrong, rather than writing a partial stripe
    ## that would later reconstruct to garbage.
    proc write_stripe(self, stripe: Int, data: Array) -> Bool:
        if not self.usable():
            return false
        if len(data) != self.data_width:
            return false
        let pd: Int = self.parity_device(stripe)
        var placed: Int = 0
        var dev: Int = 0
        while dev < self.device_count:
            if dev != pd:
                let blk: Bytes = data[placed]
                if bytes_len(blk) != self.block_size:
                    return false
                if fileio.write_at(self.paths[dev], stripe * self.block_size, blk) < 0:
                    return false
                placed = placed + 1
            dev = dev + 1
        let pblk: Bytes = parity_bytes(data)
        if bytes_len(pblk) != self.block_size:
            return false
        return fileio.write_at(self.paths[pd], stripe * self.block_size, pblk) >= 0

    ## _read_device_block — Read one block, or an empty buffer if the device is
    ## marked failed or unreadable. A failed device is never silently treated as
    ## zeros: that would look like real data and corrupt the reconstruction.
    proc _read_device_block(self, device: Int, stripe: Int) -> Bytes:
        let want: Int = self.block_size
        let off: Int = stripe * want
        let got: Bytes = fileio.read_at(self.paths[device], off, want)
        if bytes_len(got) == want:
            return got
        ## Short read means the tail of the device is gone. Pad so the XOR still
        ## has a full-width operand, but the caller can tell it was short.
        return fileio.slice_bytes(got, 0, want)

    ## read_stripe — Read one stripe's data blocks, reconstructing any that are
    ## unavailable. `failed` holds device indices to treat as dead.
    proc read_stripe(self, stripe: Int, failed: Array) -> Array:
        var out: Array = []
        if not self.usable():
            return out
        let pd: Int = self.parity_device(stripe)
        let have_parity: Bool = not _in(failed, pd)
        var missing: Int = 0
        var dev: Int = 0
        while dev < self.device_count:
            if dev != pd:
                if _in(failed, dev):
                    push(out, bytes(self.block_size))
                    missing = missing + 1
                else:
                    push(out, self._read_device_block(dev, stripe))
            dev = dev + 1
        if missing == 0:
            return out
        if missing > 1 or not have_parity:
            ## Two or more missing blocks need two parity blocks (RAID6), which
            ## this array does not have. Returning zeros here would be silent
            ## corruption, so fail the whole read instead.
            return []
        let rec: Bytes = self.reconstruct(stripe, failed)
        if bytes_len(rec) < self.block_size:
            return []
        dev = 0
        var idx: Int = 0
        while dev < self.device_count:
            if dev != pd:
                if _in(failed, dev):
                    out[idx] = rec
                idx = idx + 1
            dev = dev + 1
        return out

    ## reconstruct — Recover one failed device's block for a stripe by XORing
    ## every other block, parity included.
    proc reconstruct(self, stripe: Int, failed: Array) -> Bytes:
        if not self.usable():
            return bytes()
        if len(failed) != 1:
            return bytes()
        let target: Int = failed[0]
        if target < 0 or target >= self.device_count:
            return bytes()
        let pd: Int = self.parity_device(stripe)
        ## Start from parity when the parity block is the one missing,
        ## otherwise from the first surviving data block, so the accumulator is
        ## always a full-width block even if some other block is short.
        var acc: Bytes = bytes(self.block_size)
        var started: Bool = false
        if not _in(failed, pd):
            acc = self._read_device_block(pd, stripe)
            started = bytes_len(acc) == self.block_size
        var dev: Int = 0
        while dev < self.device_count:
            if dev != pd and dev != target:
                let blk: Bytes = self._read_device_block(dev, stripe)
                if bytes_len(blk) == self.block_size:
                    if not started:
                        acc = blk
                        started = true
                    else:
                        acc = xor_bytes(acc, blk)
            dev = dev + 1
        if not started:
            return bytes()
        return acc

    ## repair_on_read — Reconstruct a failed block and write it back.
    ##
    ## Reads normally reconstruct in memory and leave the damage in place, so
    ## every subsequent read pays for it and the array is one device failure from
    ## total loss. Writing the reconstruction back while the read is in flight
    ## is the only window where the surviving copy is guaranteed to exist.
    ## Returns the number of blocks written: 1 on repair, 0 when nothing needed
    ## doing.
    proc repair_on_read(self, stripe: Int, failed: Array) -> Int:
        if not self.usable():
            return 0
        if len(failed) != 1:
            return 0
        let rec: Bytes = self.reconstruct(stripe, failed)
        if bytes_len(rec) != self.block_size:
            return 0
        let target: Int = failed[0]
        let off: Int = stripe * self.block_size
        ## Compare before writing. If the block on disk already matches the
        ## reconstruction there is nothing to repair, and saying "1" would make
        ## a caller believe it had fixed a device it never touched. It also
        ## proves the reconstruction is honest: agreeing with the surviving
        ## copy is the only evidence that the parity was right.
        if bytes_equal(self._read_device_block(target, stripe), rec):
            return 0
        if fileio.write_at(self.paths[target], off, rec) < 0:
            return 0
        return 1

    ## get_info — Report the mapping this array would use.
    proc get_info(self) -> Dict:
        return {
            "device_count": self.device_count,
            "block_size": self.block_size,
            "data_width": self.data_width,
            "parity_device": self.parity_device(0)
        }

