#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
qemu_debug.py — debugging driver for the NimixOS kernel under QEMU.

Three complementary modes (QEMU debugging best practices, see DECISIONS.md
"QEMU debug tooling" 2026-06-28):

  log   Boot with -d int,cpu_reset,guest_errors -no-reboot -no-shutdown and
        capture BOTH the QEMU event log (interrupts, exceptions, CPU state on
        triple-fault/reset) and a clean de-ANSI serial transcript. This is the
        "autopsy" — the first thing to run on a silent fault or triple fault.

  gdb   Boot with the GDB stub (-s -S, paused) and print the exact gdb command
        to attach with kernel symbols loaded. The "scalpel" — breakpoints,
        single-step, inspect registers/memory/used.idx etc.

  qmp   Boot with a QMP socket and drive QEMU programmatically over raw JSON
        (no external dependency): query run-state, issue monitor commands
        (info registers / info mem), and quit cleanly. Automation.

Usage:
  qemu_debug.py log  [--iso I] [--disk D] [--virtio-blk] [--until REGEX] [--timeout S]
  qemu_debug.py gdb  [--iso I] [--disk D] [--virtio-blk] [--kernel ELF]
  qemu_debug.py qmp  [--iso I] [--disk D] [--virtio-blk] [--monitor "info registers"] [--until REGEX]

Examples:
  # Autopsy a silent/triple fault — shows the faulting vector + CPU state:
  python3 tests/qemu_debug.py log --iso build/nimixos-test.iso --until "suite=" --timeout 30
  # Interactive gdb on the disk-boot path:
  python3 tests/qemu_debug.py gdb --iso nimixos.iso --disk disk.img --virtio-blk
  # Programmatic: boot, wait for a line, dump registers, quit:
  python3 tests/qemu_debug.py qmp --iso nimixos.iso --monitor "info registers" --until "nimixos>"
"""

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time

QEMU = "qemu-system-x86_64"
DEFAULT_BIOS = "/usr/share/ovmf/OVMF.fd"
SCRATCH = os.environ.get("QEMU_DEBUG_OUT", "qemu-debug")
GDB_PORT = 1234
QMP_PORT = 4445

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def strip_noise(text: str) -> str:
    """Remove NUL bytes and ANSI escapes — the serial stream is full of both."""
    return ANSI.sub("", text.replace("\x00", ""))


def disk_args(disk, virtio_blk):
    """Attach a disk image, as virtio-blk-pci (real path) or legacy IDE."""
    if not disk or not os.path.exists(disk):
        return []
    if virtio_blk:
        return ["-drive", f"if=none,file={disk},format=raw,id=d0",
                "-device", "virtio-blk-pci,drive=d0"]
    return ["-hda", disk]


def base_cmd(args):
    """QEMU invocation shared by all modes (display-less, deterministic)."""
    return [QEMU, "-cdrom", args.iso, "-bios", args.bios, "-m", str(args.mem),
            "-display", "none"] + disk_args(args.disk, args.virtio_blk)


# ──────────────────────────────────────────────────────────────────────────────
# Mode: log — autopsy via -d logging + clean serial capture
# ──────────────────────────────────────────────────────────────────────────────

def mode_log(args):
    os.makedirs(SCRATCH, exist_ok=True)
    serial_path = os.path.join(SCRATCH, "serial.log")
    qemu_path = os.path.join(SCRATCH, "qemu-events.log")
    serial_raw = open(serial_path + ".raw", "wb")

    cmd = base_cmd(args) + [
        "-no-reboot", "-no-shutdown",            # freeze on triple-fault, don't silently reset
        "-d", "int,cpu_reset,guest_errors",      # log interrupts/exceptions + CPU state on reset
        "-D", qemu_path,                          # QEMU event log → file
        "-serial", "file:" + serial_path + ".raw",
    ]
    print(f"[debug-log] {' '.join(cmd)}")
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # A faulting kernel can spew the SAME exception forever (#UD/#GP loop), which
    # would fill the disk. Cap the event log and bail early on a detected loop.
    found = _wait_for_file_pattern(serial_path + ".raw", args.until, args.timeout,
                                   proc, guard_log=qemu_path)
    _terminate(proc)
    serial_raw.close()

    raw = open(serial_path + ".raw", "rb").read().decode("latin-1")
    clean = strip_noise(raw)
    open(serial_path, "w").write(clean)

    print(f"\n=== serial (clean) → {serial_path} ===")
    print("\n".join(l for l in clean.splitlines() if l.strip())[-4000:])
    print(f"\n=== QEMU events (faults/resets) → {qemu_path} ===")
    _print_fault_summary(qemu_path)
    if args.until:
        print(f"\n[debug-log] pattern {args.until!r}: {'FOUND' if found else 'NOT FOUND'}")
    return 0 if (found or not args.until) else 1


VEC_NAMES = {                       # x86 exception vectors worth naming
    0x06: "#UD invalid-opcode", 0x08: "#DF double-fault",
    0x0D: "#GP general-protection", 0x0E: "#PF page-fault",
    0x00: "#DE divide-error", 0x0C: "#SS stack-fault",
}


def _print_fault_summary(qemu_path):
    """Summarise faults. A repeating exception is collapsed to one entry + count,
    so an infinite #UD/#PF loop reads as a diagnosis, not 700k identical lines."""
    if not os.path.exists(qemu_path):
        print("(no QEMU event log produced)")
        return
    lines = open(qemu_path).read().splitlines()
    # Lines look like:  "     768204: v=06 e=0000 i=0 ... pc=000000000000101e ..."
    # v < 0x20 are CPU exceptions (the bugs); v >= 0x20 are normal hardware IRQs.
    from collections import Counter
    sig = Counter()
    for l in lines:
        m = re.search(r"v=([0-9a-f]{2}).*?pc=([0-9a-f]+)", l)
        if not m:
            continue
        v = int(m.group(1), 16)
        if v < 0x20:                            # exception, not a routine IRQ
            sig[(v, m.group(2).lstrip("0") or "0")] += 1
    resets = sum("CPU Reset" in l or "RESET" in l for l in lines)
    if not sig:
        print("(no CPU exceptions logged — clean run)" +
              (f"  [{resets} resets seen]" if resets > 1 else ""))
        return
    total = sum(sig.values())
    print(f"{total} CPU exception(s); distinct (vector,RIP) signatures:")
    for (v, rip), n in sig.most_common(8):
        name = VEC_NAMES.get(v, f"vector 0x{v:02x}")
        loop = "  <-- REPEATING (fault loop)" if n > 50 else ""
        print(f"  {name}  RIP=0x{rip}  x{n}{loop}")
    # Show one full CPU-state block for the first exception (vector + reg lines).
    for i, l in enumerate(lines):
        m = re.search(r"v=([0-9a-f]{2})", l)
        if m and int(m.group(1), 16) < 0x20:
            print("\nfirst exception CPU state:")
            print("\n".join(lines[i:i + 5]))
            break


