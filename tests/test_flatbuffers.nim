# SPDX-License-Identifier: GPL-2.0
## Tests for minimal FlatBuffers builder/reader in kernel/ipc/flatbuffers.nim

import kernel/ipc/flatbuffers
import std/strutils

proc testDispatchMsg() =
  var b: FbBuilder
  fbInit(b)

  # Build DispatchMsg: op=0x02000001, pid=42, class=0 (Realtime), region=3
  # Write fields back-to-front (region last written = first field in layout)
  # Layout (back-to-front): region(i32), class(u8), pid(u32), op(u32)
  fbWriteI32(b, 3'i32)          # region
  fbWriteU8(b, 0'u8)            # class = Realtime
  fbWriteU32(b, 42'u32)         # pid
  fbWriteU32(b, 0x02000001'u32) # op

  let (p, len) = fbData(b)
  assert p != nil, "fbData pointer must be non-nil"
  assert len > 0,  "fbData len must be > 0"
  echo "PASS: fbData returns non-nil pointer, len=", len

  # Set up reader over the written data
  var r: FbReader
  r.data = cast[ptr UncheckedArray[byte]](p)
  r.len  = len

  # Fields are written back-to-front, so reading front-to-back gives them in order:
  # offset 0: op (u32)
  # offset 4: pid (u32)
  # offset 8: class (u8)
  # offset 9: region (i32)
  let op     = fbReadU32(r, 0)
  let pid    = fbReadU32(r, 4)
  let cls    = fbReadU8(r, 8)
  let region = fbReadI32(r, 9)

  assert op == 0x02000001'u32, "op mismatch: " & $op
  echo "PASS: op = 0x", op.toHex
  assert pid == 42'u32, "pid mismatch: " & $pid
  echo "PASS: pid = ", pid
  assert cls == 0'u8, "class mismatch: " & $cls
  echo "PASS: class = ", cls
  assert region == 3'i32, "region mismatch: " & $region
  echo "PASS: region = ", region

testDispatchMsg()
echo "All flatbuffers tests passed."
