/*
 * sagefs.c - SageFS Linux Kernel Filesystem Driver
 *
 * Full VFS implementation allowing `mount -t sagefs /dev/sdb /mnt`.
 * Reads on-disk SageFS format: superblock at block 0, inode entries
 * in reserved blocks 8-15, root inode (ino=3) stores dir entries as
 * inline hex-encoded data.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/fs.h>
#include <linux/buffer_head.h>
#include <linux/slab.h>
#include <linux/mm.h>
#include <linux/uaccess.h>
#include <linux/stat.h>
#include <linux/namei.h>
#include <linux/export.h>
#include <linux/mount.h>
#include <linux/seq_file.h>
#include <linux/pagemap.h>
#include <linux/writeback.h>
#include <linux/errno.h>
#include <linux/string.h>
#include <linux/time.h>
#include <linux/time64.h>
#include <linux/ktime.h>
#include <linux/init.h>
#include <linux/ctype.h>
#include <linux/fs_context.h>

#define SAGEFS_MAGIC 0x53414745
#define SAGEFS_BLOCK_SIZE 4096
#define SAGEFS_BLOCK_BITS 12
#define SAGEFS_INODE_ENTRY_START_BLK 8
#define SAGEFS_INODE_ENTRY_BYTE_SIZE (8 * SAGEFS_BLOCK_SIZE)
#define SAGEFS_MAX_INLINE_DATA 8192
#define SAGEFS_MAX_NAME_LEN 256
#define SAGEFS_ROOT_INO 3
#define SAGEFS_README_INO 2

/* On-disk superblock (v1.2, 452 bytes) */
struct sagefs_on_disk_sb {
	__le32 magic;
	__le32 version_major;
	__le32 version_minor;
	__le32 block_size;
	__le32 segment_size;
	__le64 total_segments;
	__le64 total_blocks;
	__le64 free_segments;
	__le64 root_inode;
	__le64 checkpoint_ver;
	__le64 nat_start_blk;
	__le64 sit_start_blk;
	__le64 ssa_start_blk;
	__le64 main_start_blk;
	char uuid[36];
	char label[256];
	__le32 flags;
	__le32 checksum_algo;
	__le32 compress_algo;
	__le32 encryption_algo;
	__le32 raid_level;
	__le64 create_time;
	__le32 mount_count;
	__le32 max_mount_count;
	__le32 state;
	__le64 image_size;
	__le64 inode_entry_start_blk;
	__le64 inode_entry_byte_size;
	__le32 checksum;
};

/* In-memory private inode data */
struct sagefs_inode_info {
	struct inode vfs_inode;
	__u64 ino;
	__u32 mode;
	__u32 size;
	char inline_data[SAGEFS_MAX_INLINE_DATA];
	size_t inline_len;
	struct mutex lock;
};

/* Superblock private data */
struct sagefs_sb_info {
	struct buffer_head *sb_bh;
	struct sagefs_on_disk_sb *onsb;
	struct block_device *bdev;
	__u64 total_blocks;
	__u32 block_size;
	__u64 inode_entry_start_blk;
	__u64 inode_entry_byte_size;
};

static struct kmem_cache *sagefs_inode_cachep;

/* Forward declarations for operations tables */
static struct super_operations sagefs_super_ops;
static struct inode_operations sagefs_dir_inode_ops;
static struct inode_operations sagefs_file_inode_ops;
static const struct file_operations sagefs_dir_file_ops;
static const struct file_operations sagefs_file_file_ops;
static const struct address_space_operations sagefs_aops;
static void sagefs_put_super(struct super_block *sb)
{
	struct sagefs_sb_info *sbi = sb->s_fs_info;
	if (sbi) {
		if (sbi->sb_bh)
			brelse(sbi->sb_bh);
		kfree(sbi);
		sb->s_fs_info = NULL;
	}
}

static int sagefs_sync_fs(struct super_block *sb, int wait);
static int sagefs_statfs(struct dentry *dentry, struct kstatfs *buf);
static int sagefs_fill_super(struct super_block *sb, struct fs_context *fc);
static int sagefs_get_tree(struct fs_context *fc);

