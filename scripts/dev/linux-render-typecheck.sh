#!/bin/bash
# `Sources/WapleRender/**` 를 **리눅스에서 타입체크**한다(`swiftc -typecheck`).
#
# 왜 있는가
# ---------
# WapleRender 는 `import Metal`/`MetalKit`/`AppKit` 이라 리눅스에서 `swiftc -parse` 밖에 못 돌리는데
# **`-parse` 는 타입체크를 하지 않는다**. `-parse` 의 rc=0 은 아무것도 보장하지 않고, 그 공백에서
# 이 브랜치의 macOS CI 가 두 번 깨졌다:
#   · `b98db0a` — `Mesh3DShaders.swift:152` 스위프트 멀티라인 리터럴 안의 `\n` 하나로 MSL 이 깨짐
#   · `bb5f902` — `SceneRendererResources.swift:1214` 가 그 스코프에 **없는 이름** `texW`/`texH` 사용
# 두 번째 유형(스코프/타입 오류)은 타입체크만 하면 확실히 잡힌다. 이 스크립트가 그것을 한다.
#
# 어떻게
# ------
# `scripts/dev/linux-shim/` 의 대역 모듈(Metal·MetalKit·AppKit·CoreGraphics·QuartzCore·CoreText·
# ImageIO·AVFoundation·CoreVideo·Accelerate·JavaScriptCore·CryptoKit·Compression·ScreenCaptureKit·
# WebKit·UniformTypeIdentifiers)을
# `swiftc -emit-module` 로 만들고, 같은 검색 경로에서 커버 대상 소스를 `-typecheck` 한다.
# `Sources/` 는 **한 글자도 건드리지 않는다**(심볼릭 링크도 아니고 경로를 그대로 넘긴다).
#
# 한계(솔직하게)
# --------------
#  · **심이 실제 프레임워크와 다르면 거짓 통과/거짓 실패가 난다.** 심은 애플 헤더에서 기계적으로
#    생성한 것이 아니라 손으로 적은 것이고, 확신 없는 자리는 각 심 파일에 `확신 없음` 으로 표시돼 있다.
#    **최종 판정자는 여전히 macOS CI 다.**
#  · [2026-08-21] 커버는 **55/55**(제외 0). 새 프레임워크를 쓰는 파일이 생기면 심을 쓰기 전까지
#    아래 `EXCLUDED` 에 넣는다(`docs/dev/linux-typecheck.md`).
#  · MSL(셰이더) 문자열의 내용은 검사하지 않는다 — `b98db0a` 류(리터럴 안 MSL 문법)는 못 잡는다.
#    이건 `scripts/spec/` 게이트와 `WapleCore` 쪽 셰이더 테스트의 영역이다.
#  · `@MainActor` 격리·Sendable 진단은 실제 SDK 어노테이션(`@preconcurrency` 강등 포함)에
#    의존하므로 여기 결과와 macOS 결과가 다를 수 있다.
#
# [2026-08-21] `--tests` 로 **`Tests/WapleRenderTests/**` 도 타입체크**한다
# ------------------------------------------------------------------------------
# 이 리포에서 제일 큰 사각지대였다. `Tests/WapleRenderTests/**` 는 152파일인데 macOS 전용
# 타깃이라 리눅스에서 **`swiftc -parse` 밖에** 못 돌렸고, 그래서 테스트 파일을 고친 작업은
# "구문은 맞다" 만 확인한 채 푸시됐다. `-parse` 가 아무것도 보장하지 않는다는 것은 이 브랜치가
# 이미 두 번 배웠다(위 `bb5f902`). 테스트 파일은 오히려 더 위험하다 — 소스보다 자주 고쳐지고,
# `@testable import` 로 internal 표면까지 만지며, **깨져도 프로덕션 코드가 아니라서 리뷰가 얕다**.
#
# `--tests` 는 심 위에 `WapleCore`·`WapleSnapshot`·`WapleRender` 를 `-enable-testing` 으로
# **모듈로 emit** 한 뒤 테스트 152파일을 한 번에 `-typecheck` 한다. `@testable import` 가
# 실제로 동작한다(그래서 internal 심볼 오타·시그니처 변경도 잡힌다).
#
# [2026-08-21] `--lib` 로 **`WapleLibrary`·`WaplePolicy` 와 그 테스트**까지
# ------------------------------------------------------------------------------
# 둘 다 종전에 **어떤 리눅스 검증도 못 받았다**. 이유는 렌더와 정반대다 — 애플 프레임워크를
# 안 써서가 아니라, 이 하네스가 `WapleRender` 만 보게 만들어져 있었기 때문이다.
# `Sources/WapleLibrary/**`(7파일)는 `Foundation`+`WapleCore`, `Sources/WaplePolicy/**`(1파일)는
# `Foundation` 하나뿐이라 **심이 거의 필요 없다**. 실제로 모자랐던 것은 하나다:
# 리눅스 Foundation 에 `URL` 의 보안 스코프 북마크 API 가 **아예 없다**
# (`linux-shim/zz-linux-url-bookmark.swift` 머리말에 실측 오류 문구를 적어 뒀다).
#
# [2026-08-21] `--app` 으로 **앱 계층(`Sources/Waple`·`Tests/WapleAppTests`)**까지
# ------------------------------------------------------------------------------
# 이 리포의 마지막 큰 사각지대였다. 48파일 8,842줄이 `SwiftUI`·`Combine`·`Security`·
# `ServiceManagement` 를 쓰는데 그 심이 없어 **어떤 리눅스 검증도 못 받고 있었다**.
# 새 심 넷(`swiftui.swift`·`combine.swift`·`security.swift`·`servicemanagement.swift`)과
# `appkit-app.swift`·`coregraphics.swift` 보강으로 **46/48 + 34/36** 을 덮는다.
# 못 덮는 넷은 전부 **심으로 메울 수 없는 컴파일러/툴체인 제약**이다(`APP_EXCLUDED` 참조).
#
# ⚠️ **SwiftUI 심은 다른 심들보다 훨씬 관대하다.** 결과 빌더와 수식어 반환 타입을 전부
# `AnyView` 로 접기 때문에 "이 수식어를 이 뷰에 붙일 수 있는가" 는 검증되지 않는다.
# 검증되는 것은 식별자 존재·인자 라벨·인자 타입·프로퍼티 래퍼 결합이다
# (`linux-shim/swiftui.swift` 머리말에 무엇이 되고 무엇이 안 되는지 적어 뒀다).
#
# 사용:
#   scripts/dev/linux-render-typecheck.sh
#   scripts/dev/linux-render-typecheck.sh --tests    소스 + 테스트 152파일까지 타입체크
#   scripts/dev/linux-render-typecheck.sh --lib      + WapleLibrary·WaplePolicy 소스와 그 테스트
#   scripts/dev/linux-render-typecheck.sh --app      + Sources/Waple 46/48 + Tests/WapleAppTests 34/36
#       └ `--tests` 와 `--lib` 를 포함한다(WapleRender·WapleLibrary 모듈이 필요하다).
#       └ [2026-08-26] 다만 `Tests/WapleRenderTests` 의 타입체크 **결과와는 독립**으로 돈다.
#         그쪽이 깨져도 앱 계층은 검사된다(종료코드는 둘 다 반영). 근거는 해당 블록 주석.
#   scripts/dev/linux-render-typecheck.sh --replace SceneRendererResources.swift=/tmp/old.swift
#       └ 커버 목록의 한 파일을 다른 경로의 파일로 갈아끼운다(양성 대조·회귀 재현용).
#   scripts/dev/linux-render-typecheck.sh --list       커버/제외 목록만 출력하고 끝낸다
#
# 환경변수:
#   WAPLE_SWIFT_BIN               swift 툴체인 bin (기본 /opt/swift/usr/bin)
#   WAPLE_LINUX_TYPECHECK_DIR     작업 디렉터리 (기본 $TMPDIR/waple-linux-render-typecheck)
#   WAPLE_SWIFT_LOCK              공유 락 파일 (기본 $TMPDIR/waple-swift.lock — 고정 경로).
#                                 다른 swift 작업과 같은 락을 쓰려면 **반드시 명시**해라.
#   WAPLE_SWIFT_LOCK_WAIT         락 대기 초 (기본 3600)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SWIFTC_DIR="${WAPLE_SWIFT_BIN:-/opt/swift/usr/bin}"
WORK="${WAPLE_LINUX_TYPECHECK_DIR:-${TMPDIR:-/tmp}/waple-linux-render-typecheck}"
# 락 기본값은 **작업 디렉터리와 무관한 고정 경로**다. 종전엔 `$(dirname "$WORK")/swift.lock` 로
# 유도했는데, 그러면 WORK 를 다르게 잡은 두 실행이 **서로 다른 락**을 잡아 상호배제가 아예 안 된다
# (실측 2026-08-21: `/tmp/swift.lock` 과 `<스크래치패드>/swift.lock` 이 동시에 잡혀 있었다 —
# 이 컨테이너에서 동시 swift 빌드 2개는 OOM 으로 컨테이너를 통째로 재시작시킨다).
# 다른 swift 작업(`linux-core-tests.sh` 를 flock 으로 감싸는 관례)과 묶으려면
# **`WAPLE_SWIFT_LOCK` 을 그 락 파일로 명시**해라 — 유도에 기대지 마라.
LOCK="${WAPLE_SWIFT_LOCK:-${TMPDIR:-/tmp}/waple-swift.lock}"

