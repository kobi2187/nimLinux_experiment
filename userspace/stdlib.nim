# SPDX-License-Identifier: GPL-2.0
## NimixOS Standard Library
##
## Standard functions and utilities for user-space applications
## Provides memory, string, I/O, and system call wrappers

import ../core/types
import ./message

# ═══════════════════════════════════════════════════════════════════════════
# Memory Functions - Forth-style decomposition
# ═══════════════════════════════════════════════════════════════════════════

# Simple embedded heap allocator using a free-list strategy
# Real implementation would integrate with kernel allocator via syscalls
var heapStart {.noinit.}: pointer
var heapEnd {.noinit.}: pointer
var nextFree {.noinit.}: pointer

type
  MemHeader = object
    size: uint64          # Size of allocation (including header)
    isFree: bool         # Whether block is free
    next: ptr MemHeader  # Next block in list

# Core operation: mark memory in use
proc mark_used(hdr: ptr MemHeader, size: uint64) =
  ## Mark header as used with given size
  hdr.size = size
  hdr.isFree = false

# Core operation: mark memory free
proc mark_free(hdr: ptr MemHeader) =
  ## Mark header as free
  hdr.isFree = true

# Core operation: get pointer to user data from header
proc header_to_data(hdr: ptr MemHeader): pointer =
  ## Return pointer to data after header
  cast[pointer](cast[uint64](hdr) + sizeof(MemHeader))

# Core operation: get header from data pointer
proc data_to_header(data: pointer): ptr MemHeader =
  ## Return pointer to header before data
  cast[ptr MemHeader](cast[uint64](data) - sizeof(MemHeader))

# Core operation: find contiguous free block
proc find_free_block(size: uint64): ptr MemHeader =
  ## Search free list for block >= size
  var current = cast[ptr MemHeader](heapStart)
  while cast[uint64](current) < cast[uint64](heapEnd):
    if current.isFree and current.size >= size + sizeof(MemHeader):
      return current
    if current.next != nil:
      current = current.next
    else:
      break
  return nil

# Core operation: split block if needed
proc split_block(hdr: ptr MemHeader, requestedSize: uint64) =
  ## Split free block if remainder is large enough
  let remainderSize = hdr.size - requestedSize - sizeof(MemHeader)
  if remainderSize > sizeof(MemHeader):
    let newHdr = cast[ptr MemHeader](cast[uint64](hdr) + requestedSize)
    newHdr.size = remainderSize
    newHdr.isFree = true
    newHdr.next = hdr.next
    hdr.next = newHdr
    hdr.size = requestedSize

proc malloc*(size: uint64): pointer =
  ## Allocate memory block
  # Strategy: Find free block in heap, mark as used, return data pointer
  # If no free block exists, return nil (in real OS would extend heap via syscall)
  if size == 0:
    return nil

  let neededSize = size + sizeof(MemHeader)
  let block = find_free_block(neededSize)
  if block == nil:
    return nil

  mark_used(block, neededSize)
  split_block(block, neededSize)
  return header_to_data(block)

proc free*(ptr: pointer): bool =
  ## Deallocate memory block
  # Strategy: Mark header as free, return to free list
  if ptr == nil:
    return true

  let hdr = data_to_header(ptr)
  mark_free(hdr)
  return true

proc realloc*(ptr: pointer, newSize: uint64): pointer =
  ## Reallocate memory to new size
  # Strategy: If larger, allocate new block and copy. If smaller, just update header.
  if ptr == nil:
    return malloc(newSize)

  let hdr = data_to_header(ptr)
  let oldSize = hdr.size - sizeof(MemHeader)

  if newSize <= oldSize:
    # Shrink or same size - update header, leave extra space as new free block
    hdr.size = newSize + sizeof(MemHeader)
    split_block(hdr, newSize + sizeof(MemHeader))
    return ptr
  else:
    # Grow - allocate new block, copy old data, free old
    let newPtr = malloc(newSize)
    if newPtr != nil:
      memcpy(newPtr, ptr, oldSize)
      discard free(ptr)
    return newPtr

proc calloc*(count: uint64, size: uint64): pointer =
  ## Allocate and zero-initialize memory
  # Strategy: Allocate block then zero-fill entire region
  let totalSize = count * size
  let ptr = malloc(totalSize)
  if ptr != nil:
    memset(ptr, 0, totalSize)
  return ptr

# ─── Byte-level operations (Forth-style: simple, composable) ───

