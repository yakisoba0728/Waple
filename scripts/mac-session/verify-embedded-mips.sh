#!/bin/bash
# 임베디드 PNG/JPEG mip 체인 복원 검증 (커밋 53b69ac 계열).
#
# 이 변경은 **의도적으로 픽셀을 바꾼다** — 그래서 검증 질문이 평소와 다르다.
# "안 바뀌었는가" 가 아니라 **"바뀌어야 할 씬만 바뀌었는가"** 다.
# 기대 집합은 **실행 시점에 코퍼스를 직접 스캔해** 산출한다(정적 목록 아님).
# spec 의 목록은 윈도우 162씬 기준이라 170씬 코퍼스에서 7종이 누락됐었다.
#
# 필요:
#   WAPLE_REAL_PKGS       실물 배경 디렉터리 (기본 ~/Downloads/wallpaper_dev/backgrounds)
#   WAPLE_BASE_ASSETS     설치 assets 디렉터리
#   WAPLE_PRE_BASELINE    **이 변경 전** release 캡처 디렉터리 (없으면 아래 4단계가 안내하고 건너뜀)
#
# 구현 전 기준선 뜨는 법(중요 — 커밋된 baseline-81098bb 는 debug 라 대조에 못 쓴다):
#   git stash && swift run -c release WapleCompat --capture ~/Downloads/waple-pre --label pre <corpus> && git stash pop
set -uo pipefail

REPO="${WAPLE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ROOT="${WAPLE_DEV_ROOT:-$HOME/Downloads/wallpaper_dev}"
OUT="${WAPLE_VERIFY_OUT:-$HOME/Downloads/waple-verify-mips}"
export WAPLE_REAL_PKGS="${WAPLE_REAL_PKGS:-$ROOT/backgrounds}"
export WAPLE_BASE_ASSETS="${WAPLE_BASE_ASSETS:-$ROOT/assets}"
FAIL=0

