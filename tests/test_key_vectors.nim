# SPDX-License-Identifier: GPL-2.0
## The golden key vectors (tests/libnimix/key_vectors.txt) must still equal the Nim keymap
## (input/evdev_keymap.nim, the authority). The C side (libnimix/nimix_keymap.h, used by the
## raylib platform) is checked against the same file by tests/libnimix/test_keymap.c, so a
## change to either keymap forces regenerating the vectors, and the other side then fails
## until it matches. Regenerate: nim c -r tests/libnimix/gen_key_vectors.nim > <that file>
import std/[strutils, parseutils]
import ../input/evdev_keymap

const Vectors = staticRead("libnimix/key_vectors.txt")

proc testVectors() =
  var n = 0
  for line in Vectors.splitLines:
    if line.len == 0 or line[0] == '#': continue
    let f = line.splitWhitespace
    assert f.len == 3, "vector line: " & line
    let code = parseInt(f[0])
    let flags = parseInt(f[1])
    let want = parseInt(f[2])
    var ks: KeyState
    if (flags and 1) != 0: discard ks.keyToChar(42, 1)
    if (flags and 2) != 0: discard ks.keyToChar(58, 1)
    if (flags and 4) != 0: discard ks.keyToChar(29, 1)
    assert ks.keyToChar(uint16(code), 1) == want, "key vector: " & line
    inc n
  assert n == 1024, "128 codes x 8 modifier combinations"
  echo "PASS: ", n, " key vectors still equal the Nim keymap"

when isMainModule:
  testVectors()
  echo "All key vector tests passed."
