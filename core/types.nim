# SPDX-License-Identifier: GPL-2.0
## Foundational types - LAYER 0: No dependencies
##
## This module provides the fundamental types used throughout NimixOS.
## It has zero dependencies and can be imported by any other module.

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Address Types
  # ═══════════════════════════════════════════════════════════════════════════

  PhysAddr* = distinct uint64
    ## Physical memory address - represents actual hardware addresses

  VirtAddr* = distinct uint64
    ## Virtual memory address - used by CPU with paging enabled

  # ═══════════════════════════════════════════════════════════════════════════
  # Page Size Constants
  # ═══════════════════════════════════════════════════════════════════════════

  PageSize* = enum
    ps4K = 4096           ## 4KB pages (standard)
    ps2M = 2097152        ## 2MB huge pages
    ps1G = 1073741824     ## 1GB gigantic pages

const
  FrameSize* = 4096'u64           ## Standard page frame size
  PageShift* = 12                  ## log2(4096)
  HugePageShift* = 21             ## log2(2MB)
  GiantPageShift* = 30            ## log2(1GB)

type
  # ═══════════════════════════════════════════════════════════════════════════
  # Result Type for Error Handling
  # ═══════════════════════════════════════════════════════════════════════════

  Result*[T, E] = object
    ## A type that represents either a successful value or an error.
    ## This is the primary error handling mechanism in NimixOS,
    ## avoiding heap-allocated exceptions.
    case isOk*: bool
    of true:
      value*: T
    of false:
      error*: E

  # Convenience alias for void results
  VoidResult*[E] = Result[void, E]

# ═══════════════════════════════════════════════════════════════════════════
# Result Type Constructors
# ═══════════════════════════════════════════════════════════════════════════

template ok*[T](val: T): untyped =
  ## Create a successful result with a value.
  ## Infers the full Result[T, E] type from the enclosing proc's return type.
  type Res = typeof(result)
  Res(isOk: true, value: val)

template ok*(): untyped =
  ## Create a successful void result.
  ## Infers the full Result[T, E] type from the enclosing proc's return type.
  type Res = typeof(result)
  Res(isOk: true)

template err*[E](e: E): untyped =
  ## Create an error result.
  ## Infers the full Result[T, E] type from the enclosing proc's return type.
  type Res = typeof(result)
  Res(isOk: false, error: e)

func isErr*[T, E](r: Result[T, E]): bool {.inline.} =
  ## Check if result is an error
  not r.isOk

proc get*[T, E](r: Result[T, E]): T {.inline.} =
  ## Get the value, assumes isOk is true
  assert r.isOk, "Attempted to get value from error result"
  r.value

proc getErr*[T, E](r: Result[T, E]): E {.inline.} =
  ## Get the error, assumes isOk is false
  assert not r.isOk, "Attempted to get error from ok result"
  r.error

proc `?`*[T, E](r: Result[T, E]): T =
  ## Propagate error or unwrap value (for use in procs returning Result)
  if r.isOk:
    r.value
  else:
    raise newException(Defect, "Result error propagation failed")

proc `?`*[E](r: Result[void, E]): void =
  ## Propagate error for void results (for use in procs returning Result)
  if not r.isOk:
    raise newException(Defect, "Result error propagation failed")

proc mapErr*[T, E1, E2](r: Result[T, E1], f: proc(e: E1): E2): Result[T, E2] {.inline.} =
  ## Transform the error type of a Result
  if r.isOk:
    when T is void:
      Result[T, E2](isOk: true)
    else:
      Result[T, E2](isOk: true, value: r.value)
  else:
    Result[T, E2](isOk: false, error: f(r.error))

proc map*[T1, T2, E](r: Result[T1, E], f: proc(v: T1): T2): Result[T2, E] {.inline.} =
  ## Transform the value type of a Result
  if r.isOk:
    Result[T2, E](isOk: true, value: f(r.value))
  else:
    Result[T2, E](isOk: false, error: r.error)

# ═══════════════════════════════════════════════════════════════════════════
# Option Type
# ═══════════════════════════════════════════════════════════════════════════

type
  Option*[T] = object
    ## Optional value - either contains a value or is empty
    case isSome*: bool
    of true:
      val*: T
    of false:
      discard

func some*[T](val: T): Option[T] {.inline.} =
  ## Create an Option containing a value
  Option[T](isSome: true, val: val)

func none*[T](): Option[T] {.inline.} =
  ## Create an empty Option
  Option[T](isSome: false)

func none*(T: typedesc): Option[T] {.inline.} =
  ## Create an empty Option (alternative syntax)
  Option[T](isSome: false)

func isNone*[T](o: Option[T]): bool {.inline.} =
  ## Check if option is empty
  not o.isSome

proc get*[T](o: Option[T]): T {.inline.} =
  ## Get the value, assumes isSome is true
  assert o.isSome, "Attempted to get value from None"
  o.val

func getOrDefault*[T](o: Option[T], default: T): T {.inline.} =
  ## Get value or return default if empty
  if o.isSome: o.val else: default

# ═══════════════════════════════════════════════════════════════════════════
# Address Arithmetic
# ═══════════════════════════════════════════════════════════════════════════

# PhysAddr arithmetic
func `+`*(a: PhysAddr, b: uint64): PhysAddr {.inline.} =
  PhysAddr(uint64(a) + b)
func `-`*(a: PhysAddr, b: uint64): PhysAddr {.inline.} =
  PhysAddr(uint64(a) - b)
func `-`*(a, b: PhysAddr): uint64 {.inline.} =
  uint64(a) - uint64(b)
func `==`*(a, b: PhysAddr): bool {.inline.} =
  uint64(a) == uint64(b)
func `<`*(a, b: PhysAddr): bool {.inline.} =
  uint64(a) < uint64(b)
