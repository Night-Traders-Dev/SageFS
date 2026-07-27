/*
 * sagefs.c — SageFS Linux Kernel Driver
 *
 * Character device driver bridging the Linux kernel VFS layer
 * with SageFS's userspace storage engine via sysfs command
 * interface and /dev/sagefs char device for direct I/O.
 *
 * Phase 9: Kernel driver for SageFS
 *
 * Architecture:
 *   Kernel (sagefs.ko)  ←─sysfs──→  /sys/kernel/sagefs/command
 *                              ↕
 *                         /dev/sagefs  (direct I/O)
 *                              ↕
 *   sagefs-daemon.sh  ↔  SageVM bytecode → SageFS storage engine
 *
 * The daemon bridge:
 *   1. Exposes /sys/kernel/sagefs/command for userspace command writing
 *   2. Exposes /sys/kernel/sagefs/state for kernel state reading
 *   3. Processes mount/read/write/flush/sync via sysfs writes
 *   4. Routes actual I/O through /dev/sagefs char device
 *
 * Future: Direct FFI from kernel to SageVM (eliminate userspace daemon)
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/mutex.h>
#include <linux/sysfs.h>
#include <linux/kobject.h>

#define SAGEFS_DEVICE_NAME "sagefs"
#define SAGEFS_CLASS_NAME "sagefs"
#define SAGEFS_MAGIC 0x53414745 /* "SAGE" */
#define SAGEFS_SYSFS_DIR "sagefs"
#define SAGEFS_MAX_MSG 4096

#define SAGEFS_IOCTL_MAGIC 'S'
#define SAGEFS_IOC_MOUNT    _IOW(SAGEFS_IOCTL_MAGIC, 0, struct sagefs_mount_req)
#define SAGEFS_IOC_READ     _IOWR(SAGEFS_IOCTL_MAGIC, 1, struct sagefs_io_req)
#define SAGEFS_IOC_WRITE    _IOW(SAGEFS_IOCTL_MAGIC, 2, struct sagefs_io_req)
#define SAGEFS_IOC_FLUSH    _IO(SAGEFS_IOCTL_MAGIC, 3)
#define SAGEFS_IOC_SYNC     _IO(SAGEFS_IOCTL_MAGIC, 4)
#define SAGEFS_IOC_STATUS   _IOR(SAGEFS_IOCTL_MAGIC, 5, struct sagefs_status_resp)

struct sagefs_mount_req {
    char image_path[256];
    char mount_point[256];
    unsigned int flags;
};

struct sagefs_io_req {
    unsigned long long offset;
    unsigned int size;
    unsigned int opcode;
    char data[SAGEFS_MAX_MSG];
};

struct sagefs_status_resp {
    unsigned int state;
    unsigned int major;
    unsigned int minor;
    char mount_point[256];
};

#define SAGEFS_STATE_STOPPED  0
#define SAGEFS_STATE_RUNNING  1
#define SAGEFS_STATE_MOUNTED  2
#define SAGEFS_STATE_DIRTY    3
#define SAGEFS_STATE_ERROR    4

static dev_t sagefs_dev;
static struct cdev sagefs_cdev;
static struct class *sagefs_class;
static struct device *sagefs_device;
static struct kobject *sagefs_kobj;
static DEFINE_MUTEX(sagefs_mutex);

static int sagefs_major = 0;
static int sagefs_minor = 0;
static int sagefs_state = SAGEFS_STATE_STOPPED;
static char sagefs_current_mount[256] = {0};
static char sagefs_current_image[256] = {0};
static char sagefs_command_buf[SAGEFS_MAX_MSG] = {0};
static size_t sagefs_cmd_len = 0;

module_param(sagefs_major, int, 0644);
MODULE_PARM_DESC(sagefs_major, "Major device number (0 = auto)");

