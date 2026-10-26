#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Host tests for NimixOS WASM apps (regular apps) — no QEMU needed.

Runs each module under wasmtime with Python stand-ins for the NimixOS host
calls (env.*) and checks behaviour plus the sandbox contract: a module may
import ONLY the NimixOS host API, never libc/WASI.

    pip install wasmtime        # optional dependency; skipped if missing
    python3 tests/test_wasm_apps.py build/apps
"""
import sys

try:
    import wasmtime as w
except ImportError:
    print("SKIP: wasmtime not installed (pip install wasmtime)")
    sys.exit(0)

HOST_API = {"serial_write", "sip_exit", "args_get", "event_subscribe",
            "event_wait", "chan_send"}


class FakeHost:
    """Records what an app does through the NimixOS host API."""

    def __init__(self, args=b"", reply=None):
        self.args, self.reply = args, reply
        self.out, self.exit_code, self.sent = "", None, []

    def run(self, path):
        eng = w.Engine()
        store = w.Store(eng)
        mod = w.Module.from_file(eng, path)
        mem = []
        i32 = w.ValType.i32()

        def read(p, n):
            return bytes(mem[0].read(store, p, p + n))

        def serial_write(p, n): self.out += read(p, n).decode(errors="replace")
        def sip_exit(code): self.exit_code = code
        def args_get(p, n):
            b = self.args[:n]
            mem[0].write(store, b, p)
            return len(b)
        def event_subscribe(p): return 1
        def event_wait(tok, p, n):
            if self.reply is None: return -1
            b = self.reply[:n]
            mem[0].write(store, b, p)
            return len(b)
        def chan_send(np_, dp, n):
            self.sent.append((read(np_, 32).split(b"\0")[0], read(dp, n)))

        table = {"serial_write": ([i32, i32], [], serial_write),
                 "sip_exit": ([i32], [], sip_exit),
                 "args_get": ([i32, i32], [i32], args_get),
                 "event_subscribe": ([i32], [i32], event_subscribe),
                 "event_wait": ([i32, i32, i32], [i32], event_wait),
                 "chan_send": ([i32, i32, i32], [], chan_send)}
        imports = []
        for imp in mod.imports:
            assert imp.module == "env" and imp.name in HOST_API, \
                f"{path}: imports {imp.module}.{imp.name} — outside the NimixOS host API"
            params, results, fn = table[imp.name]
            imports.append(w.Func(store, w.FuncType(params, results), fn))
        inst = w.Instance(store, mod, imports)
        mem.append(inst.exports(store)["memory"])
        try:
            inst.exports(store)["_start"](store)
        except w.Trap:
            pass   # sip_exit is followed by a trap in the runtime shim
        return self


def fs_reply(status, data=b""):
    return status.to_bytes(4, "little", signed=True) + data


def main(appdir):
    h = FakeHost().run(f"{appdir}/hello.wasm")
    assert "Hello from a Nim WASM app" in h.out and h.exit_code == 0, h.out
    print("PASS: hello")

    h = FakeHost(args=b"notes.txt", reply=fs_reply(5, b"hello")).run(f"{appdir}/cat.wasm")
    assert h.sent == [(b"fs", b"fs.reply.cat\0notes.txt\0")], h.sent
    assert h.out == "hello" and h.exit_code == 0, (h.out, h.exit_code)
    print("PASS: cat — protocol request + prints reply data")

    h = FakeHost(args=b"nope", reply=fs_reply(-1)).run(f"{appdir}/cat.wasm")
    assert "not found" in h.out and h.exit_code == 1, h.out
    print("PASS: cat — missing file")

    h = FakeHost(args=b"notes.txt").run(f"{appdir}/cat.wasm")
    assert "no reply from fs_server" in h.out and h.exit_code == 1, h.out
    print("PASS: cat — server not running")

    h = FakeHost().run(f"{appdir}/cat.wasm")
    assert "usage" in h.out and h.exit_code == 1 and not h.sent, h.out
    print("PASS: cat — usage")
    print("All WASM app tests passed.")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "build/apps")
