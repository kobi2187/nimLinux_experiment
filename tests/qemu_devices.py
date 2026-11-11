#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Host-verified virtio device + crash-report tests for NimixOS under QEMU.

Each device test makes the guest do something with a real effect outside the
VM, then checks that effect on the host — not the guest's word for it:

    console shell output  → screendump equals the serial byte stream rendered
                            on the host by the same term/gfx code; keys typed
                            on the virtio keyboard reach the shell
    gpu    devtest gpu    → QMP screendump of the virtio-gpu head: 4 colour bars
    snd    devtest snd    → QEMU wav audiodev recording: ~440 Hz square wave
    net    devtest net    → QEMU filter-dump pcap: our UDP marker frame
    input  QMP keys a, b  → guest prints evdev codes 30/48 (down + up)

Crash tests check the serial crash report — vector, registers, a backtrace
that tools/symbolize.py resolves to the faulting proc — and the policy:
a ring-3 fault (fault.elf) kills only that task and the system carries on;
a kernel-mode fault (devtest crash-*) halts, one boot per fault.

    python3 tests/qemu_devices.py                 # devices + crashes
    python3 tests/qemu_devices.py --only devices  # or: crashes
"""
import argparse
import os
import re
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import nimix_qemu as nq            # noqa: E402
import symbolize                   # noqa: E402

PROMPT = "nimixos> "
BAR_COLORS = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]
NET_MARKER = b"NIMIXOS-DEVTEST"


class Guest:
    """QEMU with serial on stdio pipes and a QMP socket."""

    def __init__(self, cfg: nq.QemuConfig):
        self.proc = subprocess.Popen(nq.build_cmd(cfg), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=open(os.environ.get("NIMIX_QEMU_STDERR", os.devnull), "wb"))
        self.out = bytearray()
        threading.Thread(target=self._pump, daemon=True).start()
        self.qmp = None
        if cfg.qmp:
            self.qmp = nq.Qmp(cfg.qmp)

    def _pump(self):
        for chunk in iter(lambda: self.proc.stdout.read1(4096), b""):
            self.out.extend(chunk)

    def text(self, start=0) -> str:
        return self.out[start:].replace(b"\x00", b"").decode(errors="replace")

    def wait(self, pattern: str, timeout: float, start=0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if pattern in self.text(start):
                return True
            if self.proc.poll() is not None:
                return pattern in self.text(start)
            time.sleep(0.1)
        return False

    def type(self, line: str):
        for ch in line + "\r":                 # the shell reads one char at a time
            self.proc.stdin.write(ch.encode())
            self.proc.stdin.flush()
            time.sleep(0.02)

    def run(self, line: str, timeout=30, until=PROMPT) -> str:
        mark = len(self.out)
        self.type(line)
        self.wait(until, timeout, mark + len(line))
        return self.text(mark)

    def close(self):
        try:
            if self.qmp:
                self.qmp.execute("quit")
        except Exception:                      # noqa: BLE001 — already gone is fine
            pass
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


# ── host-side evidence ───────────────────────────────────────────────────────

def read_ppm(path):
    data = open(path, "rb").read()
    magic, dims, maxval, pixels = data.split(b"\n", 3)
    assert magic == b"P6" and maxval == b"255", (magic, maxval)
    w, h = map(int, dims.split())
    return w, h, pixels


def check_gpu(ppm):
    w, h, px = read_ppm(ppm)
    y = h // 2
    got = []
    for i in range(4):
        x = i * w // 4 + w // 8                # middle of bar i
        o = (y * w + x) * 3
        got.append(tuple(px[o:o + 3]))
    assert got == BAR_COLORS, f"bar pixels {got} != {BAR_COLORS}"
    return f"{w}x{h}, bars {got}"


def check_snd(wav):
    data = open(wav, "rb").read()
    i = data.index(b"data") + 8
    samples = struct.unpack(f"<{(len(data) - i) // 2}h", data[i:i + (len(data) - i) // 2 * 2])
    left = samples[0::2]
    nz = [k for k, s in enumerate(left) if s != 0]
    assert nz, "recording is silent"
    seg = left[nz[0]:nz[-1] + 1]
    crossings = sum(1 for a, b in zip(seg, seg[1:]) if (a < 0) != (b < 0))
    hz = crossings / 2 / (len(seg) / 44100)
    assert 400 < hz < 480, f"tone {hz:.0f} Hz, expected ~440"
    return f"{len(seg)} frames, {hz:.0f} Hz"


CONSOLE_START = "[SERVICES] \u2713 framebuffer console".encode()
REPLAY = os.path.join(ROOT, "build/term_replay")


def check_console(serial: bytes, ppm: str, tmp: str) -> str:
    """The display must equal the console byte stream rendered on the host
    by the same term/gfx code (tools/term_replay.nim) — pixel for pixel."""
    start = serial.index(CONSOLE_START)
    start = serial.rindex(b"\n", 0, start) + 1          # the mirror starts at this line
    stream = os.path.join(tmp, "console.bin")
    open(stream, "wb").write(serial[start:])
    w, h, shown = read_ppm(ppm)
    want = os.path.join(tmp, "console-want.ppm")
    subprocess.run([REPLAY, stream, str(w), str(h), want], check=True)
    expected = read_ppm(want)[2]
    if shown != expected:
        bad = sum(1 for i in range(0, len(shown), 3) if shown[i:i + 3] != expected[i:i + 3])
        raise AssertionError(f"{bad} pixels differ from the host replay ({ppm} vs {want})")
    return f"{w}x{h} matches host replay of {len(serial) - start} console bytes"


def check_net(pcap):
    data = open(pcap, "rb").read()
    assert NET_MARKER in data, "marker frame not in pcap"
    return f"marker frame captured ({len(data)} B pcap)"


# ── tests ────────────────────────────────────────────────────────────────────

def boot(tmp, **kw) -> Guest:
    cfg = nq.QemuConfig(iso=os.path.join(ROOT, kw.pop("iso")), bios=kw.pop("bios"),
                        disk=os.path.join(ROOT, "disk.img"), serial="stdio",
                        qmp=os.path.join(tmp, "qmp.sock"), **kw)
    g = Guest(cfg)
    if not g.wait(PROMPT, 120):
        g.close()
        raise RuntimeError("no shell prompt:\n" + g.text()[-2000:])
    return g


def test_devices(tmp, iso, bios) -> list:
    results = []
    pcap, wav, ppm = (os.path.join(tmp, n) for n in ("net.pcap", "snd.wav", "gpu.ppm"))
    g = boot(tmp, iso=iso, bios=bios, devices=("all",), pcap=pcap, wav=wav)
    try:
        def step(name, guest_cmd, ok_text, check):
            try:
                out = g.run(guest_cmd) if guest_cmd else ""
                assert ok_text in out, f"guest said: {out.strip()[-300:]}"
                results.append((name, True, check()))
            except Exception as e:             # noqa: BLE001 — report and continue
                results.append((name, False, str(e)))

        def console_check():
            g.run("version")                       # typed on serial
            # ls.elf (ring 3) writes while the shell task renders: the race
            # the console's snapshot flush exists for.
            g.run("ls", until="app exit code")
            mark = len(g.out)
            for k in "version":                    # typed on the virtio keyboard
                g.qmp.send_key(k)
            g.qmp.send_key("ret")
            assert g.wait("NimixOS v", 15, mark), "keyboard input did not reach the shell"
            g.wait(PROMPT, 10, mark)
            time.sleep(0.5)                        # let the console's batched flush land
            g.qmp.screendump(ppm, device="gpu0")
            return check_console(bytes(g.out), ppm, tmp)
        step("console", None, "", console_check)   # before gpu: devtest paints over it
        step("gpu", "devtest gpu", "bars presented",
             lambda: (g.qmp.screendump(ppm, device="gpu0"), check_gpu(ppm))[1])
        step("snd", "devtest snd", "in flight 0", lambda: "recorded")
        step("net", "devtest net", "sent", lambda: "sent")

        def input_check():
            mark = len(g.out)
            g.type("devtest input")
            assert g.wait("listening", 15, mark), "devtest input did not start"
            time.sleep(0.5)
            for k in ("a", "b"):
                g.qmp.send_key(k)
            g.wait(PROMPT, 15, mark + 14)
            out = g.text(mark)
            for code in (30, 48):
                for val in (1, 0):
                    assert f"key code={code} value={val}" in out, f"missing key {code}/{val}: {out[-300:]}"
            return "a/b down+up delivered by IRQ"
        step("input", None, "", input_check)
    finally:
        g.close()                               # flushes the wav + pcap files
    # snd/net evidence is complete only after QEMU exits.
    for i, (name, ok, msg) in enumerate(results):
        if ok and name in ("snd", "net"):
            try:
                results[i] = (name, True, check_snd(wav) if name == "snd" else check_net(pcap))
            except Exception as e:             # noqa: BLE001
                results[i] = (name, False, str(e))
    return results


CRASHES = [
    # (devtest arg, serial evidence, proc the symbolizer must name)
    ("crash-pf",    "CPU EXCEPTION 14 (Page Fault) in kernel mode", "crashPageFault"),
    ("crash-ud",    "CPU EXCEPTION 6 (Invalid Opcode) in kernel mode", "crashInvalidOpcode"),
    # The index check fails in crashPanic, which the C compiler may inline.
    ("crash-panic", "KERNEL PANIC", ("crashPanic", "devtest")),
]


def named_frame(serial: str, tables, names) -> str:
    """The first symbolized backtrace frame naming one of `names`."""
    assert "backtrace:" in serial, "no backtrace"
    named = "".join(symbolize.symbolize(serial.splitlines(keepends=True), tables))
    names = names if isinstance(names, tuple) else (names,)
    hits = [l for l in named.splitlines() if "<-" in l and any(f"<- {p}" in l for p in names)]
    assert hits, f"{names} not in symbolized frames:\n{named[-800:]}"
    return hits[0].split("<-")[1].strip()


def test_crashes(tmp, iso, bios, kernel) -> list:
    """Kernel-mode faults: report + backtrace, then the machine halts."""
    results = []
    for arg, evidence, proc in CRASHES:
        g = boot(tmp, iso=iso, bios=bios, devices=("blk",))
        try:
            out = g.run(f"devtest {arg}", timeout=20, until="=== halted")
            assert evidence in out, f"no '{evidence}' in: {out[-400:]}"
            results.append((arg, True, named_frame(out, [symbolize.SymTab(kernel)], proc)))
        except Exception as e:                 # noqa: BLE001
            results.append((arg, False, str(e)))
        finally:
            g.close()
    return results


USER_FAULTS = [
    # (fault.elf arg, serial evidence, proc the symbolizer must name)
    ("",   "CPU EXCEPTION 14 (Page Fault) in USER mode", "nullWrite"),
    ("ud", "CPU EXCEPTION 6 (Invalid Opcode) in USER mode", "invalidOpcode"),
]


BUFFER_CASES = [
    # (buftest mode, expected app message, must the kernel kill it?)
    ("ok",   "buftest: ok", False),
    ("big",  "buftest: big ok", False),
    ("pass", "buftest: passed through a channel intact", False),
    ("move", "buftest: writing after giving the buffer away", True),
    ("seal", "buftest: writing to a sealed buffer", True),
    ("lend", "buftest: writing after giving the buffer away", True),
]


def test_buffers(tmp, iso, bios) -> list:
    """ipc/buffers enforced from ring 3: the rule (owned or sealed, never
    shared mutable) holds by page rights; a violation kills only that task."""
    results = []
    g = boot(tmp, iso=iso, bios=bios, devices=("blk",))
    try:
        for mode, said, killed in BUFFER_CASES:
            name = f"buffers-{mode}"
            try:
                until = "system continues" if killed else "app exit code"
                out = g.run(f"buftest {mode}", timeout=40, until=until)
                assert said in out, f"app did not say '{said}': {out[-300:]}"
                assert "still alive" not in out and "FAIL" not in out, out[-300:]
                if killed:
                    assert "CPU EXCEPTION 14 (Page Fault) in USER mode" in out, out[-300:]
                    results.append((name, True, "violation faulted; only buftest was killed"))
                else:
                    assert "app exit code: 0" in out, out[-300:]
                    results.append((name, True, said.split(": ", 1)[1]))
            except Exception as e:             # noqa: BLE001
                results.append((name, False, str(e)))
        assert "NimixOS" in g.run("version"), "shell dead after buffer violations"
    finally:
        g.close()
    return results


def test_clock(tmp, iso, bios) -> list:
    """V3b: the fine clock reaches ring 3 through a read-only page, no syscall.
    3 s of PIT ticks must measure 3 s (+-1 %) on the app's own rdtsc, and
    writing the page must fault and kill only the writer."""
    results = []
    g = boot(tmp, iso=iso, bios=bios, devices=("blk",))
    try:
        try:
            out = g.run("clocktest", timeout=60, until="app exit code")
            assert "clocktest: ok" in out and "FAIL" not in out, out[-400:]
            m = re.search(r"3000 ms of ticks measured (\d+) ms", out)
            assert m and 2970 <= int(m.group(1)) <= 3030, f"measured: {out[-300:]}"
            per = re.search(r"a clock read costs (\d+) ns, no syscall", out)
            assert per, out[-300:]
            results.append(("clock-read", True,
                            f"3000 ticks-ms measured {m.group(1)} ms; a read costs {per.group(1)} ns"))
        except Exception as e:                 # noqa: BLE001
            results.append(("clock-read", False, str(e)))
        try:
            out = g.run("clocktest write", timeout=40, until="system continues")
            assert "writing the read-only time page" in out, out[-300:]
            assert "still alive" not in out, out[-300:]
            assert "CPU EXCEPTION 14 (Page Fault) in USER mode" in out, out[-300:]
            results.append(("clock-write", True, "write to the time page faulted; only clocktest was killed"))
        except Exception as e:                 # noqa: BLE001
            results.append(("clock-write", False, str(e)))
        assert "NimixOS" in g.run("version"), "shell dead after the time page fault"
    finally:
        g.close()
    return results


def test_libc(tmp, iso, bios) -> list:
    """V2b: a plain C program (picolibc + libnimix) runs on NimixOS: printf,
    strtod, qsort, malloc, libm, nanosleep, files, directories, arguments."""
    results = []
    g = boot(tmp, iso=iso, bios=bios, devices=("blk",))
    try:
        try:
            out = g.run("libctest a b", timeout=60, until="app exit code")
            assert "libctest: ok" in out and "FAIL" not in out, out[-600:]
            m = re.search(r"libctest: (\d+) checks, 0 failed", out)
            assert m, out[-300:]
            slept = re.search(r"slept 250 ms, measured (\d+) ms", out)
            results.append(("libc", True, f"{m.group(1)} checks; 250 ms sleep measured {slept.group(1)} ms"))
        except Exception as e:                 # noqa: BLE001
            results.append(("libc", False, str(e)))
        assert "NimixOS" in g.run("version"), "shell dead after libctest"
    finally:
        g.close()
    return results


def test_fpu(tmp, iso, bios) -> list:
    """A program's x87/SSE state survives timer interrupts and doesn't leak
    between tasks (the kernel must not clobber xmm before saving it)."""
    results = []
    g = boot(tmp, iso=iso, bios=bios, devices=("blk",))
    try:
        try:
            out = g.run("fputest", timeout=40, until="app exit code")
            assert "fputest: ok" in out and "FAIL" not in out and "changed" not in out, out[-500:]
            results.append(("fpu", True, "xmm0-15 + x87 intact across ~8 timer ticks; clean start"))
        except Exception as e:                 # noqa: BLE001
            results.append(("fpu", False, str(e)))
    finally:
        g.close()
    return results


def gfx_pattern(w=640, h=400):
    """tests: the exact pixels apps/c/gfxtest presents (B8G8R8X8 -> RGB bytes)."""
    out = bytearray()
    for y in range(h):
        for x in range(w):
            if x in (0, w - 1) or y in (0, h - 1):
                out += b"\xff\xff\xff"
            else:
                out += bytes((x * 255 // (w - 1), y * 255 // (h - 1), (x ^ y) & 255))
    return bytes(out)


def region(ppm, x0, y0, w, h):
    sw, sh, px = read_ppm(ppm)
    return b"".join(px[((y0 + y) * sw + x0) * 3:((y0 + y) * sw + x0 + w) * 3] for y in range(h))


def test_display(tmp, iso, bios) -> list:
    """Display ABI v1: a ring-3 program presents an owned buffer. The screendump of
    the region must equal the pattern recomputed on the host, bad requests are
    refused, and the console returns when the program exits."""
    results = []
    ppm1, ppm2 = os.path.join(tmp, "gfx1.ppm"), os.path.join(tmp, "gfx2.ppm")
    g = boot(tmp, iso=iso, bios=bios, devices=("blk", "gpu"))
    try:
        try:
            mark = len(g.out)
            g.type("gfxtest hold")
            assert g.wait("gfxtest: presented", 40, mark), "never presented: " + g.text(mark)[-500:]
            out = g.text(mark)
            assert "FAIL" not in out, out[-600:]
            time.sleep(0.5)
            g.qmp.screendump(ppm1, device="gpu0")
            want = gfx_pattern()
            got = region(ppm1, 100, 50, 640, 400)
            bad = sum(1 for i in range(0, len(want), 3) if want[i:i + 3] != got[i:i + 3])
            assert bad == 0, f"{bad} of {len(want) // 3} pixels differ from the host pattern"
            results.append(("display-present", True, "640x400 region == host pattern; 10 bad requests refused"))
        except Exception as e:                 # noqa: BLE001
            results.append(("display-present", False, str(e)))
        try:
            assert g.wait("app exit code: 0", 30, mark), "gfxtest did not exit cleanly: " + g.text(mark)[-300:]
            g.wait(PROMPT, 10, mark)
            time.sleep(1.0)                    # the console repaints in a batched flush
            g.qmp.screendump(ppm2, device="gpu0")
            got2 = region(ppm2, 100, 50, 640, 400)
            same = sum(1 for i in range(0, len(want), 3) if want[i:i + 3] == got2[i:i + 3])
            assert same < len(want) // 3 // 20, f"{same} pixels still show the program's frame"
            results.append(("display-release", True, "the console repainted the screen after the owner exited"))
        except Exception as e:                 # noqa: BLE001
            results.append(("display-release", False, str(e)))
        assert "NimixOS" in g.run("version"), "shell dead after gfxtest"
    finally:
        g.close()
    return results


def test_raylib(tmp, iso, bios) -> list:
    """V5b: raylib 6.2 (rlsw) running on NimixOS in a ring-3 C program. The guest
    screendump must equal the host render of the same scene, and show REAL colours."""
    results = []
    ppm = os.path.join(tmp, "rl.ppm")
    host = os.path.join(ROOT, "build/v5/rldemo_host.ppm")
    g = boot(tmp, iso=iso, bios=bios, devices=("blk", "gpu"))
    try:
        mark = len(g.out)
        g.type("rldemo hold")
        try:
            assert g.wait("rldemo: presented", 60, mark), "never presented: " + g.text(mark)[-600:]
            assert "FAIL" not in g.text(mark), g.text(mark)[-600:]
            time.sleep(0.7)
            g.qmp.screendump(ppm, device="gpu0")
            got = region(ppm, 0, 0, 640, 400)
            want = read_ppm(host)[2]
            bad = [i // 3 for i in range(0, len(want), 3) if want[i:i + 3] != got[i:i + 3]]
            assert not bad, (f"{len(bad)} of {len(want) // 3} pixels differ from the host render; "
                             f"first at (x={bad[0] % 640}, y={bad[0] // 640})")
            results.append(("raylib-render", True, "raylib on NimixOS == the host render, all 256,000 pixels"))
        except Exception as e:                 # noqa: BLE001
            results.append(("raylib-render", False, str(e)))
        try:
            def px(x, y):
                i = (y * 640 + x) * 3
                return tuple(got[i:i + 3])
            truth = {"SKYBLUE rectangle": ((50, 50), (102, 191, 255)),
                     "GREEN circle": ((120, 260), (0, 228, 48)),
                     "MAROON triangle": ((520, 120), (190, 33, 55)),
                     "RAYWHITE background": ((600, 20), (245, 245, 245))}
            for name, (pos, rgb) in truth.items():
                assert px(*pos) == rgb, f"{name} at {pos} is {px(*pos)}, want {rgb} (red/blue swapped?)"
            results.append(("raylib-colours", True, "real colours on screen (SKYBLUE, GREEN, MAROON, RAYWHITE)"))
        except Exception as e:                 # noqa: BLE001
            results.append(("raylib-colours", False, str(e)))
        try:
            assert g.wait("rldemo: ok", 30, mark), "rldemo did not finish: " + g.text(mark)[-300:]
            assert g.wait("app exit code: 0", 20, mark), g.text(mark)[-300:]
        except Exception as e:                 # noqa: BLE001
            results.append(("raylib-exit", False, str(e)))
        assert "NimixOS" in g.run("version"), "shell dead after rldemo"
    finally:
        g.close()
    return results


def test_raylib_keys(tmp, iso, bios) -> list:
    """V5c: keyboard input into raylib. Real key events injected through QEMU (the
    virtio keyboard) reach the program as raylib key codes and characters, move a
    square on the screen, and do NOT reach the shell: input follows display ownership.
    Each key waits for the program's own acknowledgement (its log line) before the
    next is sent: a frame takes a while under TCG, and two taps in one frame are one
    IsKeyPressed edge by raylib's design."""
    results = []
    shots = [os.path.join(tmp, f"keys{i}.ppm") for i in range(2)]
    RED, BG = (230, 41, 55), (245, 245, 245)
    KEY_D, KEY_RIGHT, KEY_LEFT, KEY_Q = 68, 262, 263, 81          # raylib 6.2 KeyboardKey values

    def pixel(ppm, x, y):
        sw, sh, px = read_ppm(ppm)
        i = (y * sw + x) * 3
        return tuple(px[i:i + 3])

    g = boot(tmp, iso=iso, bios=bios, devices=("blk", "gpu", "input"))
    try:
        mark = len(g.out)
        g.type("rlkeys")

        def press(name, code):
            seen = len(g.out)
            g.qmp.send_key(name)
            assert g.wait(f"rlkeys: key {code}", 15, seen), f"the program never saw {name}: " + g.text(seen)[-300:]
            time.sleep(0.4)                    # let the frame that reacts to it be drawn

        try:
            assert g.wait("rlkeys: ready", 60, mark), "never started: " + g.text(mark)[-500:]
            time.sleep(1.0)
            g.qmp.screendump(shots[0], device="gpu0")
            assert pixel(shots[0], 40, 170) == RED and pixel(shots[0], 100, 170) == BG, "start position wrong"
            keys_mark = len(g.out)
            for _ in range(3):
                press("d", KEY_D)
            g.qmp.screendump(shots[1], device="gpu0")
            assert pixel(shots[1], 40 + 60, 170) == RED, f"3 x D: square not at step 3: {pixel(shots[1], 100, 170)}"
            assert pixel(shots[1], 40, 170) == BG, "the square is also still at step 0"
            results.append(("keys-move", True, "3 injected D presses moved the square 3 steps on screen"))
        except Exception as e:                 # noqa: BLE001
            results.append(("keys-move", False, str(e)))
        try:
            press("right", KEY_RIGHT)
            press("left", KEY_LEFT)
            press("left", KEY_LEFT)
            g.qmp.send_key("q")
            assert g.wait("rlkeys: ok", 20, mark), "did not quit on Q: " + g.text(mark)[-400:]
            out = g.text(mark)
            seq = [int(x) for x in re.findall(r"rlkeys: key (\d+)", out)]
            assert seq == [KEY_D] * 3 + [KEY_RIGHT, KEY_LEFT, KEY_LEFT, KEY_Q], f"keys received: {seq}"
            m = re.search(r'rlkeys: x=(-?\d+) text="([^"]*)"', out)
            assert m and m.group(1) == "2", f"final position {m and m.group(1)}, want 2 (3 +1 -1 -1)"
            assert m.group(2) == "ddd", f"characters received: {m.group(2)!r}, want 'ddd'"
            results.append(("keys-received", True, "exact key sequence D D D Right Left Left Q; characters 'ddd'; x = 2"))
        except Exception as e:                 # noqa: BLE001
            results.append(("keys-received", False, str(e)))
        try:
            g.wait(PROMPT, 10, mark)
            time.sleep(0.5)
            out = g.run("version")
            assert "NimixOS" in out, "shell dead: " + out[-200:]
            typed = g.text(keys_mark)
            assert "Unknown command" not in typed, "the shell received the program's keystrokes: " + typed[-300:]
            results.append(("keys-not-leaked", True, "the shell did not receive the keys typed into the program"))
        except Exception as e:                 # noqa: BLE001
            results.append(("keys-not-leaked", False, str(e)))
    finally:
        g.close()
    return results


