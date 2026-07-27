# SageFS Kernel Driver (Phase 9)

## Overview

The SageFS kernel driver (`src/kernel/sagefs.c`) provides a Linux kernel module that bridges the kernel VFS layer with SageFS's userspace storage engine via sysfs command interface and `/dev/sagefs` character device.

## Architecture

```
┌─────────────────────────────────────────────────┐
│ Kernel (sagefs.ko)                            │
│  /dev/sagefs  ← char dev ──→  I/O buffer       │
│  /sys/kernel/sagefs/  ← sysfs ──→  cmd/state   │
└───────────────────┬─────────────────────────────┘
                      │ sysfs command
                      ▼
┌─────────────────────────────────────────────────┐
│ Userspace Daemon (sagefs_daemon.sh)       │
│  Reads /sys/kernel/sagefs/command           │
│  Routes to SageVM bytecode → SageFS engine  │
│  Updates /sys/kernel/sagefs/state           │
└───────────────────┬─────────────────────────────┘
                      │ VFS
                      ▼
              SageFS image file
```

## Building

```bash
cd src/kernel
make
sudo insmod sagefs.ko
```

## Sysfs Interface

### `/sys/kernel/sagefs/state` (read-only)
Driver state: 0=STOPPED, 1=RUNNING, 2=MOUNTED, 3=DIRTY, 4=ERROR

### `/sys/kernel/sagefs/image_path` (read-only)
Current SageFS image path being managed.

### `/sys/kernel/sagefs/mount_point` (read-only)
Current mount point (empty if not mounted).

### `/sys/kernel/sagefs/command` (write-only)
Send commands to the driver:
- `mount /path/to/image.sagefs` — Set image path and mark DIRTY
- `read offset=N size=N` — Queue a read operation
- `write offset=N size=N` — Queue a write operation, mark DIRTY
- `flush` — Flush pending writes, stay DIRTY
- `sync` — Sync metadata to disk, mark MOUNTED

## IOCTL Interface (via /dev/sagefs)

| Command | Direction | Description |
|---------|-----------|-------------|
| `SAGEFS_IOC_MOUNT` | Write | Mount a SageFS image at mount point |
| `SAGEFS_IOC_READ` | Read/Write | Read data at offset |
| `SAGEFS_IOC_WRITE` | Write | Write data at offset |
| `SAGEFS_IOC_FLUSH` | None | Flush pending writes |
| `SAGEFS_IOC_SYNC` | None | Sync filesystem metadata |
| `SAGEFS_IOC_STATUS` | Read | Get driver state and mount info |

## Userspace Daemon

`sagefs_daemon.sh` provides a bridge between the sysfs command interface and SageFS's userspace runtime. It polls `/sys/kernel/sagefs/command` for new commands and routes them to the SageVM bytecode interpreter.

### Usage

```bash
sudo ./sagefs_daemon.sh &
echo "mount /tmp/test.img" > /sys/kernel/sagefs/command
cat /sys/kernel/sagefs/state  # → 2 (MOUNTED)
```

## FFI Integration Path (Future)

The long-term goal is to use SageVM's FFI capabilities directly from kernel space, eliminating the userspace daemon entirely. This would make SageFS a fully native kernel filesystem with direct access to the storage engine.