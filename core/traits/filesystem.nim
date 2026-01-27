# SPDX-License-Identifier: GPL-2.0
## Filesystem trait - LAYER 0
##
## Defines the interfaces that any filesystem implementation must provide.
## Based on VFS concepts similar to Linux's VFS layer.

import ../types

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Filesystem Errors
  # ═══════════════════════════════════════════════════════════════════════════

  FsError* = enum
    ## Filesystem operation errors
    fsOk = 0
    fsNotFound           ## File or directory not found
    fsPermissionDenied   ## Permission denied
    fsNoSpace            ## No space left on device
    fsIoError            ## I/O error
    fsInvalidPath        ## Invalid path
    fsNotDirectory       ## Expected directory, got file
    fsIsDirectory        ## Expected file, got directory
    fsBusy               ## Resource busy
    fsExists             ## File already exists
    fsNotEmpty           ## Directory not empty
    fsReadOnly           ## Read-only filesystem
    fsInvalidOp          ## Invalid operation
    fsTooManyLinks       ## Too many symbolic links
    fsNameTooLong        ## Filename too long
    fsNoSuchDev          ## No such device
    fsInvalid            ## Invalid argument

  # ═══════════════════════════════════════════════════════════════════════════
  # Inode Types
  # ═══════════════════════════════════════════════════════════════════════════

  InodeType* = enum
    ## Type of filesystem object
    itFile       ## Regular file
    itDirectory  ## Directory
    itSymlink    ## Symbolic link
    itBlockDev   ## Block device
    itCharDev    ## Character device
    itFifo       ## Named pipe (FIFO)
    itSocket     ## Unix domain socket

  # ═══════════════════════════════════════════════════════════════════════════
  # File Mode and Permissions
  # ═══════════════════════════════════════════════════════════════════════════

  FileMode* = distinct uint32
    ## File mode including type and permissions

const
  # File type bits
  S_IFMT*: FileMode   = 0o170000.FileMode  ## Mask for file type
  S_IFSOCK*: FileMode = 0o140000.FileMode  ## Socket
  S_IFLNK*: FileMode  = 0o120000.FileMode  ## Symbolic link
  S_IFREG*: FileMode  = 0o100000.FileMode  ## Regular file
  S_IFBLK*: FileMode  = 0o060000.FileMode  ## Block device
  S_IFDIR*: FileMode  = 0o040000.FileMode  ## Directory
  S_IFCHR*: FileMode  = 0o020000.FileMode  ## Character device
  S_IFIFO*: FileMode  = 0o010000.FileMode  ## FIFO

  # Permission bits
  S_ISUID*: FileMode  = 0o004000.FileMode  ## Set-user-ID
  S_ISGID*: FileMode  = 0o002000.FileMode  ## Set-group-ID
  S_ISVTX*: FileMode  = 0o001000.FileMode  ## Sticky bit

  S_IRWXU*: FileMode  = 0o000700.FileMode  ## User rwx
  S_IRUSR*: FileMode  = 0o000400.FileMode  ## User read
  S_IWUSR*: FileMode  = 0o000200.FileMode  ## User write
  S_IXUSR*: FileMode  = 0o000100.FileMode  ## User execute

  S_IRWXG*: FileMode  = 0o000070.FileMode  ## Group rwx
  S_IRGRP*: FileMode  = 0o000040.FileMode  ## Group read
  S_IWGRP*: FileMode  = 0o000020.FileMode  ## Group write
  S_IXGRP*: FileMode  = 0o000010.FileMode  ## Group execute

  S_IRWXO*: FileMode  = 0o000007.FileMode  ## Other rwx
  S_IROTH*: FileMode  = 0o000004.FileMode  ## Other read
  S_IWOTH*: FileMode  = 0o000002.FileMode  ## Other write
  S_IXOTH*: FileMode  = 0o000001.FileMode  ## Other execute

proc `or`*(a, b: FileMode): FileMode {.inline.} =
  FileMode(uint32(a) or uint32(b))

proc `and`*(a, b: FileMode): FileMode {.inline.} =
  FileMode(uint32(a) and uint32(b))

