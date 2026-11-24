# Device ports (K3) — the typed front door to a device module

Status: **layers 1-4 BUILT 2026-11-17 for the input port** (`ipc/ports/`, `kernel/ports/`, evdev decoder, consumers, attack test). Human chose Option 2 (typed port) on
2026-11-16. Kernel glue and the input device are the next layers (below). Mechanism M2 of `core_design.md`.

## What a port is
The one official way to use a device module (the hardware-facing code). Rules, each enforced by the code:

| rule | how it is enforced |
|------|--------------------|
| **typed**: a closed set of operations and events per device | enums; every handler/decoder is an exhaustive `case` (a new operation does not compile until handled) |
| **no pointers, no shared memory across it** | `putPayload/getPayload` are generic with `static: doAssert supportsCopyMem(T)` and a size bound: a payload with a pointer or string does not compile |
| **exclusive**: one holder at a time | `portBind` makes an `okPortClient` object with **no duplicate right**; a second bind is `psBusy`; moving the handle keeps it exclusive; the holder's death (last close) frees the port (`portOnDestroyed`); `checkInvariants` states "a port has more than one holder" |
| **written once, two transports** | `Link` (client) and `Emitter`/`serve` (device) over `tkDirect` (a procedure call, device linked in) or `tkMessage` (a channel); one `Handler` is the device module in both; one test scenario runs unchanged over both |
| **bounded, never blocks the device** | one request outstanding per link; events: when a queue is full the **newest is lost** and the next event that fits is preceded by an in-band `Lost{count}` (reserved op `0xFFFF`) so the client can resync |
| **hostile bytes are refused whole** | `fromWire` validates class, status, length; a malformed message is counted (`malformed`), never acted on |

## Files
`ipc/ports/port.nim` (wire message, status codes, payloads, Lost, exclusive binding, invariants) ·
`ipc/ports/input_port.nim` (the input port: `InputOp` = info/flush; `InputEvent` = key/motion/button/wheel/lost) ·
`ipc/ports/link.nim` (the two transports behind one client API) · `tests/test_ports.nim`.

## Decisions made while building (reversible, inside the boundary)
- **One request outstanding per link** (psBusy otherwise). Pipelining/batching is a later leaf; replies stay unambiguous.
- **Lost-newest with an in-band marker**, not drop-oldest. Found because the first version dropped OLDEST in the
  direct transport but NEWEST over a full channel: the client could not even see the loss. One rule for both.
- **Replies are never starved by events**: when the client's ring is full while it drains the channel, the
  newest events are counted and announced (client-side), so a reply behind them is still read.
- Port message = exactly one channel message (12-byte header + 244 payload); bulk data uses buffers (later).

## Layers 2-4 (DONE for input; see DECISIONS 2026-11-17 K3 layers 2-4). The plan they followed:
2. **Kernel glue** (`kernel/ports/kports.nim`): a `PortRegistry` beside `gHs/gCh`, the destroy hook calls
   `portOnDestroyed`, a spawn grant `input` in the manifest resolves to `portBind` of the input port, syscalls
   for the message transport (request/reply/event use the existing channel calls; only `bind` is new).
3. **The input device module** behind the port: the virtio-input driver emits `InputEvent`s through an `Emitter`
   instead of publishing the `input` topic; the focused-window server (or, for now, the shell) is the single client.
4. **The attacking test** (ring 3): a "keylogger" program started beside the real client gets nothing and cannot
   bind; the client gets every key; killing the client frees the port. Then retire the `input` topic (S3b, part).

## What this does not decide
How the device module is *placed* (kernel or server) per kernel model: that is the residency map and a measured
choice; the port is what makes it a one-line change. The contract/IDL (K1) will generate what is hand-written here.

## Display port and screen capture (design record; build blocked on D3 and the render server)
**Decided 2026-11-17 (human: "Yes, option A")**: whole-screen capture is a right held only by the compositor
(the render server). The user triggers it with a key chord that only the holder of the input port can see; the
image goes to the app the user chooses as a sealed read-only buffer; an app may capture its OWN window (it owns
that buffer). No manifest name grants whole-screen capture. Today no call can read the screen back (the display
calls are info/present/modes/set-mode), and other apps' memory is isolated, so nothing needs closing now; the
overlay hole (first present wins) is closed by the display port, which waits on D3 (who may own the display).

## Wire format (human, 2026-11-24)
Services use MsgPack. Device ports keep the fixed packed records described here, by decision ("keep the current home-made
format"): their messages are made in interrupt context where nothing may allocate, and a fixed layout needs no encoding. The C
side is generated from the Nim types (K1), so the home-made format is written down once, in Nim. A new port that is not hot and
not in interrupt context should start from MsgPack.
