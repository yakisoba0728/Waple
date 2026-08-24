#!/bin/bash
# Xcode 없는 macOS 에서 **테스트 타깃 7개를 타입체크**한다.
#
# 왜 있는가
# ---------
# Xcode 없이 CommandLineTools 만 있는 맥에서는 `XCTest` 모듈이 없다. 그래서:
#   · `swift test` 가 `unable to resolve module dependency: 'XCTest'` 로 **아예 안 돈다**
#   · `swift build --build-tests` 도 같은 이유로 실패한다
#   · 즉 테스트 코드는 **타입체크조차 안 된 채** 푸시되고, 판정이 전부 CI(1회 ~12분)로 밀린다
#
# 그 공백에서 나는 실패는 단언 실패가 아니라 **컴파일 실패**라 스위트 전체가 안 돈다.
# AGENTS.md 가 `swiftc -parse` 를 두고 "rc=0 을 검증 근거로 쓰지 마라 — `-parse` 는 타입체크를
# 하지 않는다" 고 못 박은 것과 같은 문제이고, 리눅스 쪽은 이미 `linux-render-typecheck.sh` 로
# 이 구멍을 메워 뒀다. 이 스크립트는 **같은 방법론을 XCTest 에 적용한 macOS 판**이다.
#
# 어떻게
# ------
# `scripts/dev/xctest-shim/XCTest.swift`(대역 모듈)를 `swiftc -emit-module` 로 세우고,
# 이미 빌드된 프로덕션 모듈(`.build/…/Products/Debug`)과 함께 각 테스트 타깃을 `-typecheck` 한다.
# `Tests/` 도 `Sources/` 도 **한 글자도 건드리지 않는다**(경로를 그대로 넘긴다).
#
# 무엇을 잡나 (실측)
# ------------------
# 없는 심볼 · 타입 불일치 · 잘못된 인자 라벨 · 없는 오버로드 · override 불일치 ·
# 액터 격리 위반. 즉 **CI 를 빨갛게 만드는 컴파일 실패의 대부분**이다.
#
# 무엇을 못 잡나 (솔직하게)
# -------------------------
#  · **단언의 참/거짓.** 이건 타입체크지 실행이 아니다. `XCTAssertEqual(1, 2)` 는 통과한다.
#  · **심이 실물과 다르면 거짓 통과/거짓 실패가 난다.** 심은 애플 헤더에서 기계 생성한 것이
#    아니라 손으로 적은 것이다. 실제로 세 번 틀렸고 그때마다 실물 동작을 실측해 맞췄다:
#      ① `@_exported import AppKit` 누락 → `MTLCreateSystemDefaultDevice`/`NSView` 거짓 실패
#      ② `accuracy:` 오버로드를 `FloatingPoint` 하나만 둠 → `Int` 호출 거짓 실패.
#         실물은 `FloatingPoint` **와** `Numeric` 을 **둘 다** 갖는다(하나만 두면 반대쪽이 깨진다)
#      ③ `setUp`/`tearDown` 계열에 `@MainActor` 누락 → `@MainActor final class …: XCTestCase`
#         가 그걸 override 하는 자리(리포에 5개)에서 거짓 실패
#    **최종 판정자는 여전히 macOS CI 다.**
#  · **`WapleAppTests` 는 신선도가 떨어진다.** `Waple` 앱 타깃은 이 환경에서 SwiftUI 매크로
#    플러그인 부재로 **빌드 자체가 안 되므로**, 그 `.swiftmodule` 이 이전 빌드의 것일 수 있다.
#    앱 타깃 소스를 고쳤다면 이 스크립트의 `WapleAppTests` 결과를 믿지 마라.
#
# 사용
# ----
#   scripts/dev/macos-test-typecheck.sh                 # 7개 타깃 전부
#   scripts/dev/macos-test-typecheck.sh WapleCoreTests  # 지정 타깃만
#
# 종료코드: 0 = 전부 통과, 1 = 하나라도 에러.
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)

# Xcode 가 선택돼 있으면 이 스크립트는 **쓸 이유가 없다** — `swift test` 가 도는데 굳이 심을
# 거쳐 타입체크만 하는 것은 오차원만 늘린다. 그래서 조용히 통과시키지 않고 그 사실을 말한다.
# (2026-08-25: 이 리포를 만지는 맥 하나가 세션 도중 CommandLineTools → Xcode 27 로 바뀌었다.
#  머신 상태는 가정하지 말고 매번 확인하는 게 맞다.)
DEVDIR=$(xcode-select -p 2>/dev/null || true)
case "$DEVDIR" in
    */Xcode*.app/Contents/Developer)
        echo "이 머신에는 Xcode 가 선택돼 있다($DEVDIR)."
        echo "그러면 이 스크립트가 아니라 \`swift test\` 를 돌려라 — 타입체크는 그것의 부분집합이다."
        echo "그래도 굳이 돌리려면 WAPLE_FORCE_TYPECHECK=1 을 붙여라."
        [ "${WAPLE_FORCE_TYPECHECK:-0}" = "1" ] || exit 0
        ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
    echo "이 스크립트는 macOS 전용이다(리눅스는 scripts/dev/linux-*.sh)." >&2
    exit 1