proc byte_copy(dest: pointer, src: pointer, count: uint64) =
  ## Copy bytes one at a time
  # Used by memcpy when overlapping regions not a concern
  var d = cast[ptr uint8](dest)
  var s = cast[ptr uint8](src)
  for i in 0..<count:
    d[i] = s[i]

proc byte_copy_backward(dest: pointer, src: pointer, count: uint64) =
  ## Copy bytes backward to handle overlap
  # Used when source and destination regions overlap
  var d = cast[ptr uint8](dest)
  var s = cast[ptr uint8](src)
  var i = count - 1
  while i >= 0:
    d[i] = s[i]
    if i == 0: break
    i -= 1

proc byte_fill(ptr: pointer, value: uint8, count: uint64) =
  ## Fill memory with byte value
  # Used by memset
  var p = cast[ptr uint8](ptr)
  for i in 0..<count:
    p[i] = value

proc byte_compare(ptr1: pointer, ptr2: pointer, count: uint64): int32 =
  ## Compare memory byte-by-byte
  # Used by memcmp - returns <0, 0, or >0
  var p1 = cast[ptr uint8](ptr1)
  var p2 = cast[ptr uint8](ptr2)
  for i in 0..<count:
    if p1[i] < p2[i]:
      return -1
    elif p1[i] > p2[i]:
      return 1
  return 0

proc memcpy*(dest: pointer, src: pointer, size: uint64) =
  ## Copy memory block (source and dest must not overlap)
  if size == 0 or dest == src:
    return
  byte_copy(dest, src, size)

proc memset*(ptr: pointer, value: uint8, size: uint64) =
  ## Set memory block to value
  if size == 0:
    return
  byte_fill(ptr, value, size)

proc memcmp*(ptr1: pointer, ptr2: pointer, size: uint64): int32 =
  ## Compare memory blocks
  if size == 0 or ptr1 == ptr2:
    return 0
  return byte_compare(ptr1, ptr2, size)

proc memmove*(dest: pointer, src: pointer, size: uint64) =
  ## Move memory block (handles overlapping regions)
  if size == 0 or dest == src:
    return

  # Determine direction based on overlap
  let destAddr = cast[uint64](dest)
  let srcAddr = cast[uint64](src)

  if destAddr > srcAddr and destAddr < srcAddr + size:
    # Destination overlaps source from below - copy backward
    byte_copy_backward(dest, src, size)
  else:
    # No overlap or dest before src - copy forward
    byte_copy(dest, src, size)

# ═══════════════════════════════════════════════════════════════════════════
# String Functions - Forth-style: char-level then string-level operations
# ═══════════════════════════════════════════════════════════════════════════

# ─── Char-level operations (building blocks) ───

proc is_char_in_set(ch: uint8, set: cstring): bool =
  ## Check if character exists in delimiter set
  var p = cast[ptr uint8](set)
  var i = 0
  while i < 256:
    if p[i] == 0:
      break
    if p[i] == ch:
      return true
    i += 1
  return false

proc char_is_digit(ch: uint8): bool =
  ## Check if char is 0-9
  ch >= 48 and ch <= 57

proc char_is_hex(ch: uint8): bool =
  ## Check if char is hex digit
  (ch >= 48 and ch <= 57) or (ch >= 97 and ch <= 102) or (ch >= 65 and ch <= 70)

proc char_to_lower(ch: uint8): uint8 =
  ## Convert char to lowercase
  if ch >= 65 and ch <= 90:
    ch + 32
  else:
    ch

# ─── String-level operations (composed from char operations) ───

proc strlen*(str: cstring): uint64 =
  ## Get string length (count until null terminator)
  # Strategy: Walk pointer until null byte
  var length = 0'u64
  var p = cast[ptr uint8](str)
  while p[length] != 0:
    length += 1
  return length

proc char_at(str: cstring, idx: uint64): uint8 =
  ## Get character at index
  cast[ptr uint8](str)[idx]

proc strdup*(str: cstring): cstring =
  ## Duplicate string (allocate new copy)
  # Strategy: Get length, allocate space, copy bytes
  if str == nil:
    return nil

  let len = strlen(str) + 1
  let newStr = cast[cstring](malloc(len))
  if newStr != nil:
    memcpy(cast[pointer](newStr), cast[pointer](str), len)
  return newStr

