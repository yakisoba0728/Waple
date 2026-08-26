// swift-tools-version:5.9
import PackageDescription

// [2026-08-19] 엄격 동시성 진단을 **경고로** 켠다.
//
// README 의 "Swift 6.3+" 는 컴파일러 버전이지 언어 모드가 아니다. 매니페스트에
// swiftSettings 가 없어서 전 타깃이 Swift 5 minimal checking 으로 빌드되고 있었고,
// 그 결과 @MainActor 표기가 사실상 권고에 그쳤다 — 코드 리뷰에서 독립적으로 세 번
// 지적된 사항이다(백그라운드 큐의 NSView/MTKView 생성, @MainActor 아닌
// LibraryViewModel 을 importQueue 에서 접근, 동기화 없는 mutable static 다수).
//
// 언어 모드를 바로 .v6 로 올리면 그 전부가 **에러**가 되어 빌드가 통째로 멎는다.
// 그래서 먼저 -strict-concurrency=complete 로 진단만 켠다. 빌드는 계속 서고,
// CI 로그가 고쳐야 할 목록 전부를 뱉는다. 그 목록을 소진한 뒤에 모드를 올린다.
//
// unsafeFlags 는 이 패키지가 **루트**일 때만 허용된다. Waple 은 의존성으로 쓰이지
// 않는 앱이라 제약에 걸리지 않는다(zero-dep, 아무도 이 패키지를 import 하지 않는다).
let strictConcurrency: [SwiftSetting] = [
    .unsafeFlags(["-strict-concurrency=complete"]),
]

