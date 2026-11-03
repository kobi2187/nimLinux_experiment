# SPDX-License-Identifier: GPL-2.0
## hello — a regular NimixOS app, written in Nim, running as WASM.

import ../nimix_wasm

nimixWasmMain:
  var words = @["Hello", "from", "a", "Nim", "WASM", "app"]
  var line = ""
  for w in words: line.add(w & " ")
  write(line & "on NimixOS!\n")
  exitApp(0)