proc strcmp*(str1: cstring, str2: cstring): int32 =
  ## Compare strings lexicographically
  # Strategy: Compare char-by-char until difference or null
  if str1 == str2:
    return 0

  var p1 = cast[ptr uint8](str1)
  var p2 = cast[ptr uint8](str2)
  var i = 0
  while p1[i] != 0 and p2[i] != 0:
    if p1[i] < p2[i]:
      return -1
    elif p1[i] > p2[i]:
      return 1
    i += 1

  # One string ended - check if both ended
  if p1[i] == 0 and p2[i] == 0:
    return 0
  elif p1[i] == 0:
    return -1
  else:
    return 1

proc strncmp*(str1: cstring, str2: cstring, n: uint64): int32 =
  ## Compare first n characters of strings
  # Strategy: Same as strcmp but stop at n chars
  if str1 == str2:
    return 0

  var p1 = cast[ptr uint8](str1)
  var p2 = cast[ptr uint8](str2)
  for i in 0..<n:
    if p1[i] == 0 and p2[i] == 0:
      return 0
    if p1[i] != p2[i]:
      if p1[i] < p2[i]:
        return -1
      else:
        return 1
  return 0

proc strcpy*(dest: cstring, src: cstring): cstring =
  ## Copy string to destination
  # Strategy: Copy bytes including null terminator
  if dest == nil or src == nil:
    return dest

  let srcLen = strlen(src) + 1
  memcpy(cast[pointer](dest), cast[pointer](src), srcLen)
  return dest

proc strcat*(dest: cstring, src: cstring): cstring =
  ## Concatenate src onto dest
  # Strategy: Find null in dest, then copy src from there
  if dest == nil or src == nil:
    return dest

  let destLen = strlen(dest)
  let srcLen = strlen(src) + 1
  let destPtr = cast[ptr uint8](dest)
  let srcPtr = cast[ptr uint8](src)

  memcpy(cast[pointer](addr destPtr[destLen]), cast[pointer](srcPtr), srcLen)
  return dest

proc strchr*(str: cstring, ch: uint8): cstring =
  ## Find first occurrence of character
  # Strategy: Walk until char found or null
  if str == nil:
    return nil

  var p = cast[ptr uint8](str)
  var i = 0
  while p[i] != 0:
    if p[i] == ch:
      return cast[cstring](addr p[i])
    i += 1

  # Check for null terminator match
  if ch == 0:
    return cast[cstring](addr p[i])

  return nil

proc strstr*(haystack: cstring, needle: cstring): cstring =
  ## Find first occurrence of substring
  # Strategy: For each position in haystack, try to match needle
  if haystack == nil or needle == nil:
    return nil

  let needleLen = strlen(needle)
  if needleLen == 0:
    return haystack

  var h = cast[ptr uint8](haystack)
  var pos = 0'u64

  while h[pos] != 0:
    # Try to match needle at current position
    if strncmp(cast[cstring](addr h[pos]), needle, needleLen) == 0:
      return cast[cstring](addr h[pos])
    pos += 1

  return nil

var strtok_state {.noinit.}: ptr uint8  # State for strtok
var strtok_len {.noinit.}: uint64        # Length of current token string

proc strtok*(str: cstring, delim: cstring): cstring =
  ## Tokenize string on delimiters (stateful)
  # Strategy: On first call (str != nil), save pointer. On subsequent calls,
  # continue from saved pointer. Return nil when exhausted.
  if delim == nil or strlen(delim) == 0:
    return nil

  var start = strtok_state
  if str != nil:
    start = cast[ptr uint8](str)

  if start == nil or start[0] == 0:
    return nil

  # Skip leading delimiters
  while start[0] != 0 and is_char_in_set(start[0], delim):
    start += 1

  if start[0] == 0:
    strtok_state = nil
    return nil

  # Mark start of token
  let tokenStart = start

  # Find end of token
  while start[0] != 0 and not is_char_in_set(start[0], delim):
    start += 1

  # Store for next call
  strtok_state = start
  if start[0] != 0:
    start[0] = 0  # Null-terminate token (destructive!)
    strtok_state = start + 1

  return cast[cstring](tokenStart)

proc sprintf*(buffer: cstring, format: cstring): int32 =
  ## Format string into buffer (simplified - no argument processing)
  # Strategy: Copy format string as-is (real implementation would handle %d, %s, etc)
  if buffer == nil or format == nil:
    return -1

  let len = strlen(format)
  memcpy(cast[pointer](buffer), cast[pointer](format), len + 1)
  return cast[int32](len)

proc snprintf*(buffer: cstring, size: uint64, format: cstring): int32 =
  ## Format string into buffer with size limit
  # Strategy: Same as sprintf but respect size limit
  if buffer == nil or format == nil or size == 0:
    return -1

  let len = strlen(format)
  let copySize = if len < size - 1: len else: size - 1
  memcpy(cast[pointer](buffer), cast[pointer](format), copySize)
  cast[ptr uint8](buffer)[copySize] = 0
  return cast[int32](copySize)

