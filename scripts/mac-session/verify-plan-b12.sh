#!/bin/bash
# 계획 B Task 1·2 검증 — 구현이 끝난 뒤 돌린다.
#
# 이 세션은 측정이 아니라 구현이다. 그래서 검증도 다르다:
#   - 빌드가 되는가
#   - 신규 테스트가 통과하는가
#   - **기존 스위트가 안 깨졌는가** (가장 중요)
#   - 동봉 에셋이 번들에서 실제로 읽히는가
#   - 골든이 안 바뀌었는가 (Task 1·2 는 픽셀을 바꾸면 안 된다)
set -uo pipefail

REPO="${WAPLE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ROOT="${WAPLE_DEV_ROOT:-$HOME/Downloads/wallpaper_dev}"
OUT="${WAPLE_VERIFY_OUT:-$HOME/Downloads/waple-verify}"
export WAPLE_REAL_PKGS="$ROOT/backgrounds"
export WAPLE_BASE_ASSETS="$ROOT/assets"
FAIL=0

hr(){ printf '%s\n' "----------------------------------------------------------------"; }
ok(){ printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad(){ printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=1; }

cd "$REPO" || exit 1
mkdir -p "$OUT"

hr; echo "1. 빌드 (release)"; hr
T0=$SECONDS
if swift build -c release 2>&1 | tail -15; then ok "빌드 $((SECONDS-T0))초"; else bad "빌드 실패"; exit 1; fi

hr; echo "2. Package.swift 에 리소스 선언이 실제로 들어갔는가"; hr
if grep -q 'resources:' Package.swift && grep -q 'WEAssets' Package.swift; then
    ok "Package.swift resources 선언 존재"
    grep -n -A2 "resources:" Package.swift | sed 's/^/    /'
else
    bad "Package.swift 에 resources 선언이 없다 — 동봉이 빌드에 안 들어간다"
fi

if grep -rq "Bundle.module" Sources/WapleRender/; then
    ok "Bundle.module 참조 존재"
else
    bad "Bundle.module 참조 0건 — 코드가 번들 리소스를 안 읽는다"
fi

hr; echo "3. 번들 산출물에 에셋이 실제로 있는가"; hr
BND=$(find .build/release -name "*WapleRender*.bundle" -maxdepth 3 2>/dev/null | head -1)
if [ -n "$BND" ]; then
    N=$(find "$BND" -type f | wc -l | tr -d ' ')
    echo "  번들: $BND"
    echo "  파일 $N 개"
    [ "$N" -ge 2900 ] && ok "에셋 번들 확보(기대 2,940)" || bad "파일이 $N 개뿐"
    [ -f "$BND/WEAssets/shaders/common.h" ] && ok "common.h 존재" \
        || bad "WEAssets/shaders/common.h 없음 — 디렉터리 구조가 평탄화됐을 수 있다(.copy 확인)"
else
    bad "리소스 번들을 못 찾았다 — resources 선언이 빠졌거나 빌드가 안 만들었다"
fi

hr; echo "4. 신규 테스트"; hr
for f in BundledAssetsTests GoldenBaselineOracleTests; do
    if launchctl asuser "$(id -u)" env WAPLE_REAL_PKGS="$WAPLE_REAL_PKGS" \
        WAPLE_BASE_ASSETS="$WAPLE_BASE_ASSETS" \
        swift test -c release --filter "$f" 2>&1 | tee "$OUT/$f.log" | tail -5 | grep -qE "Executed .* tests.*0 failures|with 0 failures"; then
        ok "$f 통과"
    else
        bad "$f 실패 — $OUT/$f.log"
    fi
done

hr; echo "5. 기존 스위트 무회귀 (가장 중요)"; hr
T0=$SECONDS
launchctl asuser "$(id -u)" env WAPLE_REAL_PKGS="$WAPLE_REAL_PKGS" \
    WAPLE_BASE_ASSETS="$WAPLE_BASE_ASSETS" \
    swift test -c release 2>&1 | tee "$OUT/full-suite.log" | tail -20
if grep -qE "with 0 failures|Executed .*, 0 failures" "$OUT/full-suite.log"; then
    ok "전 스위트 통과 ($((SECONDS-T0))초)"
else
    bad "전 스위트 실패 — $OUT/full-suite.log"
    grep -E "error:|failed \(" "$OUT/full-suite.log" | head -20 | sed 's/^/    /'
fi
TESTS=$(grep -oE "Executed [0-9]+ tests" "$OUT/full-suite.log" | grep -oE "[0-9]+" | head -1)
echo "  테스트 수: ${TESTS:-?} (종전 기준값 2,125 + 신규분)"

hr; echo "6. 골든 무변화 (Task 1·2 는 픽셀을 바꾸면 안 된다)"; hr
LABEL="verify-$(git rev-parse --short HEAD)"
launchctl asuser "$(id -u)" env WAPLE_REAL_PKGS="$WAPLE_REAL_PKGS" \
    WAPLE_BASE_ASSETS="$WAPLE_BASE_ASSETS" \
    swift run -c release WapleCompat --capture "$OUT" --label "$LABEL" "$ROOT" \
    2>&1 | tee "$OUT/capture.log" | tail -6

python3 - "$REPO/spec/golden/snapshot/baseline-81098bb" "$OUT/$LABEL" <<'PY'
import json, os, sys
a, b = sys.argv[1], sys.argv[2]
try:
    from PIL import Image
except ImportError:
    print("  (PIL 없음 — 픽셀 대조 건너뜀. pip3 install pillow)"); sys.exit(0)
ma = {e["id"]: e for e in json.load(open(os.path.join(a, "manifest.json")))["entries"]}
mb_path = os.path.join(b, "manifest.json")
if not os.path.exists(mb_path):
    print("  !! B 매니페스트 없음 — 캡처 실패"); sys.exit(1)
mb = {e["id"]: e for e in json.load(open(mb_path))["entries"]}
changed = []
for sid in sorted(set(ma) & set(mb)):
    pa = os.path.join(a, "thumbs", f"{sid}.png")
    pb = os.path.join(b, "thumbs", f"{sid}.png")
    if not (os.path.exists(pa) and os.path.exists(pb)): continue
    if open(pa, "rb").read() == open(pb, "rb").read(): continue
    ia, ib = Image.open(pa).convert("RGB"), Image.open(pb).convert("RGB")
    if ia.size != ib.size: changed.append((sid, -1)); continue
    pxa, pxb = ia.load(), ib.load()
    w, h = ia.size; mx = 0
    for y in range(h):
        for x in range(w):
            d = max(abs(p-q) for p, q in zip(pxa[x,y], pxb[x,y]))
            if d > mx: mx = d
    if mx: changed.append((sid, mx))
print(f"  대조 {len(set(ma)&set(mb))}종 · 픽셀 변화 {len(changed)}종")
for sid, mx in changed[:20]:
    print(f"    {sid} 최대차 {mx}")
if changed:
    print("  !! Task 1·2 는 픽셀을 바꾸면 안 된다. 위 씬을 조사할 것.")
PY

hr
[ "$FAIL" = 0 ] && printf '\033[32m검증 통과\033[0m\n' || printf '\033[31mFAIL 있음 — 위 항목 확인\033[0m\n'
echo "로그: $OUT"
hr
exit "$FAIL"