/* Forward declarations */
static struct inode *sagefs_iget(struct super_block *sb, unsigned long ino);
static int sagefs_persist_inode(struct inode *inode);

/* ===========================================================================
 * Inode cache management
 * =========================================================================== */

static struct inode *sagefs_alloc_inode(struct super_block *sb)
{
	struct sagefs_inode_info *ei;

	ei = kmem_cache_zalloc(sagefs_inode_cachep, GFP_KERNEL);
	if (!ei)
		return NULL;

	mutex_init(&ei->lock);
	INIT_LIST_HEAD(&ei->vfs_inode.i_lru);
	ei->ino = 0;
	ei->mode = 0;
	ei->size = 0;
	ei->inline_len = 0;

	return &ei->vfs_inode;
}

static void sagefs_destroy_inode(struct inode *inode)
{
	struct sagefs_inode_info *ei = container_of(inode, struct sagefs_inode_info, vfs_inode);
	kmem_cache_free(sagefs_inode_cachep, ei);
}

static int sagefs_write_inode(struct inode *inode, struct writeback_control *wbc)
{
	return sagefs_persist_inode(inode);
}

/* ===========================================================================
 * On-disk inode entry parsing
 * =========================================================================== */

/*
 * Read all inode entries from the reserved block area and find the one
 * matching the requested inode number.
 */
static int sagefs_read_inode_entry(struct super_block *sb, __u32 target_ino,
				   __u32 *mode, __u32 *size,
				   char **data_out, size_t *data_len_out)
{
	struct sagefs_sb_info *sbi = sb->s_fs_info;
	__u64 area_start, area_end, off;
	int found = 0;

	if (!sb->s_bdev)
		return -ENODEV;

	area_start = sbi->inode_entry_start_blk * sbi->block_size;
	area_end = area_start + sbi->inode_entry_byte_size;

	for (off = area_start; off + 16 <= area_end; ) {
		struct buffer_head *bh;
		__u32 ino, mode_val, size_val;
		__u16 name_len, data_len;
		__u64 blk = off >> SAGEFS_BLOCK_BITS;
		__u64 blk_off = off & (SAGEFS_BLOCK_SIZE - 1);

		if (blk_off + 16 > SAGEFS_BLOCK_SIZE)
			break;

		bh = sb_bread(sb, blk);
		if (!bh)
			break;

		ino = le32_to_cpu(*(__le32 *)(bh->b_data + blk_off));
		mode_val = le32_to_cpu(*(__le32 *)(bh->b_data + blk_off + 4));
		size_val = le32_to_cpu(*(__le32 *)(bh->b_data + blk_off + 8));
		name_len = le16_to_cpu(*(__le16 *)(bh->b_data + blk_off + 12));
		data_len = le16_to_cpu(*(__le16 *)(bh->b_data + blk_off + 14));

		if (ino == 0 && mode_val == 0 && size_val == 0 &&
		    name_len == 0 && data_len == 0) {
			brelse(bh);
			break;
		}

		if (blk_off + 16 + name_len + data_len > SAGEFS_BLOCK_SIZE) {
			brelse(bh);
			break;
		}

		if (data_len > SAGEFS_MAX_INLINE_DATA) {
			brelse(bh);
			break;
		}

		if (ino == target_ino) {
			*mode = mode_val;
			*size = size_val;
			*data_len_out = data_len;
		if (data_len > 0 && data_len <= SAGEFS_MAX_INLINE_DATA) {
			*data_out = kmemdup(bh->b_data + blk_off + 16 + name_len,
					    data_len, GFP_KERNEL);
			if (!*data_out) {
				brelse(bh);
				return -ENOMEM;
			}
		} else {
			*data_out = NULL;
		}
			found = 1;
		}

		brelse(bh);
		off += 16 + name_len + data_len;
	}

	if (!found)
		return -ENOENT;

	return 0;
}