# ═══════════════════════════════════════════════════════════════════════════
# I/O Functions - Forth-style: syscall wrappers then high-level I/O
# ═══════════════════════════════════════════════════════════════════════════

type
  FILE* = object
    fd*: int32
    flags*: uint16      # O_RDONLY, O_WRONLY, O_RDWR
    buffer*: pointer    # Read/write buffer
    bufSize*: uint64    # Buffer capacity
    bufPos*: uint64     # Current position in buffer
    bufLen*: uint64     # Bytes in buffer
    eof*: bool          # End-of-file reached

# Standard file descriptors
const
  STDIN_FD* = 0
  STDOUT_FD* = 1
  STDERR_FD* = 2

# File open flags (POSIX-compatible)
const
  O_RDONLY* = 0x0000
  O_WRONLY* = 0x0001
  O_RDWR* = 0x0002
  O_APPEND* = 0x0008
  O_CREAT* = 0x0100
  O_TRUNC* = 0x0200

# ─── Core syscall wrappers (low-level I/O) ───

proc syscall_open(path: cstring, flags: int32, mode: int32): int32 =
  ## Open file via syscall - returns fd or -1
  # In real implementation: int SYS_open(const char *path, int flags, mode_t mode)
  # For now, return -1 to indicate not implemented
  -1

proc syscall_close(fd: int32): int32 =
  ## Close file descriptor via syscall
  # In real implementation: int SYS_close(int fd)
  if fd >= 0: 0 else: -1

proc syscall_read(fd: int32, buffer: pointer, count: uint64): int64 =
  ## Read from fd via syscall - returns bytes read
  # In real implementation: ssize_t SYS_read(int fd, void *buf, size_t count)
  -1

proc syscall_write(fd: int32, buffer: pointer, count: uint64): int64 =
  ## Write to fd via syscall - returns bytes written
  # In real implementation: ssize_t SYS_write(int fd, const void *buf, size_t count)
  -1

proc syscall_seek(fd: int32, offset: int64, whence: int32): int64 =
  ## Seek in file via syscall - returns new offset
  # In real implementation: off_t SYS_lseek(int fd, off_t offset, int whence)
  -1

# ─── Buffer management ───

proc init_file_buffer(file: ptr FILE, bufSize: uint64): bool =
  ## Initialize read/write buffer for file
  # Strategy: Allocate buffer, reset positions
  if bufSize == 0:
    bufSize = 4096  # Default buffer size

  let buf = malloc(bufSize)
  if buf == nil:
    return false

  file.buffer = buf
  file.bufSize = bufSize
  file.bufPos = 0
  file.bufLen = 0
  return true

proc flush_write_buffer(file: ptr FILE): int32 =
  ## Flush buffered writes to disk
  # Strategy: If write mode and buffer has data, write to fd
  if file == nil or file.buffer == nil or file.bufLen == 0:
    return 0

  let written = syscall_write(file.fd, file.buffer, file.bufLen)
  if written < 0:
    return -1

  file.bufPos = 0
  file.bufLen = 0
  return 0

proc refill_read_buffer(file: ptr FILE): int32 =
  ## Refill read buffer from disk
  # Strategy: Read from fd into buffer, reset position
  if file == nil or file.buffer == nil:
    return -1

  let bytesRead = syscall_read(file.fd, file.buffer, file.bufSize)
  if bytesRead <= 0:
    if bytesRead == 0:
      file.eof = true
    return cast[int32](bytesRead)

  file.bufPos = 0
  file.bufLen = cast[uint64](bytesRead)
  return 0

# ─── High-level I/O operations ───

proc fopen*(filename: cstring, mode: cstring): ptr FILE =
  ## Open file and return FILE* handle
  # Strategy: Parse mode, call syscall_open, initialize FILE structure
  if filename == nil or mode == nil:
    return nil

  var flags = O_RDONLY
  var creationMode = 0o644  # rw-r--r--

  if mode[0] == 'r' as uint8:
    flags = O_RDONLY
  elif mode[0] == 'w' as uint8:
    flags = O_WRONLY or O_CREAT or O_TRUNC
  elif mode[0] == 'a' as uint8:
    flags = O_WRONLY or O_CREAT or O_APPEND

  let fd = syscall_open(filename, flags, creationMode)
  if fd < 0:
    return nil

  let filePtr = cast[ptr FILE](malloc(sizeof(FILE)))
  if filePtr == nil:
    discard syscall_close(fd)
    return nil

  filePtr.fd = fd
  filePtr.flags = cast[uint16](flags)
  filePtr.eof = false

  if not init_file_buffer(filePtr, 4096):
    discard syscall_close(fd)
    discard free(filePtr)
    return nil

  return filePtr