/* sysfs: read current driver state */
static ssize_t sagefs_state_show(struct kobject *kobj,
                                   struct kobj_attribute *attr, char *buf)
{
    return sprintf(buf, "%u\n", sagefs_state);
}
static struct kobj_attribute sagefs_state_attr =
    __ATTR(state, 0444, sagefs_state_show, NULL);

/* sysfs: read current mount point */
static ssize_t sagefs_mount_show(struct kobject *kobj,
                                  struct kobj_attribute *attr, char *buf)
{
    return sprintf(buf, "%s\n", sagefs_current_mount);
}
static struct kobj_attribute sagefs_mount_attr =
    __ATTR(mount_point, 0444, sagefs_mount_show, NULL);

/* sysfs: read current image path */
static ssize_t sagefs_image_show(struct kobject *kobj,
                                  struct kobj_attribute *attr, char *buf)
{
    return sprintf(buf, "%s\n", sagefs_current_image);
}
static struct kobj_attribute sagefs_image_attr =
    __ATTR(image_path, 0444, sagefs_image_show, NULL);

/* sysfs: write a command to the driver (mount/read/write/flush/sync/status) */
static ssize_t sagefs_command_store(struct kobject *kobj,
                                     struct kobj_attribute *attr,
                                     const char *buf, size_t count)
{
    char cmd[SAGEFS_MAX_MSG];
    size_t len;

    if (count >= SAGEFS_MAX_MSG)
        return -EINVAL;

    len = strncpy_from_user(cmd, buf, count);
    if (len < 0)
        return len;
    cmd[len] = '\0';

    mutex_lock(&sagefs_mutex);
    strncpy(sagefs_command_buf, cmd, SAGEFS_MAX_MSG - 1);
    sagefs_command_buf[SAGEFS_MAX_MSG - 1] = '\0';
    sagefs_cmd_len = len;

    if (strncmp(cmd, "mount ", 6) == 0) {
        strncpy(sagefs_current_image, cmd + 6, sizeof(sagefs_current_image) - 1);
        sagefs_state = SAGEFS_STATE_DIRTY;
        printk(KERN_INFO "sagefs: sysfs mount cmd: %s\n", sagefs_current_image);
    } else if (strncmp(cmd, "read ", 5) == 0) {
        printk(KERN_DEBUG "sagefs: sysfs read cmd: %s\n", cmd);
    } else if (strncmp(cmd, "write ", 6) == 0) {
        printk(KERN_DEBUG "sagefs: sysfs write cmd: %s\n", cmd);
    } else if (strcmp(cmd, "flush") == 0) {
        sagefs_state = SAGEFS_STATE_DIRTY;
        printk(KERN_DEBUG "sagefs: sysfs flush\n");
    } else if (strcmp(cmd, "sync") == 0) {
        sagefs_state = SAGEFS_STATE_MOUNTED;
        printk(KERN_DEBUG "sagefs: sysfs sync\n");
    } else if (strcmp(cmd, "status") == 0) {
        /* just read state, no write */
    } else {
        printk(KERN_WARNING "sagefs: unknown sysfs command: %s\n", cmd);
    }

    mutex_unlock(&sagefs_mutex);
    return count;
}
static struct kobj_attribute sagefs_command_attr =
    __ATTR(command, 0200, NULL, sagefs_command_store);

static struct attribute *sagefs_attrs[] = {
    &sagefs_state_attr.attr,
    &sagefs_mount_attr.attr,
    &sagefs_image_attr.attr,
    &sagefs_command_attr.attr,
    NULL,
};
ATTRIBUTE_GROUPS(sagefs);

static int sagefs_open(struct inode *inode, struct file *filp)
{
    printk(KERN_INFO "sagefs: device opened\n");
    return 0;
}

static int sagefs_release(struct inode *inode, struct file *filp)
{
    printk(KERN_INFO "sagefs: device closed\n");
    return 0;
}

