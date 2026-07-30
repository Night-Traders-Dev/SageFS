# SageFS Kernel Driver (Phase 9)

`sagefs.c` is a Linux VFS kernel module that registers the `sagefs` filesystem type,
enabling `mount -t sagefs /dev/sdb /mnt/sagefs` directly through the kernel block layer.

## Build

```bash
cd src/kernel
make CC=clang LD=ld.lld
sudo insmod sagefs.ko
```

## Test

```bash
# nodev mount (no block device required)
sudo mount -t sagefs none /mnt/sagefs
stat /mnt/sagefs
sudo umount /mnt/sagefs

# block device mount
# sudo mount -t sagefs /dev/sdb /mnt/sagefs
```

## Dependencies

- Linux kernel headers 7.1.x (Debian Sid)
- clang + ld.lld (or gcc)
- kernel module build system (kbuild)

## Current Status

- Module loads, `mount -t sagefs none /mnt` works
- `stat` on root inode succeeds
- `ls` and `umount` trigger OOM crash (i_lru/kernel 7.1 compatibility issue)
- Block device path (`get_tree_bdev`) not yet tested