proc fclose*(file: ptr FILE): int32 =
  ## Close file and release resources
  # Strategy: Flush buffers, close fd, free FILE structure
  if file == nil:
    return -1

  var result = 0

  if (file.flags and O_WRONLY) != 0:
    result = flush_write_buffer(file)

  if syscall_close(file.fd) < 0:
    result = -1

  if file.buffer != nil:
    discard free(file.buffer)

  discard free(file)
  return result

proc fread*(buffer: pointer, size: uint64, count: uint64, file: ptr FILE): uint64 =
  ## Read count items of size bytes from file
  # Strategy: Fill buffer as needed, deliver bytes from buffer
  if buffer == nil or file == nil or size == 0 or count == 0:
    return 0

  let totalNeeded = size * count
  var bytesRead = 0'u64

  while bytesRead < totalNeeded:
    if file.bufPos >= file.bufLen:
      # Need to refill buffer
      if refill_read_buffer(file) < 0 or file.eof:
        break

    let avail = file.bufLen - file.bufPos
    let remaining = totalNeeded - bytesRead
    let toCopy = if avail < remaining: avail else: remaining

    if toCopy == 0:
      break

    memcpy(cast[pointer](cast[uint64](buffer) + bytesRead),
           cast[pointer](cast[uint64](file.buffer) + file.bufPos),
           toCopy)

    bytesRead += toCopy
    file.bufPos += toCopy

  return bytesRead div size

proc fwrite*(buffer: pointer, size: uint64, count: uint64, file: ptr FILE): uint64 =
  ## Write count items of size bytes to file
  # Strategy: Write to buffer, flush when full
  if buffer == nil or file == nil or size == 0 or count == 0:
    return 0

  let totalToWrite = size * count
  var bytesWritten = 0'u64

  while bytesWritten < totalToWrite:
    let avail = file.bufSize - file.bufLen
    let remaining = totalToWrite - bytesWritten
    let toWrite = if avail < remaining: avail else: remaining

    if toWrite == 0:
      # Buffer full, flush it
      if flush_write_buffer(file) < 0:
        break
      continue

    memcpy(cast[pointer](cast[uint64](file.buffer) + file.bufLen),
           cast[pointer](cast[uint64](buffer) + bytesWritten),
           toWrite)

    bytesWritten += toWrite
    file.bufLen += toWrite

  return bytesWritten div size

proc fseek*(file: ptr FILE, offset: int64, whence: int32): int32 =
  ## Seek to position in file
  # Strategy: Flush write buffer, call syscall_seek
  if file == nil:
    return -1

  if (file.flags and O_WRONLY) != 0:
    if flush_write_buffer(file) < 0:
      return -1

  # Reset read buffer
  file.bufPos = 0
  file.bufLen = 0
  file.eof = false

  let newOffset = syscall_seek(file.fd, offset, whence)
  if newOffset < 0:
    return -1

  return 0

proc ftell*(file: ptr FILE): uint64 =
  ## Get current position in file
  # Strategy: Call syscall_seek(0, SEEK_CUR) to get position
  if file == nil:
    return 0

  let pos = syscall_seek(file.fd, 0, SEEK_CUR)
  if pos < 0:
    return 0

  # Adjust for buffered data
  if (file.flags and O_WRONLY) != 0:
    return cast[uint64](pos) + file.bufLen
  else:
    return cast[uint64](pos) - file.bufLen + file.bufPos

proc fgets*(buffer: cstring, size: int32, file: ptr FILE): cstring =
  ## Read line from file into buffer
  # Strategy: Read char-by-char until newline or size limit
  if buffer == nil or file == nil or size <= 0:
    return nil

  var pos = 0
  let maxChars = size - 1

  while pos < maxChars:
    let nRead = fread(addr buffer[pos], 1, 1, file)
    if nRead == 0:
      break

    if buffer[pos] == '\n':
      pos += 1
      break

    pos += 1

  buffer[pos] = '\0'

  if pos == 0:
    return nil

  return buffer

