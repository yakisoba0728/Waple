#!/bin/bash
# 커밋되는 골든 기준선을 다시 뜬다 — **자기검증 포함**.
#
# 절차: release 로 전 코퍼스를 두 번(별도 프로세스) 뜨되 **두 캡처 사이에 마우스 커서를 옮긴다**.
# 두 캡처가 비트동일해야 통과다. 이건 형식적인 절차가 아니라 실제로 깨졌던 것을 막는 게이트다 —
# 2026-08-02 이전에는 캡처가 커서 위치를 픽셀에 구웠고(29종/170종), 그래서 세션이 갈리면
# 기준선이 흔들렸다(spec/golden/nondeterminism.json → oracle.nondet.rootCause).
#
# 통과하면 첫 캡처를 spec/golden/snapshot/baseline-<sha>/ 로 설치한다(manifest + thumbs).
# 사용: rebaseline-golden.sh [출력루트]
set -uo pipefail
REPO="${WAPLE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ROOT="${WAPLE_DEV_ROOT:-$HOME/Downloads/wallpaper_dev}"
OUT="${1:-$HOME/Downloads/waple-rebaseline}"
BIN="$REPO/.build/release/WapleCompat"
TMP="$(mktemp -d)"

cd "$REPO" || exit 1
if [ -n "$(git status --porcelain -- Sources Package.swift)" ]; then
    echo "!! Sources 에 커밋 안 된 변경이 있다 — 기준선 라벨(sha)이 실제 코드와 어긋난다. 먼저 커밋할 것."
    exit 1
fi
SHA=$(git rev-parse --short HEAD)
echo "빌드(release) · HEAD=$SHA"
swift build -c release 2>&1 | tail -2 || exit 1
echo "바이너리 sha256=$(shasum -a 256 "$BIN" | awk '{print $1}')"

cat > "$TMP/cursor.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let a = CommandLine.arguments
if a.count >= 3, let x = Double(a[1]), let y = Double(a[2]) {
    CGWarpMouseCursorPosition(CGPoint(x: x, y: y)); CGAssociateMouseAndMouseCursorPosition(1)
}
if let loc = CGEvent(source: nil)?.location { print("\(loc.x) \(loc.y)") }
SWIFT
swiftc -O "$TMP/cursor.swift" -o "$TMP/cursor" || { echo "!! cursor 헬퍼 빌드 실패"; exit 1; }
ORIG="$("$TMP/cursor")"; OX="${ORIG%% *}"; OY="${ORIG##* }"

mkdir -p "$OUT"
cap() {
    [ -d "$OUT/$1" ] && { echo "  $1 이미 있음 — 건너뜀"; return 0; }
    echo "  $1 캡처…"
    launchctl asuser "$(id -u)" env WAPLE_REAL_PKGS="$ROOT/backgrounds" WAPLE_BASE_ASSETS="$ROOT/assets" \
        "$BIN" --capture "$OUT" --label "$1" "$ROOT" 2>&1 | tail -4
}

cap "baseline-$SHA"
"$TMP/cursor" 37 613 >/dev/null   # ← 두 캡처 사이에 커서를 옮긴다(핀이 빠지면 여기서 갈린다)
echo "커서 이동: $ORIG → $("$TMP/cursor")"
cap "verify-$SHA"
"$TMP/cursor" "$OX" "$OY" >/dev/null
rm -rf "$TMP"

python3 - "$OUT" "$SHA" "$REPO" <<'PY'
import json, os, shutil, sys
out, sha, repo = sys.argv[1], sys.argv[2], sys.argv[3]
def man(d):
    with open(os.path.join(out, d, "manifest.json"), encoding="utf-8") as fh:
        m = json.load(fh)
    return m, {e["id"]: e for e in m["entries"]}
m1, a = man(f"baseline-{sha}")
_, b = man(f"verify-{sha}")
diff = sorted(i for i in a if i in b and a[i]["hash"] != b[i]["hash"])
print(f"\n씬 {len(a)}종 · empties {len(m1['empties'])} · failures {len(m1['failures'])}")
print(f"커서를 옮긴 뒤 재캡처 대조: 상이 {len(diff)}종")
if diff:
    print("  " + " ".join(diff[:20]))
    print("!! 두 캡처가 다르다 — 포인터 핀이 새거나 다른 미핀 입력이 있다. 설치하지 않는다.")
    sys.exit(1)
if m1["failures"]:
    print("!! 마운트 실패가 있다 — 설치하지 않는다."); sys.exit(1)
dark = [e["id"] for e in m1["entries"] if e["meanLuma"] <= 0.0]
if dark:
    print(f"!! 완전 검정 프레임 {len(dark)}종 — 설치하지 않는다: {dark[:10]}"); sys.exit(1)

# 매니페스트 **내부 모순** — deterministic=true 인데 selfMaxDiff!=0.
#
# 이 검사가 없어서 2026-08-18 에 3706286085 이 selfMaxDiff=3 인 채로 굳어졌고, CI 의
# GoldenBaselineOracleTests.testDeterministicScenesHaveZeroSelfDiff 가 잡아 되돌려야 했다.
# 위 커서-이동 대조는 **두 캡처가 서로 같은가**만 본다 — 한 캡처 안에서 두 마운트가
# 어긋난 것은 못 본다. 설치 후 게이트를 돌려도 안 잡힌다(새 기준선 자신과 비교하므로
# 당연히 통과한다). 그래서 사람이 오라클 테스트를 따로 돌려야 했는데, 기억에 의존하는
# 규칙은 언젠가 또 빠진다 — 여기서 막는다.
inconsistent = sorted(e["id"] for e in m1["entries"]
                      if e.get("deterministic", True) and e.get("selfMaxDiff", 0) != 0)
if inconsistent:
    print(f"!! deterministic=true 인데 selfMaxDiff!=0 인 씬 {len(inconsistent)}종 — 설치하지 않는다:")
    for i in inconsistent[:10]:
        print(f"     {i}  selfMaxDiff={a[i].get('selfMaxDiff')}")
    print("   같은 캡처 안에서 두 마운트가 어긋났다는 뜻이다. 캐시를 지우고 다시 떠라:")
    print(f"     rm -rf {out}/{{baseline,verify}}-{sha}")
    sys.exit(1)

dst = os.path.join(repo, "spec", "golden", "snapshot", f"baseline-{sha}")
if os.path.exists(dst):
    shutil.rmtree(dst)
shutil.copytree(os.path.join(out, f"baseline-{sha}"), dst)
n = len(os.listdir(os.path.join(dst, "thumbs")))
print(f"\n설치: spec/golden/snapshot/baseline-{sha}/ (manifest + thumbs {n}장)")
print("README(spec/golden/snapshot/README.md)에 새 기준선 항목을 추가할 것.")
PY
