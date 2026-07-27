# SageFS Kernel Driver

## Overview

The SageFS kernel driver (`src/kernel/sagefs.c`) provides a Linux kernel module that bridges the kernel VFS layer with SageFS's userspace storage engine via a character device interface.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                 Linux Kernel (VFS)                  │
│  ┌──────────────────────────────────────────────┐  │
│  │         sagefs.ko (character device)         │  │
│  │  /dev/sagefs  ←── ioctl ──→  Userspace      │  │
│  └──────────────────────────────────────────────┘  │
└────────────────────┬──────────────────────────────┘
                     │ ioctl / FFI
                     ▼
┌─────────────────────────────────────────────────────┐
│             SageFS Userspace Daemon                 │
│  ┌─────────┐  ┌─────────┐  ┌───────────────────┐  │
│  │  FUSE   │  │   FFI   │  │ SageFS Storage    │  │
│  │ Handlers│──│ Bridge  │──│ Engine (SageLang) │  │
│  └─────────┘  └─────────┘  └───────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## IOCTL Interface

| Command | Direction | Description |
|---------|-----------|-------------|
| `SAGEFS_IOC_MOUNT` | Write | Mount a SageFS image |
| `SAGEFS_IOC_READ` | Read/Write | Read data at offset |
| `SAGEFS_IOC_WRITE` | Write | Write data at offset |
| `SAGEFS_IOC_FLUSH` | None | Flush pending writes |
| `SAGEFS_IOC_SYNC` | None | Sync metadata |

## Building

```bash
cd src/kernel
make                 # builds sagefs.ko
sudo insmod sagefs.ko  # loads the module
sudo rmmod sagefs     # unloads the module
```

## FFI Integration Path (Future)

The long-term goal is to use SageVM's FFI capabilities directly from kernel space, allowing the kernel driver to call into SageFS's storage engine without a userspace daemon. This would make SageFS a fully native kernel filesystem.