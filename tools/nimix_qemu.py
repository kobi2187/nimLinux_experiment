#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""nimix_qemu — the one place that knows how to run NimixOS under QEMU.

Library (used by tests/qemu_harness.py, tests/qemu_debug.py, tests/qemu_devices.py)
and CLI (used by the Makefile `qemu*` targets; `make gdb-attach` connects gdb).

    tools/nimix_qemu.py run                       # serial on this terminal
    tools/nimix_qemu.py run --devices all --gui   # every virtio device + window
    tools/nimix_qemu.py run --gdb wait            # paused, gdb stub on :1234
    tools/nimix_qemu.py run --qmp /tmp/nimix.qmp  # QMP socket for automation
    tools/nimix_qemu.py run --log int,cpu_reset   # QEMU event log (autopsy)

Devices (virtio-pci, what the drivers expect): blk net gpu snd input — or "all".
Host-side evidence for each: --pcap (net frames), --wav (audio out),
QMP screendump (gpu framebuffer), QMP input-send-event (keyboard).
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field

QEMU = "qemu-system-x86_64"
DEFAULT_BIOS = "/usr/share/ovmf/OVMF.fd"
ALL_DEVICES = ("blk", "net", "gpu", "snd", "input")


@dataclass
class QemuConfig:
    iso: str = "nimixos.iso"
    bios: str = DEFAULT_BIOS
    mem_mb: int = 256
    disk: str = "disk.img"
    devices: tuple = ("blk",)
    display: str = "none"          # none | gtk | sdl | vnc:<n>
    accel: str = "auto"            # auto (kvm if /dev/kvm) | kvm | tcg
    serial: str = "stdio"          # stdio | file:<p> | pipe:<base> | pty | tcp:<port>
    gdb: str = ""                  # "" | "on" (:1234) | "wait" (paused at reset)
    gdb_port: int = 1234
    qmp: str = ""                  # unix socket path
    log: str = ""                  # -d flags, e.g. "int,cpu_reset,guest_errors"
    log_file: str = "qemu-events.log"
    pcap: str = ""                 # net: dump every frame to this pcap
    wav: str = ""                  # snd: record guest audio output to this wav
    no_reboot: bool = True
    extra: list = field(default_factory=list)


def device_args(cfg: QemuConfig) -> list:
    """QEMU arguments for the requested virtio devices."""
    devs = set(ALL_DEVICES if "all" in cfg.devices else cfg.devices)
    unknown = devs - set(ALL_DEVICES)
    if unknown:
        raise ValueError(f"unknown device(s): {', '.join(sorted(unknown))}")
    args = []
    if "blk" in devs and cfg.disk and os.path.exists(cfg.disk):
        args += ["-drive", f"if=none,file={cfg.disk},format=raw,id=d0",
                 "-device", "virtio-blk-pci,drive=d0"]
    if "net" in devs:
        args += ["-netdev", "user,id=n0", "-device", "virtio-net-pci,netdev=n0"]
        if cfg.pcap:
            args += ["-object", f"filter-dump,id=f0,netdev=n0,file={cfg.pcap}"]
    if "gpu" in devs:
        # id: QMP screendump/inputs target devices by id (the std VGA head is
        # the primary console otherwise).
        args += ["-device", "virtio-gpu-pci,id=gpu0"]
    if "snd" in devs:
        backend = f"wav,id=a0,path={cfg.wav}" if cfg.wav else "none,id=a0"
        # streams=1: output only (stream 0) — the driver has no capture path.
        args += ["-audiodev", backend, "-device", "virtio-sound-pci,id=snd0,audiodev=a0,streams=1"]
    if "input" in devs:
        args += ["-device", "virtio-keyboard-pci,id=kbd0",
                 "-device", "virtio-mouse-pci,id=mouse0"]
    return args


def build_cmd(cfg: QemuConfig) -> list:
    cmd = [QEMU, "-cdrom", cfg.iso, "-bios", cfg.bios, "-m", f"{cfg.mem_mb}M"]
    accel = cfg.accel
    if accel == "auto":
        accel = "kvm" if os.access("/dev/kvm", os.R_OK | os.W_OK) else "tcg"
    cmd += ["-accel", accel]
    if cfg.display.startswith("vnc:"):
        cmd += ["-display", "none", "-vnc", ":" + cfg.display[4:]]
    else:
        cmd += ["-display", cfg.display]
    if cfg.serial.startswith("tcp:"):
        cmd += ["-serial", f"tcp::{cfg.serial[4:]},server=on,wait=off"]
    else:
        cmd += ["-serial", cfg.serial]
    if cfg.no_reboot:
        cmd += ["-no-reboot"]
    cmd += device_args(cfg)
    if cfg.gdb:
        cmd += ["-gdb", f"tcp::{cfg.gdb_port}"]
        if cfg.gdb == "wait":
            cmd += ["-S"]
    if cfg.qmp:
        cmd += ["-qmp", f"unix:{cfg.qmp},server=on,wait=off"]
    if cfg.log:
        cmd += ["-d", cfg.log, "-D", cfg.log_file, "-no-shutdown"]
    return cmd + list(cfg.extra)


