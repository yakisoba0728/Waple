#!/bin/bash
# 커밋된 골든 기준선 대비 픽셀 회귀 게이트 — `WapleCompat --compare` 를 **실제로 돌린다**.
#
# 왜 이 파일이 생겼나 (2026-08-16 감사):
#   `SnapshotCompare.swift` 의 3단 판정(① 해시/픽셀 동일 즉시 통과 ② 절대 임계 + 기준선 밝기로
#   정규화한 상대차 ③ 아주 어두운 씬의 structureLoss)이 **리포 어디에서도 호출되지 않았다**.
#   `grep -rn -- "--compare" scripts/ .github/ Tests/` 의 히트 3건이 전부 "쓰지 않는다" 는
#   문장이었다(ab-deviations/README.md, 03-ab-diff.py). 판정기가 안 돌면 없는 것과 같다 —
#   이 리포에서 안전망이 조용히 무력했던 사건의 반복이다(gate-analysis.json 의 negativeControl 참조).
#
# 왜 CI 가 아닌가:
#   ① CI 러너에 **코퍼스가 없다**. WE 워크샵 pkg 는 커밋 대상이 아니고, 코퍼스가 없으면
#      --compare 는 베이스라인 entry 를 전부 skip 해 exit 2(환경 오류)를 낼 뿐 아무것도 검증하지 않는다.
#   ② 코퍼스를 넣더라도 수십 GB 전송 + 씬 170종 캡처가 40분 타임아웃 예산을 먹는다(캡처 자체는
#      2026-08-16 실측 140.6초/warm, docs/snapshot-regression.md 는 1× 패스 ≈360초·피크 RSS ≈3.9GB).
#      결정적인 것은 ① 이고 ② 는 보조 근거다.
#   그래서 **코퍼스가 있는 로컬 맥 세션**의 검증 경로에 붙인다 — `verify-plan-b12.sh` §7 이 이걸 부른다.
#   (Metal 가용성은 이유가 아니다. AGENTS.md 실측대로 GPU 는 CI 에서도 잡힌다.)
#
# 종료코드는 --compare 의 것을 그대로 물려준다:
#   0 = 회귀 없음 · 1 = 결정 씬 FAIL 또는 렌더→무픽셀 회귀 · 2 = 환경 오류(코퍼스/베이스라인 부재 등)
set -uo pipefail

REPO="${WAPLE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ROOT="${WAPLE_DEV_ROOT:-$HOME/Downloads/wallpaper_dev}"
OUT="${WAPLE_GOLDEN_OUT:-${TMPDIR:-/tmp}/waple-golden-gate}"
# WapleCompat 은 `WAPLE_REAL_PKGS` 를 **읽지 않는다** — 그건 XCTest 쪽 변수고, 여기서 코퍼스를
# 정하는 것은 아래 위치 인자 `$ROOT` 다(SnapshotPipeline.sceneContainer: $ROOT/backgrounds 가
# 있으면 그것, 없으면 $ROOT). 그래서 존재 검사도 그 해석을 그대로 따라간다 — WAPLE_REAL_PKGS 만
# 보면 "변수는 맞는데 정작 다른 디렉터리를 훑는" 조합을 통과시킨다.
# 반면 `WAPLE_BASE_ASSETS` 는 SnapshotPipeline.swift:266 이 실제로 읽는다(공유 셰이더 common.h).
export WAPLE_BASE_ASSETS="${WAPLE_BASE_ASSETS:-$ROOT/assets}"
SCENES="$ROOT/backgrounds"
[ -d "$SCENES" ] || SCENES="$ROOT"

cd "$REPO" || exit 2
mkdir -p "$OUT"

