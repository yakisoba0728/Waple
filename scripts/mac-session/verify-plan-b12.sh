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

# [수정 2026-08-16] 이 검사는 뒤집혀 있었다. 종전엔 `Bundle.module` 참조가 **있으면 OK** 였다.
# 그런데 b901326("배포본 즉사 2차")가 그 유일한 사용처(BaseAssetsSettings)를 **의도적으로 걷어냈다** —
# SwiftPM 이 생성하는 접근자는 못 찾으면 경고가 아니라 fatalError 이고 탐색 후보가 빌드 시스템마다
# 다르다(swiftbuild=Contents/Resources, native=앱 루트+빌드 절대경로). 그래서 CI(native) 산출물이
# 실행 즉시 죽었고(v0.1.0-beta.3 `could not load resource bundle`), 앱 루트 후보는 codesign 이
# "unsealed contents present in the bundle root" 로 막아 만족시킬 방법조차 없다.
# 대체는 `BaseAssetsSettings.bundledAssetsDirectory` 의 **직접 탐색**(후보 4 × 레이아웃 2, 실패 시 nil)이다.
# 즉 지금의 불변식은 정반대다: **코드에 Bundle.module 이 0건**일 것 + **대체 구현이 실재**할 것.
#
# 조건만 뒤집으면 clean tree 에서 오탐이 난다 — BaseAssetsSettings.swift:52 의 근거 주석이
# "`Bundle.module` 을 쓰지 않는다" 라고 그 단어를 그대로 적고 있다(지우면 안 되는 설계 근거).
# 그래서 **주석 줄을 제외하고** 센다. 탐색 범위도 WapleRender/ → Sources/ 전체로 넓혔다
# (b901326 의 의도는 "종속을 걷어낸다" 이지 한 타깃만 보는 게 아니다).
CODE_HITS=$(grep -rn "Bundle\.module" Sources/ 2>/dev/null \
            | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(///|//|\*|/\*)' || true)
if [ -z "$CODE_HITS" ]; then
    ok "Bundle.module 코드 참조 0건 (b901326 이후의 불변식)"
else
    bad "Bundle.module 코드 참조가 살아 있다 — 배포본이 실행 즉시 죽는다(v0.1.0-beta.3 재발)"
    printf '%s\n' "$CODE_HITS" | head -5 | sed 's/^/    /'
fi

# 불변식의 나머지 반쪽 — 대체 구현이 실제로 있는가. 위 검사만 두면 "그냥 아무 데서도 안 읽는다"
# 와 "직접 찾는다" 를 구별하지 못한다.
ASSETS_SRC="Sources/WapleRender/BaseAssetsSettings.swift"
if grep -q "bundledAssetsDirectory" "$ASSETS_SRC" \
   && grep -q "Waple_WapleRender.bundle" "$ASSETS_SRC"; then
    ok "대체 구현 존재 — bundledAssetsDirectory 의 직접 탐색($ASSETS_SRC)"
else
    bad "직접 탐색 구현이 없다 — 동봉 에셋을 읽을 경로가 아무 데도 없다 ($ASSETS_SRC)"
fi

hr; echo "3. 번들 산출물에 에셋이 실제로 있는가"; hr
# [수정 2026-08-01] 종전에 이 검사가 FAIL 을 냈는데 실제로는 에셋이 정상 동봉돼
# 있었다. 스크립트 버그 둘이 겹쳤다:
#   (a) .build/release 는 심볼릭 링크(-> out/Products/Release)라 find 가 안 내려간다
#       -> -L 로 링크를 따라가고 탐색 루트를 .build 로 넓힌다
#   (b) macOS 번들은 $BND/Contents/Resources/... 레이아웃이다. $BND/WEAssets/... 로
#       찾으면 없다 -> 두 레이아웃을 모두 본다
# [확인 2026-08-16] b901326 이후에도 이 검사는 유효하다. 그 커밋이 바꾼 것은 **앱 번들** 쪽이고
# (Waple_WapleRender.bundle 통째 대신 WEAssets 폴더만 Contents/Resources 에 넣는다),
# 여기가 보는 곳은 .app 이 아니라 .build 다. Package.swift:16 의 `.copy("Resources/WEAssets")`
# 는 그대로이고, package-app.sh:40-44 가 아직도 .build/<config>/Waple_WapleRender.bundle 에서
# WEAssets 를 꺼내 온다 — 이 번들이 없으면 패키징이 그 자리에서 exit 1 이다.
BND=$(find -L .build -name "*WapleRender*.bundle" -maxdepth 6 2>/dev/null | head -1)
if [ -n "$BND" ]; then
    N=$(find -L "$BND" -type f | wc -l | tr -d ' ')
    echo "  번들: $BND"
    echo "  파일 $N 개"
    [ "$N" -ge 2900 ] && ok "에셋 번들 확보(기대 2,940)" || bad "파일이 $N 개뿐"
    HDR_PATH=""
    for cand in "$BND/Contents/Resources/WEAssets/shaders/common.h" \
                "$BND/WEAssets/shaders/common.h"; do
        [ -f "$cand" ] && HDR_PATH="$cand" && break
    done
    if [ -n "$HDR_PATH" ]; then
        ok "common.h 존재 — 디렉터리 구조 보존됨 ($HDR_PATH)"
    else
        bad "common.h 를 두 레이아웃 어디서도 못 찾았다 — .copy 가 평탄화했을 수 있다"
        find -L "$BND" -name "common.h" | head -3 | sed 's/^/    실제 위치: /'
    fi
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
# [수정 2026-08-16] 이 절 — "가장 중요" 라고 적어 둔 그 절 — 의 판정과 출력이 둘 다 틀려 있었다.
# 셋이 겹쳤다:
#   (a) 통과 조건이 `grep -q "with 0 failures"` 였다. 로그 **아무 데나** 그 문자열이 있으면
#       통과다. 번들이 5개라 하나가 깨져도 나머지가 찍은 "with 0 failures" 를 주워
#       "전 스위트 통과" 를 냈다. 실측 확인: WapleCoreTests 가 4건 실패한 로그를 통과로 판정.
#       §2 의 Bundle.module 게이트와 같은 종류의 결함이다 — 시끄럽게 틀리는 게 아니라 조용히 통과.
#       -> 번들 요약 줄만 뽑아 **실패 수를 합산**한다. 요약 줄이 0개인 것도 실패로 본다
#          (스위트가 아예 안 돌았거나 로그가 잘린 것을 통과로 오독하지 않기 위해).
#   (b) 번들별 출력 정규식이 `with [0-9]+ failures` 라 **스킵이 있는 번들을 통째로 빠뜨렸다**
#       (실제 형식은 "with 7 tests skipped and 0 failures"). 하필 가장 큰 두 번들
#       (WapleRenderTests 995·WapleCoreTests 786)이 사라지고, 실패한 번들이 바로 그중
#       하나여서 "번들별 줄로 판단할 것" 이라는 아래 안내 자체가 성립하지 않았다.
#   (c) 테스트 수가 전 Executed 줄 합이라 6,429 로 부풀었다(클래스 소계 혼입).
#       주석은 "번들 총계 줄들을 합산한다" 였는데 코드는 로그 전체를 훑고 있었다.
#       -> 번들 합을 헤드라인으로 낸다. AGENTS.md 의 기준값도 번들 합이다.
BUNDLE_SUMMARY=$(grep -A1 -E "^Test Suite '[A-Za-z0-9_]+\.xctest' (passed|failed) at" \
                 "$OUT/full-suite.log" 2>/dev/null \
                 | grep -oE "Executed [0-9]+ tests?, with ([0-9]+ tests? skipped and )?[0-9]+ failures?")
NBUNDLE=$(printf '%s' "$BUNDLE_SUMMARY" | grep -c "Executed")
NFAIL=$(printf '%s\n' "$BUNDLE_SUMMARY" | grep -oE "[0-9]+ failures?" \
        | grep -oE "^[0-9]+" | awk '{s+=$1} END {print s+0}')
TESTS=$(printf '%s\n' "$BUNDLE_SUMMARY" | grep -oE "Executed [0-9]+" \
        | grep -oE "[0-9]+" | awk '{s+=$1} END {print s+0}')
# 기대 번들 수는 Package.swift 에서 끌어온다 — 하드코딩하면 타깃이 늘 때 조용히 낡는다.
# 이게 없으면 **잘린 로그가 통과한다**: 앞부분만 남은 로그에 통과 번들 하나만 들어 있으면
# 실패 합이 0 이라 OK 가 된다(실측 확인). 번들 수까지 봐야 "다 돌고 다 통과" 가 된다.
NEXPECT=$(grep -cE '^[[:space:]]*\.testTarget' Package.swift)
if [ "$NBUNDLE" -ne "$NEXPECT" ]; then
    bad "번들 요약 $NBUNDLE 개 — Package.swift 의 testTarget $NEXPECT 개와 다르다. 스위트가 다 안 돌았거나 로그가 잘렸다 ($OUT/full-suite.log)"
    printf '%s\n' "$BUNDLE_SUMMARY" | sed 's/^/    /'
elif [ "$NFAIL" -ne 0 ]; then
    bad "전 스위트 실패 — 번들 $NBUNDLE 개에서 실패 $NFAIL 건 ($OUT/full-suite.log)"
    grep -E "error:|failed \(" "$OUT/full-suite.log" | head -20 | sed 's/^/    /'
else
    ok "전 스위트 통과 — 번들 $NBUNDLE 개, 실패 0 ($((SECONDS-T0))초)"
fi
# **[정정 2026-09-01] 이 줄은 AGENTS.md 가 명시적으로 금지한 숫자를 기준값으로 찍고 있었다.**
# 종전: `(기준값 2,300 — AGENTS.md, 2026-08-19 CI 실측. 코퍼스 유무와 무관하다)`.
# AGENTS.md 「빌드와 테스트」의 구성 표는 그 `실행` 열을 두고
#   "**이 열의 숫자를 현재값으로 인용하지 마라** — 현재값은 `ci.yml` 의 census 스텝과
#    위 `grep` 이 정본이다"
# 라고 못박는다. 2,300 은 2026-08-19 스냅샷이고 지금 정본 하한은 그보다 한참 위다.
# 그래서 값을 박지 않고 **정본에서 읽는다** — 래칫이 갱신되면 여기도 따라온다.
FLOOR=$(grep -oE '"\$\{EXECUTED:-0\}" -lt [0-9]+' "$REPO/.github/workflows/ci.yml" \
        | grep -oE '[0-9]+$' | head -1)
if [ -z "${FLOOR:-}" ]; then
    echo "  번들 합: ${TESTS:-?}  (!! ci.yml 의 실행 수 하한을 못 읽었다 — census 스텝이 바뀌었나?)"
else
    echo "  번들 합: ${TESTS:-?}  (하한 ${FLOOR} — 정본은 .github/workflows/ci.yml 의 'Skip / execution census'. 코퍼스 유무와 무관하다)"
fi
echo "  번들별:"
printf '%s\n' "$BUNDLE_SUMMARY" | sed 's/^/    /'

hr; echo "6. 골든 무변화 (Task 1·2 는 픽셀을 바꾸면 안 된다)"; hr
# [수정 2026-08-01] 커밋된 baseline-81098bb 는 **debug** 캡처인데 여기서는 release 로
# 뜬다. debug<->release 는 코드 변경 없이도 30종이 달라진다(최대차 249, 실측).
# 그래서 커밋 기준선과 직접 비교하면 항상 오탐이다.
# 올바른 대조는 **구현 전 release 기준선**이다. 없으면 만들라고 안내하고 넘어간다.
#
# [수정 2026-08-16] 위 "커밋된 기준선은 debug 뿐" 은 더 이상 사실이 아니다.
# ba64c99·88c195e 이후 `spec/golden/snapshot/baseline-6f0bcf0/`(170종, **release**,
# GoldenBaseline.currentLabel)가 커밋돼 있다. debug<->release 오탐 근거는 baseline-81098bb
# 에만 해당한다. 그래도 **자동 기본값으로 삼지는 않는다** — 31fecaa 는 "이 구현 직전" 이
# 아니라 "블룸 교체 직후" 라서 축이 다르고, 기본값을 바꾸면 게이트 의미가 조용히 달라진다.
# 구현 직전 캡처가 없을 때 **차선의 후보**로만 쓸 것:
#   WAPLE_PRE_RELEASE_BASELINE=spec/golden/snapshot/baseline-6f0bcf0
PRE="${WAPLE_PRE_RELEASE_BASELINE:-}"
if [ -z "$PRE" ] || [ ! -d "$PRE/thumbs" ]; then
    echo "  !! 구현 전 release 기준선이 없다. 이 대조는 성립하지 않는다."
    echo "     커밋된 baseline-81098bb 는 debug 라 release 캡처와 항상 30종이 어긋난다."
    echo "     구현 **전에** 아래를 떠 두고 WAPLE_PRE_RELEASE_BASELINE 으로 지정할 것:"
    echo "       git stash && swift run -c release WapleCompat --capture <dir> --label pre-release <corpus>"
    echo "     차선책: 커밋된 release 기준선 spec/golden/snapshot/baseline-6f0bcf0 를"
    echo "       WAPLE_PRE_RELEASE_BASELINE 로 지정 — 단 축이 '구현 직전' 이 아님을 알고 쓸 것."
    echo "     (이번 실행은 아래 캡처만 남기고 대조는 건너뛴다)"
    SKIP_GOLDEN_DIFF=1
fi
LABEL="verify-$(git rev-parse --short HEAD)"
launchctl asuser "$(id -u)" env WAPLE_REAL_PKGS="$WAPLE_REAL_PKGS" \
    WAPLE_BASE_ASSETS="$WAPLE_BASE_ASSETS" \
    swift run -c release WapleCompat --capture "$OUT" --label "$LABEL" "$ROOT" \
    2>&1 | tee "$OUT/capture.log" | tail -6

if [ "${SKIP_GOLDEN_DIFF:-0}" = "1" ]; then
    echo "  (구현 전 release 기준선 부재로 대조 생략)"
else
python3 - "$PRE" "$OUT/$LABEL" <<'PY'
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
fi

hr; echo "7. 골든 게이트 — 커밋된 기준선 대비 WapleCompat --compare 실판정"; hr
# [추가 2026-08-16] §6 과 **축이 다르다**. §6 은 "이번 구현이 픽셀을 움직였는가"(구현 직전
# 기준선 대비, 옵트인)이고, 여기는 "현재 빌드가 커밋된 골든과 같은가"(항상)다. 그래서 §6 의
# `WAPLE_PRE_RELEASE_BASELINE` 기본값을 바꾸지 않고 절을 따로 뒀다 — 그 절의 주석이 경고한
# "기본값을 바꾸면 게이트 의미가 조용히 달라진다" 를 그대로 지킨다.
#
# 왜 새로 붙였나: `SnapshotCompare.swift` 의 3단 판정(해시 동일 / 절대+상대 임계 / structureLoss)이
# 리포 어디에서도 호출되지 않고 있었다(2026-08-16 감사). §6 은 PIL 로 직접 대조하는데다
# `WAPLE_PRE_RELEASE_BASELINE` 미설정이면 통째로 건너뛰고, 그 결과가 FAIL 에 반영되지도 않는다.
# 정성껏 만든 판정기가 안 돌면 없는 것과 같다.
GOLDEN_OUT="$OUT/golden-gate"
WAPLE_REPO="$REPO" WAPLE_DEV_ROOT="$ROOT" WAPLE_GOLDEN_OUT="$GOLDEN_OUT" \
    bash scripts/mac-session/golden-gate.sh
GRC=$?
if [ "$GRC" = 0 ]; then
    ok "골든 무회귀 (--compare exit 0)"
else
    bad "골든 게이트 실패 (exit $GRC) — $GOLDEN_OUT/compare.log"
    echo "     FAIL 이 **의도된 렌더 변경** 때문이라면 기준선을 재생성하고 라벨을 갱신할 것:"
    echo "       bash scripts/mac-session/rebaseline-golden.sh"
    echo "     (판정 기준선 라벨은 GoldenBaselineOracleTests.swift 의 currentLabel 이다)"
fi

hr
[ "$FAIL" = 0 ] && printf '\033[32m검증 통과\033[0m\n' || printf '\033[31mFAIL 있음 — 위 항목 확인\033[0m\n'
echo "로그: $OUT"
hr
exit "$FAIL"
