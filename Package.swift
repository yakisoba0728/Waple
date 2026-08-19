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
        .executableTarget(
            name: "Waple",
            dependencies: ["WapleCore", "WapleLibrary", "WapleRender"],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "WapleCompat",
            dependencies: ["WapleCore", "WapleRender", "WapleSnapshot"],
            swiftSettings: strictConcurrency
        ),
        // 테스트 타깃에는 아직 걸지 않는다. 진단 목록을 먼저 소스에서 소진하고,
        // 그다음 테스트로 넓힌다 — 한 번에 켜면 어느 쪽 경고인지 로그에서 뒤섞인다.
        .testTarget(name: "WapleCoreTests", dependencies: ["WapleCore"]),
        .testTarget(name: "WapleSnapshotTests", dependencies: ["WapleSnapshot"]),
        .testTarget(name: "WapleLibraryTests", dependencies: ["WapleLibrary", "WapleCore"]),
        .testTarget(name: "WapleRenderTests", dependencies: ["WapleRender", "WapleCore"]),
        .testTarget(name: "WapleAppTests", dependencies: ["Waple", "WapleCore", "WapleLibrary", "WapleRender"]),
    ]
)
