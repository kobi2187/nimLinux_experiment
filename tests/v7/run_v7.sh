#!/bin/sh
# V7 (BACKLOG): RUI's counter example, unchanged, through the raylib bridge's
# direct backend (adapted naylib -> raylib 6.2 memory platform + rlsw) with the
# Pixie text engine. Gate: it builds, runs headless, and paints text.
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
$NIM c --skipParentCfg --skipProjCfg --hints:off --warnings:off -d:release \
    --path:build/bridge/naylib $P -d:ruiTextPixie -d:ruiNoGlfw \
    --nimcache:"$OUT/nc_direct" -o:"$OUT/rui_counter" tests/v7/rui_counter.nim
[ -z "$RUI_FONT_FILE" ] && [ -f /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf ] &&
  export RUI_FONT_FILE=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
line=$("$OUT/rui_counter" "$OUT/counter_direct.ppm" | grep '^v7:')
echo "$line"
ink=$(echo "$line" | sed 's/.*dark pixels //')
[ "$ink" -ge 500 ] || { echo "FAIL: only $ink dark pixels: no text/widgets painted"; exit 1; }
echo "PASS: RUI counter painted headless through the bridge (direct), $ink dark pixels"
