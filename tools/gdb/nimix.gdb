# SPDX-License-Identifier: GPL-2.0
# NimixOS gdb helpers — sourced by `make gdb-attach` / qemu_debug.py gdbinit.
# Works without debug info (frame-pointer walk + ELF symbols); build with
# `make DEBUG=1` for source lines and locals.

define nimix-breaks
  # Stop on every fatal path: CPU exception report, Nim panic/abort.
  rbreak ^fatalExceptionHandler__
  break nimixPrintBacktraceHere
end
document nimix-breaks
Break on CPU-exception reports and Nim runtime panics.
end

python
import gdb
import re

NIM = re.compile(r"^(?P<name>.+?)__(?P<mod>[A-Za-z0-9_]+?)_u\d+$")

def demangle(sym):
    m = NIM.match(sym)
    if not m:
        return sym
    mod = m.group("mod").replace("OOZ", "").replace("95", "_").replace("Z", "/")
    return "%s (%s)" % (m.group("name"), mod)

_SYMS = None

def symbols():
    """name → address for the kernel ELF (via nm: works without debug info,
    where gdb's own lookup misses BSS/data symbols)."""
    global _SYMS
    if _SYMS is None:
        import subprocess
        out = subprocess.run(["nm", gdb.current_progspace().filename],
                             capture_output=True, text=True).stdout
        _SYMS = {}
        for line in out.splitlines():
            parts = line.split()
            if len(parts) == 3:
                _SYMS[parts[2]] = int(parts[0], 16)
    return _SYMS

def find_symbol(prefix):
    """Address of <prefix> or <prefix>__<module>_u<n> (a Nim global/proc)."""
    for name, addr in symbols().items():
        if name == prefix or name.startswith(prefix + "__"):
            return addr
    raise gdb.GdbError("symbol %s not found" % prefix)

def describe(addr):
    try:
        s = gdb.execute("info symbol 0x%x" % addr, to_string=True).strip()
    except gdb.error:
        return "?"
    if s.startswith("No symbol"):
        return "?"
    name, _, rest = s.partition(" in section")
    base, _, off = name.partition(" + ")
    return demangle(base.strip()) + ("+" + off if off else "")

def u64(addr):
    return int(gdb.selected_inferior().read_memory(addr, 8).cast("Q")[0])

class NimixBt(gdb.Command):
    """Frame-pointer backtrace from the current rip/rbp (no debug info needed)."""
    def __init__(self):
        super().__init__("nimix-bt", gdb.COMMAND_STACK)
    def invoke(self, arg, from_tty):
        rip = int(gdb.parse_and_eval("$rip")) & (2**64 - 1)
        frame = int(gdb.parse_and_eval("$rbp")) & (2**64 - 1)
        print("  #0  0x%016x  %s" % (rip, describe(rip)))
        for n in range(1, 32):
            if frame == 0 or frame & 7 or frame >= 1 << 47:
                break
            try:
                nxt, ret = u64(frame), u64(frame + 8)
            except gdb.MemoryError:
                break
            if ret == 0:
                break
            print("  #%-2d 0x%016x  %s" % (n, ret, describe(ret - 1)))
            if nxt <= frame or nxt - frame > 1 << 20:
                break
            frame = nxt
NimixBt()

class NimixDmesg(gdb.Command):
    """Print the kernel log ring (what the `dmesg` shell command shows)."""
    def __init__(self):
        super().__init__("nimix-dmesg", gdb.COMMAND_DATA)
    def invoke(self, arg, from_tty):
        ring = find_symbol("klogRing")
        written = u64(find_symbol("klogWritten"))
        size = 16384                                    # core/klog_ring.KlogRingSize
        n = min(written, size)
        mem = gdb.selected_inferior().read_memory(ring, size).tobytes()
        start = (written - n) % size
        data = mem[start:] + mem[:start] if n == size else mem[:n]
        print(data[-n:].decode(errors="replace"))
NimixDmesg()

class NimixApp(gdb.Command):
    """nimix-app ELF BIAS — load an app's symbols at its PIE load bias
    (the kernel logs it as 'ELF PIE: load bias=0x…')."""
    def __init__(self):
        super().__init__("nimix-app", gdb.COMMAND_FILES)
    def invoke(self, arg, from_tty):
        argv = gdb.string_to_argv(arg)
        if len(argv) != 2:
            raise gdb.GdbError("usage: nimix-app <elf> <bias>")
        gdb.execute("add-symbol-file %s -o %s" % (argv[0], argv[1]))
NimixApp()

class NimixSym(gdb.Command):
    """nimix-sym NAME — list kernel symbols for a Nim proc/var (mangled names)."""
    def __init__(self):
        super().__init__("nimix-sym", gdb.COMMAND_DATA)
    def invoke(self, arg, from_tty):
        want = arg.strip()
        for name, addr in sorted(symbols().items(), key=lambda kv: kv[1]):
            if name == want or name.startswith(want + "__"):
                print("0x%016x  %s  [%s]" % (addr, demangle(name), name))
NimixSym()
end

define nimix-help
  echo NimixOS gdb helpers:\n
  echo \  nimix-breaks          break on CPU-exception reports + Nim panics\n
  echo \  nimix-bt              frame-pointer backtrace (no debug info needed)\n
  echo \  nimix-dmesg           print the kernel log ring\n
  echo \  nimix-sym NAME        find a Nim proc/var by name (mangled symbols)\n
  echo \  nimix-app ELF BIAS    load app symbols at its PIE load bias\n
end