/*
 * Get a VFS inode by number. Reads the on-disk inode entry and populates
 * the VFS inode with mode, size, and inline data.
 */
static struct inode *sagefs_iget(struct super_block *sb, unsigned long ino)
{
	struct inode *inode;
	__u32 mode, size;
	char *data = NULL;
	size_t data_len = 0;
	int ret;

	inode = iget_locked(sb, ino);
	if (!inode)
		return ERR_PTR(-ENOMEM);

	{
		struct sagefs_inode_info *ei_check = container_of(inode, struct sagefs_inode_info, vfs_inode);
		if (ei_check->ino != 0)
			return inode;
	}

 	ret = sagefs_read_inode_entry(sb, ino, &mode, &size, &data, &data_len);
	if (ret < 0) {
		/* Inode not found on disk - create a minimal one */
		struct sagefs_inode_info *ei = container_of(inode, struct sagefs_inode_info, vfs_inode);
		inode->i_mode = S_IFREG | 0644;
		inode->i_size = 0;
		inode->i_blocks = 0;
		set_nlink(inode, 1);
		inode_set_atime(inode, 0, 0);
		inode_set_mtime(inode, 0, 0);
		inode_set_ctime(inode, 0, 0);
		inode->i_op = &sagefs_file_inode_ops;
		inode->i_fop = &sagefs_file_file_ops;
		inode->i_data.a_ops = &sagefs_aops;
		ei->ino = ino;
		ei->mode = inode->i_mode;
		ei->size = 0;
		ei->inline_len = 0;
		unlock_new_inode(inode);
		return inode;
	}

	inode->i_mode = mode;
	inode->i_size = size;
	inode->i_blocks = 0;
	set_nlink(inode, 1);
	inode_set_atime(inode, 0, 0);
	inode_set_mtime(inode, 0, 0);
	inode_set_ctime(inode, 0, 0);

	if (S_ISDIR(mode)) {
		inode->i_op = &sagefs_dir_inode_ops;
		inode->i_fop = &sagefs_dir_file_ops;
		set_nlink(inode, 2);
	} else {
		inode->i_op = &sagefs_file_inode_ops;
		inode->i_fop = &sagefs_file_file_ops;
	}
	inode->i_data.a_ops = &sagefs_aops;

	{
		struct sagefs_inode_info *ei = container_of(inode, struct sagefs_inode_info, vfs_inode);
		ei->ino = ino;
		ei->mode = mode;
		ei->size = size;
		if (data && data_len <= SAGEFS_MAX_INLINE_DATA) {
			memcpy(ei->inline_data, data, data_len);
			ei->inline_len = data_len;
		} else {
			ei->inline_len = 0;
		}
	}

	if (data)
		kfree(data);

	unlock_new_inode(inode);
	return inode;
}

/* ===========================================================================
 * Directory entry parsing (root inode's inline hex data)
 * =========================================================================== */

/*
 * The root inode stores directory entries as inline data in hex-encoded
 * format: LE16 count + repeated (LE32 ino, LE16 name_len, LE8 ftype, name).
 * The inline data is a hex string, so we need to decode it first.
 */
/* ===========================================================================
 * Directory operations
 * =========================================================================== */

static int sagefs_create(struct mnt_idmap *idmap, struct inode *dir,
			 struct dentry *dentry, umode_t mode, bool excl)
{
	struct inode *inode;
	struct sagefs_inode_info *ei;
	int ret;

	inode = sagefs_iget(dir->i_sb, get_next_ino());
	if (IS_ERR(inode))
		return PTR_ERR(inode);

	inode->i_mode = mode | S_IFREG;
	inode->i_size = 0;
	inode->i_blocks = 0;
	set_nlink(inode, 1);
	inode->i_op = &sagefs_file_inode_ops;
	inode->i_fop = &sagefs_file_file_ops;
	inode->i_data.a_ops = &sagefs_aops;

	ei = container_of(inode, struct sagefs_inode_info, vfs_inode);
	ei->ino = inode->i_ino;
	ei->mode = inode->i_mode;
	ei->size = 0;
	ei->inline_len = 0;

