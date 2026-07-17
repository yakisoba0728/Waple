#!/bin/bash
# Waple 앱 아이콘(.icns) 생성 — 코드 드로잉(외부 에셋/폰트 무의존).
# make-icon.swift 로 1024 마스터 PNG 를 그린 뒤 sips 로 iconset 리샘플, iconutil 로 .icns 로 묶는다.
# 산출물 scripts/Waple.icns 는 리포에 커밋되고, package-app.sh 가 앱 번들에 복사한다.
set -euo pipefail
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MASTER="$TMP/master.png"
swift make-icon.swift "$MASTER"

ICONSET="$TMP/Waple.iconset"
mkdir -p "$ICONSET"
gen() { sips -z "$1" "$1" "$MASTER" --out "$ICONSET/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

iconutil -c icns "$ICONSET" -o Waple.icns
echo "Built $(pwd)/Waple.icns"