# ── 커버 대상 ────────────────────────────────────────────────────────────────
# 여기 있는 파일은 리눅스에서 **타입체크된다**.
COVERED=(
    ArtworkColors.swift
    AudioSpectrum.swift
    BaseAssetsSettings.swift
    BlendMSL.swift
    DXT5Decoder.swift
    DesktopWindow.swift
    DesktopWindowController.swift
    EffectShaders.swift
    FFmpegConverter.swift
    HDRBloomPass.swift
    HDRBloomPyramidPass.swift
    HDRPostPass.swift
    LDRBloomPass.swift
    MediaPoller.swift
    Mesh3DShaders.swift
    OggVorbis/OggPageReader.swift
    OggVorbis/VorbisBitReader.swift
    OggVorbis/VorbisCodebook.swift
    OggVorbis/VorbisDecoder.swift
    OggVorbis/VorbisImdct.swift
    OggVorbis/VorbisTables.swift
    NowPlayingProvider.swift
    OffscreenCapture.swift
    ParallaxController.swift
    ParticleShaders.swift
    QuadShaders.swift
    RendererFactory.swift
    Scene3DLighting.swift
    Scene3DMath.swift
    SceneAudioPlayer.swift
    SceneLivePresentationFix.swift
    SceneRenderSettings.swift
    SceneRenderer.swift
    SceneRenderer3D.swift
    SceneRendererFinalizer.swift
    SceneRendererFrameEncoder.swift
    SceneRendererResources.swift
    SceneVideoLayer.swift
    SystemAudioSpectrumProvider.swift
    TexDecoder.swift
    TextRasterizer.swift
    TextScriptEngine.swift
    UserPropertyStore.swift
    VideoFallbackHTML.swift
    VideoRenderer.swift
    VideoSettings.swift
    VideoTextureExtractor.swift
    VolumetricLightPass.swift
    WallpaperBridgeJS.swift
    WallpaperRenderer.swift
    WallpaperSchemeHandler.swift
    WallpaperWindowLevel.swift
    WebHardPauseJS.swift
    WebInputProxyView.swift
    WebRenderer.swift
)

# ── 제외 ────────────────────────────────────────────────────────────────────
# `파일:사유`. 사유는 `docs/dev/linux-typecheck.md` 와 동일해야 한다.
# **[2026-08-21] 지금은 0건이다** — WebKit·UniformTypeIdentifiers 심이 들어오면서 마지막 4파일
# (WebRenderer/WebInputProxyView/WallpaperSchemeHandler/RendererFactory)까지 커버로 옮겼다.
# 배열은 남겨 둔다: 새 프레임워크를 쓰는 파일이 생기면 심을 쓰기 전까지 여기에 넣는다.
EXCLUDED=(
)