func `<=`*(a, b: PhysAddr): bool {.inline.} =
  uint64(a) <= uint64(b)

# VirtAddr arithmetic
func `+`*(a: VirtAddr, b: uint64): VirtAddr {.inline.} =
  VirtAddr(uint64(a) + b)
func `-`*(a: VirtAddr, b: uint64): VirtAddr {.inline.} =
  VirtAddr(uint64(a) - b)
func `-`*(a, b: VirtAddr): uint64 {.inline.} =
  uint64(a) - uint64(b)
func `==`*(a, b: VirtAddr): bool {.inline.} =
  uint64(a) == uint64(b)
func `<`*(a, b: VirtAddr): bool {.inline.} =
  uint64(a) < uint64(b)
func `<=`*(a, b: VirtAddr): bool {.inline.} =
  uint64(a) <= uint64(b)

# Conversions
func toUint64*(a: PhysAddr): uint64 {.inline.} = uint64(a)
func toUint64*(a: VirtAddr): uint64 {.inline.} = uint64(a)
func toPhysAddr*(a: uint64): PhysAddr {.inline.} = PhysAddr(a)
proc toVirtAddr*(a: uint64): VirtAddr {.inline.} = VirtAddr(a)

# ═══════════════════════════════════════════════════════════════════════════
# Alignment Utilities
# ═══════════════════════════════════════════════════════════════════════════

proc alignUp*(address: uint64, align: uint64): uint64 {.inline.} =
  ## Align address up to the next boundary
  (address + align - 1) and not (align - 1)

proc alignDown*(address: uint64, align: uint64): uint64 {.inline.} =
  ## Align address down to the previous boundary
  address and not (align - 1)

proc isAligned*(address: uint64, align: uint64): bool {.inline.} =
  ## Check if address is aligned
  (address and (align - 1)) == 0

# Address-specific alignment
proc alignUp*(a: PhysAddr, align: uint64): PhysAddr {.inline.} =
  PhysAddr(alignUp(uint64(a), align))

proc alignDown*(a: PhysAddr, align: uint64): PhysAddr {.inline.} =
  PhysAddr(alignDown(uint64(a), align))

proc isAligned*(a: PhysAddr, align: uint64): bool {.inline.} =
  isAligned(uint64(a), align)

proc alignUp*(a: VirtAddr, align: uint64): VirtAddr {.inline.} =
  VirtAddr(alignUp(uint64(a), align))

proc alignDown*(a: VirtAddr, align: uint64): VirtAddr {.inline.} =
  VirtAddr(alignDown(uint64(a), align))

proc isAligned*(a: VirtAddr, align: uint64): bool {.inline.} =
  isAligned(uint64(a), align)

# ═══════════════════════════════════════════════════════════════════════════
# Page/Frame Utilities
# ═══════════════════════════════════════════════════════════════════════════

proc pageAlignUp*(address: uint64): uint64 {.inline.} =
  alignUp(address, FrameSize)

proc pageAlignDown*(address: uint64): uint64 {.inline.} =
  alignDown(address, FrameSize)

proc isPageAligned*(address: uint64): bool {.inline.} =
  isAligned(address, FrameSize)

proc toFrameNumber*(a: PhysAddr): uint64 {.inline.} =
  ## Convert physical address to frame number
  uint64(a) shr PageShift

proc toPhysAddr*(frameNum: uint64): PhysAddr {.inline.} =
  ## Convert frame number to physical address
  PhysAddr(frameNum shl PageShift)

# ═══════════════════════════════════════════════════════════════════════════
# Common Error Types
# ═══════════════════════════════════════════════════════════════════════════

type
  KernelError* = enum
    ## Generic kernel error codes
    keNone = 0
    keOutOfMemory
    keInvalidArgument
    keNotFound
    kePermissionDenied
    keAlreadyExists
    keBusy
    keNotSupported
    keIoError
    keInterrupted
    keTimedOut
    keWouldBlock
    keInvalidState

# ═══════════════════════════════════════════════════════════════════════════
# Bit Manipulation Utilities
# ═══════════════════════════════════════════════════════════════════════════

proc setBit*(value: var uint64, bit: int) {.inline.} =
  value = value or (1'u64 shl bit)

proc clearBit*(value: var uint64, bit: int) {.inline.} =
  value = value and not (1'u64 shl bit)

proc testBit*(value: uint64, bit: int): bool {.inline.} =
  (value and (1'u64 shl bit)) != 0

proc toggleBit*(value: var uint64, bit: int) {.inline.} =
  value = value xor (1'u64 shl bit)

# ═══════════════════════════════════════════════════════════════════════════
# Size Utilities
# ═══════════════════════════════════════════════════════════════════════════

const
  KiB* = 1024'u64
  MiB* = 1024'u64 * KiB
  GiB* = 1024'u64 * MiB
  TiB* = 1024'u64 * GiB

proc toKiB*(bytes: uint64): uint64 {.inline.} = bytes div KiB
proc toMiB*(bytes: uint64): uint64 {.inline.} = bytes div MiB
proc toGiB*(bytes: uint64): uint64 {.inline.} = bytes div GiB

proc toHexImpl(val: uint64): string =
  ## Convert uint64 to hex string (no 0x prefix, lowercase)
  const hexChars = "0123456789abcdef"
  for i in countdown(15, 0):
    let nibble = (val shr (i * 4)) and 0xF
    result.add hexChars[nibble]

proc toHex*(val: SomeUnsignedInt): string =
  ## Convert unsigned integer to lowercase hex string (no prefix)
  ## Strips leading zeros for cleaner output
  let full = toHexImpl(uint64(val))
  # Strip leading zeros
  var i = 0
  while i < full.len - 1 and full[i] == '0':
    inc i
  full[i..^1]
