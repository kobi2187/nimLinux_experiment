# BACKLOG.md — Dependency Tree of Tasks

Source of truth is **taskwarrior** (`task list project:nimixos`). This file is the
structured view — parents hold intent, leaves are executable. Layer tags encode
dependency order: layer0 must complete before layer1, etc.

Tags: CLEAR = path obvious | FUZZY = outcome known, path uncertain | OPEN = undecidable yet | PARENT = not executable directly | SPAWN = own sub-project

---

## ROADMAP v2 (2026-11-14) — structure first. Where this disagrees with the sections below, v2 wins.

Order of work: from what **must** work exactly one way (everything assumes it) down to what has leeway.
Layers are defined in ARCHITECTURE.md §0. Proposals: `docs/proposals/core_design.md`,
`capabilities.md`, `render_server_v6.md`. Items marked SCAFFOLD work today but are stubs to stand on:
replace them, never copy their shape.

### Dependency tree

```
L1 STRUCTURE
 S1 handle tables+rights ──┬─ S2 channels, badges, peer-closed ──┬─ S3 spawn with handles + launcher policy
   (buffers fold in)       │                                     │     (removes ambient: chanSend, topics,
                           │                                     │      first-present display)
 S4 wait/wake + timers ────┼─────────────────────────────────────┤
 S5 rings + small-buffer lane (buffers: DONE, host rings DONE)   │
 S6 charging + death cleanup ────────────────────────────────────┤
 S7 syscall gate checks (DONE) ── shrinks as S3/K-layer replace calls
 S8 memory isolation depth (DECISION) ── under S1's guarantees
L2 CONTRACTS                                                     │
 K1 contract format → SDK/server stubs ──────────────────────────┤
 K2 dispatcher Stage 2 (sessions, discovery, QoS fields, correlation)  needs S1 S2 S3 K1
 K3 device-port interface (queue-shaped, priority hints)               needs S1 S2 S5
L3 DEVICE MODULES (driver DONE in kernel; each gains a port)           needs K3
 M1 display   M2 input   M3 block   M4 net   M5 sound
L4 DOMAIN SERVERS
 V1 render server (V6 slices)   needs K2 K3 S4 S5 M1 M2
 V2 file server, lent buffers   needs K2 K3 M3
 V3 console + terminal client   needs V1 M2   V4 audio  needs K3 M5   V5 net stack  needs K3 M4
L5 CLIENTS
 C1 SDKs (libnimix, bridge)   C2 userspace WASM host (V8)   C3 RUI apps   C4 benchmark (V9)   C5 desktop
```

### Status

