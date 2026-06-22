#!/usr/bin/env python3
"""
NimixOS QEMU Serial Test Harness

Usage:
    python3 tests/qemu_harness.py --iso nimixos.iso
    python3 tests/qemu_harness.py --iso nimixos.iso --disk disk.img --timeout 60
    python3 tests/qemu_harness.py --iso nimixos.iso --bios /usr/share/ovmf/OVMF.fd

Launches QEMU with a named pipe on /tmp/nimix, sends shell commands to the
NimixOS serial console, and asserts patterns in the output.

Exit codes: 0 = all tests pass, 1 = one or more tests failed.
"""

import argparse
import atexit
import os
import re
import signal
import subprocess
import sys
import threading
import time

PIPE_BASE = "/tmp/nimix"
PIPE_IN   = PIPE_BASE + ".in"
PIPE_OUT  = PIPE_BASE + ".out"

# ---------------------------------------------------------------------------
# Built-in test cases: (name, command_or_None, expected_pattern)
# ---------------------------------------------------------------------------
TESTS = [
    ("boot",    None,       r"nimixos>"),
    ("help",    "help",     r"Commands:"),
    ("version", "version",  r"NimixOS"),
    ("meminfo", "meminfo",  r"Physical memory"),
    ("model",   "model",    r"Kernel model"),
    ("unknown", "zzz",      r"Unknown command"),
]


class QemuHarness:
    def __init__(self, iso, disk=None, bios="/usr/share/ovmf/OVMF.fd",
                 mem=256, timeout=30):
        self.iso     = iso
        self.disk    = disk
        self.bios    = bios
        self.mem     = mem
        self.timeout = timeout

        self._proc      = None
        self._out_fd    = None
        self._in_fd     = None
        self._buf       = ""
        self._buf_lock  = threading.Lock()
        self._reader    = None
        self._stop_evt  = threading.Event()

        atexit.register(self.cleanup)

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start(self):
        """Create named pipes and launch QEMU."""
        # Remove stale pipes
        for p in (PIPE_IN, PIPE_OUT):
            try:
                os.remove(p)
            except FileNotFoundError:
                pass

        os.mkfifo(PIPE_IN)
        os.mkfifo(PIPE_OUT)

        cmd = [
            "qemu-system-x86_64",
            "-cdrom",   self.iso,
            "-bios",    self.bios,
            "-m",       f"{self.mem}M",
            "-serial",  f"pipe:{PIPE_BASE}",
            "-display", "none",
            "-no-reboot",
        ]
        if self.disk and os.path.exists(self.disk):
            cmd += ["-hda", self.disk]

        # Launch QEMU; keep stdout/stderr quiet unless debugging
        self._proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        # Open the write end of .in (QEMU reads from it)
        # Must open non-blocking first so we don't deadlock waiting for reader
        self._in_fd = open(PIPE_IN, "wb", buffering=0)

        # Open the read end of .out (QEMU writes to it)
        self._out_fd = open(PIPE_OUT, "rb", buffering=0)

        # Background reader thread fills self._buf
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    def cleanup(self):
        """Kill QEMU and close file handles."""
        self._stop_evt.set()

        if self._proc and self._proc.poll() is None:
            try:
                self._proc.send_signal(signal.SIGTERM)
                self._proc.wait(timeout=3)
            except Exception:
                try:
                    self._proc.kill()
                except Exception:
                    pass

        for fd in (self._in_fd, self._out_fd):
            if fd:
                try:
                    fd.close()
                except Exception:
                    pass

        for p in (PIPE_IN, PIPE_OUT):
            try:
                os.remove(p)
            except FileNotFoundError:
                pass

    # ------------------------------------------------------------------
    # Internal reader
    # ------------------------------------------------------------------

    def _read_loop(self):
        while not self._stop_evt.is_set():
            try:
                chunk = self._out_fd.read(256)
                if not chunk:
                    time.sleep(0.01)
                    continue
                text = chunk.decode("utf-8", errors="replace")
                with self._buf_lock:
                    self._buf += text
            except Exception:
                break

    def _get_buf(self):
        with self._buf_lock:
            return self._buf

    # ------------------------------------------------------------------
    # Public helpers
    # ------------------------------------------------------------------

    def send(self, cmd: str):
        """Send a command line to the serial console."""
        line = (cmd + "\n").encode("utf-8")
        self._in_fd.write(line)
        self._in_fd.flush()

    def expect(self, pattern: str, timeout: float = 10.0) -> tuple[bool, str]:
        """
        Wait up to `timeout` seconds for `pattern` (regex) to appear in serial
        output.  Returns (matched, captured_output).
        """
        deadline = time.monotonic() + timeout
        regex    = re.compile(pattern, re.IGNORECASE)
        while time.monotonic() < deadline:
            buf = self._get_buf()
            if regex.search(buf):
                return True, buf
            time.sleep(0.1)
        return False, self._get_buf()

    def clear_buf(self):
        with self._buf_lock:
            self._buf = ""

    def wait_prompt(self, timeout: float = None) -> bool:
        """Wait for the initial shell prompt."""
        t = timeout if timeout is not None else self.timeout
        ok, _ = self.expect(r"nimixos>", timeout=t)
        return ok


# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

def run_tests(harness: QemuHarness) -> bool:
    """Run all TESTS.  Returns True if every test passes."""
    print(f"\n{'='*60}")
    print("NimixOS QEMU Test Suite")
    print(f"{'='*60}")

    all_pass = True

    for name, cmd, pattern in TESTS:
        harness.clear_buf()

        if cmd is None:
            # Boot test: just wait for initial prompt (already booted)
            ok, output = harness.expect(pattern, timeout=harness.timeout)
        else:
            harness.send(cmd)
            ok, output = harness.expect(pattern, timeout=10)

        status = "PASS" if ok else "FAIL"
        if not ok:
            all_pass = False

        print(f"  [{status}] {name:<12}  pattern={pattern!r}")
        if not ok:
            # Show last 400 chars of output for debugging
            snippet = output[-400:].replace("\r", "").strip()
            print(f"           Output (tail):\n{snippet}\n")

        # Wait for next prompt before next test
        if cmd is not None:
            harness.expect(r"nimixos>", timeout=5)

    print(f"{'='*60}")
    print("Result:", "ALL PASS" if all_pass else "SOME TESTS FAILED")
    print(f"{'='*60}\n")
    return all_pass


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="NimixOS QEMU serial test harness",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--iso",     required=True,
                        help="Path to NimixOS ISO image")
    parser.add_argument("--disk",    default=None,
                        help="Path to disk image (optional)")
    parser.add_argument("--bios",    default="/usr/share/ovmf/OVMF.fd",
                        help="Path to OVMF firmware (default: /usr/share/ovmf/OVMF.fd)")
    parser.add_argument("--mem",     type=int, default=256,
                        help="QEMU memory in MB (default: 256)")
    parser.add_argument("--timeout", type=int, default=30,
                        help="Boot timeout in seconds (default: 30)")
    args = parser.parse_args()

    if not os.path.isfile(args.iso):
        print(f"ERROR: ISO not found: {args.iso}", file=sys.stderr)
        sys.exit(1)

    if not os.path.isfile(args.bios):
        print(f"ERROR: BIOS not found: {args.bios}", file=sys.stderr)
        sys.exit(1)

    harness = QemuHarness(
        iso=args.iso,
        disk=args.disk,
        bios=args.bios,
        mem=args.mem,
        timeout=args.timeout,
    )

    print(f"Launching QEMU: {args.iso}")
    print(f"  bios={args.bios}  mem={args.mem}M  boot-timeout={args.timeout}s")

    harness.start()

    print("Waiting for boot prompt…")
    if not harness.wait_prompt():
        print("FAIL: timed out waiting for nimixos> prompt", file=sys.stderr)
        harness.cleanup()
        sys.exit(1)

    print("Boot prompt received.")

    passed = run_tests(harness)
    harness.cleanup()
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