type
  # ═══════════════════════════════════════════════════════════════════════════
  # File Statistics
  # ═══════════════════════════════════════════════════════════════════════════

  Stat* = object
    ## File statistics (similar to struct stat)
    dev*: uint64           ## Device ID
    ino*: uint64           ## Inode number
    mode*: FileMode        ## File mode
    nlink*: uint32         ## Number of hard links
    uid*: uint32           ## User ID
    gid*: uint32           ## Group ID
    rdev*: uint64          ## Device ID (if special file)
    size*: int64           ## Total size in bytes
    blksize*: int64        ## Block size for I/O
    blocks*: int64         ## Number of 512B blocks
    atime*: int64          ## Access time (nanoseconds)
    mtime*: int64          ## Modification time (nanoseconds)
    ctime*: int64          ## Status change time (nanoseconds)

  StatFs* = object
    ## Filesystem statistics
    fsType*: uint64        ## Filesystem type
    blockSize*: uint64     ## Optimal transfer block size
    totalBlocks*: uint64   ## Total blocks
    freeBlocks*: uint64    ## Free blocks
    availBlocks*: uint64   ## Available blocks (non-superuser)
    totalInodes*: uint64   ## Total inodes
    freeInodes*: uint64    ## Free inodes
    fsId*: uint64          ## Filesystem ID
    maxNameLen*: uint64    ## Maximum filename length

  # ═══════════════════════════════════════════════════════════════════════════
  # Forward Declarations
  # ═══════════════════════════════════════════════════════════════════════════

  Inode* = ref object of RootObj
    ## Represents a filesystem object (file, directory, etc.)
    ino*: uint64           ## Inode number
    mode*: FileMode        ## File type and permissions
    nlink*: uint32         ## Link count
    uid*: uint32           ## Owner user ID
    gid*: uint32           ## Owner group ID
    size*: int64           ## Size in bytes
    atime*: int64          ## Access time
    mtime*: int64          ## Modification time
    ctime*: int64          ## Change time
    ops*: ptr InodeOps     ## Operations
    fileOps*: ptr FileOps  ## File operations
    superBlock*: SuperBlock ## Parent superblock
    private*: pointer      ## Filesystem-private data

  Dentry* = ref object
    ## Directory entry - cached name-to-inode mapping
    name*: array[256, char]  ## Entry name
    nameLen*: int            ## Length of name
    inode*: Inode            ## Associated inode
    parent*: Dentry          ## Parent directory
    children*: seq[Dentry]   ## Child entries (if directory)
    mounted*: SuperBlock     ## Mounted filesystem (if mount point)
    refCount*: int           ## Reference count

  File* = ref object
    ## Open file handle
    dentry*: Dentry        ## Associated dentry
    inode*: Inode          ## Associated inode
    pos*: int64            ## Current file position
    flags*: uint32         ## Open flags
    mode*: FileMode        ## Access mode
    private*: pointer      ## Driver-private data

  SuperBlock* = ref object of RootObj
    ## Filesystem superblock
    fsType*: FilesystemType  ## Filesystem type
    blockSize*: uint64       ## Block size
    maxFileSize*: int64      ## Maximum file size
    root*: Dentry            ## Root dentry
    flags*: uint32           ## Mount flags
    ops*: ptr SuperOps       ## Operations
    private*: pointer        ## Filesystem-private data

  # ═══════════════════════════════════════════════════════════════════════════
  # Operation Tables
  # ═══════════════════════════════════════════════════════════════════════════

  InodeOps* = object
    ## Operations on inodes
    lookup*: proc(dir: Inode, name: cstring, nameLen: int): Result[Dentry, FsError] {.nimcall.}
    create*: proc(dir: Inode, name: cstring, nameLen: int, mode: FileMode): Result[Inode, FsError] {.nimcall.}
    mkdir*: proc(dir: Inode, name: cstring, nameLen: int, mode: FileMode): Result[Inode, FsError] {.nimcall.}
    unlink*: proc(dir: Inode, name: cstring, nameLen: int): Result[void, FsError] {.nimcall.}
    rmdir*: proc(dir: Inode, name: cstring, nameLen: int): Result[void, FsError] {.nimcall.}
    rename*: proc(oldDir: Inode, oldName: cstring, oldLen: int,
                  newDir: Inode, newName: cstring, newLen: int): Result[void, FsError] {.nimcall.}
    symlink*: proc(dir: Inode, name: cstring, nameLen: int, target: cstring): Result[Inode, FsError] {.nimcall.}
    readlink*: proc(inode: Inode, buf: pointer, bufLen: int): Result[int, FsError] {.nimcall.}
    link*: proc(oldDentry: Dentry, dir: Inode, name: cstring, nameLen: int): Result[void, FsError] {.nimcall.}
    getattr*: proc(inode: Inode): Result[Stat, FsError] {.nimcall.}
    setattr*: proc(inode: Inode, stat: Stat, mask: uint32): Result[void, FsError] {.nimcall.}
    truncate*: proc(inode: Inode, size: int64): Result[void, FsError] {.nimcall.}

  FileOps* = object
    ## Operations on open files
    read*: proc(file: File, buf: pointer, count: int, offset: int64): Result[int, FsError] {.nimcall.}
    write*: proc(file: File, buf: pointer, count: int, offset: int64): Result[int, FsError] {.nimcall.}
    llseek*: proc(file: File, offset: int64, whence: int): Result[int64, FsError] {.nimcall.}
    ioctl*: proc(file: File, cmd: uint32, arg: uint64): Result[int, FsError] {.nimcall.}
    mmap*: proc(file: File, vma: pointer): Result[void, FsError] {.nimcall.}
    open*: proc(inode: Inode, file: File): Result[void, FsError] {.nimcall.}
    flush*: proc(file: File): Result[void, FsError] {.nimcall.}
    release*: proc(file: File): Result[void, FsError] {.nimcall.}
    fsync*: proc(file: File, datasync: bool): Result[void, FsError] {.nimcall.}
    readdir*: proc(file: File, callback: proc(name: cstring, nameLen: int, ino: uint64, dtype: uint8): bool): Result[void, FsError] {.nimcall.}
    poll*: proc(file: File, wait: pointer): uint32 {.nimcall.}

  SuperOps* = object
    ## Superblock operations
    statfs*: proc(sb: SuperBlock): Result[StatFs, FsError] {.nimcall.}
    sync*: proc(sb: SuperBlock): Result[void, FsError] {.nimcall.}
    remount*: proc(sb: SuperBlock, flags: uint32, data: pointer): Result[void, FsError] {.nimcall.}
    unmount*: proc(sb: SuperBlock): Result[void, FsError] {.nimcall.}
    allocInode*: proc(sb: SuperBlock): Result[Inode, FsError] {.nimcall.}
    freeInode*: proc(sb: SuperBlock, inode: Inode): Result[void, FsError] {.nimcall.}
    writeInode*: proc(sb: SuperBlock, inode: Inode): Result[void, FsError] {.nimcall.}
    dropInode*: proc(sb: SuperBlock, inode: Inode) {.nimcall.}

  # ═══════════════════════════════════════════════════════════════════════════
  # Filesystem Type Registration
  # ═══════════════════════════════════════════════════════════════════════════

  FilesystemType* = ref object
    ## Filesystem type registration
    name*: array[32, char]   ## Filesystem name
    flags*: uint32           ## Filesystem flags
    mount*: proc(source: cstring, flags: uint32, data: pointer): Result[SuperBlock, FsError] {.nimcall.}
    next*: FilesystemType    ## Linked list of filesystem types