hr(){ printf '%s\n' "----------------------------------------------------------------"; }
ok(){ printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad(){ printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=1; }
warn(){ printf '  \033[33m??\033[0m    %s\n' "$1"; }

cd "$REPO" || exit 1
mkdir -p "$OUT"

hr; echo "1. 빌드 (release)"; hr
T0=$SECONDS
if swift build -c release 2>&1 | tail -20; then ok "빌드 $((SECONDS-T0))초"; else bad "빌드 실패"; exit 1; fi

hr; echo "2. 신규/변경 테스트"; hr
# TexMipChainParseTests  — 파스가 임베디드 체인을 넘기는가 (거짓 전제 테스트 교체분 포함)
# TexMipChainDecodeTests — 레벨별 독립 디코드 + 단일 mip 무회귀 + 손상 레벨 폴백
# TexDecoderTests        — 기존 임베디드 단일 경로 무회귀
for f in TexMipChainParseTests TexMipChainDecodeTests TexDecoderTests; do
    if launchctl asuser "$(id -u)" env WAPLE_REAL_PKGS="$WAPLE_REAL_PKGS" \
        WAPLE_BASE_ASSETS="$WAPLE_BASE_ASSETS" \
        swift test -c release --filter "$f" 2>&1 | tee "$OUT/$f.log" \
        | grep -qE "Executed [0-9]+ tests?,.*with 0 failures"; then
        ok "$f 통과"
    else
        bad "$f 실패 — $OUT/$f.log"
        grep -E "error:|XCTAssert.*failed" "$OUT/$f.log" | head -10 | sed 's/^/      /'
    fi
done

hr; echo "3. 실물 코퍼스 프로브 — 임베디드 701개가 전 레벨 디코드되는가"; hr
# 이게 이 변경의 핵심 실증이다. found==decoded 이고 embedded>0 이어야 한다.
# embedded==0 이면 코퍼스가 안 붙었거나 파스가 체인을 못 넘긴 것 — 통과해도 의미 없다(양성 대조).
launchctl asuser "$(id -u)" env WAPLE_REAL_PKGS="$WAPLE_REAL_PKGS" \
    WAPLE_BASE_ASSETS="$WAPLE_BASE_ASSETS" \
    swift test -c release --filter RealTexMipChainProbeTests 2>&1 | tee "$OUT/probe.log" | tail -20
PROBE=$(grep -o "\[mipchain-probe\].*" "$OUT/probe.log" | tail -1)
echo "  $PROBE"
EMB=$(printf '%s' "$PROBE" | sed -n 's/.*embedded=\([0-9]*\).*/\1/p')
if grep -qE "Executed [0-9]+ tests?,.*with 0 failures" "$OUT/probe.log" \
   && ! grep -qE "with [1-9][0-9]* failures?" "$OUT/probe.log"; then
    if [ "${EMB:-0}" -gt 0 ]; then
        ok "프로브 통과 · 임베디드 $EMB 개 전 레벨 디코드 (윈도우 실측 기대치 701)"
    else
        bad "프로브는 통과했지만 embedded=0 — 양성 대조 불성립(코퍼스 미연결 의심)"
    fi
elif grep -q "skipped" "$OUT/probe.log"; then
    bad "프로브 skip — 코퍼스를 못 찾았다. WAPLE_REAL_PKGS 확인"
else
    bad "프로브 실패 — $OUT/probe.log"
fi

hr; echo "4. 전 스위트 무회귀"; hr
T0=$SECONDS
launchctl asuser "$(id -u)" env WAPLE_REAL_PKGS="$WAPLE_REAL_PKGS" \
    WAPLE_BASE_ASSETS="$WAPLE_BASE_ASSETS" \
    swift test -c release 2>&1 | tee "$OUT/full.log" | tail -20
if grep -qE "with [1-9][0-9]* failures?" "$OUT/full.log"; then
    bad "전 스위트 실패 — $OUT/full.log"
    grep -E "error:|XCTAssert.*failed|with [1-9][0-9]* failures?" "$OUT/full.log" | head -20 | sed 's/^/      /'
elif grep -qE "with 0 failures" "$OUT/full.log"; then ok "전 스위트 통과 ($((SECONDS-T0))초)"
else
    bad "전 스위트 실패 — $OUT/full.log"
    grep -E "error:|failed \(" "$OUT/full.log" | head -20 | sed 's/^/      /'
fi
# [수정 2026-08-01] 종전 합산은 클래스 단위 소계까지 더해 6411 로 부풀었다(실제 2,143).
# 번들('*.xctest')의 "Test Suite ... passed/failed" 직후 줄만 센다.
echo "  번들별:"
grep -A1 -E "Test Suite '.*\.xctest'.*(passed|failed)" "$OUT/full.log" 2>/dev/null     | grep -oE "Executed [0-9]+ tests?, with [0-9]+ failures?" | sed 's/^/    /'
TESTS=$(grep -A1 -E "Test Suite '.*\.xctest'.*(passed|failed)" "$OUT/full.log" 2>/dev/null     | grep -oE "Executed [0-9]+ tests?" | grep -oE "[0-9]+" | awk '{s+=$1} END {print s+0}')
echo "  번들 합: ${TESTS:-?}  (기준 2,159 — 2026-08-16 실측, 코퍼스 유무 무관. 종전 2,143)"

hr; echo "5. 골든 — **바뀌어야 할 씬만** 바뀌었는가"; hr
PRE="${WAPLE_PRE_BASELINE:-}"
LABEL="mips-$(git rev-parse --short HEAD)"
launchctl asuser "$(id -u)" env WAPLE_REAL_PKGS="$WAPLE_REAL_PKGS" \
    WAPLE_BASE_ASSETS="$WAPLE_BASE_ASSETS" \
    swift run -c release WapleCompat --capture "$OUT" --label "$LABEL" "$ROOT" \
    2>&1 | tee "$OUT/capture.log" | tail -6

if [ -z "$PRE" ] || [ ! -d "$PRE/thumbs" ]; then
    warn "구현 전 release 기준선이 없어 대조를 건너뛴다."
    echo "     커밋된 baseline-81098bb 는 **debug** 캡처다 — release 와는 코드 변경 없이도"
    echo "     30종이 어긋나므로 이 대조에 쓰면 항상 오탐이다."
    echo "     이렇게 떠서 WAPLE_PRE_BASELINE 으로 지정할 것:"
    echo "       git stash && swift run -c release WapleCompat --capture ~/Downloads/waple-pre --label pre $ROOT && git stash pop"
else
python3 - "$PRE" "$OUT/$LABEL" "$WAPLE_REAL_PKGS" <<'PY'
import json, os, sys
import struct
pre, post, corpus = sys.argv[1], sys.argv[2], sys.argv[3]

# [수정 2026-08-01] 기대 집합을 spec 의 **정적 목록**에서 읽던 것을 **실행 시점 코퍼스 산출**로 바꿨다.
# 그 목록은 윈도우 코퍼스 162씬 기준인데 macOS 코퍼스는 170씬이라, 정당하게 바뀐 7종이
# "기대 집합 밖 = 조사 대상" 으로 잘못 떴다(실측 8건 중 7건). 코퍼스에서 직접 세면
# 표본이 달라져도 성립한다.
def embedded_multimip(pkg_path):
    """이 패키지가 임베디드(PNG/JPEG/GIF) mipCount>1 텍스처를 하나라도 갖는가."""
    try:
        b = open(pkg_path, "rb").read()
    except OSError:
        return False
    try:
        n = struct.unpack_from("<i", b, 0)[0]
        p = 4 + n
        cnt = struct.unpack_from("<i", b, p)[0]
        p += 4
        ents = []
        for _ in range(cnt):
            ln = struct.unpack_from("<i", b, p)[0]
            p += 4
            name = b[p:p + ln].decode("utf-8", "replace")
            p += ln
            off, size = struct.unpack_from("<2i", b, p)
            p += 8
            ents.append((name, off, size))
        base = p
    except Exception:
        return False
    for name, off, size in ents:
        if not name.lower().endswith(".tex"):
            continue
        t = b[base + off:base + off + size]
        if len(t) < 60 or t[:4] != b"TEXV":
            continue
        try:
            flags = struct.unpack_from("<i", t, 22)[0]
            q = 42
            if flags & 0x40:
                q += 4
            if int(t[13:17]) > 0:
                q += 4
            if t[q:q + 4] != b"TEXB":
                continue
            ver = int(t[q + 4:q + 8])
            q += 9 + 4                     # 매직+NUL, imageCount
            if ver < 3:
                continue
            imageFormat = struct.unpack_from("<i", t, q)[0]
            q += 4
            if ver >= 4:
                q += 4
            if imageFormat not in (2, 13, 25):
                continue
            mipCount = struct.unpack_from("<i", t, q)[0]
            if 1 < mipCount < 64:
                return True
        except Exception:
            continue
    return False

expected = set()
if os.path.isdir(corpus):
    for sid in sorted(os.listdir(corpus)):
        d = os.path.join(corpus, sid)
        if not os.path.isdir(d):
            continue
        for fn in ("scene.pkg", "gifscene.pkg"):
            fp = os.path.join(d, fn)
            if os.path.exists(fp) and embedded_multimip(fp):
                expected.add(sid)
                break
print("  기대 집합(코퍼스 산출): %d종" % len(expected))
if not expected:
    print("  !! 코퍼스에서 임베디드 mip>1 을 0종 찾았다 — 파서가 깨졌거나 경로가 틀렸다.")
    print("     이 상태의 '기대 집합 밖' 판정은 신뢰할 수 없다.")
    sys.exit(1)
try:
    from PIL import Image
except ImportError:
    print("  (PIL 없음 — pip3 install pillow 후 재실행)"); sys.exit(0)
ma = {e["id"]: e for e in json.load(open(os.path.join(pre, "manifest.json")))["entries"]}
mbp = os.path.join(post, "manifest.json")
if not os.path.exists(mbp):
    print("  !! 캡처 실패 — 매니페스트 없음"); sys.exit(1)
mb = {e["id"]: e for e in json.load(open(mbp))["entries"]}
common = sorted(set(ma) & set(mb))
changed = set()
for sid in common:
    pa, pb = os.path.join(pre, "thumbs", f"{sid}.png"), os.path.join(post, "thumbs", f"{sid}.png")
    if not (os.path.exists(pa) and os.path.exists(pb)):
        continue
    if open(pa, "rb").read() == open(pb, "rb").read():
        continue
    ia, ib = Image.open(pa).convert("RGB"), Image.open(pb).convert("RGB")
    if ia.size != ib.size:
        changed.add(sid); continue
    if any(p != q for p, q in zip(ia.getdata(), ib.getdata())):
        changed.add(sid)
inside = changed & expected           # 기대대로 바뀐 씬
outside = changed - expected          # **조사 대상** — 이 변경이 건드릴 이유가 없는 씬
missing = (expected & set(common)) - changed   # 기대했는데 안 바뀐 씬(축소 없는 씬이면 정상)
print(f"  대조 {len(common)}종 · 변화 {len(changed)}종")
print(f"    기대 집합 안: {len(inside)}  (기대 {len(expected & set(common))}종 중)")
print(f"    기대 집합 밖: {len(outside)}  <- 0 이어야 한다")
print(f"    안 바뀐 기대 씬: {len(missing)}  (레이어가 축소 없이 1:1 로 그려지면 정상)")
if outside:
    print("  !! 기대 밖 변화 — 이 커밋이 건드릴 이유가 없는 씬이다. 조사할 것:")
    for sid in sorted(outside)[:20]:
        print(f"       {sid}")
    sys.exit(1)
if not inside:
    print("  !! 기대 집합에서 변화가 0 — mip 이 실제로 샘플되지 않았을 수 있다.")
    print("     (음성 대조: 이 변경이 화면에 아무 영향이 없다면 배선이 끊긴 것이다)")
    sys.exit(1)
PY
    [ $? -ne 0 ] && bad "골든 대조 이상 — 위 출력 확인" || ok "기대 집합 안에서만 변화"
fi

hr
[ "$FAIL" = 0 ] && printf '\033[32m검증 통과\033[0m\n' || printf '\033[31mFAIL 있음 — 위 항목 확인\033[0m\n'
echo "로그: $OUT"
hr
exit "$FAIL"
