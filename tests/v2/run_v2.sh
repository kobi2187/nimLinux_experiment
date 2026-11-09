#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# V2 (BACKLOG): the libc/libm for the render-server ELF is picolibc.
#   1. picolibc builds for NimixOS userspace (freestanding x86-64, PIC)
#   2. raylib 6.2 + rlsw compile against picolibc's own headers and link,
#      needing exactly the OS-layer symbols in expected_os_symbols.txt
#   3. picolibc's libm is accurate (native run, compared in ULPs)
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
gcc -nostdlib -static -fPIC -o /dev/null "$OUT"/rcore.o "$OUT"/rshapes.o "$OUT"/rtextures.o \
    "$OUT"/rtext.o "$OUT"/rmodels.o "$LIBC/lib/libc.a" "$(gcc -print-libgcc-file-name)" -Wl,-e,0 2>&1 |
  grep -o "undefined reference to \`[A-Za-z0-9_]*'" | sed "s/undefined reference to \`//;s/'//" |
  sort -u > "$OUT/needed.txt" || true
grep -v '^#' "$ROOT/tests/v2/expected_os_symbols.txt" | sort -u > "$OUT/expected.txt"
if ! diff -u "$OUT/expected.txt" "$OUT/needed.txt" > "$OUT/symbols.diff"; then
  echo "FAIL: raylib + rlsw need a different set of libc symbols than tests/v2/expected_os_symbols.txt:"
  cat "$OUT/symbols.diff"; exit 1
fi
echo "PASS: raylib + rlsw link against picolibc, needing only the $(wc -l < "$OUT/needed.txt") OS-layer symbols"

# 3. libm accuracy, run natively
gcc -O2 -D_GNU_SOURCE -Werror=implicit-function-declaration -ffreestanding -fno-stack-protector -nostdinc -isystem "$LIBC/include" -isystem "$GI" \
    -nostdlib -static -no-pie -fno-pic -o "$OUT/libm_check" "$ROOT/tests/v2/libm_check.c" \
    "$LIBC/lib/libc.a" "$(gcc -print-libgcc-file-name)" -Wl,-e,_start
"$OUT/libm_check" > "$OUT/libm.out"
python3 "$ROOT/tests/v2/check_libm.py" "$OUT/libm.out"
