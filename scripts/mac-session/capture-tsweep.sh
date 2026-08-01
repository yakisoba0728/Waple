#!/bin/bash
# 불안정 씬(spec/golden/nondeterminism.json)을 **시각별로** 떠서 프레임 해시를 남긴다.
# 세션 상태가 바뀔 때마다 한 번씩 뜨면, t=0 이 이미 다른지(마운트/로드 발산) t 가 커지며
# 갈리는지(프레임 누적)를 가를 수 있다.
#
# 사용: capture-tsweep.sh <상태라벨>            # 예: capture-tsweep.sh F
# 산출: ~/Downloads/waple-nd2/tsweep-<라벨>/ (프레임 PNG) + 같은 이름의 hashes.json
#
# 함정 둘(실측):
#  1) 다중 시각 마운트의 t=6 은 t=6 **단독** 캡처와 다르다 — 캡처 루프가 프레임 간 스크립트/
#     파티클 연속성을 유지하기 때문. 비교는 같은 WAPLE_CAPTURE_TIME 끼리만.
#  2) 부가 프레임 파일명이 `%.1f` 라 0 과 0.033 이 같은 파일로 충돌한다. 소수 첫째자리가
#     다른 시각만 지정할 것.
set -uo pipefail
LBL="${1:?사용: capture-tsweep.sh <상태라벨>}"
REPO="${WAPLE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ROOT="${WAPLE_DEV_ROOT:-$HOME/Downloads/wallpaper_dev}"
OUT="${WAPLE_TSWEEP_OUT:-$HOME/Downloads/waple-nd2}/tsweep-$LBL"
BIN="$REPO/.build/release/WapleCompat"
TIMES="${WAPLE_TSWEEP_TIMES:-0,0.1,1,6}"

rm -rf "$OUT"; mkdir -p "$OUT"
python3 -c "
import json
d=json.load(open('$REPO/spec/golden/nondeterminism.json'))
print('\n'.join([e for e in d['entries'] if e['id']=='oracle.nondet.unstableSet'][0]['value']['ids']))
" | while read -r sid; do
    [ -z "$sid" ] && continue
    launchctl asuser "$(id -u)" env WAPLE_CAPTURE_TIME="$TIMES" \
        WAPLE_REAL_PKGS="$ROOT/backgrounds" WAPLE_BASE_ASSETS="$ROOT/assets" \
        "$BIN" --capture "$OUT" --label "$sid" "$ROOT/backgrounds/$sid" >/dev/null 2>&1 || echo "실패 $sid"
done

python3 - "$OUT" "$LBL" <<'PY'
import hashlib, json, os, sys
out, lbl = sys.argv[1], sys.argv[2]
frames = {}
for sid in sorted(os.listdir(out)):
    d = os.path.join(out, sid, "thumbs")
    if not os.path.isdir(d):
        continue
    for f in sorted(os.listdir(d)):
        if not f.endswith(".png"):
            continue
        # <id>.png = 캐논(마지막 시각) · <id>_t<초>.png = 부가 프레임
        key = f[:-4].replace(f"{sid}_", "") if f != f"{sid}.png" else "canon"
        frames.setdefault(sid, {})[key] = hashlib.sha256(open(os.path.join(d, f), "rb").read()).hexdigest()[:16]
json.dump({"state": lbl, "frames": frames}, open(f"{out}/hashes.json", "w"), indent=1, sort_keys=True)
print(f"{len(frames)}종 · 프레임 {sum(len(v) for v in frames.values())}개 → {out}/hashes.json")
print("정본에 넣으려면: cp 해서 spec/golden/snapshot/nondet-2026-08-01/tsweep/<라벨>.json 로 두고")
print("               python scripts/spec/measure_nondeterminism.py 를 다시 돌린다")
PY