# ──────────────────────────────────────────────────────────────────────────────
# Mode: gdb — scalpel via the -s -S stub + a symbol-loaded .gdbinit
# ──────────────────────────────────────────────────────────────────────────────

def mode_gdb(args):
    kernel = args.kernel or _guess_kernel(args.iso)
    gdbinit = os.path.join(SCRATCH, "gdbinit")
    os.makedirs(SCRATCH, exist_ok=True)
    _write_gdbinit(gdbinit, kernel)

    cmd = base_cmd(args) + ["-s", "-S", "-no-reboot", "-no-shutdown"]
    print(f"[debug-gdb] launching paused QEMU with GDB stub on :{GDB_PORT}")
    print(f"[debug-gdb] {' '.join(cmd)}")
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.5)
    print("\n=== Connect a debugger in another terminal: ===")
    print(f"    gdb -x {gdbinit}")
    print("  (kernel symbols loaded; breakpoints set; 'continue' to run)")
    print("\n[debug-gdb] Ctrl-C here to stop QEMU when done.")
    try:
        proc.wait()
    except KeyboardInterrupt:
        _terminate(proc)
    return 0


def _write_gdbinit(path, kernel):
    """A .gdbinit that loads kernel symbols, connects, and sets useful stops."""
    content = f"""# Auto-generated by qemu_debug.py — NimixOS kernel debugging
set confirm off
set architecture i386:x86-64
file {kernel}
target remote localhost:{GDB_PORT}

# Stops that matter for this kernel. Add your own with: break <proc>
break kernelMain
break panic
# virtio disk path (the V10 bug lived here):
break virtioBlkRead
break virtioBlkInitPci

# Handy: dump the virtqueue used-ring index when stopped in the blk path
define vq
  printf "used.idx=%d lastUsed=%d\\n", gVirtioBlk.queue.used.idx, gVirtioBlk.queue.lastUsed
end

echo \\n[gdbinit] symbols loaded, connected to :{GDB_PORT}. 'continue' to boot.\\n
"""
    open(path, "w").write(content)


