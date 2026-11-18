# Display ABI v1 — how a ring-3 program puts pixels on the screen

Status: **PROPOSED 2026-11-09** (my pick is built as V5; the human can redirect: the ABI is two calls,
so changing it is cheap). Context: `render_server.md` (PLATFORM_NIMIX), `bulk_data.md` (buffers).

## The problem
raylib's software renderer (rlsw) draws into memory. Something has to get a damaged rectangle of
that memory onto the virtio-gpu scanout. Today only the kernel touches the GPU, and the kernel
console owns the screen.

## Options
| | what the program does | kernel's job | verdict |
|--|--|--|--|
| **A. present from an owned buffer (pick)** | renders into a buffer it owns, calls `Present(rect)` | validates and copies the rect to the scanout, flushes it | the kernel stays the only GPU toucher; every access is checked; maps onto "present a surface" later |
| B. map the scanout into the program | renders straight into scanout memory, calls `Flush(rect)` | maps GPU DMA memory user-writable | zero copy, but needs device capabilities (R0/R2) and lets a program write memory the GPU reads (tearing, no bounds check by construction) |
| C. a write-style stream (`write(fb, ...)`) | streams pixels | copies | path-based and unframed: the shape POSIX gives, not one we want |

**A now, B when device capabilities exist (R0/R2).** The calls below survive that move: `Present`
takes a buffer handle today, and a lent surface or compositor target tomorrow.

## The calls (2)
Syscalls have four argument registers, so requests are structs passed by pointer, each starting
with its own `size` (versioning: the kernel accepts a larger struct, ignores unknown tail fields).

```c
typedef struct { uint32_t size, width, height, format, stride_bytes; } NimixDisplayInfo;
int nimixDisplayInfo(NimixDisplayInfo *out);          /* format 1 = B8G8R8X8, little-endian pixels */

typedef struct {
    uint32_t size;
    uint32_t handle;        /* an owned or sealed buffer the caller can read (nimixBufCreate) */
    uint32_t stride_bytes;  /* of the buffer's rows */
    int32_t  sx, sy, w, h;  /* the rectangle in the buffer */
    int32_t  dx, dy;        /* where it lands on the display */
} NimixPresent;
int nimixDisplayPresent(const NimixPresent *req);
```
Returns 0, or `-1` bad request, `-2` display busy (another task owns it), `-3` no display.

- **Ownership is implicit.** The first successful `Present` makes the caller the display owner:
  the kernel console stops painting (its text grid keeps updating from the serial mirror). A second
  task gets -2. The owner's exit, kill or fault releases it and repaints the console. No separate
  acquire call: ownership without a presented frame is not useful, and "release on any exit path"
  already exists (task cleanup).
- **Every access is checked.** The kernel reads the caller's buffer only through the buffers store
  (the caller must hold a readable handle: owned or sealed, so a buffer lent away cannot be read),
  and checks the source rect against the buffer's size and stride and the destination rect against
  the display. A bad request changes nothing.
- **Pixel format is the display's.** The program converts (raylib's R8G8B8A8 to B8G8R8X8); the
  kernel copies bytes. Conversion cost is proportional to the damage, in user code, where it can
  use SIMD, and the kernel stays a dumb checked copy.
- **One kernel call per frame** fits VISION's budget (about one per frame).

## Input
Not in this ABI. Keys already arrive as evdev triples on the `input` event topic
(`nimixEventSubscribe/Poll`); V5b maps them into raylib. Mouse needs a device first.

## Tests
Host: nothing to unit-test but the rect checks (pure, `display_checks`). QEMU: a ring-3 program
draws with raylib and presents; the guest screendump must equal the host render of the same
program pixel for pixel; a second presenter is refused; the console returns when the owner exits;
a bad rectangle and a lent-away buffer are refused.

## v2: display modes (2026-11-12)
Raised by the human: an OS switches to a graphics mode for a graphics session; it does not reuse
the boot console's.

```c
typedef struct { unsigned width, height; } NimixDisplayMode;
int nimixDisplayModes(NimixDisplayMode *out, int max);   /* returns how many modes exist; writes up to max */
int nimixDisplaySetMode(unsigned width, unsigned height); /* 0, -1 not a listed mode, -2 busy, -3 no display */
```
- **Who may set it.** The caller becomes the display owner (as a present does) and the screen is cleared.
  Another task's owned display answers -2. `nimixDisplayInfo` always reports the current mode.
- **Which modes.** A fixed list of standard sizes that fit the boot framebuffer, plus the boot mode
  (`display_checks.modeList`, host-tested). Anything else is -1: the kernel never builds a resource of
  a size a caller made up.
- **Restore.** When the owner ends (exit, kill, fault) the kernel sets the boot mode back and the console
  repaints over a cleared background: the state a user sees after a game exits is the state before it.
- **Mechanism (virtio-gpu).** A smaller mode is a prefix of the boot framebuffer's DMA memory: a new 2D
  resource of the new size is created and attached to it, made the scanout (`SET_SCANOUT`), and the old
  resource freed (ids alternate 1/2). No allocation, so a mode change cannot fail for lack of memory.
- **Ceiling = boot mode.** Larger modes need a larger DMA framebuffer allocated up front (8 MB for
  1920x1080). Not offered yet: the seam is `virtioGpuFbBytes`, and the answer belongs with V4b sizing.
- **Rejected:** a fixed mode with scaling at present time (a compositor does that; it costs a pass per
  frame and leaves the console's stale margins); modes taken from the host's EDID (the host window is a
  test-harness choice, not a property of the OS).
- **Tests.** Host: the mode list and validation. QEMU (`display-mode-set`, `display-mode-restore`): the
  screendump is 800x600 with the host pattern and nothing else lit; bad modes are refused; afterwards the
  screen equals the host replay of the console stream, pixel for pixel.
