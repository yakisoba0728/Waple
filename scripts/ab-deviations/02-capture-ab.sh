#!/bin/bash
# Waple A/B — 이탈 3건 제거 후 B 캡처
#
# A 쪽은 이미 리포에 있다: spec/golden/snapshot/baseline-81098bb/
# 별도 임시 worktree 에 패치를 적용해 B 를 뜬다. 원래 작업 트리는 건드리지 않는다.

set -uo pipefail

REPO="${WAPLE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ROOT="${WAPLE_DEV_ROOT:-$HOME/Downloads/wallpaper_dev}"
OUT="${WAPLE_AB_OUT:-$HOME/Downloads/waple-ab}"

hr() { printf '%s\n' "----------------------------------------------------------------"; }
cd "$REPO" || { echo "리포 없음: $REPO"; exit 1; }
REPO="$(pwd -P)"
case "$ROOT" in /*) ;; *) ROOT="$REPO/$ROOT" ;; esac
case "$OUT" in /*) ;; *) OUT="$REPO/$OUT" ;; esac
export WAPLE_REAL_PKGS="$ROOT/backgrounds"
export WAPLE_BASE_ASSETS="$ROOT/assets"

if [ -n "$(git status --porcelain)" ]; then
    echo "!! 작업 트리가 더럽다. 패치를 적용할 수 없다."
    git status --short
    exit 1
fi

# 원래 작업 트리의 실행 중 편집을 지우지 않도록, 소유한 worktree 만 정리한다.
TMP="$(mktemp -d)" || exit 1
WORKTREE="$TMP/tree"
cleanup() {
    if [ -d "$WORKTREE" ]; then
        git -C "$REPO" worktree remove --force "$WORKTREE" || echo "!! 임시 worktree 등록 정리 실패: $WORKTREE" >&2
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
git worktree add --detach "$WORKTREE" HEAD || exit 1
cd "$WORKTREE" || exit 1

hr; echo "1. 이탈 제거 패치 적용"; hr

py() { /usr/bin/env python3 "$@"; }

py - <<'PYEOF'
import re, sys, pathlib

REPO = pathlib.Path(".")
fails = []

def patch(rel, subs):
    p = REPO / rel
    s = p.read_text(encoding="utf-8")
    orig = s
    for old, new, label in subs:
        if old not in s:
            fails.append(f"{rel}: 패턴 미발견 — {label}\n   찾던 것: {old!r}")
            continue
        s = s.replace(old, new, 1)
        print(f"  ok  {rel}  [{label}]")
    if s != orig:
        p.write_text(s, encoding="utf-8")

# --- D1: GGX 분모 바닥값 제거 (CPU) ---
patch("Sources/WapleCore/ScenePBRLighting.swift", [
    ("let denominator = max(rawDenominator, ggxDenominatorFloor)",
     "let denominator = rawDenominator   // [A/B] D1 제거",
     "D1 GGX 바닥값(CPU)"),
])

# --- D2: nl/nv 하한 제거 (CPU) ---
patch("Sources/WapleCore/ScenePBRLighting.swift", [
    ("let nv = max(simd_dot(normal, view), 0.001)",
     "let nv = max(simd_dot(normal, view), 0.0)   // [A/B] D2 제거",
     "D2 nv 하한(CPU)"),
    ("let nl = max(simd_dot(normal, light), 0.001)",
     "let nl = max(simd_dot(normal, light), 0.0)   // [A/B] D2 제거",
     "D2 nl 하한(CPU)"),
])

# --- D1: GGX 분모 바닥값 제거 (MSL) ---
patch("Sources/WapleRender/Mesh3DShaders.swift", [
    ("float denominator = max(rawDenominator, 1e-4);",
     "float denominator = rawDenominator;   // [A/B] D1 제거",
     "D1 GGX 바닥값(MSL)"),
])

# --- D3: 블렌드 가드를 WE 의 정확 비교로 (MSL) ---
# WE: (blend == 0.0) ? blend : max(1-(1-base)/blend, 0)
#     (blend == 1.0) ? blend : min(base/(1-blend), 1)
patch("Sources/WapleRender/BlendMSL.swift", [
    ("inline float3 we_colorburn(float3 b, float3 s) { return select(max(1.0-(1.0-b)/max(s,1e-5), 0.0), float3(0.0), s <= 0.0); }",
     "inline float3 we_colorburn(float3 b, float3 s) { return select(max(1.0-(1.0-b)/s, 0.0), s, s == 0.0); }   // [A/B] D3 -> WE 정확비교",
     "D3 colorburn"),
    ("inline float3 we_colordodge(float3 b, float3 s) { return select(min(b/max(1.0-s,1e-5), 1.0), float3(1.0), s >= 1.0); }",
     "inline float3 we_colordodge(float3 b, float3 s) { return select(min(b/(1.0-s), 1.0), s, s == 1.0); }   // [A/B] D3 -> WE 정확비교",
     "D3 colordodge"),
    ("inline float3 we_reflect(float3 b, float3 s) { return select(min(b*b/max(1.0-s,1e-5), 1.0), float3(1.0), s >= 1.0); }",
     "inline float3 we_reflect(float3 b, float3 s) { return select(min(b*b/(1.0-s), 1.0), s, s == 1.0); }   // [A/B] D3 -> WE 정확비교",
     "D3 reflect"),
])

if fails:
    print("\n!! 패치 실패 — 소스가 예상과 다르다. 아래를 그대로 보고해라:\n")
    for f in fails:
        print("  " + f)
    sys.exit(1)
print("\n패치 4파일 적용 완료")
PYEOF

if [ $? -ne 0 ]; then
    echo "패치 실패 — 중단한다(임시 worktree 는 trap 이 정리)"
    exit 1
fi

hr; echo "2. 변경 확인"; hr
git diff --stat
echo
git diff -U0 | grep -E "^[+-][^+-]" | head -20

hr; echo "3. release 빌드 (콜드면 5~12분)"; hr
T0=$SECONDS
if ! swift build -c release 2>&1 | tail -20; then
    echo "빌드 실패 — 위 출력 전문을 보고할 것"
    exit 1
fi
echo "  빌드 $((SECONDS-T0))초"

hr; echo "4. B 캡처 (release, 약 10분 예상)"; hr
mkdir -p "$OUT"
LABEL="ab-deviations-removed"
T0=$SECONDS
launchctl asuser "$(id -u)" \
    env WAPLE_REAL_PKGS="$WAPLE_REAL_PKGS" WAPLE_BASE_ASSETS="$WAPLE_BASE_ASSETS" \
    swift run -c release WapleCompat --capture "$OUT" --label "$LABEL" "$ROOT" 2>&1 \
    | tee "$OUT/capture-$LABEL.log" | tail -25
RC=${PIPESTATUS[0]}
echo "  캡처 $((SECONDS-T0))초, 종료코드 $RC"

hr; echo "결과"; hr
M="$OUT/$LABEL/manifest.json"
if [ -f "$M" ]; then
    echo "  B 매니페스트: $M"
    python3 -c "
import json
m=json.load(open('$M'))
print(f\"  entries={len(m.get('entries',[]))} empties={len(m.get('empties',[]))} failures={len(m.get('failures',[]))}\")
"
    echo
    echo "다음: python3 03-ab-diff.py"
else
    echo "  !! 매니페스트 없음 — 캡처 실패. 로그 확인: $OUT/capture-$LABEL.log"
fi
exit $RC
