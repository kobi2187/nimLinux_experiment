# SPDX-License-Identifier: GPL-2.0
## Incremental UTF-8 decoding — bytes arrive one at a time (a terminal sees
## a character stream), so the decoder is a tiny state machine. Malformed
## input yields U+FFFD and decoding resynchronises on the next byte.

const Replacement* = 0xFFFD'u32

type
  Utf8Decoder* = object
    cp: uint32      ## codepoint bits gathered so far
    need: int       ## continuation bytes still expected

  Utf8Step* = object
    ready*: bool    ## a codepoint is complete
    cp*: uint32
    again*: bool    ## the byte was not consumed: feed it once more

func leadBits(b: uint32): tuple[need: int; bits: uint32] {.inline.} =
  if b < 0x80: (0, b)
  elif (b and 0xE0) == 0xC0: (1, b and 0x1F)
  elif (b and 0xF0) == 0xE0: (2, b and 0x0F)
  elif (b and 0xF8) == 0xF0: (3, b and 0x07)
  else: (-1, 0'u32)

proc feed*(d: var Utf8Decoder; c: char): Utf8Step =
  let b = uint32(c)
  if d.need > 0:
    if (b and 0xC0) != 0x80:                 # sequence cut short
      d.need = 0
      return Utf8Step(ready: true, cp: Replacement, again: true)
    d.cp = (d.cp shl 6) or (b and 0x3F)
    dec d.need
    return Utf8Step(ready: d.need == 0, cp: d.cp)
  let (need, bits) = leadBits(b)
  if need < 0: return Utf8Step(ready: true, cp: Replacement)
  d.need = need
  d.cp = bits
  Utf8Step(ready: need == 0, cp: bits)

iterator utf8Codepoints*(s: openArray[char]): uint32 =
  var d: Utf8Decoder
  var i = 0
  while i < s.len:
    let st = d.feed(s[i])
    if st.ready: yield st.cp
    if not st.again: inc i
  if d.need > 0: yield Replacement          # truncated at the end