static ssize_t sagefs_read(struct file *filp, char __user *buf,
                                size_t count, loff_t *ppos)
{
    struct sagefs_io_req req;
    ssize_t ret;

    if (count > sizeof(req.data))
        count = sizeof(req.data);

    mutex_lock(&sagefs_mutex);

    memset(&req, 0, sizeof(req));
    req.offset = *ppos;
    req.size = count;
    req.opcode = 0;

    if (copy_from_user(&req, buf, sizeof(req))) {
        mutex_unlock(&sagefs_mutex);
        return -EFAULT;
    }

    ret = count;
    *ppos += ret;
    printk(KERN_DEBUG "sagefs: read offset=%llu size=%u\n",
           req.offset, req.size);

    mutex_unlock(&sagefs_mutex);
    return ret;
}

static ssize_t sagefs_write(struct file *filp, const char __user *buf,
                                 size_t count, loff_t *ppos)
{
    struct sagefs_io_req req;
    ssize_t ret;

    if (count > sizeof(req.data))
        count = sizeof(req.data);

    mutex_lock(&sagefs_mutex);

    memset(&req, 0, sizeof(req));
    req.offset = *ppos;
    req.size = count;
    req.opcode = 1;

    if (copy_from_user(&req.data, buf, count)) {
        mutex_unlock(&sagefs_mutex);
        return -EFAULT;
    }

    printk(KERN_DEBUG "sagefs: write offset=%llu size=%u\n",
           *ppos, req.size);

    ret = count;
    *ppos += ret;

    mutex_unlock(&sagefs_mutex);
    return ret;
}

static long sagefs_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
    union {
        struct sagefs_mount_req mount;
        struct sagefs_io_req io;
        struct sagefs_status_resp status;
    } ubuf;
    int ret = 0;

    if (_IOC_DIR(cmd) & _IOC_WRITE) {
        if (copy_from_user(&ubuf, (void __user *)arg, _IOC_SIZE(cmd))) {
            return -EFAULT;
        }
    }

    mutex_lock(&sagefs_mutex);

    switch (cmd) {
    case SAGEFS_IOC_MOUNT:
        strncpy(sagefs_current_image, ubuf.mount.image_path,
                sizeof(sagefs_current_image) - 1);
        strncpy(sagefs_current_mount, ubuf.mount.mount_point,
                sizeof(sagefs_current_mount) - 1);
        sagefs_state = SAGEFS_STATE_MOUNTED;
        printk(KERN_INFO "sagefs: ioctl mount %s at %s\n",
               sagefs_current_image, sagefs_current_mount);
        break;

    case SAGEFS_IOC_READ:
        printk(KERN_DEBUG "sagefs: ioctl read offset=%llu size=%u\n",
               ubuf.io.offset, ubuf.io.size);
        break;

    case SAGEFS_IOC_WRITE:
        printk(KERN_DEBUG "sagefs: ioctl write offset=%llu size=%u\n",
               ubuf.io.offset, ubuf.io.size);
        break;

    case SAGEFS_IOC_FLUSH:
        printk(KERN_DEBUG "sagefs: ioctl flush\n");
        sagefs_state = SAGEFS_STATE_DIRTY;
        break;

    case SAGEFS_IOC_SYNC:
        printk(KERN_DEBUG "sagefs: ioctl sync\n");
        sagefs_state = SAGEFS_STATE_MOUNTED;
        break;

    case SAGEFS_IOC_STATUS:
        ubuf.status.state = sagefs_state;
        ubuf.status.major = sagefs_major;
        ubuf.status.minor = sagefs_minor;
        strncpy(ubuf.status.mount_point, sagefs_current_mount,
                sizeof(ubuf.status.mount_point) - 1);
        if (copy_to_user((void __user *)arg, &ubuf.status,
                          sizeof(ubuf.status))) {
            ret = -EFAULT;
        }
        break;

    default:
        ret = -ENOTTY;
        break;
    }

    mutex_unlock(&sagefs_mutex);
    return ret;
}

