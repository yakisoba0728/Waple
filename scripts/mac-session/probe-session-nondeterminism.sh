#!/bin/bash
# 골든 캡처의 재현성이 **어느 축에서** 깨지는지 잰다 — 측정 전용(커밋·푸시하지 말 것).
#
# 결론(2026-08-01 실측, spec/golden/nondeterminism.json):
#   같은 세션 안에서는 프로세스를 갈라도 전 코퍼스가 비트동일하고,
#   세션이 갈리면 **29종**이 갈린다. 부하·순서·TZ·CWD 는 값을 바꾸지 못한다.
#
# 이 스크립트는 그 측정을 다시 뜬다. 다섯 단계 전부 "차이 0" 이 기대값이고,
# 마지막에 커밋된 세션 매니페스트와 대조해 **지금이 새 세션인지**(=상태가 플립했는지) 알려준다.
# 플립했으면 tsweep(t=0,0.1,1,6) 대조로 마운트 발산 대 프레임 누적을 가를 수 있다 —
# spec/golden/nondeterminism.json 의 oracle.nondet.cause 참조.
#
# 소요: 전 코퍼스 캡처 3회(각 ~3분) + 단건 십수 회 ≈ 12분.
#
# 왜 probe-nondeterminism.sh 로는 부족한가: 그쪽은 한 번 호출에 runA·runB 를 **둘 다** 떠서
# 두 캡처 사이에 아무것도 끼울 수 없다(부하를 끼우라는 지시를 그대로 따라도 안 끼워진다).
set -uo pipefail

REPO="${WAPLE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ROOT="${WAPLE_DEV_ROOT:-$HOME/Downloads/wallpaper_dev}"
OUT="${WAPLE_VERIFY_OUT:-$HOME/Downloads/waple-session-nondet}"
BIN="$REPO/.build/release/WapleCompat"
SCENES="${WAPLE_PROBE_SCENES:-3302695207 3629379075 3696323523}"   # 불안정 가족 중 3종

cd "$REPO" || exit 1
mkdir -p "$OUT"

echo "빌드(release)…"
swift build -c release 2>&1 | tail -3 || exit 1
echo "바이너리 sha256=$(shasum -a 256 "$BIN" | awk '{print $1}')"
echo "  (세션 간 대조의 전제 — 이 값이 이전 실행과 같아야 '같은 바이너리' 주장이 선다)"

cap() {   # cap <출력루트> <라벨> <씬루트> [추가 env…]
    local out="$1" lbl="$2" root="$3"; shift 3
    [ -d "$out/$lbl" ] && return 0
    launchctl asuser "$(id -u)" env "$@" \
        WAPLE_REAL_PKGS="$ROOT/backgrounds" WAPLE_BASE_ASSETS="$ROOT/assets" \
        "$BIN" --capture "$out" --label "$lbl" "$root" >/dev/null 2>&1
}

echo
echo "[1/5] 전 코퍼스 2회(별도 프로세스) — 세션 내 재현성"
cap "$OUT" R1 "$ROOT"; cap "$OUT" R2 "$ROOT"

echo "[2/5] 단건 3회 × ${SCENES// /, } — 순차 캡처 값과 일치하는가"
for sid in $SCENES; do
    for k in 1 2 3; do cap "$OUT/single" "${sid}_$k" "$ROOT/backgrounds/$sid"; done
done

echo "[3/5] 부하 개입 — 단건 → 전 코퍼스 → 단건"
for sid in $SCENES; do cap "$OUT/interleave" "pre_$sid" "$ROOT/backgrounds/$sid"; done
cap "$OUT" R3 "$ROOT"
for sid in $SCENES; do cap "$OUT/interleave" "post_$sid" "$ROOT/backgrounds/$sid"; done

echo "[4/5] 타임존 4종"
for tz in UTC Asia/Tokyo Pacific/Kiritimati America/Los_Angeles; do
    cap "$OUT/tz" "$(echo "$tz" | tr '/' '_')" "$ROOT/backgrounds/${SCENES%% *}" TZ="$tz"
