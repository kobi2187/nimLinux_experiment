# NimixOS — Agent Guide

## Build/Lint/Test Commands

```bash
# Build kernel (all 3 models: monolithic, sasos, microkernel)
make build

# Build a single kernel model
nim c --os:any --mm:arc -d:StandaloneHeapSize=16777216 -d:release -d:danger --noMain --outdir:build kernel/init/main.nim

# Build with debug info
nimble debug

# Build Nim userspace apps (PIE, --os:standalone)
make nim-apps

# Build WASM apps from C source
make apps

# Run all host unit tests
make test

# Run a single test (refc memory management)
nim c -r --skipParentCfg --mm:refc --path:. -d:noSignalHandler tests/test_<name>.nim

# Run a test with ARC memory management
nim c -r --skipParentCfg --mm:arc --panics:on --path:. --nimblePath:$HOME/.nimble/pkgs2 -d:noSignalHandler tests/test_dispatch_logic.nim

# Run a test that needs -d:testing flag
nim c -r --skipParentCfg --mm:refc --path:. -d:noSignalHandler -d:testing tests/test_osalloc.nim

# Build ISO and boot in QEMU
make qemu

# Boot with VGA display
make qemu-gui

# Boot with GDB server on :1234 (paused at start)
make qemu-debug

# Create FAT16 disk image (32 MB)
make disk

# Add/update apps on disk image
make disk-add-apps

# List disk contents
make disk-ls

# Run QEMU integration tests
make test-qemu DISK=disk.img OVMF=/usr/share/ovmf/OVMF.fd

# Run the Nim test suite entry point
nimble test

# Clean build artifacts
make clean
```

## Code Style Guidelines

### Imports
- Group imports by layer (core first, then arch, mm, sched, kernel, drivers, servers)
- One `import` statement per logical group
- Use relative paths from the project root (e.g., `import ../../core/types`)

### Formatting
- Indent with 2 spaces
- Max line length: soft limit around 100 chars
- Section dividers: `# ═══════════════════════...` (80 chars with `#`)

### Naming
- **Types**: PascalCase (`KernelError`, `PhysAddr`, `Option`, `Result`)
- **Procs/Variables**: camelCase (`initKernel`, `parseBootInfo`, `globalTestSuite`)
- **Constants**: PascalCase or UPPER_SNAKE (`FrameSize`, `KiB`, `MiB`)
- **Enum values**: PascalCase with lowercase prefix (`keOutOfMemory`, `trPass`, `ps4K`)
- **Generic parameters**: single capital letters (`T`, `E`)
- Files/directories: snake_case

### Types
- Use `distinct` types for strong typing (`PhysAddr = distinct uint64`)
- Use custom `Result[T, E]` tagged union for error handling (not exceptions)
- Use `Option[T]` for optional values
- Use `VoidResult[E]` alias for void-returning results
- Prefer `ptr` over `ref` for kernel objects

### Error Handling
- Return `Result[T, E]` with `ok()`/`err()` template constructors
- Use `kpanic()` for unrecoverable errors (halts CPU)
- Use `kassert()` for assertions in kernel code
- Propagate errors with `?` operator (raises Defect on failure in test context)
- In tests, use `framework.nim` assertions: `assertTrue`, `assertEqual`, `assertNil`, etc.
- Exceptions only for unknown I/O.

### Logging
- `klog(level, msg)` — structured kernel logging
- `klogHex(level, label, val)` — log hex values
- `klogInt(level, label, val)` — log decimal ints
- Compile-time level filtering via `-d:logLevel=N` (0=DEBUG, 1=INFO, 2=WARN, 3=ERROR, 4=PANIC)

### Conventions
- Mark performance-critical procs with `{.inline.}`
- No `return result` — use implicit `result` variable
- Use `when defined(release)` / `when not defined(release)` for debug-only code
- Annotate noreturn procs with `{.noReturn.}` or `{.noreturn.}`
- Document types/procs with `##` doc comments above the definition
- Test files go in `tests/test_<component>.nim`
- Test files import `./framework` for test utilities and `unittest`
- Kernel source files live in `kernel/`, `core/`, `mm/`, `sched/`, `arch/`, `drivers/`, `fs/`, `ipc/`
- Use `addr` operator for getting pointers, not `unsafeAddr`
- Prefer `for i in 0..<n:` over `for i in 0..n-1:`
- Use `case` statements with exhaustive branches for enum types
- Define error enums with `ke` prefix (e.g., `keOutOfMemory`, `keInvalidArgument`)