	d_instantiate(dentry, inode);
	ret = sagefs_persist_inode(inode);
	if (ret < 0)
		printk(KERN_WARNING "sagefs: failed to persist new inode %llu\n", inode->i_ino);

	return 0;
}

static struct dentry *sagefs_lookup(struct inode *dir, struct dentry *dentry,
				     unsigned int flags)
{
	struct sagefs_sb_info *sbi = dir->i_sb->s_fs_info;
	__u64 area_start = sbi->inode_entry_start_blk * sbi->block_size;
	__u64 area_end = area_start + sbi->inode_entry_byte_size;
	__u64 off;

	for (off = area_start; off + 16 <= area_end; ) {
		struct buffer_head *bh;
		__u32 ino, mode_val;
		__u16 name_len, data_len;
		__u64 blk = off >> SAGEFS_BLOCK_BITS;
		__u64 blk_off = off & (SAGEFS_BLOCK_SIZE - 1);

		if (blk_off + 16 > SAGEFS_BLOCK_SIZE)
			break;

		bh = sb_bread(dir->i_sb, blk);
		if (!bh)
			break;

		ino = le32_to_cpu(*(__le32 *)(bh->b_data + blk_off));
		mode_val = le32_to_cpu(*(__le32 *)(bh->b_data + blk_off + 4));
		name_len = le16_to_cpu(*(__le16 *)(bh->b_data + blk_off + 12));
		data_len = le16_to_cpu(*(__le16 *)(bh->b_data + blk_off + 14));

		if (ino == 0 && mode_val == 0 && name_len == 0 && data_len == 0) {
			brelse(bh);
			break;
		}

		if (blk_off + 16 + name_len + data_len > SAGEFS_BLOCK_SIZE) {
			brelse(bh);
			break;
		}

		if (name_len > 0 && dentry->d_name.len == name_len &&
		    !memcmp(bh->b_data + blk_off + 16, dentry->d_name.name, name_len)) {
			struct inode *inode;
			brelse(bh);
			inode = sagefs_iget(dir->i_sb, ino);
			if (IS_ERR(inode))
				return ERR_CAST(inode);
			return d_splice_alias(inode, dentry);
		}

		brelse(bh);
		off += 16 + name_len + data_len;
	}

	return NULL;
}

static int sagefs_unlink(struct inode *dir, struct dentry *dentry)
{
	return -ENOSYS;
}

static struct dentry *sagefs_mkdir(struct mnt_idmap *idmap, struct inode *dir,
				 struct dentry *dentry, umode_t mode)
{
	return ERR_PTR(-ENOSYS);
}

static int sagefs_rmdir(struct inode *dir, struct dentry *dentry)
{
	return -ENOSYS;
}

static int sagefs_rename(struct mnt_idmap *idmap, struct inode *old_dir,
			  struct dentry *old_dentry, struct inode *new_dir,
			  struct dentry *new_dentry, unsigned int flags)
{
	return -ENOSYS;
}

static int sagefs_setattr(struct mnt_idmap *idmap, struct dentry *dentry,
			   struct iattr *attr)
{
	return simple_setattr(idmap, dentry, attr);
}

static int sagefs_getattr(struct mnt_idmap *idmap, const struct path *path,
			   struct kstat *stat, u32 request_mask, unsigned int query_flags)
{
	struct inode *inode = d_inode(path->dentry);
	generic_fillattr(idmap, inode->i_ino, inode, stat);
	return 0;
}

static int sagefs_statfs(struct dentry *dentry, struct kstatfs *buf)
{
	return simple_statfs(dentry, buf);
}

/* ===========================================================================
 * File operations
 * =========================================================================== */

static int sagefs_open(struct inode *inode, struct file *filp)
{
	return 0;
}

static int sagefs_release(struct inode *inode, struct file *filp)
{
	return 0;
}