# ── `--app` 제외 ────────────────────────────────────────────────────────────
# `Sources/Waple/**`(48) 와 `Tests/WapleAppTests/**`(36)는 **제외 목록 방식**이다(커버 목록이
# 아니라). 새 파일이 조용히 새는 방향이 반대이기 때문이다 — 새 파일은 자동으로 커버되고,
# 여기 적힌 것만 빠진다. 대신 **목록의 파일이 트리에 없으면 실패**시켜 스테일 제외를 막는다.
#
# 네 파일 전부 **심으로 메울 수 없는** 사유다(자세한 진단은 `docs/dev/linux-typecheck.md`).
APP_EXCLUDED=(
    "AppDelegate.swift:@objc/#selector 24곳. 리눅스는 objc-interop 이 꺼져 있어 오류이고, 켜면 (1) 리눅스 NSObject 가 interop 없이 빌드돼 어떤 클래스 타입도 ObjC 표현 불가라 :1381 @objc func applyRecent(_ sender: NSMenuItem) 이 막히고 (2) 모든 inout→포인터 변환이 broken standard library 로 깨진다"
    "main.swift:#selector(NSText.cut(_:)) 4곳 + AppDelegate 참조. 위와 같은 사유"
)
APP_TEST_EXCLUDED=(
    "AppUIV06RegressionTests.swift:AppDelegate.swift:11 의 ScreenCountBaseline 을 쓴다 — 그 파일이 커버 밖이라 따라 나간다"
    "WorkshopPagingTests.swift:@MainActor 테스트 클래스가 override func tearDown() 에서 격리 상태를 만진다. 리눅스 swift-corelibs-xctest 의 tearDown 은 스위프트 메서드라 오버라이드가 nonisolated 로 고정된다(애플 XCTest 는 ObjC 메서드라 클래스의 @MainActor 가 살아 있다). 툴체인 쪽이라 심으로 못 고친다"
)

# ── `--tests` 제외 ──────────────────────────────────────────────────────────
# [2026-08-26] `Tests/WapleRenderTests/**` 에도 제외 목록이 생겼다. 규약은 `APP_TEST_EXCLUDED`
# 와 같다 — 새 파일은 자동으로 커버되고 여기 적힌 것만 빠지며, 목록의 파일이 트리에 없으면 실패한다.
#
# **왜 이제야 생겼나**: 종전에는 `linux-shim/metalkit.swift` 의 `MTKViewDelegate` 격리 누락으로
# **소스 단계가 먼저 죽어**(`SceneRenderer.swift` 의 `tickAnimationEvents` 호출이
# `[#ActorIsolatedCall]`) 이 단계까지 도달한 적이 없었다. 심을 실물과 같은
# `@preconcurrency @MainActor` 로 고치자 처음 돌았고, 그때 드러난 것이 아래 한 건이다.
RENDER_TEST_EXCLUDED=(
    "VideoLiveSettingsTests.swift:@MainActor 테스트 클래스가 override func setUp()/tearDown() 에서 격리 상태(tempDir)를 만진다. 리눅스 swift-corelibs-xctest 의 setUp/tearDown 은 스위프트 메서드라 오버라이드가 nonisolated 로 고정된다(애플 XCTest 는 ObjC 메서드라 클래스의 @MainActor 가 살아 있다). 바로 위 APP_TEST_EXCLUDED 의 WorkshopPagingTests.swift 와 **같은 결함 부류**이고, 툴체인 쪽이라 심으로 못 고친다"
)

# ── 인자 ────────────────────────────────────────────────────────────────────
# **원본 인자를 먼저 보관한다.** 아래 파싱이 `shift` 로 `$@` 를 소모하는데, 그 뒤의 락 재실행
# (`exec flock ... "$0" "$@"`)이 빈 인자를 넘겨 `--replace` 가 조용히 사라진 적이 있다
# (양성 대조가 rc=0 을 줘서 발견 — 도구가 아무것도 안 하고 통과하는 최악의 실패였다).
ORIG_ARGS=("$@")
LIST_ONLY=0
WITH_TESTS=0
WITH_COMPAT=0
WITH_LIB=0
WITH_APP=0
declare -a REPLACE_FROM=() REPLACE_TO=()
while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST_ONLY=1; shift ;;
        --tests) WITH_TESTS=1; shift ;;
        --compat) WITH_TESTS=1; WITH_COMPAT=1; shift ;;
        --lib) WITH_LIB=1; shift ;;
        --app) WITH_TESTS=1; WITH_LIB=1; WITH_APP=1; shift ;;
        --replace)
            [ $# -ge 2 ] || { echo "!! --replace 는 <파일명>=<경로> 를 요구한다" >&2; exit 2; }
            REPLACE_FROM+=("${2%%=*}"); REPLACE_TO+=("${2#*=}"); shift 2 ;;
        *) echo "!! 알 수 없는 인자: $1" >&2; exit 2 ;;
    esac
done

if [ "$LIST_ONLY" = 1 ]; then
    echo "== 커버(${#COVERED[@]}) =="; printf '  %s\n' "${COVERED[@]}"
    echo "== --app 제외 · Sources/Waple(${#APP_EXCLUDED[@]}) =="; printf '  %s\n' "${APP_EXCLUDED[@]}"
    echo "== --app 제외 · Tests/WapleAppTests(${#APP_TEST_EXCLUDED[@]}) =="; printf '  %s\n' "${APP_TEST_EXCLUDED[@]}"
    echo "== --tests 제외 · Tests/WapleRenderTests(${#RENDER_TEST_EXCLUDED[@]}) =="; printf '  %s\n' "${RENDER_TEST_EXCLUDED[@]}"
    echo "== 제외(${#EXCLUDED[@]}) =="
    # 빈 배열에 `printf` 를 그대로 걸면 빈 줄 하나가 찍힌다(제외가 0건인 현 상태).
    [ "${#EXCLUDED[@]}" -gt 0 ] && printf '  %s\n' "${EXCLUDED[@]}"
    exit 0
fi

# ── 공유 락 ─────────────────────────────────────────────────────────────────
# 4코어/16GB 컨테이너에서 동시 swift 빌드 2개는 OOM 으로 컨테이너를 재시작시킨다.
# 기본 락 파일은 작업 디렉터리의 **상위 + `/swift.lock`** 이다. 그래서
# `WAPLE_LINUX_TYPECHECK_DIR=<공유디렉터리>/linux-render-typecheck` 로 돌리면
# `<공유디렉터리>/swift.lock` 이 되어, 같은 자리에 `flock` 하는 다른 swift 작업과 자동으로
# 같은 락을 쓴다(`linux-core-tests.sh` 는 스스로 락을 잡지 않으므로 호출자가 감싼다).
# 다른 락을 쓰려면 `WAPLE_SWIFT_LOCK` 로 지정해라.
if [ "${WAPLE_TYPECHECK_LOCKED:-0}" != "1" ]; then
    mkdir -p "$(dirname "$LOCK")"
    # 어느 락을 잡는지 매번 찍는다 — 락이 갈리면 조용히 OOM 이 나므로 보이게 둔다.
    echo "== 락: $LOCK (WAPLE_SWIFT_LOCK 으로 바꾼다)" >&2
    export WAPLE_TYPECHECK_LOCKED=1
    exec flock -w "${WAPLE_SWIFT_LOCK_WAIT:-3600}" "$LOCK" "$0" "${ORIG_ARGS[@]}"