fi

SDK=$(xcrun --show-sdk-path 2>/dev/null)
if [ -z "$SDK" ]; then echo "SDK 경로를 못 찾았다(xcrun --show-sdk-path)." >&2; exit 1; fi
TARGET_TRIPLE=arm64-apple-macos14.0   # Package.swift 의 platforms 와 같게 유지할 것

# 프로덕션 모듈이 있어야 `@testable import` 가 붙는다. 앱 타깃(Waple)은 이 환경에서 못 서므로
# 실패를 무시한다 — 그 결과는 위 "무엇을 못 잡나" 의 세 번째 항목이다.
echo "── 프로덕션 모듈 빌드"
for t in WapleCore WapleRender WapleLibrary WapleSnapshot WaplePolicy WapleCompatCore; do
    if ! swift build --target "$t" >/dev/null 2>&1; then
        echo "  ✗ $t 빌드 실패 — 먼저 이걸 고쳐라(테스트 타입체크는 여기에 의존한다)."
        swift build --target "$t" 2>&1 | grep -E ': error:' | head -5
        exit 1
    fi
done
echo "  ✓ 6개 타깃"

# `.build` 레이아웃은 빌드 시스템(SwiftPM native vs Xcode)에 따라 다르다 — 둘 다 찾는다.
MODDIR=""
for cand in "$ROOT/.build/out/Products/Debug" "$ROOT/.build/debug" "$ROOT/.build/arm64-apple-macosx/debug"; do
    if [ -d "$cand" ] && ls "$cand"/WapleCore.swiftmodule >/dev/null 2>&1; then MODDIR="$cand"; break; fi
done
if [ -z "$MODDIR" ]; then
    echo "빌드된 WapleCore.swiftmodule 을 못 찾았다. .build 레이아웃이 바뀌었는지 확인하라." >&2
    exit 1
fi

SHIM_SRC="$ROOT/scripts/dev/xctest-shim/XCTest.swift"
SHIM_DIR="${TMPDIR:-/tmp}/waple-xctest-shim"
mkdir -p "$SHIM_DIR"
echo "── XCTest 대역 모듈"
if ! (cd "$SHIM_DIR" && swiftc -emit-module -module-name XCTest \
        -emit-module-path XCTest.swiftmodule \
        -target "$TARGET_TRIPLE" -sdk "$SDK" "$SHIM_SRC" 2>&1 | head -10); then
    echo "  ✗ 심 빌드 실패" >&2; exit 1
fi
echo "  ✓ $SHIM_DIR/XCTest.swiftmodule"

ALL_TARGETS="WapleCoreTests WapleRenderTests WapleAppTests WapleLibraryTests WapleSnapshotTests WaplePolicyTests WapleCompatCoreTests"
TARGETS="${*:-$ALL_TARGETS}"

echo "── 테스트 타깃 타입체크"
fail=0
for T in $TARGETS; do
    if [ ! -d "$ROOT/Tests/$T" ]; then echo "  ✗ Tests/$T 없음"; fail=1; continue; fi
    out=$(swiftc -typecheck -module-name "$T" \
            -I "$SHIM_DIR" -I "$MODDIR" \
            -F "$MODDIR/PackageFrameworks" -F "$MODDIR" \
            -sdk "$SDK" -target "$TARGET_TRIPLE" \
            "$ROOT/Tests/$T"/*.swift 2>&1 | grep ': error:')
    n=$(printf '%s' "$out" | grep -c ': error:')
    if [ "$n" -eq 0 ]; then
        printf "  ✓ %-24s\n" "$T"
    else
        printf "  ✗ %-24s 에러 %s건\n" "$T" "$n"
        printf '%s\n' "$out" | sed "s#$ROOT/##" | head -20 | sed 's/^/      /'
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo
    echo "타입체크 실패. 이건 CI 가 컴파일 단계에서 빨개지는 것과 같은 신호다 — 푸시 전에 고쳐라."
    exit 1
fi
echo
echo "전부 통과. **단언의 참/거짓은 검증하지 않았다** — 그건 CI(macos-26)가 한다."