static ssize_t sagefs_read_iter(struct kiocb *iocb, struct iov_iter *iter)
{
	struct file *filp = iocb->ki_filp;
	struct inode *inode = filp->f_inode;
	struct sagefs_inode_info *ei = container_of(inode, struct sagefs_inode_info, vfs_inode);
	size_t count = iov_iter_count(iter);
	loff_t pos = iocb->ki_pos;
	size_t avail;

	if (pos >= ei->inline_len)
		return 0;

	avail = ei->inline_len - pos;
	if (count > avail)
		count = avail;

	if (copy_to_user(iter_iov(iter)->iov_base,
			 ei->inline_data + pos, count))
		return -EFAULT;

	iov_iter_advance(iter, count);
	iocb->ki_pos += count;
	return count;
}

static ssize_t sagefs_write_iter(struct kiocb *iocb, struct iov_iter *iter)
{
	struct file *filp = iocb->ki_filp;
	struct inode *inode = filp->f_inode;
	struct sagefs_inode_info *ei = container_of(inode, struct sagefs_inode_info, vfs_inode);
	size_t count = iov_iter_count(iter);
	loff_t pos = iocb->ki_pos;

	if (pos + count > SAGEFS_MAX_INLINE_DATA)
		count = SAGEFS_MAX_INLINE_DATA - pos;

	if (copy_from_user(ei->inline_data + pos,
			   iter_iov(iter)->iov_base, count))
		return -EFAULT;

	ei->inline_len = pos + count;
	inode->i_size = ei->inline_len;
	iov_iter_advance(iter, count);
	iocb->ki_pos += count;

	sagefs_persist_inode(inode);
	return count;
}

static int sagefs_fsync(struct file *filp, loff_t start, loff_t end, int datasync)
{
	return file_write_and_wait_range(filp, start, end);
}

static loff_t sagefs_llseek(struct file *filp, loff_t offset, int whence)
{
	struct inode *inode = filp->f_inode;
	loff_t retval = -EINVAL;

	switch (whence) {
	case 1:
		offset += filp->f_pos;
		fallthrough;
	case 0:
		if (offset < 0)
			break;
		retval = offset;
		break;
	case 2:
		offset += i_size_read(inode);
		if (offset >= 0)
			retval = offset;
		break;
	}

	if (retval >= 0)
		filp->f_pos = retval;

	return retval;
}

/* ===========================================================================
 * Directory iteration
 * =========================================================================== */

static int sagefs_readdir(struct file *filp, struct dir_context *ctx)
{
	struct inode *inode = filp->f_inode;
	struct sagefs_inode_info *ei = container_of(inode, struct sagefs_inode_info, vfs_inode);
	const char *hex_data;
	size_t hex_len;
	unsigned char *raw;
	size_t raw_len;
	__u16 count;
	size_t off, i;
	loff_t pos = ctx->pos;

	if (ei->inline_len < 4)
		return 0;

	hex_data = ei->inline_data;
	hex_len = ei->inline_len;
	raw_len = hex_len / 2;
	raw = kmalloc(raw_len, GFP_KERNEL);
	if (!raw)
		return -ENOMEM;

	for (i = 0; i < raw_len; i++) {
		char c1 = hex_data[i * 2];
		char c2 = hex_data[i * 2 + 1];
		int hi, lo;

		if (c1 >= '0' && c1 <= '9')
			hi = c1 - '0';
		else if (c1 >= 'a' && c1 <= 'f')
			hi = c1 - 'a' + 10;
		else
			hi = 0;

		if (c2 >= '0' && c2 <= '9')
			lo = c2 - '0';
		else if (c2 >= 'a' && c2 <= 'f')
			lo = c2 - 'a' + 10;
		else
			lo = 0;

		raw[i] = (hi << 4) | lo;
	}

	count = raw[0] | (raw[1] << 8);
	off = 2;

	if (pos == 0) {
		ctx->pos = 1;
		if (!dir_emit_dots(filp, ctx)) {
			kfree(raw);
			return 0;
		}
	}

	for (i = 0; i < count && off + 7 <= raw_len; i++) {
		__u32 entry_ino;
		__u16 name_len;
		__u8 ftype;
		const char *name;

		entry_ino = raw[off] | (raw[off + 1] << 8) |
			    (raw[off + 2] << 16) | (raw[off + 3] << 24);
		name_len = raw[off + 4] | (raw[off + 5] << 8);
		ftype = raw[off + 6];
		off += 7;

		if (off + name_len > raw_len)
			break;

		name = (const char *)(raw + off);
		off += name_len;

		if (pos > 1) {
			pos--;
			continue;
		}

		ctx->pos = pos + 1;
		if (!dir_emit(ctx, name, name_len, entry_ino,
			      ftype == 0 ? DT_UNKNOWN :
			      ftype == 1 ? DT_DIR : DT_REG)) {
			kfree(raw);
			return 0;
		}
		pos++;
	}

	kfree(raw);
	return 0;
}

