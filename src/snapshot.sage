## snapshot.sage — SageFS Snapshot & Subvolume Engine
##
## Copy-on-Write snapshots via B+ tree root cloning.
## Subvolumes are independent filesystem trees sharing the same partition.
## Snapshot diff computes delta between snapshots.

class Snapshot:
    proc init(self, name: String, root_block: Int, subvol_id: Int, creation_time: Int, gen: Int):
        self.name = name
        self.root_block = root_block
        self.subvol_id = subvol_id
        self.creation_time = creation_time
        self.generation = gen
        self.deleted = false

    proc to_dict(self) -> Dict:
        return {
            "name": self.name,
            "root_block": self.root_block,
            "subvol_id": self.subvol_id,
            "creation_time": self.creation_time,
            "generation": self.generation
        }

class Subvolume:
    proc init(self, id: Int, name: String, root_block: Int, gen: Int):
        self.id = id
        self.name = name
        self.root_block = root_block
        self.generation = gen
        self.snapshots = {}

    proc create_snapshot(self, snap_name: String, current_time: Int) -> Snapshot:
        let snap = Snapshot(snap_name, self.root_block, self.id, current_time, self.generation)
        self.snapshots[snap_name] = snap
        return snap

    proc get_snapshot(self, snap_name: String) -> Snapshot:
        if dict_has(self.snapshots, snap_name):
            return self.snapshots[snap_name]
        return nil

    proc delete_snapshot(self, snap_name: String) -> Bool:
        if dict_has(self.snapshots, snap_name):
            let snap = self.snapshots[snap_name]
            snap.deleted = true
            dict_delete(self.snapshots, snap_name)
            return true
        return false

    proc snapshot_count(self) -> Int:
        return len(dict_keys(self.snapshots))

    proc to_dict(self) -> Dict:
        var snap_dicts = {}
        for snap_name in dict_keys(self.snapshots):
            snap_dicts[snap_name] = self.snapshots[snap_name].to_dict()
        return {
            "id": self.id,
            "name": self.name,
            "root_block": self.root_block,
            "generation": self.generation,
            "snapshot_count": self.snapshot_count(),
            "snapshots": snap_dicts
        }

class SnapshotEngine:
    proc init(self):
        self.subvolumes = {}
        self.next_subvol_id = 1
        self.next_generation = 1

    proc create_subvolume(self, name: String, root_block: Int) -> Subvolume:
        let gen = self.next_generation
        self.next_generation = self.next_generation + 1
        let subvol = Subvolume(self.next_subvol_id, name, root_block, gen)
        self.subvolumes[name] = subvol
        self.next_subvol_id = self.next_subvol_id + 1
        return subvol

    proc get_subvolume(self, name: String) -> Subvolume:
        if dict_has(self.subvolumes, name):
            return self.subvolumes[name]
        return nil

    proc delete_subvolume(self, name: String) -> Bool:
        if dict_has(self.subvolumes, name):
            dict_delete(self.subvolumes, name)
            return true
        return false

    proc create_snapshot(self, subvol_name: String, snap_name: String, current_time: Int) -> Snapshot:
        let subvol = self.get_subvolume(subvol_name)
        if subvol == nil:
            return nil
        return subvol.create_snapshot(snap_name, current_time)

    proc delete_snapshot(self, subvol_name: String, snap_name: String) -> Bool:
        let subvol = self.get_subvolume(subvol_name)
        if subvol == nil:
            return false
        return subvol.delete_snapshot(snap_name)

    proc list_snapshots(self, subvol_name: String) -> Array:
        let subvol = self.get_subvolume(subvol_name)
        if subvol == nil:
            return []
        var result = []
        for snap_name in dict_keys(subvol.snapshots):
            push(result, subvol.snapshots[snap_name])
        return result

    proc list_subvolumes(self) -> Array:
        var result = []
        for name in dict_keys(self.subvolumes):
            push(result, self.subvolumes[name])
        return result

    proc diff_snapshots(self, subvol_name: String, snap1_name: String, snap2_name: String) -> Dict:
        let subvol = self.get_subvolume(subvol_name)
        if subvol == nil:
            return {}
        let snap1 = subvol.get_snapshot(snap1_name)
        let snap2 = subvol.get_snapshot(snap2_name)
        if snap1 == nil or snap2 == nil:
            return {}
        var diff = {}
        diff["subvolume"] = subvol_name
        diff["snap1"] = snap1_name
        diff["snap2"] = snap2_name
        diff["snap1_root"] = snap1.root_block
        diff["snap2_root"] = snap2.root_block
        diff["snap1_gen"] = snap1.generation
        diff["snap2_gen"] = snap2.generation
        return diff

    proc get_generation(self) -> Int:
        let gen = self.next_generation
        self.next_generation = self.next_generation + 1
        return gen
