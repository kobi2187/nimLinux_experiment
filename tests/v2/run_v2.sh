#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# V2 (BACKLOG): the libc/libm for the render-server ELF is picolibc.
#   1. picolibc builds for NimixOS userspace (freestanding x86-64, PIC)
#   2. raylib 6.2 + rlsw compile against picolibc's own headers and link with
#      libnimix (V2b, the OS layer) and the ABI stubs: NOTHING left unresolved
#   3. picolibc's libm is accurate (native run, compared in ULPs)
#   4. libnimix's C clock reader equals the Nim one on golden vectors
#   5. libnimix's keymap equals the Nim keymap (golden vectors) and raylib's KeyboardKey enum
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${V2_OUT:-$ROOT/build/v2}
LIBC=${PICOLIBC_OUT:-$ROOT/build/picolibc}/install
RL=$ROOT/vendor/raylib/src
mkdir -p "$OUT"

sh "$ROOT/tools/picolibc_build.sh"

# 2. raylib against picolibc's headers. Same defines as the bridge (bridge/rl_c.nim);
#    -nostdinc keeps glibc's headers out (FILE, errno and locale differ).
GI=$(gcc -print-file-name=include)
for f in rcore rshapes rtextures rtext rmodels; do
  gcc -c -O2 -fPIC -ffreestanding -fno-stack-protector -mno-red-zone -fno-omit-frame-pointer \
      -U_FORTIFY_SOURCE -D_GNU_SOURCE -nostdinc -isystem "$LIBC/include" -isystem "$GI" \
      -DPLATFORM_MEMORY -DGRAPHICS_API_OPENGL_SOFTWARE -DSUPPORT_MODULE_RAUDIO=0 \
      -DRLSW_MAX_FRAMEBUFFERS=512 -DRLSW_MAX_TEXTURES=2048 -I"$RL" \
      -o "$OUT/$f.o" "$RL/$f.c"
done
make -C "$ROOT" -s build/libnimix/libnimix.a build/nimix_abi_weak.o
# `main` is the program's; libnimix's appMain wants one.
gcc -nostdlib -static -fPIC -o /dev/null "$OUT"/rcore.o "$OUT"/rshapes.o "$OUT"/rtextures.o \
    "$OUT"/rtext.o "$OUT"/rmodels.o "$ROOT/build/libnimix/libnimix.a" "$LIBC/lib/libc.a" \
    "$(gcc -print-libgcc-file-name)" "$ROOT/build/nimix_abi_weak.o" -Wl,-e,0 -Wl,--defsym,main=0 2>&1 |
  grep -o "undefined reference to \`[A-Za-z0-9_]*'" | sed "s/undefined reference to \`//;s/'//" |
  sort -u > "$OUT/needed.txt" || true
if [ -s "$OUT/needed.txt" ]; then
  echo "FAIL: raylib + rlsw + picolibc + libnimix leave symbols unresolved (a raylib bump needs something new?):"
  cat "$OUT/needed.txt"; exit 1
fi
echo "PASS: raylib + rlsw link against picolibc + libnimix with nothing unresolved"

# 3. libm accuracy, run natively
gcc -O2 -D_GNU_SOURCE -Werror=implicit-function-declaration -ffreestanding -fno-stack-protector -nostdinc -isystem "$LIBC/include" -isystem "$GI" \
    -nostdlib -static -no-pie -fno-pic -o "$OUT/libm_check" "$ROOT/tests/v2/libm_check.c" \
    "$LIBC/lib/libc.a" "$(gcc -print-libgcc-file-name)" -Wl,-e,_start
"$OUT/libm_check" > "$OUT/libm.out"
python3 "$ROOT/tests/v2/check_libm.py" "$OUT/libm.out"

# 4. libnimix's C clock reader reproduces core/tsc_clock.nim bit for bit (golden vectors)
gcc -O2 -Wall -Wextra -I"$ROOT/libnimix" -o "$OUT/test_clock" "$ROOT/tests/libnimix/test_clock.c"
"$OUT/test_clock" "$ROOT/tests/libnimix/clock_vectors.txt"

# 5. libnimix's keymap (evdev -> raylib keys and characters) equals the Nim keymap on golden
#    vectors and raylib 6.2's own KeyboardKey enum (the test includes raylib.h)
gcc -O2 -Wall -Wextra -I"$ROOT/libnimix" -I"$RL" -o "$OUT/test_keymap" "$ROOT/tests/libnimix/test_keymap.c"
"$OUT/test_keymap" "$ROOT/tests/libnimix/key_vectors.txt"
