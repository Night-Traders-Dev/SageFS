# SageFS Kernel Driver (Phase 9)

The SageFS kernel driver is a Linux kernel module that bridges the kernel VFS layer with SageFS's userspace storage engine.

## Architecture

The kernel driver bridges the Linux kernel VFS layer with SageFS's userspace storage engine via two interfaces:

1. **Character Device** (`/dev/sagefs`): Direct char device I/O for read/write operations
2. **Sysfs Interface** (`/sys/kernel/sagefs/`): Command/state interface for daemon communication
```
┌───────────────────────────────────────────────────┐
│ Kernel (sagefs.ko)                              │
│  /dev/sagefs  ← char dev ──→  I/O buffer        │
│  /sys/kernel/sagefs/  ← sysfs ──→  command/state │
└────────────────────┬────────────────────────────┘
                     │ sysfs command
                     ▼
┌───────────────────────────────────────────────────┐
│ Userspace Daemon (sagefs_daemon.sh)             │
│  Reads /sys/kernel/sagefs/command               │
│  Routes to SageVM bytecode via SageFS runtime   │
│  Updates /sys/kernel/sagefs/state               │
└────────────────────┬────────────────────────────┘
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

## IOCTL Commands

| Command | Direction | Description |
|---------|-----------|-------------|
| `SAGEFS_IOC_MOUNT` | Write | Mount a SageFS image at a mount point |
| `SAGEFS_IOC_READ` | Read/Write | Read data from a specific offset |
| `SAGEFS_IOC_WRITE` | Write | Write data at a specific offset |
| `SAGEFS_IOC_FLUSH` | None | Flush pending writes |
| `SAGEFS_IOC_SYNC` | None | Sync filesystem metadata |

sysfs: $(cat /sys/kernel/sagefs/state)

## Sysfs Command Protocol

### /sys/kernel/sagefs/state (read-only)
Returns the current driver state:
| Value | State | Description |
|-------|-------|-------------|
| 0 | STOPPED | Driver idle, no mount |
| 1 | RUNNING | Driver active, no mount |
| 2 | MOUNTED | Filesystem mounted at mount point |
| 3 | DIRTY | Pending writes need sync |
| 4 | ERROR | Error state, fsck recommended |

### /sys/kernel/sagefs/image_path (read-only)
Current SageFS image path being managed.

### /sys/kernel/sagefs/mount_point (read-only)
Current mount point (empty if not mounted).

### /sys/kernel/sagefs/command (write-only)
Send a command to the driver. The kernel logs the command and updates state. Supported commands:

| Command | Description | State Change |
|---------|-------------|-------------|
| `mount /path/to/image.sagefs` | Set image path for mount | → DIRTY |
| `read offset=0 size=4096` | Queue a read operation | no change |
| `write offset=0 size=4096` | Queue a write operation | → DIRTY |
| `flush` | Flush pending writes | DIRTY |
| `sync` | Sync metadata to disk | → MOUNTED |

## Building

```bash
cd src/kernel
make
sudo insmod sagefs.ko
```

## Verifying Load

```bash
# Check kernel log
dmesg | tail -5

# Check sysfs state
cat /sys/kernel/sagefs/state

# Check device major/minor
cat /sys/class/sagefs/sagefs/dev

# Send a mount command via sysfs
echo "mount /tmp/test.img" > /sys/kernel/sagefs/command

# Check state
cat /sys/kernel/sagefs/state

# Unload
sudo rmmod sagefs
```

## Userspace Daemon

`sagefs_daemon.sh` provides a bridge between the sysfs command interface and SageFS's userspace runtime. It reads commands from sysfs and routes them to the SageVM bytecode interpreter.