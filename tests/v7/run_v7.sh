#!/bin/sh
# V7 (BACKLOG): RUI's counter example, unchanged, through the raylib bridge,
# with the Pixie text engine, built twice:
#   direct  adapted naylib -> in-process raylib 6.2 (memory platform + rlsw)
#   remote  routed draw calls -> commands -> loopback render server (V7b)
# Gates: both paint; remote pixels == direct; steady frames within VISION's
# budget (<= 200 records, <= 16 KB).
set -e
NIM=${NIM:-nim}
OUT=${V7_OUT:-build/v7}
RUI=vendor/rui2
mkdir -p "$OUT"
# rui2 is pinned upstream; our changes ride as patches until they land there.
for p in patches/rui2/*.patch; do
  if git -C "$RUI" apply --check "../../$p" 2>/dev/null; then git -C "$RUI" apply "../../$p"
  elif ! git -C "$RUI" apply --reverse --check "../../$p" 2>/dev/null; then
    echo "FAIL: $p neither applies nor is applied"; exit 1; fi
done
python3 tools/naylib_adapt.py
P=""
for pkg in rui_core rui_hittest rui_events rui_drawing rui_scripting rui_widgets rui_windows rui_shaped rui; do
  P="$P --path:$RUI/packages/$pkg/src"
done
[ -z "$RUI_FONT_FILE" ] && [ -f /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf ] &&
  export RUI_FONT_FILE=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
for be in direct remote; do
  if [ "$be" = remote ]; then flags="-d:rlRemote --path:build/bridge/naylib_remote"
  else flags="--path:build/bridge/naylib"; fi
  $NIM c --skipParentCfg --skipProjCfg --hints:off --warnings:off -d:release \
      $flags $P -d:ruiTextPixie -d:ruiNoGlfw \
      --nimcache:"$OUT/nc_$be" -o:"$OUT/rui_counter_$be" tests/v7/rui_counter.nim
  "$OUT/rui_counter_$be" "$OUT/counter_$be.ppm" > "$OUT/$be.log"
  grep '^v7' "$OUT/$be.log" | sed "s/^/$be /"
  ink=$(grep '^v7:' "$OUT/$be.log" | sed 's/.*dark pixels //')
  [ "$ink" -ge 500 ] || { echo "FAIL: $be painted only $ink dark pixels"; exit 1; }
done
cmp -s "$OUT/counter_direct.ppm" "$OUT/counter_remote.ppm" ||
  { echo "FAIL: remote pixels differ from direct"; exit 1; }
echo "PASS: RUI counter (3 clicks through RUI's router): remote pixels identical to direct"
st=$(grep '^v7 stats' "$OUT/remote.log")
recs=$(echo "$st" | sed 's/.*steady_max_records=\([0-9]*\).*/\1/')
bytes=$(echo "$st" | sed 's/.*steady_max_bytes=\([0-9]*\).*/\1/')
[ "$recs" -le 200 ] && [ "$bytes" -le 16384 ] ||
  { echo "FAIL: steady frame $recs records / $bytes B over budget"; exit 1; }
echo "PASS: steady frames <= $recs records, $bytes B (budget 200 / 16384)"
