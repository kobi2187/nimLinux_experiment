# SPDX-License-Identifier: GPL-2.0
## V7: RUI's counter example, unchanged, rendered headless through the raylib
## bridge (raylib 6.2 memory platform + rlsw) with the Pixie text engine.
## Built direct (in-process raylib) and with -d:rlRemote (draw calls routed
## to commands -> loopback render server). Captures frame 4 and writes it as a binary PPM to argv[1].

import std/[os, strutils, monotimes]
import rui
from raylib import loadImageFromScreen
import "../../vendor/rui2/examples/simple_counter_app"  # buildUI is exported; unchanged

let outPath = if paramCount() >= 1: paramStr(1) else: "rui_counter.ppm"
let app = newApp(title = "Counter", width = 400, height = 300)
app.setRootWidget(buildUI())
let input = newListEventSource()
app.eventSource = input
const
  plusButton = Point(x: 87, y: 108)   # the "+" button's centre at 400x300
  away = Point(x: 300, y: 250)        # empty canvas
proc mouse(kind: EventKind; at = plusButton) =
  input.push GuiEvent(kind: kind, priority: epHigh, timestamp: getMonoTime(),
                      mousePos: at)
var frames = 0
app.onFrame = proc() =
  inc frames
  case frames
  of 8, 18, 28: (mouse(evMouseMove); mouse(evMouseDown))
  of 10, 20, 30: (mouse(evMouseMove); mouse(evMouseUp))
  of 32: mouse(evMouseMove, away)     # hover fades are timed: let them settle
  else: discard
  if frames == 100:
    let shot = loadImageFromScreen()
    var ppm = "P6\n" & $shot.width & " " & $shot.height & "\n255\n"
    let px = cast[ptr UncheckedArray[uint8]](shot.data)
    var ink = 0
    # raylib 6.2 bug: rlsw's swReadPixels is already top-down and rlgl's
    # rlReadScreenPixels flips it again, so rows come back bottom-up.
    for row in countdown(shot.height.int - 1, 0):
      for col in 0 ..< shot.width.int:
        let i = row * shot.width.int + col
        ppm.add char(px[i*4]); ppm.add char(px[i*4+1]); ppm.add char(px[i*4+2])
        if px[i*4].int + px[i*4+1].int + px[i*4+2].int < 300: inc ink
    writeFile(outPath, ppm)
    echo "v7: frame ", frames, " ", shot.width, "x", shot.height, " dark pixels ", ink
app.run(maxFrames = 102)
when defined(rlRemote):
  import ../../bridge/rl_route
  echo "v7 stats: frames=", stats.frames, " syncs=", stats.syncs,
    " last_records=", stats.lastRecords, " last_bytes=", stats.lastBytes,
    " max_records=", stats.maxRecords, " max_bytes=", stats.maxBytes,
    " steady_max_records=", stats.steadyMaxRecords, " steady_max_bytes=", stats.steadyMaxBytes,
    " blob_bytes=", stats.blobBytes
