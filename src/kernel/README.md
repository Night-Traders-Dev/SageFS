# SageFS Kernel Driver (Phase 9)

The SageFS kernel driver is a Linux kernel module that bridges the kernel VFS layer with SageFS's userspace storage engine.

## Architecture

The kernel driver uses a character device (`/dev/sagefs`) to communicate between the kernel and userspace:

1. **Kernel Module** (`sagefs.ko`): Registers `/dev/sagefs` as a character device
2. **ioctl Interface**: Mount, read, write, flush, sync operations
3. **Userspace Daemon**: SageFS process that manages the actual storage engine
4. **FFI Bridge** (future): Direct calls from kernel to SageVM runtime

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

## Interface

### Userspace API

The kernel driver is designed to work with SageFS's userspace FUSE daemon:

```c
// Mount a SageFS image
struct sagefs_mount_req req = {0};
strncpy(req.image_path, "/path/to/image.sagefs", sizeof(req.image_path));
strncpy(req.mount_point, "/mount/point", sizeof(req.mount_point));
req.flags = 0;
ioctl(fd, SAGEFS_IOC_MOUNT, &req);

// Read data
struct sagefs_io_req io = {0};
io.offset = 0;
io.size = 4096;
io.opcode = SAGEFS_OP_READ;
ioctl(fd, SAGEFS_IOC_READ, &io);
```

### Future: Direct FFI Integration

The long-term goal is to use SageVM's FFI capabilities directly from kernel space,
eliminating the userspace daemon overhead entirely. This would make SageFS a fully
native kernel filesystem.