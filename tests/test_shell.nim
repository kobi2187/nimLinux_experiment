# SPDX-License-Identifier: GPL-2.0
## Tests for shell command parsing — no hardware needed

import ../shell/shell

proc makeInput(s: string): (array[256, char], int) =
  var buf: array[256, char]
  for i in 0..<min(s.len, 255):
    buf[i] = s[i]
  (buf, s.len)

proc testBasicCommands() =
  block:
    let (buf, len) = makeInput("help")
    assert parseCommand(buf, len) == scHelp
  block:
    let (buf, len) = makeInput("version")
    assert parseCommand(buf, len) == scVersion
  block:
    let (buf, len) = makeInput("meminfo")
    assert parseCommand(buf, len) == scMeminfo
  block:
    let (buf, len) = makeInput("clear")
    assert parseCommand(buf, len) == scClear
  block:
    let (buf, len) = makeInput("model")
    assert parseCommand(buf, len) == scModel
  echo "PASS: basic command parsing"

proc testWhitespaceTrimming() =
  block:
    let (buf, len) = makeInput("  help  ")
    assert parseCommand(buf, len) == scHelp
  block:
    let (buf, len) = makeInput("\tversion\n")
    assert parseCommand(buf, len) == scVersion
  echo "PASS: whitespace trimming"

proc testEmptyAndUnknown() =
  block:
    let (buf, len) = makeInput("")
    assert parseCommand(buf, len) == scEmpty
  block:
    var buf: array[256, char]
    assert parseCommand(buf, 0) == scEmpty
  block:
    let (buf, len) = makeInput("notacommand")
    assert parseCommand(buf, len) == scUnknown
  echo "PASS: empty and unknown commands"

when isMainModule:
  testBasicCommands()
  testWhitespaceTrimming()
  testEmptyAndUnknown()
  echo "All shell tests passed."