# ═══════════════════════════════════════════════════════════════════════════
# Filesystem Type Flags
# ═══════════════════════════════════════════════════════════════════════════

const
  FS_REQUIRES_DEV*     = 1'u32    ## Requires block device
  FS_NO_DCACHE*        = 2'u32    ## Don't use dentry cache
  FS_NO_ICACHE*        = 4'u32    ## Don't use inode cache
  FS_RENAME_DOES_D_MOVE* = 8'u32  ## Filesystem handles dentry move

# ═══════════════════════════════════════════════════════════════════════════
# Open Flags
# ═══════════════════════════════════════════════════════════════════════════

const
  O_RDONLY*   = 0x0000'u32
  O_WRONLY*   = 0x0001'u32
  O_RDWR*     = 0x0002'u32
  O_ACCMODE*  = 0x0003'u32
  O_CREAT*    = 0x0040'u32
  O_EXCL*     = 0x0080'u32
  O_NOCTTY*   = 0x0100'u32
  O_TRUNC*    = 0x0200'u32
  O_APPEND*   = 0x0400'u32
  O_NONBLOCK* = 0x0800'u32
  O_DSYNC*    = 0x1000'u32
  O_SYNC*     = 0x101000'u32
  O_DIRECTORY* = 0x10000'u32
  O_NOFOLLOW* = 0x20000'u32
  O_CLOEXEC*  = 0x80000'u32

# ═══════════════════════════════════════════════════════════════════════════
# Seek Whence
# ═══════════════════════════════════════════════════════════════════════════

const
  SEEK_SET* = 0  ## Seek from beginning
  SEEK_CUR* = 1  ## Seek from current position
  SEEK_END* = 2  ## Seek from end

# ═══════════════════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════════════════

proc isFile*(mode: FileMode): bool {.inline.} =
  (mode and S_IFMT) == S_IFREG

proc isDir*(mode: FileMode): bool {.inline.} =
  (mode and S_IFMT) == S_IFDIR

proc isSymlink*(mode: FileMode): bool {.inline.} =
  (mode and S_IFMT) == S_IFLNK

proc isBlockDev*(mode: FileMode): bool {.inline.} =
  (mode and S_IFMT) == S_IFBLK

proc isCharDev*(mode: FileMode): bool {.inline.} =
  (mode and S_IFMT) == S_IFCHR

proc isFifo*(mode: FileMode): bool {.inline.} =
  (mode and S_IFMT) == S_IFIFO

proc isSocket*(mode: FileMode): bool {.inline.} =
  (mode and S_IFMT) == S_IFSOCK

proc getInodeType*(mode: FileMode): InodeType =
  let typ = mode and S_IFMT
  if typ == S_IFREG: itFile
  elif typ == S_IFDIR: itDirectory
  elif typ == S_IFLNK: itSymlink
  elif typ == S_IFBLK: itBlockDev
  elif typ == S_IFCHR: itCharDev
  elif typ == S_IFIFO: itFifo
  elif typ == S_IFSOCK: itSocket
  else: itFile  # Default to file
