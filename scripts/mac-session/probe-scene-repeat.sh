#!/bin/bash
# 씬 **한 종**을 별도 프로세스로 N회 캡처해 해시 종수를 낸다 — 잔여 비결정의 재현률 측정용.
#
# 왜 별도 스크립트인가: probe-nondeterminism.sh 는 전 코퍼스를 2회만 뜬다(170종 × 2). 잔여
# 비결정은 **간헐**이라(씬 1종의 실행당 발화율 50~80% 실측) 2회로는 있고 없고를 못 가른다.
# 여기서는 한 씬만 N회 떠서 재현률 자체를 수치로 낸다.
#
# 매니페스트의 selfMaxDiff 도 같이 읽는다 — 이건 **같은 프로세스 안 두 마운트**의 최대차라
# 한 번 캡처가 표본 2개를 준다(프로세스 간 + 프로세스 내). 3706286085 는 두 축 모두에서 흔들린다
# (spec/golden/nondeterminism.json → oracle.nondet.meshMipLodResidual).
#
# 사용: probe-scene-repeat.sh <씬ID> [횟수=8] [출력루트]
set -uo pipefail
REPO="${WAPLE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ROOT="${WAPLE_DEV_ROOT:-$HOME/Downloads/wallpaper_dev}"
ID="${1:?씬 ID 를 달라 — 예: 3706286085}"
N="${2:-8}"
OUT="${3:-$HOME/Downloads/waple-scene-repeat}"
BIN="$REPO/.build/release/WapleCompat"

cd "$REPO" || exit 1
echo "빌드(release)…"
swift build -c release 2>&1 | tail -2 || exit 1
echo "HEAD=$(git rev-parse --short HEAD) · 씬 $ID · $N 회(별도 프로세스)"
mkdir -p "$OUT"
for i in $(seq 1 "$N"); do
    rm -rf "$OUT/run$i"
    launchctl asuser "$(id -u)" env WAPLE_REAL_PKGS="$ROOT/backgrounds" WAPLE_BASE_ASSETS="$ROOT/assets" \
        "$BIN" --capture "$OUT" --label "run$i" "$ROOT/backgrounds/$ID" >/dev/null 2>&1
done

python3 - "$OUT" "$N" "$ID" <<'PY'
import collections, json, os, sys
out, n, sid = sys.argv[1], int(sys.argv[2]), sys.argv[3]
seen, selfs = collections.OrderedDict(), []
for i in range(1, n + 1):
    p = os.path.join(out, f"run{i}", "manifest.json")
    if not os.path.exists(p):
        print(f"  run{i}: 매니페스트 없음 — 캡처 실패"); continue
    e = next((x for x in json.load(open(p))["entries"] if x["id"] == sid), None)
    if e is None:
        print(f"  run{i}: entry 없음 — 씬이 프레임을 못 냈다"); continue
    seen.setdefault(e["hash"], []).append(i)
    selfs.append(e["selfMaxDiff"])
    print(f"  run{i}: hash={e['hash']} meanLuma={e['meanLuma']:.8f} selfMaxDiff={e['selfMaxDiff']}")
print(f"\n프로세스 간: 해시 {len(seen)}종 / {len(selfs)}회")
for h, runs in seen.items():
    print(f"  {h} ×{len(runs)} {runs}")
nz = [s for s in selfs if s > 0]
print(f"프로세스 내(셀프체크): selfMaxDiff 비영 {len(nz)}/{len(selfs)}  값={selfs}")
print("\n해시 1종 + selfMaxDiff 전부 0 이어야 '이 씬은 결정적' 이다.")
PY
