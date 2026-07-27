## raid.sage — SageFS RAID Engine
##
## Integrated multi-device support: RAID 0/1/5/6/10.
## Simulates parity calculations and stripe mapping.

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
