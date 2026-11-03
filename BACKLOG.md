# BACKLOG.md — Dependency Tree of Tasks

Source of truth is **taskwarrior** (`task list project:nimixos`). This file is the
structured view — parents hold intent, leaves are executable. Layer tags encode
dependency order: layer0 must complete before layer1, etc.

Tags: CLEAR = path obvious | FUZZY = outcome known, path uncertain | OPEN = undecidable yet | PARENT = not executable directly | SPAWN = own sub-project

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

Outcome: a WASM app built on RUI2 (vendor/rui2) shows a working window through
the raylib render server, within VISION's budgets, and is benchmarked against
in-process raylib. Proposals: docs/proposals/render_server.md and
draw_protocol.md (PROPOSED, awaiting agreement); survey docs/surveys/rui2.md.

| # | Tag | Task | Done-check | Depends |
|---|-----|------|-----------|---------|
| V1 | DONE | vendor rui2 (submodule @0038051) + SURVEY | docs/surveys/rui2.md | — |
| V2 | CLEAR | SURVEY + adopt libc/libm: picolibc vs musl math, freestanding, for the raylib/rlsw server ELF | hosted build of rlsw links; libm functions raylib uses resolve | — |
| V3 | CLEAR | fine monotonic clock: TSC calibrated against the PIT; `nanoTime` syscall | host test of the calibration math; QEMU: 1 s sleep measures 1 s ± 1 % | — |
| V4 | FUZZY | large memory for servers/apps (> 4 MB): a large-region class or an arena-backed heap | render server gets ≥ 32 MB; app regions unchanged | buffers |
| V5 | CLEAR | raylib 6.0 + rlsw built for NimixOS: `PLATFORM_NIMIX` (virtio-gpu fb blit of damage, fine clock, event-ring input) | ELF demo draws shapes+text; screendump == host render (pixel test) | V2 V3 V4 |
| V6 | SPAWN | **render server** (app_server's second face): sessions, command-ring execution, targets, composite, present | draw_protocol conformance tests (host) + QEMU pixel test | V5, buffers rings ABI, protocol agreed |
| V7 | CLEAR | app side: `raylib`/`rlgl` shim encoding commands (naylib names/types), actor-backed `background`/`mailbox`, RUI text via the `text_*` host imports | RUI2 builds for WASM (`--mm:orc`) unchanged; host test decodes its command stream | protocol agreed |
| V8 | CLEAR | **userspace WASM host (ELF)**: move wasm3 out of the kernel; per-app host process granting host imports (buffers/rings, and the native text helper: Pixie `text_*`); ORC, larger linear memory | counter example runs in the ELF host; a text import measures at native speed (host test) | buffers B8 |
| V9 | CLEAR | **benchmark**: same RUI screen in-process (RUI + raylib/rlsw, ELF) vs server path (WASM → commands → server) | report: frame time, key-to-pixel, commands/frame, kernel calls/frame; CI gates the counts | V6 V7 V8 |
| V10 | CLEAR | audio: thread-free miniaudio backend → virtio-snd via session ring (audio server) | 440 Hz test tone through the ring (existing wav check) | buffers rings |
| V12 | PARKED | AOT for app code (wasm2c, RLBox-style isolation) | only if V9 shows the interpreter alone misses the app budget | V9 |
| V11 | CLEAR | upstream to rui2: **text-backend seam (Pango, Pixie)**; SDF/backdrop backend hook; `{.cursor.}` parent or ORC note; optional rui_scripting / rui_shaped | PRs to kobi2187/rui2; RUI desktop runs on the Pixie backend | V7 |

## Compiler target (long-term)

| TW# | Tag | Description |
|-----|-----|-------------|
| 1 | FUZZY | --os:nimix Nim compiler target (replace --os:standalone + panicoverride) |
| 2 | CLEAR | ELF: R_X86_64_GLOB_DAT + JUMP_SLOT (full dynamic linking) |
