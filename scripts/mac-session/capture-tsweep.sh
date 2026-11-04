#!/bin/bash
# 불안정 씬(spec/golden/nondeterminism.json)을 **시각별로** 떠서 프레임 해시를 남긴다.
# 세션 상태가 바뀔 때마다 한 번씩 뜨면, t=0 이 이미 다른지(마운트/로드 발산) t 가 커지며
# 갈리는지(프레임 누적)를 가를 수 있다.
#
# 사용: capture-tsweep.sh <상태라벨>            # 예: capture-tsweep.sh F
# 산출: ~/Downloads/waple-nd2/tsweep-<라벨>.<고유번호>/ (프레임 PNG + hashes.json)
#
# 함정 둘(실측):
#  1) 다중 시각 마운트의 t=6 은 t=6 **단독** 캡처와 다르다 — 캡처 루프가 프레임 간 스크립트/
#     파티클 연속성을 유지하기 때문. 비교는 같은 WAPLE_CAPTURE_TIME 끼리만.
#  2) 부가 프레임 파일명이 `%.1f` 라 0 과 0.033 이 같은 파일로 충돌한다. 소수 첫째자리가
#     다른 시각만 지정할 것.
set -uo pipefail
LBL="${1:?사용: capture-tsweep.sh <상태라벨>}"
[[ "$LBL" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "!! 안전하지 않은 상태라벨: $LBL" >&2; exit 1; }
REPO="${WAPLE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ROOT="${WAPLE_DEV_ROOT:-$HOME/Downloads/wallpaper_dev}"
OUT_ROOT="${WAPLE_TSWEEP_OUT:-$HOME/Downloads/waple-nd2}"
BIN="$REPO/.build/release/WapleCompat"
TIMES="${WAPLE_TSWEEP_TIMES:-0,0.1,1,6}"
TMP="$(mktemp -d)" || exit 1
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Validate the entire requested matrix before creating output or starting captures.
python3 - "$REPO/spec/golden/nondeterminism.json" "$TIMES" "$TMP" <<'PY' || exit 1
import json, math, pathlib, re, struct, sys
try:
    with open(sys.argv[1]) as source:
        entries = json.load(source)["entries"]
    ids = next(e["value"]["ids"] for e in entries if e["id"] == "oracle.nondet.unstableSet")
    if not isinstance(ids, list) or not ids or any(not isinstance(sid, str) or not re.fullmatch(r"[0-9]+", sid) for sid in ids) or len(set(ids)) != len(ids):
        raise ValueError("비어 있지 않은 고유 씬 ID 목록이 필요하다")
    # SnapshotPipeline parses Swift Float, then formats each filename to one decimal.
    times = [struct.unpack("f", struct.pack("f", float(t.strip())))[0] for t in sys.argv[2].split(",")]
    if not times or any(not math.isfinite(t) or t < 0 for t in times):
        raise ValueError("유한한 음수 아닌 캡처 시각이 필요하다")
    names = [f"{t:.1f}" for t in times]
    if len(set(names)) != len(names):
        raise ValueError("소수 첫째자리 프레임 이름이 충돌하는 캡처 시각")
    primary = 6.0 if 6.0 in times else times[0]
    suffixes = ["canon"] + [f"t{t:.1f}" for t in times if t != primary]
    tmp = pathlib.Path(sys.argv[3])
    (tmp / "ids").write_text("\n".join(ids) + "\n")
    (tmp / "expected.json").write_text(json.dumps({"ids": ids, "suffixes": suffixes}))
except (OSError, ValueError, KeyError, TypeError, StopIteration, OverflowError) as error:
    print(f"!! 캡처 입력이 유효하지 않다: {error}", file=sys.stderr)
    sys.exit(1)
PY
mkdir -p "$OUT_ROOT" || exit 1
OUT="$(mktemp -d "$OUT_ROOT/tsweep-$LBL.XXXXXX")" || exit 1
echo "캡처 출력: $OUT"
while IFS= read -r sid; do
    if ! launchctl asuser "$(id -u)" env WAPLE_CAPTURE_TIME="$TIMES" \
        WAPLE_REAL_PKGS="$ROOT/backgrounds" WAPLE_BASE_ASSETS="$ROOT/assets" \
        "$BIN" --capture "$OUT" --label "$sid" "$ROOT/backgrounds/$sid" >/dev/null 2>&1; then
        echo "!! 캡처 실패: $sid" >&2
        exit 1
    fi
done < "$TMP/ids"

python3 - "$OUT" "$LBL" "$TMP/expected.json" <<'PY'
import hashlib, json, pathlib, sys
out, lbl = pathlib.Path(sys.argv[1]), sys.argv[2]
try:
    expected = json.loads(pathlib.Path(sys.argv[3]).read_text())
    frames = {}
    for sid in expected["ids"]:
        frames[sid] = {}
        for key in expected["suffixes"]:
            name = f"{sid}.png" if key == "canon" else f"{sid}_{key}.png"
            data = (out / sid / "thumbs" / name).read_bytes()
            if len(data) < 33 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError(f"비어 있거나 유효하지 않은 PNG: {sid}/{name}")
            frames[sid][key] = hashlib.sha256(data).hexdigest()[:16]
    # Write success only after every requested scene and frame has been checked.
    (out / "hashes.json").write_text(json.dumps({"state": lbl, "frames": frames}, indent=1, sort_keys=True))
except (OSError, ValueError, KeyError, TypeError) as error:
    print(f"!! 캡처 결과가 유효하지 않다: {error}", file=sys.stderr)
    sys.exit(1)
print(f"{len(frames)}종 · 프레임 {sum(len(v) for v in frames.values())}개 → {out}/hashes.json")
print("정본에 넣으려면: cp 해서 spec/golden/snapshot/nondet-2026-08-01/tsweep/<라벨>.json 로 두고")
print("               python scripts/spec/measure_nondeterminism.py 를 다시 돌린다")
PY
