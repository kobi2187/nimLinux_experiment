#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Build picolibc (vendor/picolibc, pinned) for NimixOS userspace.
#   Output: $PICOLIBC_OUT (default build/picolibc): install/{include,lib/libc.a}
# Needs meson + ninja (apt install meson ninja-build, or `pip install meson`;
# set MESON="python3 -m mesonbuild.mesonmain" if it isn't on PATH).
#
# Configuration, and why:
#   multilib=false, picocrt=false, semihost=false   we have our own entry point and no debug host
#   thread-local-storage=false, single-thread=true  NimixOS has actors, not OS threads, and no TLS
#   newlib-global-errno=true                        errno is a plain global (no TLS, no __errno_location)
#   want-math-errno=false                           math functions don't set errno (smaller, faster)
#   posix-console=false                             stdio is wired by our libc OS layer (V2b)
#   specsdir=none, libdl=false, tests=false         nothing to install or test here
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${PICOLIBC_OUT:-$ROOT/build/picolibc}
MESON=${MESON:-meson}
if ! $MESON --version >/dev/null 2>&1; then
  echo "picolibc_build: meson not found (apt install meson ninja-build, or pip install meson)" >&2
  exit 1
fi
if [ ! -f "$ROOT/vendor/picolibc/meson.build" ]; then
  echo "picolibc_build: run: git submodule update --init vendor/picolibc" >&2
  exit 1
fi
if [ -f "$OUT/install/lib/libc.a" ] && [ "$OUT/install/lib/libc.a" -nt "$ROOT/tools/nimix-x86_64.cross" ] &&
   [ -z "$PICOLIBC_REBUILD" ]; then
  echo "picolibc_build: up to date ($OUT/install)"; exit 0
fi
rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
$MESON setup "$OUT/build" "$ROOT/vendor/picolibc" \
  --cross-file "$ROOT/tools/nimix-x86_64.cross" --prefix "$OUT/install" \
  -Dmultilib=false -Dtests=false -Dpicocrt=false -Dsemihost=false \
  -Dthread-local-storage=false -Dsingle-thread=true -Dnewlib-global-errno=true \
  -Dwant-math-errno=false -Dposix-console=false -Dspecsdir=none -Dlibdl=false >"$OUT.setup.log" 2>&1 ||
  { cat "$OUT.setup.log"; exit 1; }
$MESON install -C "$OUT/build" >"$OUT.install.log" 2>&1 || { tail -30 "$OUT.install.log"; exit 1; }
echo "picolibc_build: built $(git -C "$ROOT/vendor/picolibc" describe --tags 2>/dev/null || echo vendor/picolibc) -> $OUT/install"
