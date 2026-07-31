#!/bin/bash
# A/B 세션 환경 검사. 통과 못 하면 02 를 돌리지 마라.
set -uo pipefail

REPO="${WAPLE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ROOT="${WAPLE_DEV_ROOT:-$HOME/Downloads/wallpaper_dev}"
BRANCH="feat/we-engine-port-design"
FAIL=0

hr(){ printf '%s\n' "----------------------------------------------------------------"; }
ok(){ printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad(){ printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=1; }

hr; echo "1. GUI 세션 (Metal 전제)"; hr
echo "  SSH_TTY: ${SSH_TTY:-<없음 — 로컬 터미널>}"
if launchctl print "gui/$(id -u)" >/dev/null 2>&1; then
    ok "GUI(Aqua) 세션 존재"
else
    bad "GUI 세션 없음 — 콘솔에 로그인할 것"
fi

hr; echo "2. Metal 디바이스"; hr
SRC="$(mktemp -t mc).swift"
cat > "$SRC" <<'SWIFT'
import Metal
if let d = MTLCreateSystemDefaultDevice() { print("METAL_OK \(d.name)"); exit(0) }
print("METAL_NIL"); exit(3)
SWIFT
VIA="$(launchctl asuser "$(id -u)" swift "$SRC" 2>&1 | tail -1)"
rm -f "$SRC"
echo "  launchctl asuser: $VIA"
[[ "$VIA" == METAL_OK* ]] && ok "Metal 확보" || bad "Metal 실패 — 콘솔 로그인 확인"

hr; echo "3. 툴체인"; hr
if command -v swift >/dev/null 2>&1; then
    swift --version 2>&1 | head -1 | sed 's/^/  /'
    ok "swift 존재"
else
    bad "swift 없음"
fi

hr; echo "4. 리포와 브랜치"; hr
if [ -d "$REPO/.git" ]; then
    CUR="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
    echo "  경로: $REPO"
    echo "  브랜치: $CUR   (필요: $BRANCH)"
    echo "  커밋: $(git -C "$REPO" log --oneline -1)"
    [ "$CUR" = "$BRANCH" ] && ok "브랜치 일치" \
        || bad "브랜치 불일치 — git -C $REPO fetch && git -C $REPO checkout $BRANCH"
    if [ -z "$(git -C "$REPO" status --porcelain)" ]; then
        ok "작업 트리 깨끗"
    else
        bad "수정된 파일 있음 — 패치를 적용할 수 없다"
        git -C "$REPO" status --short | head
    fi
else
    bad "리포 없음: git clone -b $BRANCH https://github.com/yakisoba0728/Waple.git \"$REPO\""
fi

hr; echo "5. A 쪽 기준선 (리포 안)"; hr
BASE="$REPO/spec/golden/snapshot/baseline-81098bb"
if [ -d "$BASE/thumbs" ]; then
    N=$(ls "$BASE/thumbs"/*.png 2>/dev/null | wc -l | tr -d ' ')
    echo "  썸네일 $N 장"
    [ "$N" -ge 170 ] && ok "A 기준선 확보" || bad "썸네일이 $N 장뿐(기대 170)"
else
    bad "$BASE/thumbs 없음"
fi

hr; echo "6. 코퍼스"; hr
if [ -d "$ROOT/backgrounds" ]; then
    S=$(find "$ROOT/backgrounds" -maxdepth 2 \( -name 'scene.pkg' -o -name 'gifscene.pkg' \) 2>/dev/null | wc -l | tr -d ' ')
    echo "  씬 pkg $S 개"
    [ "$S" -ge 150 ] && ok "코퍼스 확보" || bad "씬이 $S 개뿐"
else
    bad "$ROOT/backgrounds 없음"
fi
[ -f "$ROOT/assets/shaders/common.h" ] && ok "base assets 확보" || bad "$ROOT/assets/shaders/common.h 없음"

hr; echo "7. python3 + PIL (03 이 쓴다)"; hr
if command -v python3 >/dev/null 2>&1; then
    python3 -c "import PIL; print('  PIL', PIL.__version__)" 2>/dev/null && ok "PIL 존재" \
        || bad "PIL 없음 — pip3 install pillow"
else
    bad "python3 없음"
fi

hr
[ "$FAIL" = 0 ] && printf '\033[32m전 항목 통과 — 02-capture-ab.sh 로 진행\033[0m\n' \
                || printf '\033[31mFAIL 항목을 해결한 뒤 다시 실행\033[0m\n'
hr
exit "$FAIL"
