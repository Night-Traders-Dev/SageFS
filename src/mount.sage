## mount.sage — SageFS Mount Helper with Journal Replay
##
## Entry point for mounting a SageFS image.  Reads the superblock,
## initialises all subsystems, replays the journal, cleans orphans,
## wires everything into the VFS, and hands off to the FUSE daemon.
##
## Usage:
##   sage --runtime bytecode -I src mount.sage <image> [mountpoint]
##
## At runtime the VFS layer calls into the existing core engine modules
## (superblock, segment, inode, journal, transaction, dir, btree, etc.)
## to service POSIX filesystem operations forwarded by the FUSE bridge.
##
## FFI Integration:
##   When SageVM FFI is available, this module initializes a native
##   FUSE session via libfuse3 and registers handlers directly.
##   Otherwise, it falls back to the Python FUSE bridge.

import sys
import cli_args
import imgio
import superblock
import segment as seg_module
import nat as nat_module
import allocator as alloc_module
import inode as inode_module
import btree as btree_module
import extent as extent_module
import dir as dir_module
import aio as aio_module
import cache as cache_module
import journal as journal_module
import transaction as txn_module
import fsgc as gc_module
import snapshot as snap_module
import compress as compress_module
import dedup as dedup_module
import encrypt as encrypt_module
import raid as raid_module
import xattr as xattr_module
import vfs
import fsimage
import fuse

## mount — Full mount flow
##
## Reads the image, deserializes the superblock, initializes every
## subsystem, replays the journal, detects and cleans orphan inodes,
## and returns a fully-wired vfs.VFS instance.
proc main():
    ## Take the program's own arguments rather than indexing sys.args()
    ## directly: argv[0] is the interpreter interpreted and the binary
    ## compiled, and neither is a program argument. This filter used to drop
    ## only the "src" and .sage leftovers, which left argv[0] in place -- so
    ## once compiled binaries reported it, mount.sage took the binary path as
    ## the device and failed on a superblock magic for a file it never opened.
    let args: Array[String] = cli_args.program_args(sys.args())

    if len(args) < 2:
        print("Usage: mount.sage <image> <mountpoint>")
        return

    let dev: String = args[0]
    let mountpoint: String = args[1]
    ## A mountpoint is not optional. Without one there is nothing to mount on,
    ## and the old code fell through to an event loop reading a device with no
    ## filesystem attached to it.
    let fs: vfs.VFS = fsimage.mount(dev)
    if fs == nil:
        print("SageFS: mount failed")
        return

    print("SageFS: mounted " + dev + " — entering FUSE loop on " + mountpoint)
    fuse.fuse_run(fs, mountpoint)

main()