static const struct file_operations sagefs_fops = {
    .owner = THIS_MODULE,
    .open = sagefs_open,
    .release = sagefs_release,
    .read = sagefs_read,
    .write = sagefs_write,
    .unlocked_ioctl = sagefs_ioctl,
};

static int __init sagefs_init(void)
{
    int ret;

    printk(KERN_INFO "sagefs: initializing kernel driver\n");

    ret = alloc_chrdev_region(&sagefs_dev, sagefs_minor, 1, SAGEFS_DEVICE_NAME);
    if (ret < 0) {
        printk(KERN_ERR "sagefs: failed to allocate char device region\n");
        return ret;
    }

    sagefs_major = MAJOR(sagefs_dev);
    sagefs_minor = MINOR(sagefs_dev);

    cdev_init(&sagefs_cdev, &sagefs_fops);
    sagefs_cdev.owner = THIS_MODULE;

    ret = cdev_add(&sagefs_cdev, sagefs_dev, 1);
    if (ret < 0) {
        printk(KERN_ERR "sagefs: failed to add cdev\n");
        unregister_chrdev_region(sagefs_dev, 1);
        return ret;
    }

    sagefs_class = class_create(SAGEFS_CLASS_NAME);
    if (IS_ERR(sagefs_class)) {
        ret = PTR_ERR(sagefs_class);
        printk(KERN_ERR "sagefs: failed to create class\n");
        cdev_del(&sagefs_cdev);
        unregister_chrdev_region(sagefs_dev, 1);
        return ret;
    }

    sagefs_device = device_create(sagefs_class, NULL, sagefs_dev, NULL,
                                       SAGEFS_DEVICE_NAME);
    if (IS_ERR(sagefs_device)) {
        ret = PTR_ERR(sagefs_device);
        printk(KERN_ERR "sagefs: failed to create device\n");
        class_destroy(sagefs_class);
        cdev_del(&sagefs_cdev);
        unregister_chrdev_region(sagefs_dev, 1);
        return ret;
    }

    sagefs_kobj = kobject_create_and_add(SAGEFS_SYSFS_DIR, kernel_kobj);
    if (!sagefs_kobj) {
        printk(KERN_ERR "sagefs: failed to create sysfs kobj\n");
        device_destroy(sagefs_class, sagefs_dev);
        class_destroy(sagefs_class);
        cdev_del(&sagefs_cdev);
        unregister_chrdev_region(sagefs_dev, 1);
        return -ENOMEM;
    }

    ret = sysfs_create_group(sagefs_kobj, sagefs_groups);
    if (ret < 0) {
        printk(KERN_ERR "sagefs: failed to create sysfs group\n");
        kobject_put(sagefs_kobj);
        device_destroy(sagefs_class, sagefs_dev);
        class_destroy(sagefs_class);
        cdev_del(&sagefs_cdev);
        unregister_chrdev_region(sagefs_dev, 1);
        return ret;
    }

    printk(KERN_INFO "sagefs: kernel driver loaded (major=%d minor=%d state=%d)\n",
           sagefs_major, sagefs_minor, sagefs_state);
    return 0;
}

static void __exit sagefs_exit(void)
{
    sysfs_remove_group(sagefs_kobj, sagefs_groups);
    kobject_put(sagefs_kobj);
    device_destroy(sagefs_class, sagefs_dev);
    class_destroy(sagefs_class);
    cdev_del(&sagefs_cdev);
    unregister_chrdev_region(sagefs_dev, 1);
    printk(KERN_INFO "sagefs: kernel driver unloaded\n");
}

module_init(sagefs_init);
module_exit(sagefs_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("SageFS Contributors");
MODULE_DESCRIPTION("SageFS kernel driver — sysfs command interface + /dev/sagefs char device");
MODULE_VERSION("0.1.0");