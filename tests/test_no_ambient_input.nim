# SPDX-License-Identifier: GPL-2.0
## A design guard (human, 2026-11-14: "no ambient authority"): no kernel or driver code may publish input
## on a global event topic, because any program can subscribe to a topic and read every key. Input
## reaches a program only through the input port (ipc/ports), by a handle given at spawn.
## A source scan is crude, and that is the point: it fails the moment someone writes the old way.
import std/[os, strutils, unittest]

const Roots = ["kernel", "drivers", "shell", "runtime", "ipc", "arch", "mm", "core"]
const Forbidden = ["eventPublish(\"input\"", "eventPublish(\"key.", "eventPublish(\"mouse.", "eventPublish(\"kbd", "eventPublish(\"pointer"]

const RepoRoot = currentSourcePath().parentDir.parentDir     # anchored to this file, not the working directory

suite "no ambient input":
  test "nothing publishes input on a global topic":
    var offenders: seq[string]
    var scanned = 0
    for root in Roots:
      for path in walkDirRec(RepoRoot / root):
        if not path.endsWith(".nim"): continue
        inc scanned
        let text = readFile(path)
        for needle in Forbidden:
          if needle in text: offenders.add path & ": " & needle
    check scanned > 100                                   # the scan really looked at the code (not vacuous)
    check offenders.len == 0
    if offenders.len > 0: echo offenders