# 기준선 라벨은 **코드에서 읽는다**. 여기에 상수로 박아 두면 재베이스라인 때 조용히 낡아서
# "게이트는 돌았는데 옛 기준선을 봤다" 가 된다. 폴백 상수를 두지 않는 것도 같은 이유다 —
# 못 읽으면 시끄럽게 죽는 편이 낫다.
LABEL_SRC="Tests/WapleRenderTests/GoldenBaselineOracleTests.swift"
LABEL=$(sed -n 's/.*static let currentLabel = "\([^"]*\)".*/\1/p' "$LABEL_SRC" | head -1)
if [ -z "$LABEL" ]; then
    echo "FAIL  현행 기준선 라벨을 못 읽었다 — $LABEL_SRC 의 currentLabel 선언을 확인할 것" >&2
    exit 2
fi
BASELINE="${WAPLE_GOLDEN_BASELINE:-spec/golden/snapshot/$LABEL}"

if [ ! -f "$BASELINE/manifest.json" ] || [ ! -d "$BASELINE/thumbs" ]; then
    echo "FAIL  기준선이 없다: $BASELINE (manifest.json + thumbs/ 필요)" >&2
    exit 2
fi
if [ ! -d "$SCENES" ]; then
    echo "FAIL  코퍼스가 없다: $SCENES — 이 게이트는 코퍼스 없이는 성립하지 않는다" >&2
    echo "      WAPLE_DEV_ROOT 로 코퍼스 루트를 지정할 것(<루트>/backgrounds/<id>/ 레이아웃)" >&2
    exit 2
fi

# ─── 축소 모드: 배선 확인 전용 ────────────────────────────────────────────────
# WAPLE_GOLDEN_SCENES="id,id,..." 을 주면 그 씬만 남긴 기준선 사본을 임시로 만들어 대조한다.
# 전량은 170종 캡처라 몇 분이 걸리므로 "스크립트가 정말 판정기를 부르고 종료코드를 물려받는가"
# 를 확인할 때 쓴다. **회귀/파리티 판정에 쓰지 마라** — AGENTS.md 의 축소 코퍼스 주의와 같은 이유다.
SUBSET="${WAPLE_GOLDEN_SCENES:-}"
if [ -n "$SUBSET" ]; then
    TRIM="$OUT/subset-$LABEL"
    rm -rf "$TRIM"
    mkdir -p "$TRIM/thumbs"
    python3 - "$BASELINE" "$TRIM" "$SUBSET" <<'PY' || exit 2
import json, os, shutil, sys
src, dst, ids = sys.argv[1], sys.argv[2], [s.strip() for s in sys.argv[3].split(",") if s.strip()]
m = json.load(open(os.path.join(src, "manifest.json"), encoding="utf-8"))
keep = [e for e in m["entries"] if e["id"] in ids]
missing = sorted(set(ids) - {e["id"] for e in keep})
if missing:
    print(f"  !! 기준선에 없는 씬: {missing}", file=sys.stderr); sys.exit(1)