done

echo "[5/5] 작업 디렉터리 3종"
for d in "$REPO" "$HOME" /tmp; do
    (cd "$d" && cap "$OUT/cwd" "$(echo "$d" | tr '/' '_')" "$ROOT/backgrounds/${SCENES%% *}")
done

python3 - "$OUT" "$REPO" "$SCENES" <<'PY'
import json, os, sys
out, repo, scenes = sys.argv[1], sys.argv[2], sys.argv[3].split()

def man(path):
    p = os.path.join(path, "manifest.json")
    if not os.path.exists(p):
        print(f"!! {p} 없음 — 캡처 실패"); sys.exit(1)
    return {e["id"]: e for e in json.load(open(p, encoding="utf-8"))["entries"]}

def diff(a, b):
    return sorted(i for i in a if i in b and a[i]["hash"] != b[i]["hash"])

fails = []
def check(name, got, expect=0):
    ok = (got == expect)
    print(f"  {'ok  ' if ok else 'FAIL'} {name}: {got}종 (기대 {expect})")
    if not ok: fails.append(name)

R = {k: man(f"{out}/{k}") for k in ("R1", "R2", "R3")}
print("\n=== 축 판정 ===")
check("세션 내 전 코퍼스 R1 vs R2", len(diff(R["R1"], R["R2"])))
check("부하 개입 뒤 R1 vs R3", len(diff(R["R1"], R["R3"])))

for sid in scenes:
    hs = {k: man(f"{out}/single/{sid}_{k}")[sid]["hash"] for k in "123"}
    check(f"단건 3회 {sid}", len(set(hs.values())) - 1)
    check(f"단건 == 순차 {sid}", 0 if hs["1"] == R["R1"][sid]["hash"] else 1)
    pre, post = man(f"{out}/interleave/pre_{sid}")[sid], man(f"{out}/interleave/post_{sid}")[sid]
    check(f"부하 전후 단건 {sid}", 0 if pre["hash"] == post["hash"] else 1)

first = scenes[0]
for group in ("tz", "cwd"):
    hs = {d: man(f"{out}/{group}/{d}")[first]["hash"]
          for d in sorted(os.listdir(f"{out}/{group}")) if os.path.isdir(f"{out}/{group}/{d}")}
    check(f"{group} {len(hs)}종 {first}", len(set(hs.values())) - 1)

# 커밋된 세션들과 대조 — 지금이 새 세션인가(=상태가 플립했나)
base = os.path.join(repo, "spec", "golden", "snapshot", "nondet-2026-08-01")
print("\n=== 커밋된 세션 대조(플립 감지) ===")
known = {}
for d in sorted(os.listdir(base)):
    p = os.path.join(base, d)
    if os.path.isdir(p):
        known[d] = man(p)
for d, m in known.items():
    n = len(diff(R["R1"], m))
    print(f"  R1 vs {d:<12} {n:>3}종")
uni = sorted({i for m in known.values() for i in diff(R["R1"], m)} & set(R["R1"]))
print(f"\n  지금 실행이 커밋된 세션 중 하나와 0종이면 같은 상태, 아니면 **새 세션**이다.")
print(f"  커밋 세션들과 갈리는 씬 합집합: {len(uni)}종")
json.dump({"differsFromCommittedSessions": {d: len(diff(R['R1'], m)) for d, m in known.items()},
           "unionDiffering": uni}, open(f"{out}/session-compare.json", "w"), ensure_ascii=False, indent=1)

print()
if fails:
    print(f"!! 기대와 다른 항목 {len(fails)}건 — {', '.join(fails)}")
    print("   2026-08-01 실측(spec/golden/nondeterminism.json)과 축이 달라졌다는 뜻이다. 정본을 갱신할 것.")
    sys.exit(1)
print("전 항목 기대대로 — 세션 내 재현성 유지, 부하/순서/TZ/CWD 무영향.")
PY
