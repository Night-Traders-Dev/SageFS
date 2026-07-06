import btree
import superblock

class Snapshot:
    proc init(self, name: String, root_block: Int):
        self.name = name
        self.root_block = root_block
        self.creation_time = 0
        
    proc diff(self, other_snapshot) -> Array:
        return []

class Subvolume:
    proc init(self, id: Int, name: String):
        self.id = id
        self.name = name
        self.snapshots = {}
        
    proc create_snapshot(self, snap_name: String, root_block: Int) -> Snapshot:
        let snap = Snapshot(snap_name, root_block)
        self.snapshots[snap_name] = snap
        return snap

class SnapshotEngine:
    proc init(self, sb):
        self.sb = sb
        self.subvolumes = {}
        
    proc create_subvolume(self, name: String) -> Subvolume:
        let subvol = Subvolume(len(self.subvolumes) + 1, name)
        self.subvolumes[name] = subvol
        return subvol
        
    proc create_snapshot(self, subvol_name: String, snap_name: String) -> Snapshot:
        let subvol = self.subvolumes[subvol_name]
        let root_block = 0
        return subvol.create_snapshot(snap_name, root_block)
        
    proc delete_snapshot(self, subvol_name: String, snap_name: String) -> Bool:
        let subvol = self.subvolumes[subvol_name]
        dict_delete(subvol.snapshots, snap_name)
        return true