proc fputs*(str: cstring, file: ptr FILE): int32 =
  ## Write string to file
  # Strategy: Get string length, call fwrite
  if str == nil or file == nil:
    return -1

  let len = strlen(str)
  let written = fwrite(cast[pointer](str), 1, len, file)

  if written == len:
    return cast[int32](len)
  else:
    return -1

# ─── Standard I/O shortcuts ───

proc printf*(format: cstring): int32 =
  ## Print formatted string to stdout
  # Strategy: For now, just print the format string as-is
  # Real implementation would handle % format specifiers
  if format == nil:
    return -1

  let len = strlen(format)
  let written = syscall_write(STDOUT_FD, cast[pointer](format), len)
  return if written < 0: -1 else: cast[int32](written)

proc puts*(str: cstring): int32 =
  ## Print string to stdout with newline
  # Strategy: Write string, write newline
  if str == nil:
    return -1

  let len = strlen(str)
  discard syscall_write(STDOUT_FD, cast[pointer](str), len)
  let newline = "\n"
  let nlWritten = syscall_write(STDOUT_FD, cast[pointer](newline), 1)

  if nlWritten > 0:
    return cast[int32](len + 1)
  else:
    return -1

proc getchar*(): int32 =
  ## Read character from stdin
  # Strategy: Read 1 byte from stdin
  var ch: uint8
  let nRead = syscall_read(STDIN_FD, addr ch, 1)

  if nRead <= 0:
    return EOF
  else:
    return cast[int32](ch)

proc putchar*(ch: uint8): int32 =
  ## Write character to stdout
  # Strategy: Write 1 byte to stdout
  var byte = ch
  let nWrite = syscall_write(STDOUT_FD, addr byte, 1)

  if nWrite <= 0:
    return EOF
  else:
    return cast[int32](ch)

# ═══════════════════════════════════════════════════════════════════════════
# Math Functions - Simple implementations, well-tested algorithms
# ═══════════════════════════════════════════════════════════════════════════

proc abs*(x: int32): int32 =
  ## Absolute value
  if x < 0: -x else: x

proc min*(a: uint64, b: uint64): uint64 =
  ## Minimum value
  if a < b: a else: b

proc max*(a: uint64, b: uint64): uint64 =
  ## Maximum value
  if a > b: a else: b

proc pow*(base: float, exp: float): float =
  ## Power function using exponentiation by squaring
  # Strategy: Handle special cases (exp=0, base=1, negative exp)
  # Then use binary exponentiation for efficiency
  if exp == 0.0:
    return 1.0
  if base == 1.0 or base == 0.0:
    return base
  if exp < 0.0:
    return 1.0 / pow(base, -exp)

  var result = 1.0
  var b = base
  var e = exp

  while e > 0.0:
    if cast[int64](e) mod 2 == 1:
      result *= b
    b *= b
    e /= 2.0

  return result

proc sqrt_newton(x: float): float =
  ## Square root using Newton's method
  # Strategy: Iterative refinement: x_{n+1} = (x_n + a/x_n) / 2
  if x < 0.0:
    return 0.0
  if x == 0.0 or x == 1.0:
    return x

  var guess = x
  var prev: float
  var iterations = 0

  # Iterate until convergence
  while iterations < 20:
    prev = guess
    guess = (guess + x / guess) / 2.0

    # Check for convergence (difference small enough)
    let diff = if guess > prev: guess - prev else: prev - guess
    if diff < 0.00001:
      break

    iterations += 1

  return guess

proc sqrt*(x: float): float =
  ## Square root using Newton iteration
  sqrt_newton(x)

# ═══════════════════════════════════════════════════════════════════════════
# System Call Wrappers - Architecture: Make syscalls to kernel
# ═══════════════════════════════════════════════════════════════════════════

# Syscall numbers for x86_64 (matching NimixOS syscall dispatcher)
const
  SYS_exit* = 60
  SYS_fork* = 57
  SYS_read* = 0
  SYS_write* = 1
  SYS_open* = 2
  SYS_close* = 3
  SYS_seek* = 8
  SYS_getpid* = 39
  SYS_sleep* = 35
  SYS_execve* = 59
  SYS_brk* = 12

# ─── Low-level syscall invocation ───

proc do_syscall1(num: uint64, arg1: uint64): uint64 {.inline.} =
  ## Make syscall with 1 argument via rax/rdi
  # Real x86_64 ABI: rax=syscall#, rdi=arg1, rsi=arg2, rdx=arg3, r10=arg4, r8=arg5, r9=arg6
  # In Nim, we'd use inline assembly or a syscall stub in ASM
  # For now: placeholder
  0

