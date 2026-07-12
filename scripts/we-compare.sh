#!/bin/bash
# 사용: scripts/we-compare.sh <sp-라벨> <we-레퍼런스.png>
# WAPLE_SMOKE로 앱을 띄워 메인창을 캡처하고, 레퍼런스와 좌우 배치한 HTML을 생성한다.
set -euo pipefail
cd "$(dirname "$0")/.."
LABEL="${1:?usage: we-compare.sh <label> <reference.png>}"
REF="${2:?usage: we-compare.sh <label> <reference.png>}"
OUT="docs/reference/we"
swift build
WAPLE_SMOKE=1 .build/debug/Waple &
APP_PID=$!
sleep 6
# 메인창 위치·크기(AppleScript) → 영역 캡처(그림자 없이).
read -r X Y W H < <(osascript -e 'tell application "System Events" to tell (first process whose unix id is '"$APP_PID"')
  set p to position of window 1
  set s to size of window 1
  return ((item 1 of p) as text) & " " & ((item 2 of p) as text) & " " & ((item 1 of s) as text) & " " & ((item 2 of s) as text)
end tell')
screencapture -x -R"$X,$Y,$W,$H" "$OUT/waple-$LABEL.png"
kill $APP_PID 2>/dev/null || true
cat > "$OUT/compare-$LABEL.html" <<HTML
<!doctype html><meta charset="utf-8"><title>WE vs Waple — $LABEL</title>
<body style="margin:0;background:#000;color:#fff;font:13px -apple-system">
<div style="display:flex;gap:4px">
<figure style="flex:1;margin:0"><figcaption>WE (레퍼런스)</figcaption><img src="$(basename "$REF")" style="width:100%"></figure>
<figure style="flex:1;margin:0"><figcaption>Waple ($LABEL)</figcaption><img src="waple-$LABEL.png" style="width:100%"></figure>
</div></body>
HTML
echo "→ $OUT/compare-$LABEL.html"
