## all.sage — SageFS full component graph.
##
## Importing every filesystem module here lets `sagevm compile` (the lenient
## backend) bundle and validate the ENTIRE SageFS source tree in one pass,
## which is what `./sagemake build` uses to "build the full filesystem".
## It is not executed directly (the strict `sage` bytecode runtime rejects a
## few class-body field patterns used across the components); the runnable
## entry point is src/mkfs.sage.

import superblock
import segment
import nat
import allocator
import inode
import btree
import dir
import extent
import checksum
import journal
import transaction
import snapshot
import compress
import dedup
import encrypt
import raid
import cache
import aio
import fsck
import mount
import vfs
import fuse
import xattr
import gc
import imgio
