#!/usr/bin/env python3
"""
NimixOS QEMU Serial Test Harness

Usage:
    python3 tests/qemu_harness.py --iso nimixos.iso
    python3 tests/qemu_harness.py --iso nimixos.iso --disk disk.img --timeout 60
    python3 tests/qemu_harness.py --iso nimixos.iso --bios /usr/share/ovmf/OVMF.fd
    python3 tests/qemu_harness.py --list

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

PROMPT = "nimixos> "

# ---------------------------------------------------------------------------
# Built-in test cases: (name, command_or_None, expected_pattern, timeout_s)
# ---------------------------------------------------------------------------
def build_tests(disk=None):
    """Return list of test dicts. disk-dependent tests are skipped if disk absent."""
    tests = [
        {"name": "boot",    "cmd": None,         "pattern": r"nimixos>",         "timeout": 30},
        {"name": "help",    "cmd": "help",        "pattern": r"Commands:",        "timeout": 10},
        {"name": "version", "cmd": "version",     "pattern": r"NimixOS",          "timeout": 10},
        {"name": "model",   "cmd": "model",       "pattern": r"Kernel model",     "timeout": 10},
        {"name": "unknown", "cmd": "zzz",         "pattern": r"Unknown command",  "timeout": 10},
        {"name": "ps",      "cmd": "ps",          "pattern": r"PID",              "timeout": 10},
        {"name": "stats",   "cmd": "stats",       "pattern": r"Uptime",           "timeout": 10},
        {"name": "meminfo", "cmd": "meminfo",     "pattern": r"Physical memory",  "timeout": 10},
    ]
    # exec_* tests require a disk image with the ELFs present
    disk_ok = disk and os.path.exists(disk)
    skip_reason = "disk.img not present"

    def disk_test(name, cmd, pattern, timeout=15):
        t = {"name": name, "cmd": cmd, "pattern": pattern, "timeout": timeout}
        if not disk_ok:
            t["skip"] = True
            t["skip_reason"] = skip_reason
        return t

    tests += [
        disk_test("exec_hello", "exec hello.elf", r"Hello from"),
        disk_test("exec_ps",    "exec ps.elf",    r"PID\s+CLASS\s+STATE"),
        disk_test("exec_top",   "exec top.elf",   r"uptime_ticks", timeout=20),
    ]
    return tests


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

        self._proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        self._in_fd = open(PIPE_IN, "wb", buffering=0)
        self._out_fd = open(PIPE_OUT, "rb", buffering=0)

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

    def wait_for_prompt(self, timeout: float = None) -> str:
        """
        Wait specifically for the 'nimixos> ' shell prompt.

        Returns the accumulated output when the prompt is found.
        Raises TimeoutError with a descriptive message (including what was
        received so far) if the prompt does not appear within `timeout` seconds.
        """
        t = timeout if timeout is not None else self.timeout
        deadline = time.monotonic() + t
        prompt_re = re.compile(re.escape(PROMPT))
        while time.monotonic() < deadline:
            buf = self._get_buf()
            if prompt_re.search(buf):
                return buf
            time.sleep(0.1)
        buf = self._get_buf()
        snippet = buf[-400:].replace("\r", "").strip()
        raise TimeoutError(
            f"Timed out after {t}s waiting for {PROMPT!r}. "
            f"Received so far: {snippet!r}"
        )

    def wait_prompt(self, timeout: float = None) -> bool:
        """Wait for the initial shell prompt. Returns True on success."""
        try:
            self.wait_for_prompt(timeout=timeout)
            return True
        except TimeoutError:
            return False


# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

def run_tests(harness: QemuHarness, tests: list) -> bool:
    """Run all tests.  Returns True if every non-skipped test passes."""
    print(f"\n{'='*60}")
    print("NimixOS QEMU Test Suite")
    print(f"{'='*60}")

    results = []  # list of (name, status, detail)

    for t in tests:
        name    = t["name"]
        cmd     = t["cmd"]
        pattern = t["pattern"]
        timeout = t.get("timeout", 10)

        # Skip check
        if t.get("skip"):
            reason = t.get("skip_reason", "skipped")
            print(f"  [SKIP] {name:<12}  ({reason})")
            results.append((name, "SKIP", reason))
            continue

        harness.clear_buf()

        if cmd is None:
            # Boot test: wait for initial prompt
            ok, output = harness.expect(pattern, timeout=harness.timeout)
        else:
            harness.send(cmd)
            ok, output = harness.expect(pattern, timeout=timeout)

        if ok:
            print(f"  [PASS] {name:<12}  pattern={pattern!r}")
            results.append((name, "PASS", None))
        else:
            snippet = output[-400:].replace("\r", "").strip()
            print(f"  [FAIL] {name:<12}  pattern={pattern!r}")
            results.append((name, "FAIL", (pattern, snippet)))

        # Wait for next prompt before next test
        if cmd is not None:
            harness.expect(r"nimixos>", timeout=5)

    # ------------------------------------------------------------------
    # Structured summary
    # ------------------------------------------------------------------
    print(f"{'='*60}")
    passed  = sum(1 for _, s, _ in results if s == "PASS")
    skipped = sum(1 for _, s, _ in results if s == "SKIP")
    total   = len(results)
    ran     = total - skipped
    print(f"Results: {passed}/{ran} passed" +
          (f"  ({skipped} skipped)" if skipped else ""))

    failures = [(n, d) for n, s, d in results if s == "FAIL"]
    for name, (pattern, snippet) in failures:
        print(f"FAIL: {name} — expected {pattern!r} in output, got: {snippet!r}")

    print(f"{'='*60}\n")
    return len(failures) == 0


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="NimixOS QEMU serial test harness",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--iso",     default=None,
                        help="Path to NimixOS ISO image")
    parser.add_argument("--disk",    default=None,
                        help="Path to disk image (optional)")
    parser.add_argument("--bios",    default="/usr/share/ovmf/OVMF.fd",
                        help="Path to OVMF firmware (default: /usr/share/ovmf/OVMF.fd)")
    parser.add_argument("--mem",     type=int, default=256,
                        help="QEMU memory in MB (default: 256)")
    parser.add_argument("--timeout", type=int, default=30,
                        help="Boot timeout in seconds (default: 30)")
    parser.add_argument("--list",    action="store_true",
                        help="Print all test names without running them")
    args = parser.parse_args()

    tests = build_tests(disk=args.disk)

    if args.list:
        print("Available tests:")
        for t in tests:
            suffix = "  [skip: disk absent]" if t.get("skip") else ""
            print(f"  {t['name']}{suffix}")
        return

    # Running tests requires --iso
    if not args.iso:
        parser.error("--iso is required unless --list is used")

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
    try:
        harness.wait_for_prompt()
    except TimeoutError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        harness.cleanup()
        sys.exit(1)

    print("Boot prompt received.")

    passed = run_tests(harness, tests)
    harness.cleanup()
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