proc do_syscall2(num: uint64, arg1: uint64, arg2: uint64): uint64 {.inline.} =
  ## Make syscall with 2 arguments
  0

proc do_syscall3(num: uint64, arg1: uint64, arg2: uint64, arg3: uint64): uint64 {.inline.} =
  ## Make syscall with 3 arguments
  0

# ─── High-level syscall wrappers ───

proc exit*(code: int32): int32 =
  ## Exit process (does not return)
  # Strategy: Call SYS_exit syscall with exit code
  # The kernel will terminate this process
  discard do_syscall1(SYS_exit, cast[uint64](code))
  return 0  # Never reached

proc getpid*(): uint32 =
  ## Get current process ID
  # Strategy: Call SYS_getpid syscall, returns PID
  let pid = do_syscall1(SYS_getpid, 0)
  return cast[uint32](pid)

proc sleep*(seconds: uint32): int32 =
  ## Sleep for seconds
  # Strategy: Call SYS_sleep (or use nanosleep with seconds * 1e9)
  # In NimixOS, we use the timer interrupt to track sleep
  let result = do_syscall1(SYS_sleep, cast[uint64](seconds))
  return if result == 0: 0 else: -1

proc usleep*(microseconds: uint32): int32 =
  ## Sleep for microseconds
  # Strategy: Similar to sleep but microsecond granularity
  # Would need to call into timer system
  let milliseconds = microseconds div 1000
  if milliseconds > 0:
    return sleep(milliseconds div 1000)
  return 0

# ─── Environment variables (in-process storage) ───

var envTable {.noinit.}: array[32, tuple[name: cstring, value: cstring]]
var envCount = 0

proc getenv*(name: cstring): cstring =
  ## Get environment variable
  # Strategy: Linear search through environment table
  if name == nil:
    return nil

  for i in 0..<envCount:
    if strcmp(envTable[i].name, name) == 0:
      return envTable[i].value

  return nil

proc setenv*(name: cstring, value: cstring): int32 =
  ## Set environment variable
  # Strategy: Search for existing, update or add new
  if name == nil:
    return -1

  # Try to find existing
  for i in 0..<envCount:
    if strcmp(envTable[i].name, name) == 0:
      envTable[i].value = value
      return 0

  # Add new if space available
  if envCount < 32:
    envTable[envCount].name = name
    envTable[envCount].value = value
    envCount += 1
    return 0

  return -1

proc system*(command: cstring): int32 =
  ## Execute shell command
  # Strategy: Fork, exec shell with -c command, wait for result
  # This is a complex operation requiring fork/exec/wait
  # For now: return error (not implemented)
  if command == nil:
    return -1
  return -1

proc fork*(): int32 =
  ## Fork process (create child)
  # Strategy: Call SYS_fork syscall
  # Returns child PID in parent, 0 in child, -1 on error
  let result = do_syscall1(SYS_fork, 0)
  return cast[int32](result)

proc exec*(path: cstring): int32 =
  ## Execute program (replace current process)
  # Strategy: Call SYS_execve with path and no arguments
  # This does not return on success
  if path == nil:
    return -1

  let result = do_syscall3(SYS_execve, cast[uint64](path), 0, 0)
  return cast[int32](result)

# ═══════════════════════════════════════════════════════════════════════════
# Message/Port Functions - Integrated with message.nim port system
# ═══════════════════════════════════════════════════════════════════════════

proc send_message*(port: uint32, what: uint32, arg1: int32, arg2: int32): bool =
  ## Send message to port (delegates to message.nim)
  # Strategy: Package message and send via port system
  # In real impl: Would create a Message struct and call sendMessage from message.nim
  # For now: Returns false (not fully connected)
  false

proc receive_message*(port: uint32): tuple[what: uint32, arg1: int32, arg2: int32] =
  ## Receive message from port (delegates to message.nim)
  # Strategy: Block until message available, return message contents
  # In real impl: Would call getMessage from message.nim
  (0, 0, 0)

proc get_port*(name: cstring): uint32 =
  ## Get port by name (look up in port registry)
  # Strategy: Query the port registry for named port
  # Returns port ID if found, 0 if not found
  if name == nil:
    return 0
  # In real impl: Would query port registry
  0

proc create_port*(capacity: uint32): uint32 =
  ## Create new port with given capacity
  # Strategy: Allocate new port, return port ID
  # In real impl: Would allocate port from port registry
  if capacity == 0:
    return 0
  # Returns new port ID (non-zero)
  1

# ─── Port registry (simple implementation) ───