| id | item | layer | status | depends | done-check |
|----|------|-------|--------|---------|-----------|
| S1 | per-task handle tables, rights, duplicate (narrow only), move, close-all (`ipc/handles/handle_table.nim`) | L1 | **DONE (library, host-tested; kernel integration TODO)** | — | property tests; no forged handle succeeds; lookup benchmark |
| S2 | channel endpoint pairs, handle transfer, badges, peer-closed (`ipc/handles/channel.nim`) | L1 | **DONE (library, host-tested; kernel integration TODO)** | S1 | badge = sending handle's badge; transfer moves; no leaks |
| S2k | kernel integration of S1+S2: syscalls over handles (41-46), spawn-time bootstrap grant, task-death release | L1 | **PARTIAL: channels and handles live in the kernel and are tested from ring 3 (`chan-handles`, `abi-hostile`); the buffers table is NOT yet folded in** | S1 S2 | fold buffers (S2k-b): one table for every object kind |
| S3 | `spawn(image, handles[])`, launcher policy file; remove ambient chanSend/topics/display race | L1 | PARTIAL: a spawner can give a child its bootstrap handle (shell `chantest`); no spawn syscall or policy file yet, ambient calls still present | S2k | a program given nothing can do nothing; a keylogger test gets nothing |
| S4 | block-on-wake, wake from IRQ, sub-tick timer (V2c) | L1 | TODO | S2k | idle server uses no wakeups; latency probe |
| S5 | buffers (arena, owned/sealed/move/lend, per-block rights) | L1 | **DONE** | — | `make test-devices` buffers-* |
| S5b | ring syscalls + small-buffer lane (every buffer costs a 2 MB block today) | L1 | TODO (host ring DONE) | S2k | 1 kernel call per batch; command buffers stop costing 2 MB |
| S6 | budgets follow ownership (buffers DONE; handles, channels, sessions not charged); death releases everything (tasks' buffers, display, input DONE; handle tables TODO) | L1 | PARTIAL | S1 | no resource outlives its owner (leak test) |
| S7 | syscall pointer-argument checks at the gate (V14), hostile-args program | L1 | **DONE (interim: shrinks as calls become handle operations)** | — | `abi-hostile` |
| S8 | memory isolation underneath: regions and buffers enforced per task today; per-task address spaces (Stage B) undecided | L1 | **DECISION** | — | human, capabilities.md §6.3 |
| S9 | ring 3, user windows, crash reports, FPU safety, user faults kill the task | L1 | **DONE** | — | structured + device suites |
| K1 | one contract per service; generated server stub, SDK and validation; versioning | L2 | TODO (proposed) | — | contract round-trip test; open question #3 |
| K2 | dispatcher Stage 2 | L2 | PARTIAL (Stage 1 actor loop + strict decode DONE; not in the app path) | S1 S2 S3 K1 | request/reply through it; session brokering; QoS fields end to end |
| K3 | device-port interface | L2 | TODO | S1 S2 S5b | two transports (direct call, message), same client code |
| M1 | display device module | L3 | driver DONE (kernel), modes DONE; port TODO; today SCAFFOLD (direct syscalls) | K3 | single-client bind; second client refused |
| M2 | input device module | L3 | driver DONE (all virtio-input devices); port TODO; SCAFFOLD (`input` topic) | K3 | keylogger test app gets nothing |
| M3-5 | block, net, sound modules | L3 | drivers DONE; ports TODO | K3 | per module |
| V1 | render server (V6 slices V6-0..g) | L4 | TODO (proposal) | K2 K3 S4 S5b M1 M2 | pixel-equal windows, hostile client refused |
| V2 | file server with lent buffers (+ directory scopes) | L4 | SCAFFOLD (ELF exists, calls kernel FS) | K2 K3 M3 | path escape fails |
| V3 | console server + terminal client | L4 | SCAFFOLD (kernel console/shell) | V1 M2 | typing in a window runs shell commands |
| V4, V5 | audio server, network stack server | L4 | TODO | K3 M5 / M4 | per server |
| C1 | SDKs: libnimix, raylib bridge (direct + remote host-tested), `PLATFORM_NIMIX` | L5 | libnimix/PLATFORM_NIMIX SCAFFOLD (direct kernel calls); bridge DONE (host) | K1 | apps unchanged when calls become contracts |
| C2 | userspace WASM host (V8) | L5 | TODO (wasm3 is kernel-resident) | S5b K2 | counter app runs in the ELF host |
| C3-C5 | RUI apps (V7c/d), benchmark (V9), desktop/launcher | L5 | TODO | C2 V1 | per task |

### Libraries finished and useful whatever the architecture
tsc clock + time page; keymap; term/vt, gfx, fonts; display checks and modes; syscall argument table
(`user_args`); bump heap (`sip_heap`); buffers state, arena and rings; `mpsc_ring`; the CPS actor and
dispatcher logic (priority queue, QoS policy, strict wire decode); picolibc build; libnimix; the raylib
bridge (direct and remote); the pointer and keymap helpers; the handle table and channel library (S1, S2).

### Counts
Done as designed (structure): S1 S2 (libraries) S5 S7 S9. Scaffold to replace: 10 items (ARCHITECTURE §0).
Left: S2k S3 S4 S5b S6 S8 K1 K2 K3 M ports V1-V5 C2-C5.

---

## Layer 0 — Foundation (execute now)

| TW# | Tag | Description | Done-check |
|-----|-----|-------------|-----------|
| 48 | CLEAR | Syscall gate: real ring-3 transition — save/restore regs, dispatch through ABI vtable (23 calls), return in RAX | apps run in ring 3; hello.elf syscall reaches handler |
| 37 | CLEAR | CI: GitHub Actions — build all 3 kernel models + make test + make test-qemu on push | green CI badge |

## Layer 1 — Drivers (unblock layer 2)

| TW# | Tag | Description | Done-check |
|-----|-----|-------------|-----------|
| 49 | CLEAR | PS/2 mouse driver: decode 3/4-byte protocol, publish mouse.move/mouse.click to event_server | mouse events appear in event log |
| 50 | CLEAR | RTC driver: read CMOS date/time (ports 0x70/0x71), expose nimixUptime + nimixWallClock | nimixWallClock() returns correct time in shell |

## Layer 2 — MM safety + network primitives

| TW# | Tag | Description | Done-check |
|-----|-----|-------------|-----------|
| 4 | CLEAR | Guard pages: unmapped page before/after each app region | app buffer overflow triggers page fault, not silent corruption |
| 51 | CLEAR | virtio-blk driver: replace ATA PIO diskio.c with proper virtqueue requests (spec 5.2, ~150 LOC) | disk read/write via virtio-blk passes test |
| 52 | CLEAR | ARP: send/receive request/reply, maintain arp_cache[IP→MAC] | ping to QEMU gateway resolves MAC |
| 5 | FUZZY | mmap-style ABI: nimixMapAnon(size) — grow app heap | app can allocate heap beyond initial region |

## Layer 3 — ELF + graphics primitives

| TW# | Tag | Description | Done-check |
|-----|-----|-------------|-----------|
| 8 | CLEAR | ELF loader: validate segment fits within allocated region before mapping | oversized segment returns error, no silent overwrite |
| 6 | CLEAR | ELF loader: R_X86_64_GLOB_DAT + R_X86_64_JUMP_SLOT relocations | dynamically-linked ELF loads and runs |
| 7 | CLEAR | ELF loader: strip PT_INTERP silently | ELF with PT_INTERP loads without error |
| 60 | DONE 2026-10-27 | Software rasterizer `gfx/canvas.nim` (fillTriangle still open) | screendump == host render (`make test-devices`) |
| 61 | DONE 2026-10-27 | Bitmap font (Spleen 8x16) + drawText; TTF via stb_truetype deferred to userspace | text renders in framebuffer |
| 24 | CLEAR | stdlib shim: osenv.nim — stub getenv/putenv (return nil/false) | msgpack4nim compiles under --os:nimix |

## Layer 4 — IPC encoding

| TW# | Tag | Description | Done-check |
|-----|-----|-------------|-----------|
| 22 | CLEAR | Vendor mpack/cmp as submodule for MsgPack encoding in apps | apps can encode/decode MsgPack without hand-rolling |
| 23 | CLEAR | Migrate event pub/sub payload to MsgPack encoding | event payloads are MsgPack, not raw bytes |

## Layer 5 — Servers + dispatcher foundation + audio/vendor

| TW# | Tag | Description | Done-check |
|-----|-----|-------------|-----------|
| 25 | CLEAR | fs_server ELF: owns FAT disk, exposes 'fs' channel — open/read/write/close via MsgPack | shell can open/read file via fs_server IPC |
| 26 | CLEAR | input_server ELF: IRQ1 PS2 handler publishes key.down/key.up to event_server | key presses appear as events |
| 27 | CLEAR | log_server ELF: 'log' channel collects kernel+app logs in ring buffer, queryable | logs queryable from shell |
| 28 | CLEAR | dispatch_kmod.nim: monolithic kernel module variant of dispatcher | dispatcher runs in monolithic model |
| 54 | CLEAR | Vendor miniaudio + dr_libs (WAV/MP3/FLAC decode + playback) to vendor/audio/ | audio decode test passes on host |
| 55 | CLEAR | Vendor stb_vorbis (Ogg Vorbis decode) to vendor/audio/ | Ogg decode test passes on host |
| 56 | CLEAR | Vendor pl_mpeg (MPEG1 video, ~30KB) to vendor/video/ | MPEG1 decode test passes on host |
| 57 | CLEAR | audio_server ELF: owns virtio-sound, exposes 'audio' channel (play/stop/volume via MsgPack) | audio plays via channel command |
| 47 | CLEAR | Adopt raylib KeyboardKey/MouseButton enums as canonical NimixOS input event types | input_server publishes raylib enums directly |
| 67 | FUZZY | Vendor Pango + HarfBuzz + FreeType + fontconfig for full font stack | complex text renders correctly |
| 68 | FUZZY | Pango Nim bindings: layoutText → positioned glyph runs | Nim app can render Unicode text |
| 3 | CLEAR | ps/stats: show real CPU% once procTickCurrent fires from PIT ISR | ps shows non-zero CPU% |
| 9 | FUZZY | Refactor VGA + PS2 to logic/kmod/elf scaffold pattern | both drivers follow same 3-file pattern |
| 32 | CLEAR | dispatch: serialise kernel I/O — fs_server/net_server only accept from dispatcher (cap-gated) | direct app→fs_server call is rejected without dispatcher cap |

## Layer 6 — Integration + zero-copy + app APIs

| TW# | Tag | Description | Done-check |
|-----|-----|-------------|-----------|
| 70 | SPAWN 2026-10-27 | **buffers** — frozen bulk-data API `ipc/buffers.nim` (owned/sealed, move/lend, session rings, budgets); see `subprojects/buffers/` | sub-project done-checks (spec §11) |
| 71 | PARENT | Stage B: per-app CR3 (VISION Q6 resolved) — next kernel milestone after buffers Stage A | per-task page tables; switch = CR3 load |
| 72 | SPAWN (next) | **app_server** — agreed protocol (docs/proposals/app_server_api.md) on top of buffers; freeze when spawned | two terminal windows, focus routing, pixel test |
| 29 | CLEAR | nimixos/net.nim — thin Nim app API: download/connect → MsgPack → dispatcher | app can call net.download() |
| 30 | CLEAR | nimixos/media.nim — thin Nim app API: play/pause/stop → MsgPack → dispatcher | app can call media.play() |
| 31 | CLEAR | nimixos.h C header — maps thin API to MsgPack IPC for WASM/C apps | WASM app can call fs/net/media via C header |
| 34 | CLEAR | nimixos_mem.h C header — regionOpen/regionClose for WASM/C apps | WASM app can access region cap |
| 35 | CLEAR | nimixos/streams.nim — faststreams-backed zero-copy reader/writer over region cap | app reads file via zero-copy stream |
| 36 | CLEAR | Integration test: WASM app reads file via dispatcher, verifies data via region pointer, ref count drops to zero | test passes in QEMU |
| 33 | CLEAR | Integration test: WASM app sends fs.read via thin API, dispatcher routes to fs_server, reply arrives | test passes |
| 10 | CLEAR | Path resolution: absolute paths, . and .. handling in shell + loader | cd ../foo works in shell |
| 38 | CLEAR | ARP: send/receive ARP request/reply, maintain arp_cache[] | (duplicate of layer2 task 52) |
| 39 | CLEAR | DHCP client: DISCOVER/OFFER/REQUEST/ACK, obtain IP from QEMU DHCP | OS gets IP address on boot |
| 53 | CLEAR | virtio-sound driver: PCM output queue, volume control (spec 5.14) | audio plays through QEMU virtio-sound |
| 58 | CLEAR | Audio mixing: software PCM mixer in audio_server — mix N streams with per-stream gain | two sounds play simultaneously |
| 59 | CLEAR | App-side audio API: nimixos/audio.nim — audioPlay/Stop/Volume + nimix_audio.h | app can play audio |
| 63 | CLEAR | input_server routing: PS2 IRQ → events → event_server; app_server routes to focused window | focused window receives key events |
| 65 | FUZZY | Media playback framework: pl_mpeg video + dr_mp3/stb_vorbis audio → region caps | video plays with audio |
| 11 | FUZZY | ext2 or littlefs driver — second FS option beyond FAT | ext2 volume mounts and is readable |

## Layer 7 — Services + app_server

| TW# | Tag | Description | Done-check |
|-----|-----|-------------|-----------|
| 13 | CLEAR | roster_server: track running apps (name, pid, cap token); ps uses this | ps lists live apps from roster_server |
| 14 | CLEAR | log_server: centralised log ring buffer, queryable | app log lines queryable via log_server |
| 12 | CLEAR | app_server skeleton: register window handles, route input to focused app | window creation request succeeds |
| 45 | CLEAR | audio_server ELF (duplicate detail entry; see layer5 task 57) | |
| 62 | CLEAR | app_server (full compositor): create/destroy windows, z-order, focus, route input; 'app' channel | two windows, correct input routing |
| 64 | PARTIAL | VT100 subset + renderer DONE (`term/`), shell on the fb console; the *window* waits on app_server | shell runs in a window |

## Layer 8 — GUI + raylib

| TW# | Tag | Description | Done-check |
|-----|-----|-------------|-----------|
| 15 | DONE 2026-10-27 | virtio-gpu framebuffer + damaged-rect present | framebuffer appears in qemu-gui |
| 16 | CLEAR | (see layer3 task 60 — software rasterizer) | |
| 17 | CLEAR | (see layer3 task 61 — font rendering) | |
| 18 | CLEAR | Window manager: title bar, z-order, drag, basic compositor | windows draggable |
| 19 | FUZZY | Terminal emulator window (GUI) — VT100 subset | (see layer7 task 64) |
| 40 | CLEAR | raylib: rcore PLATFORM_CUSTOM backend → virtio-gpu framebuffer blit | raylib draws to screen |
| 41 | CLEAR | raylib: software renderer (PLATFORM_CUSTOM + CPU rasterizer) | raylib 2D shapes render |
| 42 | CLEAR | raylib: input wiring — poll input_server IPC → raylib key/mouse state | raylib GetKey works |
| 43 | CLEAR | raylib: miniaudio CUSTOM backend → audio_server IPC | raylib PlaySound works |
| 44 | CLEAR | naylib: integrate Nim bindings on top of ported raylib | Nim app can call BeginDrawing/EndDrawing |
| 66 | FUZZY | Desktop env: background image, desktop icons, taskbar, app launcher (BeOS Tracker minimal) | desktop visible with working launcher |

## Layer 9 — Network services + raylib demo

| TW# | Tag | Description | Done-check |
|-----|-----|-------------|-----------|
| 46 | CLEAR | raylib: hello-raylib.elf demo — draw coloured rect + text, prove graphics stack end-to-end | coloured rect + text visible in QEMU |
| 21 | FUZZY | net_server ELF — userspace network stack, cap-gated socket API | app can open socket via net_server |
| 20 | CLEAR | TFTP client — load ELF/WASM from QEMU TFTP server | ELF loads from network |

## Vertical slice — raylib render server + RUI2 apps (2026-11-03) [PARENT]

Critical path: P0 → V2 (picolibc) → V3 (clock) → V4 (big memory) → V5 (raylib on
NimixOS) → R0 (device caps) → V6 (render server, takes the GPU = R2) → V9.
Parallel tracks: V7 bridge on RUI (after P0); V8 WASM host (= R1) with the
buffers ring ABI; V10 audio (after R0).

Outcome: a WASM app built on RUI2 (vendor/rui2) shows a working window through
the raylib render server, within VISION's budgets, and is benchmarked against
in-process raylib. Proposals: docs/proposals/render_server.md and
draw_protocol.md (PROPOSED, awaiting agreement); survey docs/surveys/rui2.md.

| # | Tag | Task | Done-check | Depends |
|---|-----|------|-----------|---------|
| V1 | DONE | vendor rui2 (submodule @0038051) + SURVEY | docs/surveys/rui2.md | — |
| **P0** | DONE (`make test-p0`) | **host loopback prototype (first, answers the perf question early):** vendor raylib **6.2** (rlsw + `rcore_memory`, headless); the bridge = our naylib-compatible binding to 6.2 (direct) + command encoder (remote) + decoder; the same screen through both paths in one process | (1) remote pixels == direct pixels (protocol conformance); (2) per-frame time and records/frame for both, reported; no NimixOS dependency | — |
| V2 | DONE (`make test-v2`) | libc/libm for the render-server ELF: **picolibc 1.8.12** (vendor/picolibc, shallow submodule; `tools/picolibc_build.sh`, cross file `tools/nimix-x86_64.cross`) | raylib + rlsw compile against picolibc's headers and link needing exactly the 31 OS-layer symbols in `tests/v2/expected_os_symbols.txt`; libm ≤ 1 ULP over 7,600 samples | — |
| V2b | DONE (`make test-v2`, `libc` in `make test-devices`) | **libnimix** (`libnimix/`, ~500 lines): `appMain`, stdio, heap = one owned arena buffer, time from the time page, whole-file `open/read/write/stat/opendir`, refusing stubs; **C programs run on NimixOS** (`apps/c/libctest`: 42 checks) | raylib + rlsw + picolibc + libnimix link with nothing unresolved; `libctest a b` passes on QEMU; the C clock reader == the Nim one on 63 golden vectors | V2 V3b V4 |
| V2c | PARKED | libnimix files over **fs_server with lent buffers** (replaces the ambient-path whole-file ABI; program-facing shapes unchanged); a one-shot timer for sub-tick `nanosleep` | `libctest` unchanged and green on the new back end | B10, R-series |
| V3 | DONE (kernel side) | fine monotonic clock: TSC calibrated against PIT channel 2 (median of 5 × 30 ms windows); pure math in `core/tsc_clock.nim`, driver `drivers/tsc.nim` (`tscNanos()` = one rdtsc + two multiplies) | host test (exact 128-bit reference, ~1 ppb); QEMU: 100 PIT ticks measure 999-1000 ms on the TSC (`make test-structured`, `tsc_*`) | — |
| V3b | DONE (`clocktest` in `make test-devices`; layout in `make test`) | the clock reaches apps through a **read-only time page** (`TimePage`, 40 bytes, versioned, at 224 MB in its own 2 MB window, user read-only for every task, written once at boot); apps use their own `rdtsc` + `clockNanos` (`apps/nim/nimix_time.nim`: `nanoTime()`); coarse fallback = `nimixUptimeSecs` (no new syscall) | `clocktest`: 3 s of PIT ticks measured 2998 ms from ring 3; a write to the page faults and kills only the writer | V3 |
| V4 | DONE (`buftest big` in `make test-devices`) | large memory for servers/apps: **memory is buffers**: a heap is one contiguous owned arena buffer (a 32 MB buffer written and verified end to end from ring 3, budget enforced and returned); no separate "large region" class. App regions unchanged | `buftest big`: 32 MB create/map/touch every page/verify; a second create refused; budget back after close | buffers |
| V4b | PARKED (measure first) | **sizing**: arena size (128 MB today, 256 MB VM) and per-class budgets (every task gets 32 MB today). Set from the real render server's numbers in V5/V9, not guessed; likely wants a larger default VM and per-class budgets | V9 shows the render server's heap + buffer high-water mark | V5 V9 |
| V5a | DONE (`display-*` in `make test-devices`) | **display ABI v1** (docs/proposals/display_abi.md): `nimixDisplayInfo` + `nimixDisplayPresent(owned buffer, rect)`; implicit ownership (console steps aside, returns on exit); every request checked (`display_checks`, host-tested) | a ring-3 C program (`gfxtest`) presents 640x400; the screendump region == the host-computed pattern (256,000 pixels); 10 bad requests refused (kernel pointers included); console repaints after exit | V2 V3b V4 |
| V5b | DONE (`raylib-render`, `raylib-colours` in `make test-devices`) | **raylib 6.2 + rlsw run on NimixOS** (`PLATFORM_NIMIX`): `tools/raylib_nimix.py` generates the platform from the pinned `rcore_memory.c` (9 exact-once substitutions: owned-buffer framebuffer, present through the display ABI, window position, no terminal polling); `apps/c/rldemo` draws a scene with plain raylib C calls | the guest screendump == the host render of the same scene, all 256,000 pixels; real colours asserted independently | V5a |
| V5f | DONE (`display-mode-*` in `make test-devices`) | **display modes** (ABI v2): list + set mode for the display owner; boot mode and console restored on release; limited to the boot framebuffer size (larger modes: V4b) | screendump is the new size with only the program's frame; afterwards equals the console replay | V5a |
| V14 | DONE (`abi-hostile` in `make test-devices`, `tests/test_user_args.nim`, `tests/test_sip_heap.nim`) | **syscall argument validation**: every ring-3 pointer argument is checked at the gate from one table (region + arena rights, read vs write), cross-checked against the ABI by reflection; hostile-argument program `abifuzz` (339 checks); fixed `mapAnon` assert and `sipAlloc` negative-size wrap | kernel survives and refuses every hostile call | V5 |
| V5d | PARKED | present only the damaged rectangle (today a full frame per `EndDrawing`: raylib tracks no damage; the V6 render server knows it from the command stream); clear the display when taking ownership; raise the shell's 512 KB program buffer if images outgrow it | V6 | V5b |
| V5c | DONE (`keys-*` in `make test-devices`) | **keyboard input into raylib**: the platform subscribes to the `input` event topic, maps evdev events to raylib keys and characters (`libnimix/nimix_keymap.h`: golden-tested against the Nim keymap and raylib's own enum), and **input follows display ownership** (the console drops keys while a program owns the screen) | injected key events move a square on the screen; the exact key sequence and characters reach the program; none reach the shell | V5b |
| V5e | DONE for mouse/tablet (`pointer`, `mouse-*` in `make test-devices`); touch and the focus model PARKED | mouse and tablet into raylib (done: every virtio-input device driven; mouse position, buttons, wheel; remaining: touch/gestures, `SetMousePosition`, and a focus model beyond "the display owner gets the keys" once there are windows (V6) | V6 | V5c |
| V6 | SPAWN (proposal written 2026-11-13: `docs/proposals/render_server_v6.md`, 12 decisions, 7 slices; awaiting the human on D1/D3/D4/D5/D7/D8/D10) | **render server** (app_server's second face): sessions, command-ring execution, targets, composite, present; **first optimisation: damage-limited compositing** (P0: raster dominates, the protocol costs ~nothing) | draw_protocol conformance tests (host) + QEMU pixel test | V5, buffers rings ABI, protocol agreed |
| V7 | PARENT | app side: the **raylib bridge** (naylib-compatible `raylib`/`rlgl`; backends direct / remote / hybrid with counted fallback), actor-backed `background`/`mailbox`, RUI text via the `text_*` host imports | RUI + a stock raylib example build unchanged against the bridge; direct = zero-cost (codegen equal to naylib); remote stream decoded on host | protocol agreed |
| V7a | DONE (`make test-v7`) | direct: **adapted naylib** (`tools/naylib_adapt.py` over pinned `vendor/naylib` v25.51.1 → raylib 6.2 memory platform + rlsw, 6.2 ABI fixes) + RUI text-engine seam with a **Pixie engine** + `ruiNoGlfw` (patches/rui2) | RUI's counter example, unchanged, paints headless with Pixie text | P0 |
| V7b | DONE (`make test-v7`) | remote: draw ops routed at the **C-symbol level**: `tools/naylib_adapt.py` also emits `build/bridge/naylib_remote/`, where every symbol with an `nxr_<Name>` in `bridge/rl_route.nim` (45: shapes, text, targets, textures, blend, scissor, the rlgl calls RUI makes) imports the encoder instead of raylib; types, CPU images, queries and window/input stay naylib. Raw rlgl framebuffers answer 0 (RUI falls back to `loadRenderTexture`); shaders invalid (as on rlsw); `LoadImageFromScreen` = counted sync point | RUI counter, 3 clicks through RUI's router: remote pixels == direct (byte-identical, repeatable); steady frames ≤ 86 records / 1,016 B | V7a |
| V7c | CLEAR | actor-backed `background`/`mailbox` behind RUI's API (threads off) | RUI builds `--threads:off` on the bridge | V7a |
| V7d | CLEAR | RUI2 for WASM (`--mm:orc`), text via `text_*` host imports | host test decodes the WASM build's command stream | V7b V8 |
| V8 | CLEAR | **userspace WASM host (ELF)**: move wasm3 out of the kernel; per-app host process granting host imports (buffers/rings, and the native text helper: Pixie `text_*`); ORC, larger linear memory | counter example runs in the ELF host; a text import measures at native speed (host test) | buffers B8 |
| V9 | CLEAR | **benchmark**: same RUI screen in-process (RUI + raylib/rlsw, ELF) vs server path (WASM → commands → server) | report: frame time, key-to-pixel, commands/frame, kernel calls/frame; CI gates the counts | V6 V7 V8 |
| V10 | CLEAR | audio: thread-free miniaudio backend → virtio-snd via session ring (audio server) | 440 Hz test tone through the ring (existing wav check) | buffers rings |
| V12 | PARKED | AOT for app code (wasm2c, RLBox-style isolation) | only if V9 shows the interpreter alone misses the app budget | V9 |
| V13 | PARKED | GPU acceleration: rlgl → virgl backend in the render server (VISION Q7) | server frame time within budget on a GPU host; rlsw output still the test reference | V6 V9 + VISION Q7 signal |
| V11 | CLEAR | upstream to rui2: **text-backend seam (Pango, Pixie)**; SDF/backdrop backend hook; `{.cursor.}` parent or ORC note; optional rui_scripting / rui_shaped | PRs to kobi2187/rui2; RUI desktop runs on the Pixie backend | V7 + **stabilized** (human, 2026-11-03: push only after we stabilize; until then `patches/rui2/`) |

## Residency migrations (2026-11-03) [PARENT]: components to their proper home

Outcome: the kernel holds only inherent mechanism (ARCHITECTURE residency
map). Order follows dependencies and the vertical slice.

| # | Tag | Task | Done-check | Depends |
|---|-----|------|-----------|---------|
| R0 | FUZZY | device-capability mechanisms: `irqSubscribe` → mailbox, MMIO caps, DMA buffer caps, PCI-config caps | a userspace test driver gets an IRQ and does DMA through caps only | buffers (DMA buffers) |
| R1 | CLEAR | wasm3 → per-app userspace ELF WASM host (= slice V8) | WASM apps run with no wasm3 code in the kernel image | V8 |
| R2 | CLEAR | virtio-gpu + display → render server (= slice V6) | no gpu driver in the kernel image; screendump tests pass | R0, V6 |
| R3 | CLEAR | virtio-input + PS/2 → input_server | keys reach apps via input_server; kernel has no input driver | R0 |
| R4 | CLEAR | virtio-snd → audio server (= slice V10) | wav test passes via the server | R0, V10 |
| R5 | CLEAR | fb console/VT → console server; kernel keeps a serial (+ minimal panic) console | shell output on screen via the console server | R2 |
| R6 | CLEAR | shell → `shell.elf` (+ a spawn syscall) | the QEMU suite drives the userspace shell | R5 |
| R7 | CLEAR | virtio-blk + VFS/FatFs → blk + fs servers | `cat` through fs_server with no FS code in the kernel | R0, buffers B10 |
| R8 | CLEAR | virtio-net + IP stack → net_server | pcap test via net_server | R0 |
| R9 | CLEAR | retire ping/dispatch kmods in the micro model (ELF servers exist) | microkernel image links neither | — |
| R10 | CLEAR | event topic registry → event server; kernel keeps notify | pub/sub tests via the server | Phase E |

## Compiler target (long-term)

| TW# | Tag | Description |
|-----|-----|-------------|
| 1 | FUZZY | --os:nimix Nim compiler target (replace --os:standalone + panicoverride) |
| 2 | CLEAR | ELF: R_X86_64_GLOB_DAT + JUMP_SLOT (full dynamic linking) |