let package = Package(
    name: "Waple",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WapleCore", swiftSettings: strictConcurrency),
        .target(name: "WapleLibrary", dependencies: ["WapleCore"], swiftSettings: strictConcurrency),
        .target(
            name: "WapleRender",
            dependencies: ["WapleCore"],
            // WE 2.8.42 공유 에셋 동봉. 워크샵 pkg 가 common_*.h 를 하나도 담지 않아
            // (코퍼스 162개 전수 0건) 이게 없으면 대부분의 씬이 불완전하게 그려진다.
            // 출처·해시는 spec/assets/manifest.json 참조.
            resources: [.copy("Resources/WEAssets")],
            swiftSettings: strictConcurrency
        ),
        // Foundation-only 순수 코어(스냅샷 매니페스트/diff) — GPU 무의존, 유닛 검증용
        .target(name: "WapleSnapshot", swiftSettings: strictConcurrency),
        // [2026-08-21] WE 재생 정책(playbackfocus/…/pausevram)의 순수 모델.
        //
        // **의존이 없다.** `WapleCore` 에 붙이면 `import simd` 때문에 리눅스에서 빌드가
        // 통째로 죽는다(실측: `AudioResponse.swift:2 error: no such module 'simd'`).
        // 이 타깃은 `import Foundation` 하나만 쓰므로 리눅스 spec 레인에서 초 단위로
        // 빌드된다 — 정책 판정은 GPU 도 창도 필요 없는 순수 산수라 그게 맞는 자리다.
        // 앞으로도 여기에 의존을 더하지 마라. 더하는 순간 이 성질이 사라진다.
        .target(name: "WaplePolicy", swiftSettings: strictConcurrency),
        // [2026-08-26] `WaplePolicy` 를 앱 타깃에 건다 — 재생정책 배선의 첫 단추.
        //
        // 모델·평가기는 진작 완성돼 있었는데 **아무도 의존하지 않아** 프로덕션 참조가 0이었다
        // (`Sources/WaplePolicy/PlaybackPolicy.swift` 677줄, 소비자는 자기 테스트뿐).
        // 소비 지점은 `Sources/Waple/AppLogic.swift` 의 `PlaybackPolicyGate` 하나다.
        //
        // **방향을 혼동하지 마라.** 위 `WaplePolicy` 타깃 주석의 금지는 "`WaplePolicy` **가**
        // 무언가에 의존하는 것" 이다(그 순간 리눅스 spec 레인이 죽는다). 여기처럼 다른 타깃이
        // `WaplePolicy` **를** 의존하는 것은 그 성질에 아무 영향이 없다 — `WaplePolicy` 는
        // 여전히 `import Foundation` 하나뿐이고 `swift build --target WaplePolicy` 도 그대로 선다.
        .executableTarget(
            name: "Waple",
            dependencies: ["WapleCore", "WapleLibrary", "WapleRender", "WaplePolicy"],
            swiftSettings: strictConcurrency
        ),
        // [2026-08-19] `WapleCompat` 을 **라이브러리 + 얇은 실행파일**로 쪼갠다.
        //
        // 종전엔 전부가 하나의 `.executableTarget` 이라 **어떤 테스트 타깃도 의존할 수 없었다**
        // (`grep -rn "import WapleCompat" Tests/` = 0건). 그래서 1,799줄(DeepScan 782 ·
        // ProfilePipeline 329 · SnapshotPipeline 321 · SnapshotCompare 172 · Report 195)이
        // 통째로 무테스트였고, `SnapshotTests` 는 판정 수식을 **베껴서 자기 산수를 단언**했다 —
        // 프로덕션 로직을 지워도 통과하는 상태였다(그 임계는 WapleSnapshot 으로 올렸다).
        //
        // 실행파일에 남는 것은 `main.swift`(인자 파싱·종료코드) 하나뿐이고, 코어가 공개하는
        // 표면은 진입점 6개(DeepScan.run · ProfilePipeline.run{Inventory,VisBlast,Profile} ·
        // SnapshotPipeline.run{Capture,Compare})뿐이다. 나머지는 모듈 내부로 남는다.
        .target(
            name: "WapleCompatCore",
            dependencies: ["WapleCore", "WapleRender", "WapleSnapshot"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "WapleCompat",
            dependencies: ["WapleCompatCore", "WapleCore", "WapleRender"],
            swiftSettings: strictConcurrency
        ),
        // 테스트 타깃에는 아직 걸지 않는다. 진단 목록을 먼저 소스에서 소진하고,
        // 그다음 테스트로 넓힌다 — 한 번에 켜면 어느 쪽 경고인지 로그에서 뒤섞인다.
        .testTarget(name: "WapleCoreTests", dependencies: ["WapleCore"]),
        .testTarget(name: "WapleSnapshotTests", dependencies: ["WapleSnapshot"]),
        // WaplePolicy 와 마찬가지로 의존을 하나만 갖는다 — 그래야
        // `swift build --target WaplePolicyTests` 가 리눅스에서 선다.
        .testTarget(name: "WaplePolicyTests", dependencies: ["WaplePolicy"]),
        // [2026-08-19] 위 분리로 처음 생긴 타깃 — 종전엔 의존 자체가 불가능했다.
        .testTarget(name: "WapleCompatCoreTests", dependencies: ["WapleCompatCore", "WapleCore", "WapleSnapshot"]),
        .testTarget(name: "WapleLibraryTests", dependencies: ["WapleLibrary", "WapleCore"]),
        // WapleSnapshot 추가(2026-08-19): SyntheticPixelGoldenTests 가 diffRGBA/DiffThreshold/
        // meanLuma 를 쓴다. 픽셀 비교 로직을 테스트 안에 다시 구현하지 않기 위한 것이다 —
        // SnapshotTests 가 relDiff/structureLoss 를 인라인으로 재구현해 **자기 산수를 단언하는**
        // 상태였고(프로덕션 로직을 지워도 통과했다), 같은 실수를 반복하지 않는다.
        .testTarget(name: "WapleRenderTests", dependencies: ["WapleRender", "WapleCore", "WapleSnapshot"]),
        // [2026-08-26] `WaplePolicy` 추가 — **`WapleCore` 와 `WaplePolicy` 를 동시에 보는 첫 타깃**이다.
        //
        // 그런 타깃이 없다는 것이 `ProjectJSONParser.parsePlaybackProperties` 주석이 약속한
        // "앱 측 감시 테스트"(파서의 여섯 키 리터럴 ↔ `PlaybackTrigger.allCases` 의 weConfigKey)가
        // 여태 쓰이지 못한 이유였다. 새 테스트 타깃을 하나 더 만들지 않은 것은, 감시 대상이
        // **앱 계층의 소비자**(`PlaybackPolicyGate`)라 `@testable import Waple` 이 어차피 필요하고,
        // `ci.yml` 의 타깃 존재 게이트도 타깃 수만큼 늘기 때문이다.
        //
        // 리눅스에서는 이 타깃이 안 돈다(`Waple` 이 AppKit/SwiftUI 다). 대신
        // `scripts/dev/linux-render-typecheck.sh --app` 이 타입체크로 덮는다 —
        // 그 경로는 `--lib` 단계에서 이미 `WaplePolicy` 모듈을 emit 하므로 추가 배선이 필요 없다.
        .testTarget(name: "WapleAppTests", dependencies: ["Waple", "WapleCore", "WapleLibrary", "WapleRender", "WaplePolicy"]),
    ]
)
