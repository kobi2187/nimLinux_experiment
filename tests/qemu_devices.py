#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Host-verified virtio device + crash-report tests for NimixOS under QEMU.

Each device test makes the guest do something with a real effect outside the
VM, then checks that effect on the host — not the guest's word for it:

    gpu    devtest gpu    → QMP screendump of the virtio-gpu head: 4 colour bars
    snd    devtest snd    → QEMU wav audiodev recording: ~440 Hz square wave
    net    devtest net    → QEMU filter-dump pcap: our UDP marker frame
    input  QMP keys a, b  → guest prints evdev codes 30/48 (down + up)

Crash tests boot once per fault and check the serial crash report: vector,
registers, a backtrace, and that tools/symbolize.py names the faulting proc.

    python3 tests/qemu_devices.py                 # devices + crashes
    python3 tests/qemu_devices.py --only devices  # or: crashes
"""
import argparse
import os
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


def test_crashes(tmp, iso, bios, kernel) -> list:
    results = []
    for arg, evidence, proc in CRASHES:
        g = boot(tmp, iso=iso, bios=bios, devices=("blk",))
        try:
            out = g.run(f"devtest {arg}", timeout=20, until="=== halted")
            assert evidence in out, f"no '{evidence}' in: {out[-400:]}"
            assert "backtrace:" in out, "no backtrace"
            named = "".join(symbolize.symbolize(out.splitlines(keepends=True),
                                                [symbolize.SymTab(kernel)]))
            frames = [l for l in named.splitlines() if "<-" in l]
            names = proc if isinstance(proc, tuple) else (proc,)
            hits = [l for l in frames if any(f"<- {p}" in l for p in names)]
            assert hits, f"{names} not in symbolized frames:\n{named[-800:]}"
            hit = hits[0]
            results.append((arg, True, hit.split("<-")[1].strip()))
        except Exception as e:                 # noqa: BLE001
            results.append((arg, False, str(e)))
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
            results += test_crashes(tmp, a.iso, a.bios, a.kernel)
    for name, ok, msg in results:
        print(f"{'PASS' if ok else 'FAIL'}: {name:12} {msg}")
    failed = sum(not ok for _, ok, _ in results)
    print(f"{len(results) - failed}/{len(results)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
