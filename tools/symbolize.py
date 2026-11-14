#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""symbolize — turn NimixOS serial crash reports into function names.

Reads a serial log (file or stdin), finds every hex address in crash reports
("rip=0x…", backtrace "#n 0x…" lines) and annotates it with the enclosing
function from the kernel ELF symbol table, or from an app ELF when the address
falls in its loaded range.

    tools/symbolize.py serial.log                          # kernel only
    tools/symbolize.py serial.log --app build/apps/ls.elf  # + app (bias from log)
    tools/symbolize.py serial.log --app ls.elf@0x4000000   # explicit load bias
    make run 2>&1 | tee s.log;  tools/symbolize.py s.log

Uses `nm` (always) and `addr2line` (file:line when built with `make DEBUG=1`).
Nim's mangled names (proc__module_u123) are shown as `proc (module)`.
"""
import argparse
import bisect
import re
import shutil
import subprocess
import sys

ADDR_LINE = re.compile(r"(rip=0x|^\s*#\d+ 0x)([0-9A-Fa-f]+)")
BIAS_LINE = re.compile(r"ELF PIE: load bias=0x([0-9A-Fa-f]+)")
NIM_MANGLED = re.compile(r"^(?P<name>.+?)__(?P<mod>[A-Za-z0-9_]+?)_u\d+$")


def demangle(sym: str) -> str:
    m = NIM_MANGLED.match(sym)
    if not m:
        return sym
    # Nim module mangling: "../" → OOZ, "/" → Z, "_" → 95.
    mod = m.group("mod").replace("OOZ", "").replace("95", "_").replace("Z", "/")
    return f"{m.group('name')} ({mod})"


class SymTab:
    def __init__(self, elf: str, bias: int = 0):
        self.elf, self.bias = elf, bias
        out = subprocess.run(["nm", "-n", "--defined-only", elf],
                             capture_output=True, text=True, check=True).stdout
        self.addrs, self.names = [], []
        for line in out.splitlines():
            parts = line.split()
            if len(parts) == 3 and parts[1] in "tTwW":
                self.addrs.append(int(parts[0], 16) + bias)
                self.names.append(parts[2])
        self.lo = self.addrs[0] if self.addrs else 0
        self.hi = self.addrs[-1] + 0x10000 if self.addrs else 0

    def lookup(self, addr: int):
        if not (self.lo <= addr < self.hi):
            return None
        i = bisect.bisect_right(self.addrs, addr) - 1
        if i < 0:
            return None
        return self.names[i], addr - self.addrs[i]

    def source_line(self, addr: int) -> str:
        if not shutil.which("addr2line"):
            return ""
        out = subprocess.run(["addr2line", "-e", self.elf, hex(addr - self.bias)],
                             capture_output=True, text=True).stdout.strip()
        return "" if "?" in out else out          # no line info (asm, no -g)


def symbolize(lines, tables):
    for line in lines:
        m = ADDR_LINE.search(line)
        if not m:
            yield line
            continue
        addr = int(m.group(2), 16)
        # A return address points after the call: look up addr-1 for frames.
        probe = addr if "rip=" in m.group(1) else addr - 1
        note = ""
        for t in tables:
            hit = t.lookup(probe)
            if hit:
                name, off = hit
                src = t.source_line(probe)
                where = "" if t.bias == 0 else f" [{t.elf}]"
                note = f"  <- {demangle(name)}+0x{off:x}{where}" + (f"  {src}" if src else "")
                break
        yield line.rstrip("\n") + note + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("log", nargs="?", default="-", help="serial log (default stdin)")
    ap.add_argument("--kernel", default="build/kernel-monolithic")
    ap.add_argument("--app", action="append", default=[],
                    help="app ELF, optionally @0xBIAS (default: last bias in log)")
    a = ap.parse_args()
    text = (sys.stdin if a.log == "-" else open(a.log, errors="replace")).read()
    text = text.replace("\x00", "")
    biases = BIAS_LINE.findall(text)
    tables = [SymTab(a.kernel)]
    for spec in a.app:
        path, _, bias = spec.partition("@")
        b = int(bias, 16) if bias else (int(biases[-1], 16) if biases else 0)
        tables.append(SymTab(path, b))
    sys.stdout.writelines(symbolize(text.splitlines(keepends=True), tables))


if __name__ == "__main__":
    main()
