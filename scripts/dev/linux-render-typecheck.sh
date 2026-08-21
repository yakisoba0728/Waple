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
# 사용:
#   scripts/dev/linux-render-typecheck.sh
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

# ── 인자 ────────────────────────────────────────────────────────────────────
# **원본 인자를 먼저 보관한다.** 아래 파싱이 `shift` 로 `$@` 를 소모하는데, 그 뒤의 락 재실행
# (`exec flock ... "$0" "$@"`)이 빈 인자를 넘겨 `--replace` 가 조용히 사라진 적이 있다
# (양성 대조가 rc=0 을 줘서 발견 — 도구가 아무것도 안 하고 통과하는 최악의 실패였다).
ORIG_ARGS=("$@")
LIST_ONLY=0
declare -a REPLACE_FROM=() REPLACE_TO=()
while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST_ONLY=1; shift ;;
        --replace)
            [ $# -ge 2 ] || { echo "!! --replace 는 <파일명>=<경로> 를 요구한다" >&2; exit 2; }
            REPLACE_FROM+=("${2%%=*}"); REPLACE_TO+=("${2#*=}"); shift 2 ;;
        *) echo "!! 알 수 없는 인자: $1" >&2; exit 2 ;;
    esac
done

if [ "$LIST_ONLY" = 1 ]; then
    echo "== 커버(${#COVERED[@]}) =="; printf '  %s\n' "${COVERED[@]}"
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

# 의존 순서: CoreGraphics(+CF) → QuartzCore → Metal → AppKit → MetalKit → 나머지
build_module CoreGraphics    "$SHIM/coregraphics.swift"       || exit 1
build_module QuartzCore      "$SHIM/quartzcore.swift"         || exit 1
build_module Metal           "$SHIM/metal.swift"              || exit 1
build_module AppKit          "$SHIM/appkit.swift"             || exit 1
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
build_module UniformTypeIdentifiers "$SHIM/uniformtypeidentifiers.swift" || exit 1
build_module simd            "$SHIM/simd.swift" "$SHIM/simd-extra.swift" || exit 1

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
fi
exit $rc