fi

if [ ! -x "$SWIFTC_DIR/swiftc" ]; then
    echo "!! swiftc 를 못 찾았다: $SWIFTC_DIR/swiftc (WAPLE_SWIFT_BIN 으로 지정할 것)" >&2
    exit 2
fi
SWIFTC="$SWIFTC_DIR/swiftc"
SHIM="$REPO/scripts/dev/linux-shim"
MODS="$WORK/mods"
mkdir -p "$MODS" "$WORK/core" || exit 2

# ── 커버/제외 목록이 실제 트리와 어긋나면 실패시킨다 ─────────────────────────
# 새 파일이 조용히 커버 밖으로 떨어지는 것을 막는다(이 도구가 죽는 가장 흔한 방식).
fail_membership=0
declare -A KNOWN=()
for f in "${COVERED[@]}"; do KNOWN[$f]=covered; done
for e in "${EXCLUDED[@]}"; do KNOWN[${e%%:*}]=excluded; done
while IFS= read -r p; do
    b="${p#$REPO/Sources/WapleRender/}"
    if [ -z "${KNOWN[$b]:-}" ]; then
        echo "!! 목록에 없는 새 파일: Sources/WapleRender/$b" >&2
        echo "   → linux-render-typecheck.sh 의 COVERED 나 EXCLUDED 에 넣고" >&2
        echo "     docs/dev/linux-typecheck.md 를 갱신해라." >&2
        fail_membership=1
    fi
    unset "KNOWN[$b]"
done < <(find "$REPO/Sources/WapleRender" -name '*.swift' | sort)
for b in "${!KNOWN[@]}"; do
    echo "!! 목록에는 있는데 트리에 없는 파일: $b (COVERED/EXCLUDED 에서 지워라)" >&2
    fail_membership=1
done
[ "$fail_membership" = 0 ] || exit 1

# `--app` 의 제외 목록도 같은 시점에 검사한다 — **심 빌드 전에** 실패해야 2분 뒤가 아니라
# 즉시 드러난다(렌더 목록 검사와 같은 이유).
if [ "$WITH_APP" = 1 ]; then
    for e in "${APP_EXCLUDED[@]}"; do
        [ -f "$REPO/Sources/Waple/${e%%:*}" ] || {
            echo "!! APP_EXCLUDED 에 있는데 트리에 없다: Sources/Waple/${e%%:*}" >&2
            echo "   → 파일이 지워졌거나 이름이 바뀌었다. 목록과 docs/dev/linux-typecheck.md 를 함께 고쳐라." >&2
            exit 1; }
    done
    for e in "${APP_TEST_EXCLUDED[@]}"; do
        [ -f "$REPO/Tests/WapleAppTests/${e%%:*}" ] || {
            echo "!! APP_TEST_EXCLUDED 에 있는데 트리에 없다: Tests/WapleAppTests/${e%%:*}" >&2
            exit 1; }
    done
fi

if [ "$WITH_TESTS" = 1 ]; then
    for e in "${RENDER_TEST_EXCLUDED[@]}"; do
        [ -f "$REPO/Tests/WapleRenderTests/${e%%:*}" ] || {
            echo "!! RENDER_TEST_EXCLUDED 에 있는데 트리에 없다: Tests/WapleRenderTests/${e%%:*}" >&2
            echo "   → 파일이 지워졌거나 이름이 바뀌었다. 목록과 docs/dev/linux-typecheck.md 를 함께 고쳐라." >&2
            exit 1; }
    done
fi

# ── 대역 모듈 빌드 ──────────────────────────────────────────────────────────
build_module() {
    local name="$1"; shift
    if ! "$SWIFTC" -emit-module -module-name "$name" -I "$MODS" \
            -emit-module-path "$MODS/$name.swiftmodule" "$@" 2>"$WORK/$name.log"; then
        echo "!! 심 모듈 빌드 실패: $name" >&2
        grep -E "error:" "$WORK/$name.log" | head -30 >&2
        return 1
    fi
    return 0
}

# `-enable-testing` 모듈 emit. `@testable import` 가 실제로 동작해야 internal 표면의 오타·
# 시그니처 변경까지 잡히기 때문에 `-typecheck` 가 아니라 emit 이다.
#
# ⚠️ **swiftc 는 진단이 나도 `.swiftmodule` 파일을 남긴다**(2026-08-21 실측: `WapleLibrary` emit 이
#    `URL.bookmarkData` 부재로 rc=1 인데 83KB 짜리 모듈이 기록됐고, 그 뒤 테스트 타입체크가
#    rc=0 을 줬다). 그러니 **rc 를 반드시 보고 즉시 멈춰야 한다** — 호출부는 전부 `|| exit 1` 이다.
#    스테일 모듈로 다음 단계가 조용히 통과하는 것이 이 하네스가 죽는 가장 조용한 방식이다.
emit_testing() {   # <모듈명> <파일...>
    local name="$1"; shift
    if ! "$SWIFTC" -emit-module -module-name "$name" -I "$MODS" -enable-testing \
            -emit-module-path "$MODS/$name.swiftmodule" "$@" 2>"$WORK/$name-testing.log"; then
        echo "!! -enable-testing 모듈 emit 실패: $name" >&2
        grep -E "error:" "$WORK/$name-testing.log" | head -30 >&2
        return 1
    fi
    return 0
}

