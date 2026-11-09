#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Compare picolibc's libm output (tests/v2/libm_check.c) with correctly rounded
references, in ULPs. Usage: check_libm.py <output-of-libm_check>"""
import math, struct, sys

def f32(b): return struct.unpack('<f', struct.pack('<I', b))[0]
def f64(b): return struct.unpack('<d', struct.pack('<Q', b))[0]
def ordered(bits, width):          # monotonic integer image of a float's bit pattern
    sign = 1 << (width - 1)
    return (sign - (bits & (sign - 1))) if bits & sign else (sign + bits)
def to32(x): return struct.unpack('<I', struct.pack('<f', x))[0]
def to64(x): return struct.unpack('<Q', struct.pack('<d', x))[0]

# name: (reference, allowed ULP). The limits are the documented accuracy of the
# algorithms (fdlibm for double, ARM optimized-routines for most float
# functions) with a little headroom; fmod/sqrt/hypot-class results are exact.
REF = {
    'sinf': (math.sin, 1), 'cosf': (math.cos, 1), 'sqrtf': (math.sqrt, 0),
    'logf': (math.log, 1), 'acosf': (math.acos, 1), 'asinf': (math.asin, 1),
    'powf': (math.pow, 1), 'atan2f': (math.atan2, 1), 'fmodf': (math.fmod, 0),
    'hypotf': (math.hypot, 1),
    'sqrt': (math.sqrt, 0), 'cos': (math.cos, 1), 'tan': (math.tan, 1),
    'acos': (math.acos, 1), 'pow': (math.pow, 1), 'fmod': (math.fmod, 0),
    'hypot': (math.hypot, 1),
}
worst = {}
bad = []
lines = [l.split() for l in open(sys.argv[1]) if l.strip()]
if len(lines) < 7000:
    sys.exit(f"FAIL: only {len(lines)} result lines (libm_check crashed?)")
for f in lines:
    name = f[0]
    if name == 'sincosf':
        x = f32(int(f[1], 16))
        for tag, ref, got in (('sincosf.sin', math.sin(x), f32(int(f[2], 16))),
                              ('sincosf.cos', math.cos(x), f32(int(f[3], 16)))):
            ulp = abs(ordered(to32(got), 32) - ordered(to32(ref), 32))
            worst[tag] = max(worst.get(tag, 0), ulp)
            if ulp > 1: bad.append((tag, x, ulp))
        continue
    if name == 'frexp':
        x = f64(int(f[1], 16)); m = f64(int(f[2], 16)); e = int(f[3], 16)
        if e >= 1 << 31: e -= 1 << 32
        worst['frexp'] = 0
        if math.ldexp(m, e) != x or not 0.5 <= abs(m) < 1: bad.append(('frexp', x, -1))
        continue
    ref, limit = REF[name]
    wide = len(f[1]) == 16
    cv, width = (f64, 64) if wide else (f32, 32)
    conv = to64 if wide else to32
    args = [cv(int(v, 16)) for v in f[1:-1]]
    got = cv(int(f[-1], 16))
    want = ref(*args)
    ulp = abs(ordered(conv(got), width) - ordered(conv(want), width))
    worst[name] = max(worst.get(name, 0), ulp)
    if ulp > limit: bad.append((name, args, ulp))
for n in sorted(worst):
    limit = '' if n.startswith('sincos') or n == 'frexp' else f" (limit {REF[n][1]})"
    print(f"  {n:12s} worst {worst[n]} ULP{limit}")
if bad:
    for b in bad[:10]: print("  OVER LIMIT:", b)
    sys.exit(f"FAIL: {len(bad)} results over their ULP limit")
print(f"PASS: picolibc libm within its ULP limits over {len(lines)} samples")