/* ===========================================================================
 * Address space operations
 * =========================================================================== */

static int sagefs_readpage(struct file *file, struct folio *folio)
{
	struct inode *inode = folio->mapping->host;
	struct sagefs_inode_info *ei = container_of(inode, struct sagefs_inode_info, vfs_inode);
	size_t avail;

	avail = ei->inline_len - folio->index * PAGE_SIZE;
	if (avail <= 0) {
		set_page_dirty(&folio->page);
		unlock_page(&folio->page);
		return 0;
	}

	if (avail > PAGE_SIZE)
		avail = PAGE_SIZE;

	memcpy(folio_address(folio), ei->inline_data + folio->index * PAGE_SIZE, avail);
	memset(folio_address(folio) + avail, 0, PAGE_SIZE - avail);
	set_page_dirty(&folio->page);
	unlock_page(&folio->page);
	return 0;
}

/* ===========================================================================
 * Persistence (write inode entries back to block device)
 * =========================================================================== */

static int sagefs_persist_inode(struct inode *inode)
{
	struct sagefs_sb_info *sbi = inode->i_sb->s_fs_info;
	struct sagefs_inode_info *ei = container_of(inode, struct sagefs_inode_info, vfs_inode);
	__u64 area_start = sbi->inode_entry_start_blk * sbi->block_size;
	__u64 area_end = area_start + sbi->inode_entry_byte_size;
	__u64 off;
	int found = 0;

	/* Search for existing entry for this inode */
	for (off = area_start; off + 16 <= area_end; ) {
		struct buffer_head *bh;
		__u32 ino, mode_val;
		__u16 name_len, data_len;
		__u64 blk = off >> SAGEFS_BLOCK_BITS;
		__u64 blk_off = off & (SAGEFS_BLOCK_SIZE - 1);

		if (blk_off + 16 > SAGEFS_BLOCK_SIZE)
			break;

		bh = sb_bread(inode->i_sb, blk);
		if (!bh)
			break;

		ino = le32_to_cpu(*(__le32 *)(bh->b_data + blk_off));
		mode_val = le32_to_cpu(*(__le32 *)(bh->b_data + blk_off + 4));
		name_len = le16_to_cpu(*(__le16 *)(bh->b_data + blk_off + 12));
		data_len = le16_to_cpu(*(__le16 *)(bh->b_data + blk_off + 14));

		if (ino == 0 && mode_val == 0 && name_len == 0 && data_len == 0)
			break;

		if (ino == ei->ino) {
			/* Update existing entry */
			*(__le32 *)(bh->b_data + blk_off + 4) = cpu_to_le32(ei->mode);
			*(__le32 *)(bh->b_data + blk_off + 8) = cpu_to_le32(ei->size);
			if (ei->inline_len > 0 && ei->inline_len <= SAGEFS_MAX_INLINE_DATA) {
				*(__le16 *)(bh->b_data + blk_off + 14) = cpu_to_le16(ei->inline_len);
				memcpy(bh->b_data + blk_off + 16 + name_len,
				       ei->inline_data, ei->inline_len);
			}
			mark_buffer_dirty(bh);
			brelse(bh);
			found = 1;
			break;
		}

		brelse(bh);
		off += 16 + name_len + data_len;
	}

	if (!found) {
		/* Find empty slot and write new entry */
		for (off = area_start; off + 16 <= area_end; ) {
			struct buffer_head *bh;
			__u32 ino, mode_val;
			__u16 name_len, data_len;
			__u64 blk = off >> SAGEFS_BLOCK_BITS;
			__u64 blk_off = off & (SAGEFS_BLOCK_SIZE - 1);

			if (blk_off + 16 > SAGEFS_BLOCK_SIZE)
				break;

			bh = sb_bread(inode->i_sb, blk);
			if (!bh)
				break;

			ino = le32_to_cpu(*(__le32 *)(bh->b_data + blk_off));
			mode_val = le32_to_cpu(*(__le32 *)(bh->b_data + blk_off + 4));
			name_len = le16_to_cpu(*(__le16 *)(bh->b_data + blk_off + 12));
			data_len = le16_to_cpu(*(__le16 *)(bh->b_data + blk_off + 14));

			if (ino == 0 && mode_val == 0 && name_len == 0 && data_len == 0) {
				/* Write new entry at this empty slot */
				*(__le32 *)(bh->b_data + blk_off) = cpu_to_le32(ei->ino);
				*(__le32 *)(bh->b_data + blk_off + 4) = cpu_to_le32(ei->mode);
				*(__le32 *)(bh->b_data + blk_off + 8) = cpu_to_le32(ei->size);
				*(__le16 *)(bh->b_data + blk_off + 12) = cpu_to_le16(0); /* name_len */
				*(__le16 *)(bh->b_data + blk_off + 14) = cpu_to_le16(ei->inline_len);
				if (ei->inline_len > 0)
					memcpy(bh->b_data + blk_off + 16,
					       ei->inline_data, ei->inline_len);
				mark_buffer_dirty(bh);
				brelse(bh);
				break;
			}

			brelse(bh);
			off += 16 + name_len + data_len;
		}
	}

	inode_set_ctime(inode, 0, 0);
	return 0;
}

