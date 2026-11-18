#!/bin/sh
# P0 (BACKLOG): the same RUI-shaped screen through the raylib bridge, direct
# (in-process raylib 6.2 + rlsw) vs remote (commands -> loopback render server).
# Gates: identical pixels, and the steady-state frame within VISION's counts.
set -e
NIM=${NIM:-nim}
OUT=${P0_OUT:-build/p0}
FRAMES=${P0_FRAMES:-60}
mkdir -p "$OUT"
for be in direct remote; do
  flag=""; [ "$be" = remote ] && flag="-d:rlRemote"
  $NIM c --skipParentCfg --skipProjCfg --hints:off -d:release $flag \
      --nimcache:"$OUT/nc_$be" -o:"$OUT/p0_$be" tests/p0/p0_scene.nim
done
"$OUT/p0_direct" "$OUT/direct.raw" "$FRAMES" | grep '^stat' | sed 's/^/direct /'
"$OUT/p0_remote" "$OUT/remote.raw" "$FRAMES" | grep '^stat' | sed 's/^/remote /' | tee "$OUT/remote.stats"
cmp -s "$OUT/direct.raw" "$OUT/remote.raw" || { echo "FAIL: remote pixels differ from direct"; exit 1; }
echo "PASS: remote pixels identical to direct"
recs=$(grep steady_records_per_frame "$OUT/remote.stats" | cut -d= -f2)
bytes=$(grep steady_bytes_per_frame "$OUT/remote.stats" | cut -d= -f2)
[ "$recs" -le 200 ] && [ "$bytes" -le 16384 ] || { echo "FAIL: steady frame $recs records / $bytes B over budget"; exit 1; }
echo "PASS: steady frame $recs records, $bytes B (budget 200 / 16384)"