class Qmp:
    """Minimal QMP client (no dependencies): connect, execute, close."""

    def __init__(self, path: str, timeout: float = 30):
        deadline = time.time() + timeout
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX)
                self.sock.connect(path)
                break
            except OSError:
                if time.time() > deadline:
                    raise TimeoutError(f"QMP socket {path} not ready")
                time.sleep(0.2)
        self.file = self.sock.makefile("rwb")
        self._read()                                   # greeting
        self.execute("qmp_capabilities")

    def _read(self) -> dict:
        while True:
            msg = json.loads(self.file.readline())
            if "event" not in msg:                     # skip async events
                return msg

    def execute(self, command: str, **arguments) -> dict:
        req = {"execute": command}
        if arguments:
            req["arguments"] = arguments
        self.file.write(json.dumps(req).encode() + b"\n")
        self.file.flush()
        reply = self._read()
        if "error" in reply:
            raise RuntimeError(f"QMP {command}: {reply['error'].get('desc')}")
        return reply.get("return", {})

    def hmp(self, line: str) -> str:
        """Human monitor command (e.g. 'info registers') via QMP."""
        return self.execute("human-monitor-command", **{"command-line": line})

    def screendump(self, path: str, device: str = ""):
        """PPM of a display head; device = QOM id (e.g. 'gpu0'), "" = primary."""
        args = {"filename": path}
        if device:
            args["device"] = device
        self.execute("screendump", **args)

    def send_key(self, qcode: str, console: str = "", hold_ms: int = 30):
        """Press and release one key (QEMU qcode, e.g. 'a', 'ret', 'spc').
        QEMU routes it to the most recently activated keyboard — virtio-keyboard
        once its driver is up. console = a display head id (e.g. 'gpu0') to
        route by console; NOT a keyboard id (QEMU rejects/crashes on that)."""
        key = {"type": "qcode", "data": qcode}
        for down in (True, False):
            args = {"events": [{"type": "key", "data": {"down": down, "key": key}}]}
            if console:
                args["device"] = console
            self.execute("input-send-event", **args)
            time.sleep(hold_ms / 1000)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def config_from_args(a) -> QemuConfig:
    iso = a.iso or (f"nimixos-{a.model}.iso" if a.model != "monolithic" else "nimixos.iso")
    return QemuConfig(
        iso=iso, bios=a.bios, mem_mb=a.mem, disk=a.disk,
        devices=tuple(a.devices.split(",")) if a.devices else (),
        display="gtk" if a.gui else a.display, accel=a.accel, serial=a.serial,
        gdb=a.gdb or "", gdb_port=a.gdb_port, qmp=a.qmp or "",
        log=a.log or "", log_file=a.log_file, pcap=a.pcap or "", wav=a.wav or "")


def add_common_args(p: argparse.ArgumentParser):
    p.add_argument("--model", default="monolithic",
                   choices=("monolithic", "microkernel", "sasos"))
    p.add_argument("--iso", default="")
    p.add_argument("--bios", default=DEFAULT_BIOS)
    p.add_argument("--mem", type=int, default=256)
    p.add_argument("--disk", default="disk.img")
    p.add_argument("--devices", default="blk",
                   help="comma list of " + ",".join(ALL_DEVICES) + " or 'all'")
    p.add_argument("--display", default="none")
    p.add_argument("--gui", action="store_true", help="shorthand for --display gtk")
    p.add_argument("--accel", default="auto", choices=("auto", "kvm", "tcg"))
    p.add_argument("--serial", default="stdio")
    p.add_argument("--gdb", nargs="?", const="on", choices=("on", "wait"))
    p.add_argument("--gdb-port", type=int, default=1234)
    p.add_argument("--qmp", default="")
    p.add_argument("--log", nargs="?", const="int,cpu_reset,guest_errors", default="")
    p.add_argument("--log-file", default="qemu-events.log")
    p.add_argument("--pcap", default="")
    p.add_argument("--wav", default="")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    run = sub.add_parser("run", help="boot NimixOS (serial on this terminal)")
    add_common_args(run)
    show = sub.add_parser("cmd", help="print the QEMU command line only")
    add_common_args(show)
    a = ap.parse_args()
    cfg = config_from_args(a)
    cmd = build_cmd(cfg)
    if a.cmd == "cmd":
        print(" ".join(cmd))
        return 0
    if cfg.gdb:
        print(f"[nimix_qemu] gdb stub on :{cfg.gdb_port}"
              f"{' (paused — continue from gdb)' if cfg.gdb == 'wait' else ''}; "
              f"attach with: make gdb-attach", file=sys.stderr)
    print("[nimix_qemu] " + " ".join(cmd), file=sys.stderr)
    return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main())
