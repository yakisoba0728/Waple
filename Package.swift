// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Waple",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WapleCore"),
        .target(name: "WapleLibrary", dependencies: ["WapleCore"]),
        .target(name: "WapleRender", dependencies: ["WapleCore"]),
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