# 의존 순서: CoreGraphics(+CF) → QuartzCore → Metal → AppKit → MetalKit → 나머지
build_module CoreGraphics    "$SHIM/coregraphics.swift"       || exit 1
build_module QuartzCore      "$SHIM/quartzcore.swift"         || exit 1
build_module Metal           "$SHIM/metal.swift"              || exit 1
# `UniformTypeIdentifiers` 가 `AppKit` 보다 앞에 온다 — `appkit-app.swift` 의
# `NSOpenPanel.allowedContentTypes` 가 `UTType` 을 쓴다(애플에서도 AppKit 이 UTI 를 끌고 온다).
build_module UniformTypeIdentifiers "$SHIM/uniformtypeidentifiers.swift" || exit 1
# AppKit 은 **두 파일**이다. `appkit-app.swift` 는 앱 계층(`Sources/Waple/**`)이 쓰는 표면
# (패널·워크스페이스·뷰컨트롤러)이고, 종전 `appkit.swift` 는 렌더가 쓰는 창·뷰다.
build_module AppKit          "$SHIM/appkit.swift" "$SHIM/appkit-app.swift" || exit 1
build_module MetalKit        "$SHIM/metalkit.swift"           || exit 1
build_module CoreVideo       "$SHIM/corevideo.swift"          || exit 1
build_module AVFoundation    "$SHIM/avfoundation.swift"       || exit 1
build_module ScreenCaptureKit "$SHIM/screencapturekit.swift"  || exit 1
build_module CoreText        "$SHIM/coretext.swift"           || exit 1
build_module ImageIO         "$SHIM/imageio.swift"            || exit 1
build_module Accelerate      "$SHIM/accelerate.swift"         || exit 1
build_module JavaScriptCore  "$SHIM/javascriptcore.swift"     || exit 1
build_module CryptoKit       "$SHIM/cryptokit.swift"          || exit 1
build_module Compression     "$SHIM/compression.swift"        || exit 1
build_module WebKit          "$SHIM/webkit.swift"             || exit 1
build_module simd            "$SHIM/simd.swift" "$SHIM/simd-extra.swift" || exit 1
# 아래 넷은 `--app`(앱 계층) 전용이지만 **항상 만든다** — 합쳐 2초 남짓이고, 심이 깨지면
# 기본 실행에서 바로 드러나는 편이 낫다(`Darwin` 을 항상 만드는 것과 같은 판단).
# 의존: Security → CoreGraphics(CF 타입) · SwiftUI → AppKit·Combine·UTI·CoreGraphics.
build_module Combine         "$SHIM/combine.swift"            || exit 1
build_module Security        "$SHIM/security.swift"           || exit 1
build_module ServiceManagement "$SHIM/servicemanagement.swift" || exit 1
build_module SwiftUI         "$SHIM/swiftui.swift"            || exit 1
# `Darwin` 은 `Sources/WapleCompatCore/ProfilePipeline.swift` 의 mach VM 질의 전용이다.
# WapleRender 는 안 쓰지만 심 빌드는 싸므로(0.2초) 항상 만들어 둔다 — `--compat` 에서만 쓰인다.
build_module Darwin          "$SHIM/darwin.swift"             || exit 1

