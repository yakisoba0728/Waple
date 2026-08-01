#!/bin/bash
# 실행 간 비결정 씬을 **프로세스를 갈라서** 찾아낸다.
#
# 왜 필요한가: 파이프라인의 셀프체크(deterministic/selfMaxDiff)는 2차 캡처를 **같은
# 프로세스** 안에서 뜬다(SnapshotPipeline.swift:187 부근). 프로세스 시작 시 정해지는 것들
# (RNG 시드·정적 캐시·딕셔너리 순회 순서·셰이더 컴파일 순서 등)이 두 캡처에서 동일하므로
# 프로세스 간 변동을 **구조적으로** 못 잡는다.
# 실측(2026-08-01): 같은 커밋·같은 빌드로 두 번 떠서 대조하니 29종이 달랐는데
# 전부 deterministic=true / selfMaxDiff=0 으로 기록돼 있었다.
#
# 이 스크립트는 같은 빌드로 **별도 프로세스 두 번** 캡처해 씬별 차이를 낸다.
# 산출물(nondet.json)만 있으면 원인 분류는 윈도우 쪽에서 코퍼스와 대조해 끝낼 수 있다.
#
# 주의: 렌더 코드를 고치는 작업이 아니다. 측정만 한다. 커밋·푸시하지 말 것.
set -uo pipefail

REPO="${WAPLE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ROOT="${WAPLE_DEV_ROOT:-$HOME/Downloads/wallpaper_dev}"
OUT="${WAPLE_VERIFY_OUT:-$HOME/Downloads/waple-nondet}"
export WAPLE_REAL_PKGS="${WAPLE_REAL_PKGS:-$ROOT/backgrounds}"
export WAPLE_BASE_ASSETS="${WAPLE_BASE_ASSETS:-$ROOT/assets}"

cd "$REPO" || exit 1
mkdir -p "$OUT"

echo "빌드(release)…"
swift build -c release 2>&1 | tail -5 || exit 1
SHA=$(git rev-parse --short HEAD)
echo "HEAD=$SHA — 같은 빌드로 **별도 프로세스** 2회 캡처한다."

for run in A B; do
    if [ -d "$OUT/run$run" ]; then
        echo "  run$run 이미 있음 — 건너뜀(다시 뜨려면 지울 것)"
        continue
    fi
    echo "  run$run 캡처…"
    launchctl asuser "$(id -u)" env WAPLE_REAL_PKGS="$WAPLE_REAL_PKGS" \
        WAPLE_BASE_ASSETS="$WAPLE_BASE_ASSETS" \
        swift run -c release WapleCompat --capture "$OUT" --label "run$run" "$ROOT" \
        2>&1 | tail -4
done

python3 - "$OUT/runA" "$OUT/runB" "$OUT/nondet.json" <<'PY'
import json, os, sys
a, b, outp = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    from PIL import Image
except ImportError:
    print("PIL 없음 — pip3 install pillow"); sys.exit(1)

def manifest(d):
    p = os.path.join(d, "manifest.json")
    if not os.path.exists(p):
        print(f"!! {p} 없음 — 캡처 실패"); sys.exit(1)
    return {e["id"]: e for e in json.load(open(p))["entries"]}

ma, mb = manifest(a), manifest(b)
rows, common = [], sorted(set(ma) & set(mb))
for sid in common:
    pa = os.path.join(a, "thumbs", f"{sid}.png")
    pb = os.path.join(b, "thumbs", f"{sid}.png")
    if not (os.path.exists(pa) and os.path.exists(pb)):
        continue
    ia, ib = Image.open(pa).convert("RGB"), Image.open(pb).convert("RGB")
    if ia.size != ib.size:
        rows.append({"id": sid, "maxDiff": -1, "meanDiff": -1.0,
                     "pipelineSaysDeterministic": bool(ma[sid].get("deterministic")),
                     "pipelineSelfMaxDiff": ma[sid].get("selfMaxDiff")})
        continue
    da, db = list(ia.getdata()), list(ib.getdata())
    mx = 0; tot = 0
    for (r1, g1, b1), (r2, g2, b2) in zip(da, db):
        d = max(abs(r1 - r2), abs(g1 - g2), abs(b1 - b2))
        if d > mx: mx = d
        tot += d
    if mx == 0:
        continue
    rows.append({"id": sid, "maxDiff": mx, "meanDiff": round(tot / len(da), 4),
                 "pipelineSaysDeterministic": bool(ma[sid].get("deterministic")),
                 "pipelineSelfMaxDiff": ma[sid].get("selfMaxDiff")})

rows.sort(key=lambda r: -r["maxDiff"])
misreported = [r for r in rows if r["pipelineSaysDeterministic"]]
print(f"대조 {len(common)}종 · 실행 간 차이 {len(rows)}종")
print(f"  그중 파이프라인이 deterministic=true 로 보고한 것: {len(misreported)}종  <- 셀프체크가 놓친 분량")
print()
print(f"  {'씬':<14}{'최대차':>7}{'평균차':>9}   파이프라인 보고")
for r in rows[:40]:
    print(f"  {r['id']:<14}{r['maxDiff']:>7}{r['meanDiff']:>9.3f}   "
          f"det={r['pipelineSaysDeterministic']} selfMax={r['pipelineSelfMaxDiff']}")
json.dump({"scenes": len(common), "nondeterministic": rows,
           "misreportedAsDeterministic": [r["id"] for r in misreported]},
          open(outp, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(f"\n기록: {outp}")
PY

echo
echo "이 파일을 그대로 돌려주면 된다: $OUT/nondet.json"
echo "(원인 분류 — 파티클/비디오/스프라이트시트 상관 — 는 윈도우에서 코퍼스와 대조해 끝낸다)"
