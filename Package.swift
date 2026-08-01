// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Waple",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WapleCore"),
        .target(name: "WapleLibrary", dependencies: ["WapleCore"]),
        .target(
            name: "WapleRender",
            dependencies: ["WapleCore"],
            // WE 2.8.42 공유 에셋 동봉. 워크샵 pkg 가 common_*.h 를 하나도 담지 않아
            // (코퍼스 162개 전수 0건) 이게 없으면 대부분의 씬이 불완전하게 그려진다.
            // 출처·해시는 spec/assets/manifest.json 참조.
            resources: [.copy("Resources/WEAssets")]
        ),
        .target(name: "WapleSnapshot"),   // Foundation-only 순수 코어(스냅샷 매니페스트/diff) — GPU 무의존, 유닛 검증용
        .executableTarget(
            name: "Waple",
            dependencies: ["WapleCore", "WapleLibrary", "WapleRender"]
        ),
        .executableTarget(
            name: "WapleCompat",
            dependencies: ["WapleCore", "WapleRender", "WapleSnapshot"]
        ),
        .testTarget(name: "WapleCoreTests", dependencies: ["WapleCore"]),
        .testTarget(name: "WapleSnapshotTests", dependencies: ["WapleSnapshot"]),
        .testTarget(name: "WapleLibraryTests", dependencies: ["WapleLibrary", "WapleCore"]),
        .testTarget(name: "WapleRenderTests", dependencies: ["WapleRender", "WapleCore"]),
        .testTarget(name: "WapleAppTests", dependencies: ["Waple", "WapleCore", "WapleLibrary", "WapleRender"]),
    ]
)
