#!/bin/bash
# `WapleCoreTests` 를 **리눅스에서** 돌린다.
#
# 왜 있는가
# ---------
# `WapleCore` 는 `import simd` 를 쓰고 애플 CoreFoundation 의 `CFGetTypeID` 로 JSON 의 true/false 를
# 숫자와 가른다. 둘 다 리눅스에 없어서, 코어 로직을 고칠 때마다 검증 수단이 macOS CI 왕복(10분)
# 하나뿐이었다. 이 스크립트는 `linux-shim/` 의 대역 모듈을 끼운 **임시 SwiftPM 패키지**를 만들어
# 같은 테스트 타깃을 그대로 돌린다 — 실측 **1,050개 / 약 82초 / 실패 0**(2026-08-21, HEAD).
#
# [2026-08-21] 종전 주석은 "946개 / 약 9초" 였는데 둘 다 낡았다. 개수가 는 것보다 **시간이
# 9배**가 된 게 중요하다 — `GLSLBundledShaderRegressionTests` 가 동봉 셰이더 239쌍을 콤보
# 극단까지 번역해 보기 때문이다(그 스윕이 실제로 번역기 구멍 7종을 찾았으니 값은 한다).
# 한 곳만 고칠 때는 `--filter <TestClass>` 를 붙여라. 이 스크립트는 인자를 그대로 넘긴다.
#
# 한계(솔직하게): 여기서 통과한다고 CI 통과가 보장되지는 않는다.
#   · 렌더 계층(`WapleRender`·Metal)은 리눅스에서 빌드 자체가 안 되므로 이 스크립트 범위 밖이다.
#   · 부동소수 결과가 macOS `simd` 와 비트동일하지는 않다(시임은 의미만 맞춘다).
#   · 골든 스냅샷 게이트는 macOS + 로컬 코퍼스가 필요하다.
# 그래도 **커밋 전에 논리 회귀를 잡는 용도로는 충분하다** — CI 가 잡아 준 실패들이 전부 이
# 범위 안에 있었다.
#
# 사용: scripts/dev/linux-core-tests.sh [swift test 에 넘길 추가 인자...]
#   예: scripts/dev/linux-core-tests.sh --filter ParticleSimulatorTests
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SWIFTC_DIR="${WAPLE_SWIFT_BIN:-/opt/swift/usr/bin}"
WORK="${WAPLE_LINUX_TEST_DIR:-${TMPDIR:-/tmp}/waple-linux-core-tests}"

if [ ! -x "$SWIFTC_DIR/swift" ]; then
    echo "!! swift 를 못 찾았다: $SWIFTC_DIR/swift (WAPLE_SWIFT_BIN 으로 지정할 것)" >&2
    exit 2
fi

# 매번 새로 링크한다 — 파일이 추가·삭제돼도 따라간다.
rm -rf "$WORK/Sources" "$WORK/Tests"
mkdir -p "$WORK/Sources/simdshim" "$WORK/Sources/WapleCore" "$WORK/Tests/WapleCoreTests"
cp "$REPO/scripts/dev/linux-shim/simd.swift" "$WORK/Sources/simdshim/simd.swift"
cp "$REPO/scripts/dev/linux-shim/corefoundation.swift" "$WORK/Sources/WapleCore/zz-linux-corefoundation.swift"
for f in "$REPO"/Sources/WapleCore/*.swift; do ln -sf "$f" "$WORK/Sources/WapleCore/"; done
for f in "$REPO"/Tests/WapleCoreTests/*.swift; do ln -sf "$f" "$WORK/Tests/WapleCoreTests/"; done

cat > "$WORK/Package.swift" <<'PKG'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "WapleCoreLinuxTests",
    targets: [
        // 모듈 이름을 `simd` 로 둬야 `import simd` 가 이 대역을 집는다.
        .target(name: "simd", path: "Sources/simdshim", sources: ["simd.swift"]),
        .target(name: "WapleCore", dependencies: ["simd"], path: "Sources/WapleCore"),
        .testTarget(name: "WapleCoreTests", dependencies: ["WapleCore", "simd"], path: "Tests/WapleCoreTests"),
    ]
)
PKG

cd "$WORK" || exit 1
# 동봉 자산 트리 위치를 넘긴다 — 이 임시 패키지는 저장소 **밖**이라 상위 디렉터리 탐색으로는
# 못 찾는다. 자산 전수 회귀 테스트(AssetJSON/EffectManifest/Model3D)가 이걸 보고 켜진다.
# 없으면 그 테스트들은 XCTSkip 으로 조용히 빠진다 — 즉 리눅스에서 **조용히 0건을 통과**하던
# 자리였다(2026-08-21: CRLF 관용 파스 결함을 리눅스가 못 잡은 원인).
export WAPLE_WE_ASSETS="${WAPLE_WE_ASSETS:-$REPO/Sources/WapleRender/Resources/WEAssets}"
"$SWIFTC_DIR/swift" test "$@"