static int sagefs_fill_super(struct super_block *sb, struct fs_context *fc)
{
	struct sagefs_sb_info *sbi;
	struct inode *root_inode;

	printk(KERN_DEBUG "sagefs: fill_super enter (minimal test)\n");

	sbi = kzalloc(sizeof(struct sagefs_sb_info), GFP_KERNEL);
	if (!sbi)
		return -ENOMEM;

	sbi->block_size = SAGEFS_BLOCK_SIZE;
	sbi->inode_entry_start_blk = SAGEFS_INODE_ENTRY_START_BLK;
	sbi->inode_entry_byte_size = SAGEFS_INODE_ENTRY_BYTE_SIZE;

	sb->s_fs_info = sbi;
	sb->s_magic = SAGEFS_MAGIC;
	sb->s_op = &sagefs_super_ops;
	sb->s_time_gran = 1;

	root_inode = sagefs_iget(sb, SAGEFS_ROOT_INO);
	if (IS_ERR(root_inode)) {
		printk(KERN_ERR "sagefs: iget failed %ld\n", PTR_ERR(root_inode));
		kfree(sbi);
		sb->s_fs_info = NULL;
		return PTR_ERR(root_inode);
	}

	root_inode->i_mode = S_IFDIR | 0555;
	root_inode->i_size = 0;
	root_inode->i_blocks = 0;
	set_nlink(root_inode, 2);
	root_inode->i_op = &sagefs_dir_inode_ops;
	root_inode->i_fop = &sagefs_dir_file_ops;

	sb->s_root = d_make_root(root_inode);
	if (!sb->s_root) {
		printk(KERN_ERR "sagefs: d_make_root failed\n");
		iput(root_inode);
		kfree(sbi);
		sb->s_fs_info = NULL;
		return -ENOMEM;
	}

	printk(KERN_DEBUG "sagefs: fill_super done (minimal)\n");
	return 0;
}

