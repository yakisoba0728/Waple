#!/bin/bash
# 캡처 픽셀이 **실제 마우스 커서 위치**에 의존하는지 잰다(세션 간 비결정 29종의 근본원인).
#
# 왜: SceneRenderer.mount 는 `parallaxEnabled || hasEffects` 면 마우스 모니터를 켜고
# (SceneRenderer.swift:1421 부근) 그 콜백이 `pointerUV` = g_PointerPosition 를 **라이브 커서**로
# 채운다. 캡처 파이프라인은 시각·오디오·난수·fitMode 는 핀하는데 **포인터는 핀하지 않는다**
# (SnapshotPipeline.pinRenderSettings). 그래서 캡처 결과에 그때그때의 커서 위치가 구워진다.
#
# 이 스크립트는 커서를 옮겨 가며 같은 씬을 떠서 해시를 비교하고, **끝나면 원위치로 되돌린다**
# (원위치가 화면 밖이면 클램프돼 정확히 못 돌아갈 수 있다 — 그 사실도 찍는다).
set -uo pipefail
REPO="${WAPLE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ROOT="${WAPLE_DEV_ROOT:-$HOME/Downloads/wallpaper_dev}"
BIN="$REPO/.build/release/WapleCompat"
SID="${WAPLE_PROBE_SCENE:-3302695207}"   # 번역 이펙트 + 포인터 반응 보유 씬
OUT_ROOT="${WAPLE_VERIFY_OUT:-$HOME/Downloads/waple-pointer}"
mkdir -p "$OUT_ROOT" || exit 1
OUT="$(mktemp -d "$OUT_ROOT/pointer.XXXXXX")" || exit 1
TMP="$(mktemp -d)" || exit 1
echo "캡처 출력: $OUT"
ORIG=""; OX=""; OY=""
cleanup() {
    if [ -n "$OX" ] && [ -n "$OY" ] && [ -x "$TMP/cursor" ]; then
        "$TMP/cursor" "$OX" "$OY" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$TMP/cursor.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let a = CommandLine.arguments
if a.count >= 3, let x = Double(a[1]), let y = Double(a[2]) {
    CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
    CGAssociateMouseAndMouseCursorPosition(1)
}
if let loc = CGEvent(source: nil)?.location { print("\(loc.x) \(loc.y)") }
SWIFT
swiftc -O "$TMP/cursor.swift" -o "$TMP/cursor" || { echo "!! cursor 헬퍼 빌드 실패"; exit 1; }

cap() {
    if ! launchctl asuser "$(id -u)" env WAPLE_REAL_PKGS="$ROOT/backgrounds" WAPLE_BASE_ASSETS="$ROOT/assets" \
        "$BIN" --capture "$OUT" --label "$1" "$ROOT/backgrounds/$SID" >/dev/null 2>&1; then
        echo "!! 캡처 실패: $1" >&2
        return 1
    fi
    python3 - "$OUT/$1/manifest.json" <<'PY'
import json, re, sys
try:
    with open(sys.argv[1]) as source:
        entries = json.load(source)["entries"]
    digest = entries[0]["hash"]
    if len(entries) != 1 or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-fA-F]{1,16}", digest):
        raise ValueError("단일 씬의 FNV-1a 64비트 hex 해시가 필요하다")
except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
    print(f"!! 캡처 매니페스트가 유효하지 않다: {error}", file=sys.stderr)
    sys.exit(1)
print(digest)
PY
}

ORIG="$("$TMP/cursor")" || exit 1
OX="${ORIG%% *}"; OY="${ORIG##* }"
[ -n "$OX" ] && [ -n "$OY" ] && [ "$ORIG" != "$OX" ] || { echo "!! 원래 커서 위치를 읽지 못했다" >&2; exit 1; }
echo "원래 커서 위치: $OX $OY"

H0="$(cap orig)" || exit 1
"$TMP/cursor" 10 10 >/dev/null || exit 1
H1="$(cap p_10_10)" || exit 1
"$TMP/cursor" 1400 800 >/dev/null || exit 1
H2="$(cap p_1400_800)" || exit 1
"$TMP/cursor" 10 10 >/dev/null || exit 1
H3="$(cap p_10_10_again)" || exit 1
"$TMP/cursor" "$OX" "$OY" >/dev/null || exit 1
NOW="$("$TMP/cursor")" || exit 1
H4="$(cap restored)" || exit 1

echo
echo "  현위치        $H0"
echo "  (10,10)       $H1"
echo "  (1400,800)    $H2"
echo "  (10,10) 재시행 $H3"
echo "  원위치 복원    $H4   (커서=$NOW)"
echo

if [ "$H1" = "$H2" ]; then
    echo "포인터 무영향 — 캡처가 커서에 의존하지 않는다(핀이 들어간 상태)."
    exit 0
fi
echo "**포인터 의존 확인** — 커서 위치가 캡처 픽셀을 바꾼다."
[ "$H1" = "$H3" ] && echo "  같은 위치로 돌아오면 같은 값이 재현된다(상태 재방문의 정체)." \
                  || echo "  주의: 같은 위치인데 값이 다르다 — 포인터 말고 다른 입력도 있다."
[ "$NOW" = "$ORIG" ] || echo "  주의: 커서를 정확히 원위치로 못 돌렸다(화면 밖 좌표는 클램프된다)."
exit 0