### Kernel Constants
- `FrameSize = 4096'u64` — standard page size
- `PageSize` enum: `ps4K` (4096), `ps2M` (2097152), `ps1G` (1073741824)
- `KiB`, `MiB`, `GiB`, `TiB` size constants
- `StandaloneHeapSize` must be defined at compile time

## Testing Framework

The project uses a custom testing framework in `tests/framework.nim` layered over `unittest`.

### Test Infrastructure
- **`framework.nim`**: Provides mocks (`MockPhysicalMemory`, `MockInterruptSystem`),
  test reporting (`TestSuite`, `TestCase`), memory leak detection (`MemoryValidator`),
  and assertion utilities
- **Assertions**: `assertTrue`, `assertFalse`, `assertEqual`, `assertNotEqual`,
  `assertNil`, `assertNotNil` — all return `bool` and auto-record failures
- **Memory tracking**: `recordAllocation`/`recordDeallocation` with leak checking via `checkMemoryLeaks()`
- **Mock memory**: `initMockPhysicalMemory(size)` + `allocateMockPhysical`/`freeMockPhysical`
  for testing allocators without hardware
- **Mock interrupts**: `recordInterrupt`/`wasInterruptFired` for interrupt dispatch validation

### Test Patterns
- Tests use `suite`/`test` blocks from `unittest`
- Import framework with `import ./framework`
- Use `check` macro for assertions in test suites
- Reset test state between runs with `resetAllTestData()`
- Print reports at the end with `printTestReport()`

## Directory Layout

```
core/           # Foundational types, serial, logging — layer 0, no dependencies
arch/           # Architecture-specific code (x86_64 boot ASM, TSS, syscall gate)
mm/             # Memory management (physical, virtual, heap, region allocator)
sched/          # Scheduling (task manager, scheduler, execution models)
kernel/         # Kernel core (init, models, ABI, capabilities, process table)
drivers/        # Device drivers (PIC, PIT, PS/2 keyboard, VGA text, PCI, virtio)
fs/             # Filesystem (FAT fs driver)
ipc/            # Inter-process communication (server channels, flatbuffers, msgpack)
servers/        # System servers (ping, dispatch, fs)
apps/           # Userspace applications (hello, ps, kill, ls, top, stats)
boot/           # Bootloader parsing
shell/          # Interactive shell
tests/          # Host-side unit tests (test_*.nim) + QEMU integration harness
vendor/         # Third-party libraries (fatfs, printf, wasm3, arsenal)
build/          # Build output artifacts

## Taskwarrior Tasks

```bash
# List all tasks
task list

# List tasks by urgency
task list

# List tasks by project
task project:nimixos

# Show task details
task <id> info

# Add a new task
task add project:nimixos tags:layerX,<tag> description

# Mark task done
task <id> done

# Modify task priority/urgency
task <id> modify priority:H