# ── WapleCore 모듈 ──────────────────────────────────────────────────────────
# 매번 다시 만든다 — 다른 작업이 WapleCore 를 고치는 중일 수 있다(실측: 이 세션에서 실제로 그랬다).
# `CFGetTypeID`/`CFBooleanGetTypeID` 는 `UserPropertyStore.swift`(WapleRender)가 **WapleCore 를 통해**
# 본다(애플에선 Foundation 이 CoreFoundation 을 재수출한다). 그래서 읽기 전용 코어 심을
# 그 두 심볼만 public 으로 바꿔 넣는다 — 사본이 아니라 파생이라 원본과 어긋날 수 없다.
# **심볼릭 링크가 아니라 복사다.** 링크로 넘기면 다른 작업이 코어를 저장하는 순간 swiftc 가
# `input file ... was modified during the build` 로 죽는다(실측: 이 세션에서 8명이 동시에 도는 동안
# 3회 재시도가 전부 소진돼 도구가 통째로 못 돌았다). 매 실행 새로 뜨는 **스냅샷**이라 스테일 위험은
# 실행 시작 시점까지로 한정된다.
rm -f "$WORK/core"/*.swift
cp "$REPO"/Sources/WapleCore/*.swift "$WORK/core/" || exit 2
sed -E 's/^(func (CFGetTypeID|CFBooleanGetTypeID))/public \1/' \
    "$SHIM/corefoundation.swift" > "$WORK/core/zz-linux-corefoundation.swift" || exit 2

# 재시도: 다른 작업이 같은 트리에서 코어를 고치고 있으면 swiftc 가
# `input file ... was modified during the build` 로 죽는다. 이건 코드 결함이 아니다.
core_ok=0
for attempt in 1 2 3; do
    if "$SWIFTC" -emit-module -module-name WapleCore -I "$MODS" \
            -emit-module-path "$MODS/WapleCore.swiftmodule" "$WORK/core"/*.swift 2>"$WORK/WapleCore.log"; then
        core_ok=1; break
    fi
    if grep -q "was modified during the build" "$WORK/WapleCore.log"; then
        echo "   (WapleCore 소스가 빌드 중 바뀌었다 — 20초 뒤 재시도 $attempt/3)" >&2
        sleep 20
        continue
    fi
    break
done
if [ "$core_ok" != 1 ]; then
    echo "!! WapleCore 모듈 빌드 실패 — WapleRender 이전 단계다. 아래는 코어 쪽 오류다." >&2
    grep -E "error:" "$WORK/WapleCore.log" | head -40 >&2
    exit 1
fi

# ── 대상 파일 목록(+ --replace 치환) ────────────────────────────────────────
declare -a SOURCES=()
for f in "${COVERED[@]}"; do
    path="$REPO/Sources/WapleRender/$f"
    for i in "${!REPLACE_FROM[@]}"; do
        if [ "${REPLACE_FROM[$i]}" = "$f" ]; then
            path="${REPLACE_TO[$i]}"
            [ -f "$path" ] || { echo "!! --replace 대상이 없다: $path" >&2; exit 2; }
            echo "== 치환: $f → $path"
        fi
    done
    [ -f "$path" ] || { echo "!! 대상 파일이 없다: $path" >&2; exit 2; }
    SOURCES+=("$path")
done

echo "== 타입체크: ${#SOURCES[@]} 파일 (제외 ${#EXCLUDED[@]}) =="
t0=$SECONDS
# WapleCore 와 같은 이유의 재시도 — 다른 작업이 같은 트리에서 `Sources/WapleRender/**` 를 저장하면
# swiftc 가 `input file ... was modified during the build` 로 죽는다(실측: 이 세션에서 실제로 났다).
# 이건 코드 결함이 아니다. **그 메시지가 있을 때만** 다시 돈다 — 진짜 오류는 재시도해도 그대로 난다.
for attempt in 1 2 3; do
    "$SWIFTC" -typecheck -I "$MODS" "${SOURCES[@]}" 2>&1 | tee "$WORK/typecheck.log"
    rc=${PIPESTATUS[0]}
    [ $rc -eq 0 ] && break
    grep -q "was modified during the build" "$WORK/typecheck.log" || break
    [ $attempt -lt 3 ] || break
    echo "   (WapleRender 소스가 빌드 중 바뀌었다 — 재시도 $attempt/3)" >&2
done
if [ $rc -eq 0 ]; then
    echo "== OK — 커버 ${#COVERED[@]} 파일 타입체크 통과 (rc=0, 타입체크 $((SECONDS - t0))초)"
else
    echo "== FAIL (rc=$rc) — 위 오류는 macOS \`swift build\` 에서도 거의 그대로 난다." >&2
    exit $rc
fi

# ── `--lib`: WapleLibrary·WaplePolicy 소스 + 그 테스트 ───────────────────────
# 렌더와 무관한 축이다(둘 다 `WapleRender` 에 의존하지 않는다). 그런데도 여기 붙이는 이유는
# 심 모듈과 `WapleCore` 스냅샷이 이미 서 있기 때문이다 — 별도 하네스를 하나 더 만들면
# 락·작업 디렉터리·재시도 규약이 두 벌로 갈린다(이 리포의 상습 결함).
#
# **`--tests` 의 서곡(`zz-test-implicit-imports.swift`)을 여기에는 넣지 않는다.** 서곡은 애플의
# Clang 모듈 전이 노출을 흉내 내는 것인데, macOS 에서 `@testable import WapleLibrary` 가 흘리는
# 것은 `WapleLibrary` 가 실제로 임포트한 것(`Foundation`·`WapleCore`→`simd`)뿐이다. 서곡을 넣으면
# AppKit·Metal 까지 흘러 **모델이 실물보다 관대해진다**. 실측으로 서곡 없이 rc=0 이므로 넣지 않는다
# (`docs/dev/linux-typecheck.md` 서곡 절의 "목록을 줄이는 것이 맞다" 와 같은 판단).
if [ "$WITH_LIB" = 1 ]; then
    echo "== WapleLibrary·WaplePolicy: 모듈 emit + 테스트 타입체크 =="
    l0=$SECONDS
    declare -a LIBSRC=() POLSRC=()
    while IFS= read -r p; do LIBSRC+=("$p"); done \
        < <(find "$REPO/Sources/WapleLibrary" -name '*.swift' | sort)
    while IFS= read -r p; do POLSRC+=("$p"); done \
        < <(find "$REPO/Sources/WaplePolicy" -name '*.swift' | sort)
    [ "${#LIBSRC[@]}" -gt 0 ] || { echo "!! Sources/WapleLibrary 에 .swift 가 없다" >&2; exit 2; }
    [ "${#POLSRC[@]}" -gt 0 ] || { echo "!! Sources/WaplePolicy 에 .swift 가 없다" >&2; exit 2; }
    # `zz-linux-url-bookmark.swift` 는 **모듈이 아니라 파일**로 함께 넣는다 — `URL` 확장이라
    # 대상 모듈 안에 있어야 보인다(리눅스 Foundation 결손, 그 파일 머리말 참조).
    emit_testing WapleLibrary "${LIBSRC[@]}" "$SHIM/zz-linux-url-bookmark.swift" || exit 1
    emit_testing WaplePolicy  "${POLSRC[@]}" || exit 1
    declare -a LTEST=()
    while IFS= read -r p; do LTEST+=("$p"); done \
        < <(find "$REPO/Tests/WapleLibraryTests" "$REPO/Tests/WaplePolicyTests" \
                 -name '*.swift' 2>/dev/null | sort)
    [ "${#LTEST[@]}" -gt 0 ] || { echo "!! library/policy 테스트 파일을 못 찾았다" >&2; exit 2; }
    "$SWIFTC" -typecheck -I "$MODS" "${LTEST[@]}" 2>&1 | tee "$WORK/lib-typecheck.log"
    lrc=${PIPESTATUS[0]}
    if [ $lrc -eq 0 ]; then
        echo "== OK — WapleLibrary ${#LIBSRC[@]} + WaplePolicy ${#POLSRC[@]} 소스, 테스트 ${#LTEST[@]} 파일 통과 (rc=0, $((SECONDS - l0))초)"
    else
        echo "== FAIL (lib, rc=$lrc) — 심 공백 판별법은 아래 --tests 실패 경로와 같다." >&2
        exit $lrc
    fi
fi

[ "$WITH_TESTS" = 1 ] || exit 0

# ── `--tests`: Tests/WapleRenderTests/** 타입체크 ───────────────────────────
# 소스 타입체크가 통과한 뒤에만 온다 — 소스가 깨져 있으면 테스트 오류는 전부 그 파생이라
# 노이즈다. 여기서는 `-typecheck` 가 아니라 **모듈 emit** 이 먼저 필요하다:
# `@testable import WapleRender` 가 실제로 동작하려면 `-enable-testing` 으로 만든 모듈이
# 있어야 하고, 그래야 internal 표면의 오타·시그니처 변경까지 잡힌다.
echo "== 테스트 타입체크: 모듈 emit(-enable-testing) =="
te0=$SECONDS
# 순서: WapleCore(이미 $WORK/core 에 스냅샷이 있다) → WapleSnapshot → WapleRender.
emit_testing WapleCore "$WORK/core"/*.swift || exit 1
if compgen -G "$REPO/Sources/WapleSnapshot/*.swift" >/dev/null; then
    emit_testing WapleSnapshot "$REPO"/Sources/WapleSnapshot/*.swift || exit 1
fi
emit_testing WapleRender "${SOURCES[@]}" || exit 1
echo "   모듈 emit $((SECONDS - te0))초"

declare -a TESTS=()
while IFS= read -r p; do
    skip=0
    for e in "${RENDER_TEST_EXCLUDED[@]}"; do
        [ "$(basename "$p")" = "${e%%:*}" ] && { skip=1; break; }
    done
    [ $skip = 1 ] || TESTS+=("$p")
done \
    < <(find "$REPO/Tests/WapleRenderTests" -name '*.swift' | sort)
[ "${#TESTS[@]}" -gt 0 ] || { echo "!! 테스트 파일을 못 찾았다" >&2; exit 2; }

# 애플의 Clang 모듈 전이 노출을 흉내 내는 서곡을 함께 넣는다(파일 머리말 참조).
TESTS+=("$SHIM/zz-test-implicit-imports.swift")

echo "== 테스트 타입체크: $(( ${#TESTS[@]} - 1 )) 파일 (+ 서곡 1) =="
tt0=$SECONDS
for attempt in 1 2 3; do
    "$SWIFTC" -typecheck -I "$MODS" "${TESTS[@]}" 2>&1 | tee "$WORK/tests-typecheck.log"
    trc=${PIPESTATUS[0]}
    [ $trc -eq 0 ] && break
    grep -q "was modified during the build" "$WORK/tests-typecheck.log" || break
    [ $attempt -lt 3 ] || break
    echo "   (테스트 소스가 빌드 중 바뀌었다 — 재시도 $attempt/3)" >&2
done
if [ $trc -eq 0 ]; then
    echo "== OK — 테스트 $(( ${#TESTS[@]} - 1 )) 파일 타입체크 통과 (rc=0, $((SECONDS - tt0))초)"

    # ── `--compat`: WapleCompatCore 소스 + 테스트 ────────────────────────────
    # `Sources/WapleCompatCore/**`(5파일)는 종전에 **어떤 리눅스 검증도 못 받았다** —
    # `import Metal`/`WapleRender`/`Darwin` 이라 코어 테스트에도, 렌더 커버에도 안 들어간다.
    # 그런데 이 계층은 스냅샷 골든 파이프라인과 DeepScan 이 사는 곳이라 조용히 깨지면
    # 골든 게이트가 통째로 무의미해진다.
    if [ "$WITH_COMPAT" = 1 ]; then
        echo "== WapleCompatCore: 모듈 emit + 테스트 타입체크 =="
        ct0=$SECONDS
        declare -a CSRC=()
        while IFS= read -r p; do CSRC+=("$p"); done \
            < <(find "$REPO/Sources/WapleCompatCore" -name '*.swift' | sort)
        if [ "${#CSRC[@]}" -eq 0 ]; then
            echo "!! Sources/WapleCompatCore 에 .swift 가 없다" >&2; exit 2
        fi
        emit_testing WapleCompatCore "${CSRC[@]}" || exit 1
        declare -a CTEST=()
        while IFS= read -r p; do CTEST+=("$p"); done \
            < <(find "$REPO/Tests/WapleCompatCoreTests" "$REPO/Tests/WapleSnapshotTests" \
                     -name '*.swift' 2>/dev/null | sort)
        if [ "${#CTEST[@]}" -eq 0 ]; then
            echo "!! compat/snapshot 테스트 파일을 못 찾았다" >&2; exit 2
        fi
        CTEST+=("$SHIM/zz-test-implicit-imports.swift")
        "$SWIFTC" -typecheck -I "$MODS" "${CTEST[@]}" 2>&1 | tee "$WORK/compat-typecheck.log"
        crc=${PIPESTATUS[0]}
        # [2026-08-21] 실행파일 타깃 `Sources/WapleCompat/**`(main.swift 하나)도 여기서 본다.
        # `WapleCompatCore` 모듈이 방금 섰으니 공짜다(실측 1초 미만). **따로 부른다** —
        # `main.swift` 는 최상위 코드라 테스트 파일들과 한 번에 넘기면 안 된다.
        if [ $crc -eq 0 ]; then
            declare -a XSRC=()
            while IFS= read -r p; do XSRC+=("$p"); done \
                < <(find "$REPO/Sources/WapleCompat" -name '*.swift' | sort)
            if [ "${#XSRC[@]}" -eq 0 ]; then
                echo "!! Sources/WapleCompat 에 .swift 가 없다" >&2; exit 2
            fi
            "$SWIFTC" -typecheck -I "$MODS" "${XSRC[@]}" 2>&1 | tee "$WORK/compatexe-typecheck.log"
            crc=${PIPESTATUS[0]}
            [ $crc -eq 0 ] || echo "== FAIL (WapleCompat 실행파일, rc=$crc)" >&2
        fi
        if [ $crc -eq 0 ]; then
            echo "== OK — WapleCompatCore 소스 ${#CSRC[@]} + 실행파일 ${#XSRC[@]} + 테스트 ${#CTEST[@]} 파일 통과 (rc=0, $((SECONDS - ct0))초)"
        else
            echo "== FAIL (compat, rc=$crc) — 위 판별법으로 심 공백부터 의심해라." >&2
            exit $crc
        fi
    fi

else
    echo "== FAIL (테스트, rc=$trc)" >&2
    # **소스 쪽과 달리 여기서는 "macOS 에서도 그대로 난다" 고 단정할 수 없다.** 테스트는
    # 소스보다 애플 API 표면을 훨씬 넓게 쓰므로(첫 실행 실측: 152파일 중 1파일이
    # `NSBitmapImageRep(data:)` · `NSColor.redComponent` 로 걸렸다) 상당수가 **심 공백**이다.
    # 심 공백과 진짜 오류를 구분하는 법: 오류가 `linux-shim/` 의 `note:` 를 달고 나오거나
    # 메시지가 "has no member" / "extra argument" 면 대개 심이 모자란 것이다. 그때는
    # 테스트가 아니라 `scripts/dev/linux-shim/` 을 고쳐라(실제 애플 헤더 시그니처를 주석에
    # 적고 본문은 더미로 둔다 — 이 도구는 타입만 본다).
    # [2026-08-21] 판별 패턴을 넓혔다. 처음엔 `has no member|extra argument|missing argument`
    # 셋뿐이라 **실제 심 공백을 "심 징후 없음" 으로 오분류**했다 —
    # `CGAffineTransform(rotationAngle:)` 부재가 "argument passed to call that takes no
    # arguments" 로 나왔기 때문이다(생성자가 없으면 `init()` 에 인자를 넘긴 꼴이 된다).
    grep -qE "linux-shim/.*note:|has no member|extra argument|missing argument|takes no arguments|cannot find '[A-Z]" \
        "$WORK/tests-typecheck.log" \
        && echo "   ↑ linux-shim/ 공백일 가능성이 높다(위 판별법 참조). 심을 먼저 의심해라." >&2 \
        || echo "   ↑ 심 공백 징후가 없다 — macOS \`swift test\` 빌드에서도 그대로 날 가능성이 높다." >&2
fi

# ── `--app` 은 위 `Tests/WapleRenderTests` 결과와 **독립**으로 돈다 ────────────
#
# [2026-08-26] 종전에는 이 블록이 `if [ $trc -eq 0 ]`(렌더 테스트 통과) 안에 들어 있었다.
# 그래서 `Tests/WapleRenderTests/**` 가 한 군데라도 깨지면 `--app` 이 **한 파일도 보지
# 못한 채** 건너뛰어졌고, **로그에 그 사실이 아무 데도 안 남았다** — 도구가 조용히
# 아무것도 안 하고 통과하는, 이 파일 머리말이 최악이라 부르는 그 실패다(`--replace` 가
# 인자 소실로 무동작 통과했던 것과 같은 부류).
#
# 실측 두 번. 둘 다 `Tests/WapleRenderTests/VideoLiveSettingsTests.swift` 의 setUp/tearDown
# 액터 격리 오류(6.3.2)였고, 그때마다 앱 계층 80파일이 통째로 안 돌았다. 그 파일은 앱
# 계층과 아무 관계가 없다. 중간에 한 번 초록이 나온 적이 있는데 그건 고쳐져서가 아니라
# **그 파일이 잠깐 트리에 없었기 때문**이다(같은 실행의 파일 수가 155 → 154 였다) —
# 여러 작업이 같은 트리를 동시에 고치는 동안 이 게이트가 얼마나 임의적인지 보여 준다.
#
# 의존이 실제로 무엇인지 보면 분리가 맞다: `Sources/Waple/**` 와 `Tests/WapleAppTests/**`
# 에 필요한 것은 **`WapleRender` 모듈이 서 있는 것**뿐이고, 그 모듈은 위
# `emit_testing WapleRender` 가 이미 세웠다(실패하면 거기서 `|| exit 1` 로 멎는다).
# `Tests/WapleRenderTests` 의 타입체크 **결과**는 그 모듈에 아무 영향이 없다.
#
# 종료코드는 그대로다 — `--app` 이 깨지면 여기서 `exit $arc`, 아니면 맨 아래 `exit $trc`
# 가 렌더 테스트 결과를 그대로 낸다. 즉 **덜 실패하게 만드는 변경이 아니라, 더 보게
# 만드는 변경**이다. (`--compat` 은 종전 자리에 그대로 둔다 — 같은 논리가 적용될
# 것 같지만 이번에 실측한 것은 `--app` 쪽뿐이다.)

# ── `--app`: Sources/Waple + Tests/WapleAppTests ─────────────────────────
# 이 리포에서 **마지막으로 남아 있던 큰 사각지대**다. `Sources/Waple/**`(48파일 8,842줄)와
# `Tests/WapleAppTests/**`(36파일)는 `SwiftUI`·`Combine`·`Security`·`ServiceManagement`
# 심이 없어 종전에 **어떤 리눅스 검증도 못 받았다**.
#
# 순서: ① 소스 타입체크 → ② `Waple` 모듈 emit(`-enable-testing`) → ③ 테스트 타입체크.
#
# ①을 따로 두는 이유(정확히 적는다): 드라이버가 `-emit-module` 에
# `-experimental-skip-non-inlinable-function-bodies-without-types` 를 붙인다(크래시 덤프의
# frontend argv 로 확인). 이름만 보면 본문을 건너뛸 것 같은데, **실측으로는 건너뛰지 않았다** —
# `SettingsView` 의 `.foregroundStyle(.secondaryy)` 돌연변이를 emit 만으로도 잡았다.
# 그 플래그의 정확한 적용 범위를 확정하지 못했으므로, 소스 오류가 **모듈이 기록되기 전에**
# 파일 단위로 드러나도록 ①을 남긴다(비용 7초). 확정되면 지워도 된다.
if [ "$WITH_APP" = 1 ]; then
    echo "== Waple(앱 계층): 소스 타입체크 + 모듈 emit + 테스트 타입체크 =="
    a0=$SECONDS
    declare -a ASRC=() ATEST=()
    while IFS= read -r p; do
        skip=0
        for e in "${APP_EXCLUDED[@]}"; do
            [ "${p#$REPO/Sources/Waple/}" = "${e%%:*}" ] && skip=1
        done
        [ "$skip" = 1 ] || ASRC+=("$p")
    done < <(find "$REPO/Sources/Waple" -name '*.swift' | sort)
    while IFS= read -r p; do
        skip=0
        for e in "${APP_TEST_EXCLUDED[@]}"; do
            [ "${p#$REPO/Tests/WapleAppTests/}" = "${e%%:*}" ] && skip=1
        done
        [ "$skip" = 1 ] || ATEST+=("$p")
    done < <(find "$REPO/Tests/WapleAppTests" -name '*.swift' | sort)
    [ "${#ASRC[@]}" -gt 0 ] || { echo "!! Sources/Waple 에 .swift 가 없다" >&2; exit 2; }
    [ "${#ATEST[@]}" -gt 0 ] || { echo "!! Tests/WapleAppTests 에 .swift 가 없다" >&2; exit 2; }
    # **서곡(prelude)은 테스트 단계에만 넣는다.** 소스 46파일은 서곡 없이 rc=0 이다(실측) —
    # 각자 필요한 것을 명시적으로 임포트하고 있고, 유일한 전이 의존이던
    # `ObservableObject`(Combine)는 `swiftui.swift` 가 애플과 똑같이 재수출한다.
    # 테스트는 다르다: `AppUIFixRegressionTests.swift:242` 가 `import AppKit` 없이
    # `NSBitmapImageRep` 을 쓰는데 macOS 에서는 `@testable import Waple` 의 Clang 모듈
    # 전이 노출로 빌드된다. 서곡을 빼면 거기서만 깨진다(실측).
    "$SWIFTC" -typecheck -I "$MODS" "${ASRC[@]}" 2>&1 | tee "$WORK/app-typecheck.log"
    arc=${PIPESTATUS[0]}
    if [ $arc -eq 0 ]; then
        emit_testing Waple "${ASRC[@]}" || exit 1
        "$SWIFTC" -typecheck -I "$MODS" "${ATEST[@]}" "$SHIM/zz-app-implicit-imports.swift" \
            2>&1 | tee "$WORK/apptests-typecheck.log"
        arc=${PIPESTATUS[0]}
    fi
    if [ $arc -eq 0 ]; then
        echo "== OK — Waple 소스 ${#ASRC[@]}(제외 ${#APP_EXCLUDED[@]}) + 테스트 ${#ATEST[@]}(제외 ${#APP_TEST_EXCLUDED[@]}, +서곡 1) 파일 통과 (rc=0, $((SECONDS - a0))초)"
    else
        echo "== FAIL (app, rc=$arc) — 위 판별법으로 심 공백부터 의심해라(SwiftUI/AppKit)." >&2
        exit $arc
    fi
fi
exit $trc