def test_user_faults(tmp, iso, bios, kernel) -> list:
    """Ring-3 faults kill only the faulting task: one boot survives them all."""
    results = []
    app = os.path.join(ROOT, "build/apps/fault.elf")
    g = boot(tmp, iso=iso, bios=bios, devices=("blk",))
    try:
        for arg, evidence, proc in USER_FAULTS:
            name = f"user-fault{('-' + arg) if arg else ''}"
            try:
                out = g.run(f"fault {arg}".strip(), timeout=30, until="system continues")
                assert evidence in out, f"no '{evidence}' in: {out[-400:]}"
                bias = int(symbolize.BIAS_LINE.findall(out)[-1], 16)
                tables = [symbolize.SymTab(kernel), symbolize.SymTab(app, bias)]
                results.append((name, True, named_frame(out, tables, proc)))
            except Exception as e:             # noqa: BLE001
                results.append((name, False, str(e)))
        try:
            assert "NimixOS" in g.run("version"), "shell dead after user faults"
            ps = g.run("ps", until="app exit code")
            assert "fault.elf" not in ps, f"faulted task still listed:\n{ps[-400:]}"
            results.append(("survives", True, "shell alive, faulted tasks gone, region reused"))
        except Exception as e:                 # noqa: BLE001
            results.append(("survives", False, str(e)))
    finally:
        g.close()
    return results


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--iso", default="nimixos.iso")
    ap.add_argument("--bios", default=nq.DEFAULT_BIOS)
    ap.add_argument("--kernel", default=os.path.join(ROOT, "build/kernel-monolithic"))
    ap.add_argument("--only", choices=("devices", "crashes"))
    a = ap.parse_args()
    results = []
    with tempfile.TemporaryDirectory(prefix="nimix-dev-") as tmp:
        if a.only in (None, "devices"):
            results += test_devices(tmp, a.iso, a.bios)
        if a.only in (None, "crashes"):
            results += test_user_faults(tmp, a.iso, a.bios, a.kernel)
            results += test_buffers(tmp, a.iso, a.bios)
            results += test_clock(tmp, a.iso, a.bios)
            results += test_libc(tmp, a.iso, a.bios)
            results += test_fpu(tmp, a.iso, a.bios)
            results += test_display(tmp, a.iso, a.bios)
            results += test_raylib(tmp, a.iso, a.bios)
            results += test_raylib_keys(tmp, a.iso, a.bios)
            results += test_crashes(tmp, a.iso, a.bios, a.kernel)
    for name, ok, msg in results:
        print(f"{'PASS' if ok else 'FAIL'}: {name:12} {msg}")
    failed = sum(not ok for _, ok, _ in results)
    print(f"{len(results) - failed}/{len(results)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
