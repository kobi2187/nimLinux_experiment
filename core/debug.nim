# SPDX-License-Identifier: GPL-2.0
## Debug Utilities - LAYER 0
##
## Self-contained debug output routines using inline assembly serial I/O.
## Zero dependencies — usable at any point during boot, even before NimMain.
##
## These functions write directly to COM1 serial port via x86 IN/OUT
## instructions. They are safe to call from any context including
## bootloader parsing, memory init, etc.

# ═══════════════════════════════════════════════════════════════════════════
# Early Serial Output (inline asm, no dependencies)
# ═══════════════════════════════════════════════════════════════════════════

const Com1Data* = 0x3F8'u16
const Com1Status* = 0x3FD'u16  # 0x3F8 + 5

proc earlyPutChar*(c: char) {.inline.} =
  ## Write a single character to COM1 via inline assembly.
  ## Safe to call before any initialization.
  ## Handles \n → \r\n translation.
  var lsr: uint8
  # Wait for THR empty (bit 5 of LSR)
  while true:
    {.emit: ["asm volatile(\"inb %1, %0\" : \"=a\"(", lsr, ") : \"Nd\"(", Com1Status, "));"].}
    if (lsr and 0x20'u8) != 0:
      break
  # Write the character
  {.emit: ["asm volatile(\"outb %0, %1\" :: \"a\"(", uint8(c), "), \"Nd\"(", Com1Data, "));"].}
  # Auto-\r\n
  if c == '\n':
    while true:
      {.emit: ["asm volatile(\"inb %1, %0\" : \"=a\"(", lsr, ") : \"Nd\"(", Com1Status, "));"].}
      if (lsr and 0x20'u8) != 0:
        break
    {.emit: ["asm volatile(\"outb %0, %1\" :: \"a\"(", uint8('\r'), "), \"Nd\"(", Com1Data, "));"].}

proc earlyPutString*(s: cstring) {.inline.} =
  ## Write a C string to COM1.
  var i = 0
  while s[i] != '\0':
    earlyPutChar(s[i])
    inc i

proc earlyPutHex*(val: uint64) =
  ## Write a 64-bit value as hexadecimal to COM1 (e.g., "0x1234ABCD").
  const hexChars = "0123456789abcdef"
  earlyPutChar('0')
  earlyPutChar('x')
  var found = false
  for i in countdown(15, 0):
    let nibble = (val shr (i * 4)) and 0xF
    if nibble != 0 or found or i == 0:
      found = true
      earlyPutChar(hexChars[int(nibble)])

proc earlyPutHexFixed*(val: uint64, digits: int) =
  ## Write hex with fixed width (zero-padded), WITHOUT "0x" prefix.
  const hexChars = "0123456789abcdef"
  for i in countdown(digits - 1, 0):
    let nibble = (val shr (i * 4)) and 0xF
    earlyPutChar(hexChars[int(nibble)])

proc earlyPutInt*(val: int64) =
  ## Write a decimal integer to COM1.
  if val < 0:
    earlyPutChar('-')
    earlyPutInt(-val)
    return
  var buf: array[20, char]
  var v = val
  var i = 0
  if v == 0:
    earlyPutChar('0')
    return
  while v > 0:
    buf[i] = char(ord('0') + int(v mod 10))
    v = v div 10
    inc i
  while i > 0:
    dec i
    earlyPutChar(buf[i])

# ═══════════════════════════════════════════════════════════════════════════
# Hex Dump Utilities
# ═══════════════════════════════════════════════════════════════════════════

proc earlyDumpHex*(address: pointer, len: int, label: cstring = nil) =
  ## Dump raw memory as hex bytes + ASCII, using early serial output.
  ##
  ## Output format (similar to hexdump -C):
  ##   [label]
  ##   DEADB000  48 65 6C 6C 6F 20 57 6F  72 6C 64 00 00 00 00 00  Hello World.....
  ##   DEADB010  ...
  ##
  if label != nil and label[0] != '\0':
    earlyPutString(label)
    earlyPutString("\n")

  let base = cast[uint64](address)
  var i = 0
  while i < len:
    # Print address offset
    earlyPutHex(uint64(i))
    earlyPutString("  ")

    # Print hex bytes (16 per row)
    var j = 0
    while j < 16 and i + j < len:
      let byteVal = cast[ptr uint8](base + uint64(i + j))[]
      earlyPutHexFixed(uint64(byteVal), 2)
      earlyPutString(" ")
      if j == 7:
        earlyPutString(" ")
      inc j

    # Pad for incomplete last row
    while j < 16:
      earlyPutString("   ")
      if j == 7:
        earlyPutString(" ")
      inc j

    # Print ASCII representation
    earlyPutString(" |")
    j = 0
    while j < 16 and i + j < len:
      let byteAddr = base + uint64(i + j)
      let ch = char(cast[ptr uint8](byteAddr)[])
      if ch >= ' ' and ch <= '~':
        earlyPutChar(ch)
      else:
        earlyPutChar('.')
      inc j
    earlyPutString("|\n")

    i += 16

proc earlyDumpDwords*(address: pointer, count: int, label: cstring = nil) =
  ## Dump memory as 32-bit hex values.
  if label != nil and label[0] != '\0':
    earlyPutString(label)
    earlyPutString("\n")

  let base = cast[uint64](address)
  for i in 0..<count:
    let val = cast[ptr uint32](base + uint64(i * 4))[]
    earlyPutString("  [")
    earlyPutInt(i * 4)
    earlyPutString("] 0x")
    earlyPutHexFixed(uint64(val), 8)
    earlyPutString("\n")

proc earlyDumpQwords*(address: pointer, count: int, label: cstring = nil) =
  ## Dump memory as 64-bit hex values.
  if label != nil and label[0] != '\0':
    earlyPutString(label)
    earlyPutString("\n")

  let base = cast[uint64](address)
  for i in 0..<count:
    let val = cast[ptr uint64](base + uint64(i * 8))[]
    earlyPutString("  [")
    earlyPutInt(i * 8)
    earlyPutString("] 0x")
    earlyPutHexFixed(uint64(val), 16)
    earlyPutString("\n")

# ═══════════════════════════════════════════════════════════════════════════
# Multiboot2-Specific Dump
# ═══════════════════════════════════════════════════════════════════════════

proc earlyDumpMultiboot2Info*(address: pointer) =
  ## Dump Multiboot2 information structure header.
  ##
  ## Structure layout:
  ##   offset 0: total_size (uint32)
  ##   offset 4: reserved   (uint32)
  ##   offset 8: first tag  ...
  ##
  let base = cast[uint64](address)
  earlyPutString("=== Multiboot2 Info Structure ===\n")
  earlyPutString("  Address:     ")
  earlyPutHex(cast[uint64](address))
  earlyPutString("\n")
  earlyPutString("  total_size:  ")
  earlyPutHex(uint64(cast[ptr uint32](base)[]))
  earlyPutString(" (")
  earlyPutInt(int64(cast[ptr uint32](base)[]))
  earlyPutString(" bytes)\n")
  earlyPutString("  reserved:    ")
  earlyPutHex(uint64(cast[ptr uint32](base + 4)[]))
  earlyPutString("\n")
  earlyPutString("  First tag at: ")
  earlyPutHex(cast[uint64](address) + 8)
  earlyPutString("\n")

  # Dump first 64 bytes raw
  earlyPutString("  Raw bytes (64):\n")
  earlyDumpHex(address, 64, nil)

proc earlyDumpMultiboot2Tag*(tagPtr: pointer, index: int) =
  ## Dump a single Multiboot2 tag header.
  let base = cast[uint64](tagPtr)
  let tagType = cast[ptr uint32](base)[]
  let tagSize = cast[ptr uint32](base + 4)[]
  earlyPutString("  Tag #")
  earlyPutInt(index)
  earlyPutString(": type=")
  earlyPutHex(uint64(tagType))
  earlyPutString(" size=")
  earlyPutHex(uint64(tagSize))
  earlyPutString(" (")
  earlyPutInt(int64(tagSize))
  earlyPutString(" bytes)")
  if tagType == 0:
    earlyPutString(" [END]")
  elif tagType == 1:
    earlyPutString(" [CMDLINE]")
  elif tagType == 2:
    earlyPutString(" [BOOTLOADER_NAME]")
  elif tagType == 4:
    earlyPutString(" [MEMORY_INFO]")
  elif tagType == 6:
    earlyPutString(" [MEMORY_MAP]")
  elif tagType == 8:
    earlyPutString(" [FRAMEBUFFER]")
  elif tagType == 9:
    earlyPutString(" [ELF_SECTIONS]")
  elif tagType == 17:
    earlyPutString(" [RSDP]")
  earlyPutString("\n")
