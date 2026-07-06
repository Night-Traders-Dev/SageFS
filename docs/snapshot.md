# Snapshot & Subvolume Engine

## Overview
The Snapshot Engine implements copy-on-write (CoW) snapshots via B+ tree root cloning, similar to BTRFS. It also supports subvolumes, which are independent filesystem trees within the same partition.

## Key Features
- **CoW Snapshots**: Instant creation by cloning the B+ tree root.
- **Subvolumes**: Distinct namespaces and trees.
- **Writable Snapshots**: Branching from any snapshot point.
- **Snapshot Diff**: Efficient delta calculations.
- **Rotation Policies**: Automated retention (hourly, daily, weekly).

## Implementation (Phase 4)
*In Progress*
