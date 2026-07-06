# RAID Engine

## Overview
The RAID Engine integrates multi-device support directly into the filesystem.

## Key Features
- **Supported Levels**: 
  - RAID 0 (stripe)
  - RAID 1 (mirror)
  - RAID 5 (single parity)
  - RAID 6 (double parity)
  - RAID 10 (stripe + mirror)
- **Repair-on-read**: Auto-fix corrupt blocks from parity or mirror.
- **Online Operations**: Add, remove, replace devices dynamically.
- **Scrubbing**: Periodic parity and mirror verification.

## Implementation (Phase 4)
*In Progress*