m["entries"] = keep          # 나머지 최상위 필드(thumbWidth/captureTime/activeDebugGates…)는 그대로 — 빼면 Codable 디코드가 실패한다
m["empties"] = []
m["failures"] = []
json.dump(m, open(os.path.join(dst, "manifest.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
for e in keep:
    shutil.copy2(os.path.join(src, "thumbs", e["id"] + ".png"), os.path.join(dst, "thumbs", e["id"] + ".png"))
print(f"  축소 기준선 {len(keep)}종: {dst}")
PY
    BASELINE="$TRIM"
    printf '\033[33m  ⚠️ 축소 모드(%s) — 배선 확인 전용이다. 이 결과로 무회귀를 주장하지 마라.\033[0m\n' "$SUBSET"
fi

echo "골든 게이트: $BASELINE  vs  현재 빌드 (git $(git rev-parse --short HEAD))"
echo "  코퍼스: $SCENES ($(ls "$SCENES" 2>/dev/null | wc -l | tr -d ' ')개) · 공유 에셋: $WAPLE_BASE_ASSETS"

LOG="$OUT/compare.log"
# macOS 는 GUI 로그인 세션 밖에서 Metal 을 주지 않는다 — SSH 실행 시 GPU 작업이 실패가 아니라
# 조용히 스킵되므로 launchctl asuser 로 감싼다(spec/golden/snapshot/README.md 와 동일 규약).
launchctl asuser "$(id -u)" env WAPLE_BASE_ASSETS="$WAPLE_BASE_ASSETS" \
    swift run -c release WapleCompat --compare "$BASELINE" "$ROOT" > "$LOG" 2>&1
RC=$?

# 씬별 마운트 로그가 수천 줄이라 판정에 필요한 부분만 올린다(전문은 $LOG).
sed -n '/\[snap compare\]/,$p' "$LOG" | grep -v '^\[Waple\]' | head -40
grep -E "^\[snap\] ⚠️|현재 마운트 실패" "$LOG" | head -10

# 요약 블록이 없다는 것은 판정이 **아예 안 돌았다**는 뜻이다(빌드 실패, 기동 실패 등).
# 그걸 exit 1 로 흘리면 "회귀를 잡았다" 로 오독된다 — 회귀가 아니라 환경 오류로 낸다.
if ! grep -q '\[snap compare\]' "$LOG"; then
    printf '  \033[31mFAIL\033[0m  판정이 실행되지 않았다(빌드/기동 실패, 원 종료코드 %s). 전문: %s\n' "$RC" "$LOG"
    tail -15 "$LOG" | sed 's/^/    /'
    exit 2
fi

# FAIL 을 읽는 데 필요한 정본 한 조각: 커밋된 기준선과의 대조는 **세션을 건너뛴 대조**이고,
# 그 축에서 불안정한 29종이 이미 측정돼 있다(spec/golden/nondeterminism.json →
# oracle.nondet.unstableSet). 그 29종은 셀프체크가 프로세스 내부만 재는 탓에 매니페스트에
# deterministic=true 로 잘못 실려 strict 로 샌다. 그래서 FAIL 목록에 그 가족이 섞이면
# "코드가 픽셀을 바꿨다" 와 "세션이 갈렸다" 가 이 대조만으로는 구별되지 않는다.
# 종료코드는 건드리지 않는다 — 판정을 무르게 하는 게 아니라 읽는 법을 붙일 뿐이다.
if [ "$RC" = 1 ]; then
    python3 - "$LOG" "$REPO/spec/golden/nondeterminism.json" <<'PY'
import json, re, sys
log, canon = sys.argv[1], sys.argv[2]
failed = re.findall(r"^  ✗ (\d+) ", open(log, encoding="utf-8", errors="replace").read(), re.M)
ids = set()
for e in json.load(open(canon, encoding="utf-8"))["entries"]:
    if e["id"].endswith("unstableSet"):
        ids = set(e["value"]["ids"])
hit = [f for f in failed if f in ids]
if hit:
    print(f"  ↳ 위 FAIL {len(failed)}종 중 {len(hit)}종이 oracle.nondet.unstableSet(세션 간 불안정 "
          f"{len(ids)}종)에 있다: {','.join(hit)}")
    print("     이 가족은 세션이 갈리면 값이 달라진다 — 코드 회귀와 세션 잡음이 이 대조만으로는 갈리지 않는다.")
clean = [f for f in failed if f not in ids]
if clean:
    print(f"  ↳ 불안정 가족 **밖**의 FAIL {len(clean)}종: {','.join(clean)} — 이쪽이 먼저 봐야 할 것이다.")
PY
fi

case "$RC" in
    0) printf '  \033[32mOK\033[0m    골든 무회귀 (WapleCompat --compare, exit 0)\n' ;;
    1) printf '  \033[31mFAIL\033[0m  골든 회귀 — 결정 씬 FAIL 또는 렌더→무픽셀 (exit 1). 전문: %s\n' "$LOG" ;;
    2) printf '  \033[31mFAIL\033[0m  환경 오류 — 베이스라인/코퍼스/썸네일 크기 불일치 (exit 2). 전문: %s\n' "$LOG" ;;
    *) printf '  \033[31mFAIL\033[0m  --compare 가 예상 밖 종료코드 %s 로 끝났다. 전문: %s\n' "$RC" "$LOG" ;;
esac
exit "$RC"
