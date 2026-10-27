# SPDX-License-Identifier: GPL-2.0
## Framebuffer console — everything written to serial also appears on the
## virtio-gpu display, through a VT terminal model (term/vt) rendered with a
## bitmap font (gfx/). Like Linux fbcon: a basis prerequisite, not policy —
## the GUI terminal *app* (app_server era) reuses the same gfx/term libs.
##
## Writes only update the character grid (cheap, any context); pixels are
## rendered and presented in batches by fbConsoleFlush, called from the
## console's idle loop, so a burst of output costs one small GPU transfer.
## Other tasks keep writing while the shell renders (preemption), so the
## flush renders a snapshot taken with interrupts off — never the live grid.

import ../../core/serial
import ../../drivers/pit
import ../../drivers/virtio/virtio_gpu
import ../../arch/x86_64/cpu_primitives
import ../../gfx/canvas
import ../../gfx/font_spleen8x16
import ../../term/vt
import ../../term/term_render

const FlushEveryTicks = 2'u64          ## at most ~50 presents/s (100 Hz PIT)

var
  gTerm: Term                          # ~190 KB: a global, never on a stack
  gSnap: Term                          # what the renderer draws (see takeSnapshot)
  gView: TermView
  gReady, gPending: bool
  gLastFlush: uint64

proc fbConsolePut(c: char) {.nimcall.} =
  ## serial mirror: grid update with interrupts off (an IRQ handler may log).
  let flags = disableInterrupts()
  gTerm.write(c)
  gPending = true
  restoreInterrupts(flags)

proc takeSnapshot() =
  ## Copy the grid and hand its damage (dirty rows, scroll count) to the
  ## snapshot atomically; writers start a fresh damage record.
  let flags = disableInterrupts()
  gSnap = gTerm
  for y in 0 ..< gTerm.rows: gTerm.dirty[y] = false
  gTerm.scrolled = 0
  gPending = false
  restoreInterrupts(flags)

proc fbConsoleFlush*(force = false) =
  ## Render what changed and show it (rate-limited unless forced).
  if not gReady or not gPending: return
  if not force and pitTicks() - gLastFlush < FlushEveryTicks: return
  takeSnapshot()
  let r = gView.render(gSnap)
  gLastFlush = pitTicks()
  virtioGpuPresentRect(r.x, r.y, r.w, r.h)

proc fbConsoleRedraw*() =
  ## Repaint every cell (after something else drew over the screen).
  for y in 0 ..< gTerm.rows: gTerm.dirty[y] = true
  gPending = true
  fbConsoleFlush(force = true)

proc fbConsoleInit*(): bool =
  ## Attach to the virtio-gpu framebuffer (false if there is no display).
  let fb = virtioGpuFbPtr()
  if fb == nil: return false
  let c = initCanvas(fb, int(gGpu.width), int(gGpu.height))
  let (cols, rows) = gridSize(c, spleen8x16)
  gTerm.initTerm(cols, rows)
  gView.initView(c, spleen8x16)
  c.clear(XtermPalette[DefaultBg])
  gReady = true
  consoleMirror = fbConsolePut
  consoleFlush = proc() {.nimcall.} = fbConsoleFlush(force = true)
  fbConsoleRedraw()
  true

proc fbConsoleActive*(): bool = gReady