var portRegistry {.noinit.}: array[16, tuple[name: cstring, portId: uint32]]
var portCount = 0

proc register_port*(name: cstring, portId: uint32): bool =
  ## Register a named port in registry
  # Strategy: Add to registry if space available
  if name == nil or portCount >= 16:
    return false

  portRegistry[portCount].name = name
  portRegistry[portCount].portId = portId
  portCount += 1
  return true

proc unregister_port*(name: cstring): bool =
  ## Unregister named port
  # Strategy: Find and remove from registry
  if name == nil:
    return false

  for i in 0..<portCount:
    if strcmp(portRegistry[i].name, name) == 0:
      # Shift remaining entries
      for j in i..<portCount-1:
        portRegistry[j] = portRegistry[j+1]
      portCount -= 1
      return true

  return false

# ═══════════════════════════════════════════════════════════════════════════
# File System Functions - Syscall wrappers for file operations
# ═══════════════════════════════════════════════════════════════════════════

const
  SYS_mkdir* = 83
  SYS_rmdir* = 84
  SYS_unlink* = 87
  SYS_rename* = 82
  SYS_stat* = 4

# ─── Directory operations ───

proc mkdir*(path: cstring, mode: uint16): int32 =
  ## Create directory
  # Strategy: Call SYS_mkdir syscall
  if path == nil:
    return -1

  let result = do_syscall2(SYS_mkdir, cast[uint64](path), cast[uint64](mode))
  return cast[int32](result)

proc rmdir*(path: cstring): int32 =
  ## Remove directory
  # Strategy: Call SYS_rmdir syscall
  if path == nil:
    return -1

  let result = do_syscall1(SYS_rmdir, cast[uint64](path))
  return cast[int32](result)

# ─── File operations ───

proc unlink*(path: cstring): int32 =
  ## Remove file
  # Strategy: Call SYS_unlink syscall
  if path == nil:
    return -1

  let result = do_syscall1(SYS_unlink, cast[uint64](path))
  return cast[int32](result)

proc rename*(oldpath: cstring, newpath: cstring): int32 =
  ## Rename file
  # Strategy: Call SYS_rename syscall
  if oldpath == nil or newpath == nil:
    return -1

  let result = do_syscall2(SYS_rename, cast[uint64](oldpath), cast[uint64](newpath))
  return cast[int32](result)

type
  Stat* = object
    size*: uint64
    mode*: uint16
    uid*: uint32
    gid*: uint32
    mtime*: uint64

proc stat*(path: cstring): uint64 =
  ## Get file stat (returns size or 0)
  # Strategy: Call SYS_stat and extract size field
  # Full implementation would return Stat structure
  if path == nil:
    return 0

  # Simplified: just return file size if available
  # Real impl: Would populate Stat struct and return it
  0

# ═══════════════════════════════════════════════════════════════════════════
# Error Functions - Error code to message mapping
# ═══════════════════════════════════════════════════════════════════════════

# Error codes (POSIX)
const
  ENOENT* = 2    # No such file or directory
  EACCES* = 13   # Permission denied
  EINVAL* = 22   # Invalid argument
  ENOMEM* = 12   # Out of memory
  EBUSY* = 16    # Device or resource busy

# ─── Error message lookup ───

proc error_message(code: int32): cstring =
  ## Get error message for code
  # Strategy: Simple lookup table
  case code
  of ENOENT: return "No such file or directory"
  of EACCES: return "Permission denied"
  of EINVAL: return "Invalid argument"
  of ENOMEM: return "Out of memory"
  of EBUSY: return "Device or resource busy"
  else: return "Unknown error"

proc perror*(msg: cstring) =
  ## Print error message to stderr
  # Strategy: Print message, colon, system error message
  if msg != nil:
    discard syscall_write(STDERR_FD, cast[pointer](msg), strlen(msg))
    discard syscall_write(STDERR_FD, cast[pointer](": "), 2)

  let errMsg = error_message(-1)  # Would use errno here
  discard syscall_write(STDERR_FD, cast[pointer](errMsg), strlen(errMsg))
  discard syscall_write(STDERR_FD, cast[pointer]("\n"), 1)

proc strerror*(error: int32): cstring =
  ## Get error message string
  # Strategy: Look up error code in message table
  return error_message(error)

# ═══════════════════════════════════════════════════════════════════════════
# Utility Macros / Constants
# ═══════════════════════════════════════════════════════════════════════════

const
  SEEK_SET* = 0
  SEEK_CUR* = 1
  SEEK_END* = 2
  EOF* = -1
  NULL* = nil
