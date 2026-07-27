import sys
import vfs as vfs_module

proc main(args: Array):
    if len(args) < 2:
        print "Usage: stats_cli.sage <image>"
        return
    let image_path = args[1]
    let fs = vfs_module.VFS(image_path, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil)
    if not fs.mount():
        print "Failed to mount image '" + image_path + "'"
        return
    print "===== SageFS Statistics ====="
    print "Image: " + image_path
    if fs.sb != nil:
        print ""
        print "--- Superblock ---"
        let d = fs.sb.to_dict()
        print "  Block size:       " + str(d["block_size"])
        print "  Total blocks:     " + str(d["total_blocks"])
        print "  Total segments:   " + str(d["total_segments"])
        print "  Free segments:    " + str(d["free_segments"])
        print "  Segment size:     " + str(d["segment_size"]) + " blocks"
        print "  UUID:             " + d["uuid"]
        print "  Label:            " + d["label"]
        print "  State:            " + str(d["state"])
        print "  Features:         0x" + str(d["flags"])
        print "  Checksum algo:    " + str(d["checksum_algo"])
        print "  Compress algo:    " + str(d["compress_algo"])
        print "  RAID level:       " + str(d["raid_level"])
    if fs.segment != nil:
        print ""
        print "--- Segment Manager ---"
        let seg_summary = fs.segment.summary()
        print "  Total segments:   " + str(seg_summary["total_segments"])
        print "  Free segments:    " + str(seg_summary["free_segments"])
        print "  Used segments:    " + str(seg_summary["used_segments"])
        print "  Dirty segments:   " + str(seg_summary["dirty_segments"])
        print "  Full segments:    " + str(seg_summary["full_segments"])
        print "  Utilization:      " + str(seg_summary["utilization_pct"]) + "%"
        print "  Valid blocks:     " + str(seg_summary["total_valid_blocks"])
    if fs.allocator != nil:
        print ""
        print "--- Block Allocator ---"
        let alloc_summary = fs.allocator.summary()
        print "  Block size:       " + str(alloc_summary["block_size"])
        print "  Total blocks:     " + str(alloc_summary["total_blocks"])
        print "  Allocated blocks: " + str(alloc_summary["allocated_blocks"])
        print "  Free blocks:      " + str(alloc_summary["free_blocks"])
        print "  Utilization:      " + str(alloc_summary["utilization_pct"]) + "%"
    if fs.nat != nil:
        print ""
        print "--- Node Address Table ---"
        let nat_stats = fs.nat.stats()
        print "  Total entries:    " + str(nat_stats["total_entries"])
        print "  Alive entries:    " + str(nat_stats["alive_entries"])
        print "  Dirty entries:    " + str(nat_stats["dirty_count"])
        print "  Journal entries:  " + str(nat_stats["journal_count"])
        print "  Free nids:        " + str(nat_stats["free_nids_count"])
        print "  Capacity:         " + str(nat_stats["max_capacity"])
    if fs.inode != nil:
        print ""
        print "--- Inode Manager ---"
        let inode_stats = fs.inode.stats()
        print "  Total inodes:     " + str(inode_stats["total"])
        print "  Dirty inodes:     " + str(inode_stats["dirty"])
        print "  Free pool:        " + str(inode_stats["free_pool_size"])
    if fs.cache != nil:
        print ""
        print "--- Cache Manager ---"
        let cache_stats = fs.cache.get_stats()
        print "  NAT cache:        " + str(cache_stats["nat"]["size"]) + " entries, hit_rate=" + str(cache_stats["nat"]["hit_rate"]) + "%"
        print "  Extent cache:     " + str(cache_stats["extent"]["size"]) + " entries, hit_rate=" + str(cache_stats["extent"]["hit_rate"]) + "%"
        print "  Node cache:       " + str(cache_stats["node"]["size"]) + " entries, hit_rate=" + str(cache_stats["node"]["hit_rate"]) + "%"
    if fs.aio != nil:
        print ""
        print "--- Async I/O Engine ---"
        let aio_stats = fs.aio.get_stats()
        print "  Total reads:      " + str(aio_stats["total_reads"])
        print "  Total writes:     " + str(aio_stats["total_writes"])
        print "  Bytes read:       " + str(aio_stats["bytes_read"])
        print "  Bytes written:    " + str(aio_stats["bytes_written"])
        print "  Pending:          " + str(aio_stats["pending"])
    if fs.compress != nil:
        print ""
        print "--- Compression Engine ---"
        let comp_stats = fs.compress.get_stats()
        print "  Original bytes:   " + str(comp_stats["original_bytes"])
        print "  Compressed bytes: " + str(comp_stats["compressed_bytes"])
        print "  Ratio:            " + str(comp_stats["ratio"])
        print "  Incompressible:   " + str(comp_stats["incompressible_count"])
    if fs.dedup != nil:
        print ""
        print "--- Dedup Engine ---"
        let dedup_stats = fs.dedup.get_stats()
        print "  Fingerprints:     " + str(dedup_stats["fingerprint_count"])
        print "  Blocks tracked:   " + str(dedup_stats["blocks_tracked"])
        print "  Hits:             " + str(dedup_stats["hits"])
        print "  Misses:           " + str(dedup_stats["misses"])
        print "  Deduped:          " + str(dedup_stats["total_deduped"])
    if fs.gc != nil:
        print ""
        print "--- Garbage Collector ---"
        let gc_stats = fs.gc.get_stats()
        print "  Foreground runs:  " + str(gc_stats["foreground_runs"])
        print "  Background runs:  " + str(gc_stats["background_runs"])
        print "  Blocks moved:     " + str(gc_stats["blocks_moved"])
        print "  Segments freed:   " + str(gc_stats["segments_freed"])
    if fs.raid != nil:
        print ""
        print "--- RAID Engine ---"
        let raid_info = fs.raid.get_info()
        print "  Level:            " + raid_info["level_name"]
        print "  Devices:          " + str(raid_info["device_count"])
        print "  Chunk size:       " + str(raid_info["chunk_size"])
        print "  Stripe width:     " + str(raid_info["stripe_width"])
        print "  Total blocks:     " + str(raid_info["total_blocks"])
        print "  Storage eff:      " + str(raid_info["storage_efficiency"])
    fs.unmount()

main(sys.args())
