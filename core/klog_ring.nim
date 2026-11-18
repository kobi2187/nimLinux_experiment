# SPDX-License-Identifier: GPL-2.0
## Kernel log ring — the last KlogRingSize bytes of klog output, kept in
## memory so `dmesg` can show boot and driver messages after they scrolled
## past (or when nothing was listening on serial). Oldest bytes are dropped.

const KlogRingSize* = 16384

var
  klogRing: array[KlogRingSize, char]
  klogWritten: uint64          ## total bytes ever written (monotonic)

proc klogRingPut*(c: char) =
  klogRing[int(klogWritten mod KlogRingSize)] = c
  inc klogWritten

proc klogRingPut*(s: cstring) =
  if s == nil: return
  var i = 0
  while s[i] != '\0':
    klogRingPut(s[i])
    inc i

proc klogRingPutHex*(v: uint64) =
  const digits = "0123456789ABCDEF"
  var started = false
  for shift in countdown(60, 0, 4):
    let d = int((v shr uint64(shift)) and 0xF)
    if d != 0 or started or shift == 0:
      started = true
      klogRingPut(digits[d])

proc klogRingPutInt*(v: int64) =
  var u = uint64(v)
  if v < 0:
    klogRingPut('-')
    u = not u + 1                  # two's complement magnitude; low(int64) safe
  if u >= 10'u64: klogRingPutInt(int64(u div 10))
  klogRingPut(char(ord('0') + int(u mod 10)))

proc klogRingLen*(): int =
  int(min(klogWritten, uint64(KlogRingSize)))

proc klogRingDropped*(): uint64 =
  ## Bytes lost to wrap-around.
  if klogWritten > KlogRingSize: klogWritten - KlogRingSize else: 0'u64

iterator klogRingChars*(): char =
  ## Oldest → newest. Snapshot the bounds first: dumping the ring to serial
  ## must not chase bytes appended while it prints.
  let total = klogWritten
  let n = min(total, uint64(KlogRingSize))
  var i = total - n
  while i < total:
    yield klogRing[int(i mod KlogRingSize)]
    inc i

proc klogRingClear*() =
  klogWritten = 0
