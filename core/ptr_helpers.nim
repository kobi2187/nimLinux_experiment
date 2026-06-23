# SPDX-License-Identifier: GPL-2.0
## Safe pointer helpers — wraps every raw `cast` behind a named operation.
##
## Design rule: each `cast` in the codebase should appear exactly once,
## inside a named proc here, so the dangerous operation is audited once
## rather than repeated with slightly different offsets throughout the code.

# ── Byte buffer views ─────────────────────────────────────────────────────────

proc toBytes*(p: pointer): ptr UncheckedArray[byte] {.inline.} =
  ## View any pointer as a byte array. Caller ensures p is non-nil and len is valid.
  cast[ptr UncheckedArray[byte]](p)

proc toChars*(p: pointer): ptr UncheckedArray[char] {.inline.} =
  ## View any pointer as a char array.
  cast[ptr UncheckedArray[char]](p)

proc copyBytes*(dst: pointer; src: pointer; n: int) {.inline.} =
  ## Copy n bytes from src to dst. Caller ensures non-nil, non-overlapping.
  let d = toBytes(dst)
  let s = toBytes(src)
  for i in 0 ..< n: d[i] = s[i]

proc copyBytesMin*(dst: pointer; dstLen: int; src: pointer; srcLen: int): int {.inline.} =
  ## Copy min(dstLen, srcLen) bytes from src to dst. Returns bytes copied.
  let n = if dstLen < srcLen: dstLen else: srcLen
  copyBytes(dst, src, n)
  n

# ── Address arithmetic ────────────────────────────────────────────────────────

proc ptrAdd*(p: pointer; offset: uint64): pointer {.inline.} =
  ## Advance a pointer by offset bytes.
  cast[pointer](cast[uint64](p) + offset)

proc ptrAddr*(p: pointer): uint64 {.inline.} =
  ## Pointer → integer address.
  cast[uint64](p)

proc readU16At*(p: pointer; offset: uint64): uint16 {.inline.} =
  ## Read a uint16 at p+offset. Named to make ELF field reads self-documenting.
  cast[ptr uint16](cast[uint64](p) + offset)[]

proc readU32At*(p: pointer; offset: uint64): uint32 {.inline.} =
  cast[ptr uint32](cast[uint64](p) + offset)[]

proc readU64At*(p: pointer; offset: uint64): uint64 {.inline.} =
  cast[ptr uint64](cast[uint64](p) + offset)[]

proc writeU64At*(p: pointer; offset: uint64; val: uint64) {.inline.} =
  ## Write a uint64 at p+offset.
  cast[ptr uint64](cast[uint64](p) + offset)[] = val

# ── Proc address capture ──────────────────────────────────────────────────────

proc procAddr*(p: pointer): uint64 {.inline.} =
  ## Capture a proc's address as uint64 for vtable/patch tables.
  cast[uint64](p)

# ── ELF-specific convenience ──────────────────────────────────────────────────

proc elfEType*(data: pointer): uint16 {.inline.} =
  ## Read e_type from an ELF header at offset 16. 2=ET_EXEC, 3=ET_DYN.
  readU16At(data, 16)

proc isPieElf*(data: pointer): bool {.inline.} =
  ## True if the ELF at data is a PIE (ET_DYN).
  elfEType(data) == 3