def _guess_kernel(iso):
    """Best-effort: the symbol'd ELF matching the ISO under build/."""
    for c in ("build/kernel-test", "build/kernel-monolithic"):
        if os.path.exists(c):
            return c
    return "build/kernel-monolithic"


# ──────────────────────────────────────────────────────────────────────────────
# Mode: qmp — automation via raw JSON over a socket (no dependency)
# ──────────────────────────────────────────────────────────────────────────────

class Qmp:
    """Minimal QMP client: connect, handshake, execute, monitor-command."""

    def __init__(self, port):
        self.sock = socket.create_connection(("localhost", port), timeout=10)
        self.f = self.sock.makefile("rwb", buffering=0)
        self._readline()                       # greeting (QMP capabilities banner)
        self.execute("qmp_capabilities")       # leave negotiation mode

    def _readline(self):
        return json.loads(self.f.readline().decode())

    def execute(self, cmd, **args):
        msg = {"execute": cmd}
        if args:
            msg["arguments"] = args
        self.f.write((json.dumps(msg) + "\n").encode())
        while True:                            # skip async events, return the reply
            reply = self._readline()
            if "return" in reply or "error" in reply:
                return reply

    def monitor(self, line):
        """Run a human-monitor command (info registers, info mem, x/…)."""
        r = self.execute("human-monitor-command", **{"command-line": line})
        return r.get("return", r)


def mode_qmp(args):
    cmd = base_cmd(args) + [
        "-qmp", f"tcp:localhost:{QMP_PORT},server,nowait",
        "-no-reboot", "-no-shutdown",
        "-serial", "file:" + os.path.join(SCRATCH, "serial.log") + ".raw",
    ]
    os.makedirs(SCRATCH, exist_ok=True)
    print(f"[debug-qmp] {' '.join(cmd)}")
    proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    serial = os.path.join(SCRATCH, "serial.log") + ".raw"
    found = _wait_for_file_pattern(serial, args.until, args.timeout, proc)

    try:
        q = Qmp(QMP_PORT)
        print("[debug-qmp] connected.")
        print("status:", q.execute("query-status").get("return"))
        if args.monitor:
            print(f"\n=== monitor: {args.monitor} ===")
            print(q.monitor(args.monitor))
        q.execute("quit")
    except Exception as e:                      # noqa: BLE001 — report any QMP failure
        print(f"[debug-qmp] QMP error: {e}", file=sys.stderr)
    _terminate(proc)
    if args.until:
        print(f"[debug-qmp] pattern {args.until!r}: {'FOUND' if found else 'NOT FOUND'}")
    return 0 if (found or not args.until) else 1


# ──────────────────────────────────────────────────────────────────────────────
# Shared helpers
# ──────────────────────────────────────────────────────────────────────────────

MAX_EVENT_LOG = 8 * 1024 * 1024     # 8 MB cap — a fault loop hits this fast


def _wait_for_file_pattern(path, pattern, timeout, proc, guard_log=None):
    """Poll a growing log file until `pattern` (regex) appears or timeout.

    If `guard_log` is given, abort early when it exceeds MAX_EVENT_LOG — a
    repeating exception loop would otherwise grow it without bound.
    """
    rx = re.compile(pattern) if pattern else None
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:            # QEMU exited
            break
        if guard_log and os.path.exists(guard_log):
            if os.path.getsize(guard_log) > MAX_EVENT_LOG:
                print(f"[debug-log] event log exceeded {MAX_EVENT_LOG//(1024*1024)}MB"
                      " — likely a repeating fault loop; stopping early.")
                return rx is None
        if rx and os.path.exists(path):
            if rx.search(strip_noise(open(path, "rb").read().decode("latin-1"))):
                return True
        time.sleep(0.25)
    return rx is None


def _terminate(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def main():
    p = argparse.ArgumentParser(description="NimixOS QEMU debug driver")
    p.add_argument("mode", choices=["log", "gdb", "qmp"])
    p.add_argument("--iso", default="nimixos.iso")
    p.add_argument("--disk", default=None)
    p.add_argument("--virtio-blk", action="store_true")
    p.add_argument("--bios", default=DEFAULT_BIOS)
    p.add_argument("--mem", type=int, default=256)
    p.add_argument("--timeout", type=int, default=30)
    p.add_argument("--until", default=None, help="regex to wait for in serial")
    p.add_argument("--kernel", default=None, help="symbol'd ELF for gdb")
    p.add_argument("--monitor", default=None, help="qmp: human-monitor command")
    args = p.parse_args()
    return {"log": mode_log, "gdb": mode_gdb, "qmp": mode_qmp}[args.mode](args)


if __name__ == "__main__":
    sys.exit(main())
