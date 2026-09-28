import vfs
import superblock
import imgio

## read_inode_data() used to cache an inode's content in CacheManager's *block
## address* cache, and nothing ever invalidated it. A read after a write therefore
## returned the content from before that write -- silent read-after-write
## corruption on a block-mapped file.
##
## It also filed file content under an inode number in the same map that
## invalidate_node() treats as block addresses, so the two key spaces shared one
## dict. Content caching now lives in its own bounded dict, and every path that
## changes what read_inode_data() would return calls _invalidate_content().

let passed = 0
let failed = 0

proc check(label: String, got, want):
    if got == want:
        passed = passed + 1
        print("  PASS  " + label)
    else:
        failed = failed + 1
        print("  FAIL  " + label + "  got=" + str(got) + " expected=" + str(want))

proc fresh(dev: String) -> VFS:
    let features: Dict = {"checksum_algo": superblock.CHECKSUM_CRC32C}
    let sb = superblock.create_superblock(4096, "Cache", 4096, 32, features)
    imgio.write_image(dev, sb.serialize())
    let f = vfs.VFS(dev)
    f.mount()
    return f

proc fill(byte_val: Int, n: Int) -> Bytes:
    var b = bytes()
    var i = 0
    while i < n:
        bytes_push(b, byte_val)
        i = i + 1
    return b

## ------------------------------------------------- read-after-write, mapped
print("  --- block-mapped read-after-write ---")
let dev = "/tmp/sagefs_cache.img"
let fs = fresh(dev)
let fd = fs.open("/f.bin", vfs.O_CREAT | vfs.O_RDWR)
fs.write(fd, fill(65, 8192))
fs.close(fd)
let ino = fs.resolve_path("/f.bin")
check("file is block-mapped", fs.inode.get_inode(ino).size, 8192)

let first = fs.read_inode_data(ino)
check("first read sees the written bytes", bytes_get(first, 0), 65)

## Rewrite the whole file with different content, as a user would.
let fd2 = fs.open("/f.bin", vfs.O_WRONLY | vfs.O_TRUNC)
fs.write(fd2, fill(66, 8192))
fs.close(fd2)
let second = fs.read_inode_data(ino)
check("read after rewrite is not stale", bytes_get(second, 0), 66)
check("rewritten length unchanged", bytes_len(second), 8192)
check("last byte also updated", bytes_get(second, 8191), 66)

## An in-place partial write must be visible too.
let fd3 = fs.open("/f.bin", vfs.O_RDWR)
fs.write(fd3, fill(67, 16))
fs.close(fd3)
let third = fs.read_inode_data(ino)
check("partial in-place write visible at offset 0", bytes_get(third, 0), 67)
check("bytes past the partial write unchanged", bytes_get(third, 100), 66)
fs.unmount()

## And the mapping must survive a remount with the same content.
let fs2 = vfs.VFS(dev)
check("remount", fs2.mount(), true)
let ino2 = fs2.resolve_path("/f.bin")
let after = fs2.read_inode_data(ino2)
check("content intact after remount", bytes_get(after, 0), 67)
check("tail intact after remount", bytes_get(after, 8191), 66)
fs2.unmount()

## ------------------------------------------------------ read-after-write, inline
print("  --- inline read-after-write ---")
let dev2 = "/tmp/sagefs_cache2.img"
let fs3 = fresh(dev2)
let fd4 = fs3.open("/small.txt", vfs.O_CREAT | vfs.O_RDWR)
fs3.write(fd4, bytes("first version"))
fs3.close(fd4)
let small_ino = fs3.resolve_path("/small.txt")
check("inline first read", bytes_get(fs3.read_inode_data(small_ino), 0), bytes_get(bytes("first version"), 0))

let fd5 = fs3.open("/small.txt", vfs.O_WRONLY | vfs.O_TRUNC)
fs3.write(fd5, bytes("second version!"))
fs3.close(fd5)
let small2 = fs3.read_inode_data(small_ino)
check("inline read after rewrite is not stale", bytes_get(small2, 0), bytes_get(bytes("second version!"), 0))
check("inline size updated", bytes_len(small2), 15)
fs3.unmount()

## ------------------------------------------------------------------- truncate
print("  --- VFS.truncate() ---")
let dev4 = "/tmp/sagefs_trunc3.img"
let fs4 = fresh(dev4)
let fd6 = fs4.open("/t.bin", vfs.O_CREAT | vfs.O_RDWR)
fs4.write(fd6, fill(88, 8192))

fs4.close(fd6)
let tino = fs4.resolve_path("/t.bin")
let before = fs4.read_inode_data(tino)
check("full read before truncate", bytes_len(before), 8192)

check("truncate to 4096", fs4.truncate("/t.bin", 4096), true)
check("inode size updated", fs4.inode.get_inode(tino).size, 4096)
let after_trunc = fs4.read_inode_data(tino)
check("read reflects the new size", bytes_len(after_trunc), 4096)
check("surviving content unchanged", bytes_get(after_trunc, 0), 88)

check("truncate to 0", fs4.truncate("/t.bin", 0), true)
check("size is zero", fs4.inode.get_inode(tino).size, 0)
check("read is empty", bytes_len(fs4.read_inode_data(tino)), 0)

## Growing is refused rather than zero-filled.
check("growing is refused", fs4.truncate("/t.bin", 4096), false)
check("truncating to the same size is a no-op", fs4.truncate("/t.bin", 0), true)
check("truncating a missing file fails", fs4.truncate("/nope.bin", 0), false)
check("negative size refused", fs4.truncate("/t.bin", -1), false)
fs4.unmount()

## The truncated size must survive a remount.
let fs5 = vfs.VFS(dev4)
check("remount after truncate", fs5.mount(), true)
let tino2 = fs5.resolve_path("/t.bin")
check("truncated size persisted", fs5.inode.get_inode(tino2).size, 0)
fs5.unmount()

## ------------------------------------------------------------------- unlink
print("  --- unlink drops cached content ---")
let dev5 = "/tmp/sagefs_cache3.img"
let fs6 = fresh(dev5)
let fd7 = fs6.open("/gone.txt", vfs.O_CREAT | vfs.O_RDWR)
fs6.write(fd7, fill(90, 5000))
fs6.close(fd7)
let gino = fs6.resolve_path("/gone.txt")
check("cached before unlink", bytes_len(fs6.read_inode_data(gino)), 5000)
check("unlink succeeds", fs6.unlink("/gone.txt"), true)
## Re-create at the same name; if the old content survived in the cache under a
## reused inode number, this would read the previous file's bytes.
let fd8 = fs6.open("/gone.txt", vfs.O_CREAT | vfs.O_RDWR)
fs6.write(fd8, fill(91, 32))
fs6.close(fd8)
let gino2 = fs6.resolve_path("/gone.txt")
check("recreated file does not inherit stale content", bytes_get(fs6.read_inode_data(gino2), 0), 91)
check("recreated file has its own length", bytes_len(fs6.read_inode_data(gino2)), 32)
fs6.unmount()

print("  Results: " + str(passed) + "/" + str(passed + failed) + " passed")
if failed > 0:
    print("  CONTENT CACHE TESTS FAILED")
else:
    print("  ALL CONTENT CACHE TESTS PASSED")