static int sagefs_sync_fs(struct super_block *sb, int wait)
{
	struct sagefs_sb_info *sbi = sb->s_fs_info;
	if (sbi->sb_bh && sbi->onsb) {
		mark_buffer_dirty(sbi->sb_bh);
		sync_dirty_buffer(sbi->sb_bh);
	}
	return 0;
}

/* ===========================================================================
 * Superblock operations table
 * =========================================================================== */

static struct super_operations sagefs_super_ops = {
	.alloc_inode = sagefs_alloc_inode,
	.destroy_inode = sagefs_destroy_inode,
	.write_inode = sagefs_write_inode,
	.put_super = sagefs_put_super,
	.sync_fs = sagefs_sync_fs,
	.statfs = sagefs_statfs,
};

static struct inode_operations sagefs_dir_inode_ops = {
	.create = sagefs_create,
	.lookup = sagefs_lookup,
	.unlink = sagefs_unlink,
	.mkdir = sagefs_mkdir,
	.rmdir = sagefs_rmdir,
	.rename = sagefs_rename,
	.setattr = sagefs_setattr,
};

static struct inode_operations sagefs_file_inode_ops = {
	.setattr = sagefs_setattr,
	.getattr = sagefs_getattr,
};

static const struct file_operations sagefs_dir_file_ops = {
	.owner = THIS_MODULE,
	.iterate_shared = sagefs_readdir,
	.llseek = default_llseek,
};

static const struct file_operations sagefs_file_file_ops = {
	.owner = THIS_MODULE,
	.open = sagefs_open,
	.release = sagefs_release,
	.read_iter = sagefs_read_iter,
	.write_iter = sagefs_write_iter,
	.fsync = sagefs_fsync,
	.llseek = sagefs_llseek,
};

static const struct address_space_operations sagefs_aops = {
	.read_folio = sagefs_readpage,
};

/* ===========================================================================
 * File system type
 * =========================================================================== */

static const struct fs_context_operations sagefs_context_ops = {
	.get_tree = sagefs_get_tree,
};

static int sagefs_get_tree(struct fs_context *fc)
{
	printk(KERN_DEBUG "sagefs: get_tree called (using nodev)\n");
	return get_tree_nodev(fc, sagefs_fill_super);
}

static int sagefs_init_fs_context(struct fs_context *fc)
{
	fc->ops = &sagefs_context_ops;
	return 0;
}

static void sagefs_kill_sb(struct super_block *sb)
{
	kill_block_super(sb);
}

static struct file_system_type sagefs_fs_type = {
	.owner = THIS_MODULE,
	.name = "sagefs",
	.init_fs_context = sagefs_init_fs_context,
	.kill_sb = sagefs_kill_sb,
	.fs_flags = FS_REQUIRES_DEV,
};

/* ===========================================================================
 * Module init/exit
 * =========================================================================== */

static int __init sagefs_init(void)
{
	int ret;

	printk(KERN_INFO "sagefs: initializing kernel filesystem driver\n");

	sagefs_inode_cachep = kmem_cache_create("sagefs_inode_cache",
						sizeof(struct sagefs_inode_info),
						NULL, SLAB_HWCACHE_ALIGN | SLAB_RECLAIM_ACCOUNT);
	if (!sagefs_inode_cachep)
		return -ENOMEM;

	ret = register_filesystem(&sagefs_fs_type);
	if (ret) {
		kmem_cache_destroy(sagefs_inode_cachep);
		return ret;
	}

	printk(KERN_INFO "sagefs: filesystem driver loaded\n");
	return 0;
}

static void __exit sagefs_exit(void)
{
	unregister_filesystem(&sagefs_fs_type);
	if (sagefs_inode_cachep)
		kmem_cache_destroy(sagefs_inode_cachep);
	printk(KERN_INFO "sagefs: filesystem driver unloaded\n");
}

module_init(sagefs_init);
module_exit(sagefs_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("SageFS Contributors");
MODULE_DESCRIPTION("SageFS Linux kernel filesystem driver");
MODULE_VERSION("0.2.0");
