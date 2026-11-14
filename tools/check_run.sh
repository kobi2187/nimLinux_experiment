#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Run a test command; FAIL on a non-zero exit AND on any sign that the program
# died on an unhandled exception, whatever its exit code says.
#
# Why: some host test binaries exit 0 after printing "Error: unhandled exception
# ... [AssertionDefect]" (found 2026-11-09: tests/test_syscall_table.nim failed
# for a whole milestone while `make test` and CI stayed green). The cause is not
# known; until it is, the output is the source of truth.
#   usage: check_run.sh <command> [args...]
out=$("$@" 2>&1)
rc=$?
printf '%s\n' "$out"
if [ "$rc" -ne 0 ]; then
  echo "TEST FAILED (exit $rc): $*" >&2
  exit 1
fi
if printf '%s\n' "$out" | grep -q "^Error: unhandled exception"; then
  echo "TEST FAILED (unhandled exception, exit code was $rc): $*" >&2
  exit 1
fi