# List task tags used in the repo
task tags
```

Common task tags: `nimixos`, `gui`, `dispatcher`, `raylib`, `zerocopy`, `network`,
`fs`, `ipc`, `elf`, `scheduler`, `testing`, `naylib`, `audio`, `input`,
`services`, `layer0`-`layer9`

Key tasks for onboarding (by ID — run `task <id> info` for details):

| ID | Pri | Layer | Description |
|----|-----|-------|-------------|
| 48 | H | layer0 | Userspace ring 3: fix syscall gate stub (all apps currently run ring 0) |
| 12 | M | layer7 | app_server skeleton: register window handles, route input |
| 32 | M | layer5 | dispatch: serialise kernel I/O (fs_server, net_server) |
| 54 | H | layer5 | Vendor miniaudio + dr_libs (single-file C audio libs) |
| 55 | H | layer5 | Vendor stb_vorbis (Ogg Vorbis decode for audio pipeline) |
| 67 | H | layer5 | Vendor Pango + HarfBuzz + FreeType + fontconfig (font stack) |
| 68 | H | layer5 | Pango Nim bindings: PangoLayout, PangoContext, PangoFontDescription |
| 45 | L | layer7 | audio_server: ELF server owning audio device |
| 15 | L | layer8 | GUI: VirtIO-GPU linear framebuffer init |
| 40 | D L | layer8 | raylib: port rcore platform backend |
| 3  | M | layer1 | ps/stats: show real CPU% once procTickCurrent fires |
| 4  | M | layer2 | Guard pages: map unmapped page before/after each app |
| 8  | M | layer3 | ELF loader: validate segment fits before mapping |
| 36 | M | layer6 | zerocopy: integration test |
| 37 | M | layer0 | CI: GitHub Actions workflow |
| 25 | M | layer5 | fs_server: ELF server owning FAT disk |

## Library Strategy

NimixOS leverages single-file C libraries (vendored, not system-installed) for
media/graphics/audio. These follow the same pattern as `vendor/fatfs/`:
drop in a `.c`/`.h`, compile via Nim's `--passC`, wrap in a thin Nim layer.

### Audio Pipeline
| Library | File | Purpose |
|---------|------|---------|
| **miniaudio** (mackron) | `vendor/audio/miniaudio.{h,c}` | Audio playback/capture, custom backend mode for NimixOS audio_server. Public domain, zero deps beyond libc. |
| **dr_wav** (mackron) | `vendor/audio/dr_wav.h` | WAV decode/encode |
| **dr_mp3** (mackron) | `vendor/audio/dr_mp3.h` | MP3 decode |
| **dr_flac** (mackron) | `vendor/audio/dr_flac.h` | FLAC decode |
| **stb_vorbis** (nothings) | `vendor/audio/stb_vorbis.c` | Ogg Vorbis decode |
| **Atomix** (BareRose) | `vendor/audio/atomix.h` | Wait-free atomic sound mixer (optional) |

### Graphics Pipeline (Pure Nim — treeform ecosystem)
| Library | Source | Purpose |
|---------|--------|---------|
| **pixie** (treeform) | `nimble install pixie` | Full 2D graphics: CPU rasterizer, paths, shapes, masking, blending, shadows, blurs, text layout, rich text spans, SIMD. Reads PNG/JPEG/BMP/GIF/SVG. **Replaces**: stb_image + software rasterizer + font rasterizer + image codecs. Pure Nim, no FFI. |
| **fidget** (treeform) | `nimble install fidget` | UI toolkit built on pixie. Declarative Nim DSL, Figma export support. Provides widgets, layout, event handling. Would need a NimixOS backend. |
| **boxy** (treeform) | `nimble install boxy` | GPU backend for pixie (OpenGL) — optional acceleration path. |

### Why pixie over single-file C libs for graphics
- **Pure Nim** — compiles with `--os:standalone`, no C compilation issues, no FFI overhead
- **All-in-one** — rasterizer + fonts + image codecs + paths/blends/masks in one library
- **SIMD accelerated** — competitive performance without GPU
- **Same author as fidget** — the UI layer integrates natively
- For NimixOS ELF apps, pixie draws directly into a region cap framebuffer

### Font Pipeline
| Library | Source | Purpose |
|---------|--------|---------|
| **Pango** (GNOME) | `vendor/font/pango/` | Text layout engine — handles bidi, complex scripts, line breaking. Depends on HarfBuzz + FreeType + GLib |
| **HarfBuzz** (behdad) | `vendor/font/harfbuzz/` | OpenType shaping engine — glyph positioning, substitution |
| **FreeType** (Freetype Team) | `vendor/font/freetype/` | TrueType/OpenType glyph rasterization to bitmap |
| **fontconfig** (freedesktop) | `vendor/font/fontconfig/` | Font discovery and matching |
| _Alternative_ | pixie has built-in text layout + font rendering | For simpler apps, pixie's own text stack may suffice without Pango |

### Video Pipeline
| Library | File | Purpose |
|---------|------|---------|
| **pl_mpeg** (phoboslab) | `vendor/video/pl_mpeg.h` | MPEG1 video decoder (single 30KB header) |
| **dav1d** (Videolabs) | system dep | AV1 decode (heavy, optional) |

### Existing Nim bindings (nimble packages — use in ELF apps, not kernel)
- `miniaudio` / `parasound` — Nim wrappers for miniaudio (for userspace apps)
- `ffmpeg` / `nimffmpeg` — FFmpeg bindings (heavy, for codec-heavy apps)
- `libvlc` — libvlc bindings (full media player embed)
- `pl_mpeg` / `mpeg` — Nim wrapper for pl_mpeg

### Integration pattern
```
Vendor C lib → thin Nim wrapper → kernel ABI or IPC channel → app API
```

Example (audio):
```
miniaudio custom backend → audio_server ELF → "audio" ServerChan → nimixos/audio.nim
```
Same pattern as `fs_server`: server owns the hardware via region caps for zero-copy,
apps send MsgPack control messages (play, stop, volume).
