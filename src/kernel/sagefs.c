/*
 * sagefs.c — SageFS Linux Kernel Driver
 *
 * Character device driver bridging the Linux kernel VFS layer
 * with SageFS's userspace storage engine via FFI or ioctl.
 *
 * Architecture:
 *   - Kernel module registers /dev/sagefs (character device)
 *   - Userspace SageFS daemon uses FFI to mount/manage images
 *   - Kernel module delegates I/O to userspace daemon via ioctl
 *   - Future: direct FFI calls from kernel to SageVM runtime
 *
 * Phase 9: Kernel driver for SageFS
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/mutex.h>

#define SAGEFS_DEVICE_NAME "sagefs"
#define SAGEFS_CLASS_NAME "sagefs"
#define SAGEFS_MAGIC 0x53414745 /* "SAGE" */

#define SAGEFS_IOCTL_MAGIC 'S'
#define SAGEFS_IOC_MOUNT    _IOW(SAGEFS_IOCTL_MAGIC, 0, struct sagefs_mount_req)
#define SAGEFS_IOC_READ     _IOWR(SAGEFS_IOCTL_MAGIC, 1, struct sagefs_io_req)
#define SAGEFS_IOC_WRITE    _IOW(SAGEFS_IOCTL_MAGIC, 2, struct sagefs_io_req)
#define SAGEFS_IOC_FLUSH    _IO(SAGEFS_IOCTL_MAGIC, 3)
#define SAGEFS_IOC_SYNC     _IO(SAGEFS_IOCTL_MAGIC, 4)

struct sagefs_mount_req {
    char image_path[256];
    char mount_point[256];
    unsigned int flags;
};

struct sagefs_io_req {
    unsigned long long offset;
    unsigned int size;
    unsigned int opcode;
    char data[4096];
};

static dev_t sagefs_dev;
static struct cdev sagefs_cdev;
static struct class *sagefs_class;
static struct device *sagefs_device;
static DEFINE_MUTEX(sagefs_mutex);

static int sagefs_major = 0;
static int sagefs_minor = 0;

module_param(sagefs_major, int, 0644);
MODULE_PARM_DESC(sagefs_major, "Major device number (0 = auto)");

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

    if (copy_from_user(&req, buf, count)) {
        mutex_unlock(&sagefs_mutex);
        return -EFAULT;
    }

    ret = count;
    *ppos += ret;

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

    printk(KERN_DEBUG "sagefs: write offset=%lld size=%u\n",
           *ppos, req.size);

    ret = count;
    *ppos += ret;

    mutex_unlock(&sagefs_mutex);
    return ret;
}

static long sagefs_ioctl(struct file *filp, unsigned int cmd, unsigned long arg)
{
    struct sagefs_mount_req mreq;
    struct sagefs_io_req io_req;
    int ret = 0;

    mutex_lock(&sagefs_mutex);

    switch (cmd) {
    case SAGEFS_IOC_MOUNT:
        if (copy_from_user(&mreq, (void __user *)arg, sizeof(mreq))) {
            ret = -EFAULT;
            break;
        }
        printk(KERN_INFO "sagefs: mount request image=%s mount=%s flags=0x%x\n",
               mreq.image_path, mreq.mount_point, mreq.flags);
        break;

    case SAGEFS_IOC_READ:
        if (copy_from_user(&io_req, (void __user *)arg, sizeof(io_req))) {
            ret = -EFAULT;
            break;
        }
        printk(KERN_DEBUG "sagefs: ioctl read offset=%llu size=%u\n",
               io_req.offset, io_req.size);
        break;

    case SAGEFS_IOC_WRITE:
        if (copy_from_user(&io_req, (void __user *)arg, sizeof(io_req))) {
            ret = -EFAULT;
            break;
        }
        printk(KERN_DEBUG "sagefs: ioctl write offset=%llu size=%u\n",
               io_req.offset, io_req.size);
        break;

    case SAGEFS_IOC_FLUSH:
        printk(KERN_DEBUG "sagefs: flush requested\n");
        break;

    case SAGEFS_IOC_SYNC:
        printk(KERN_DEBUG "sagefs: sync requested\n");
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

    printk(KERN_INFO "sagefs: kernel driver loaded (major=%d minor=%d)\n",
           sagefs_major, sagefs_minor);
    return 0;
}

static void __exit sagefs_exit(void)
{
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
MODULE_DESCRIPTION("SageFS kernel driver — userspace storage engine via FFI/ioctl");
MODULE_VERSION("0.1.0");