// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Waple",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "WapleCore"),
        .target(name: "WapleLibrary", dependencies: ["WapleCore"]),
        .target(name: "WapleRender", dependencies: ["WapleCore"]),
        .executableTarget(
            name: "Waple",
            dependencies: ["WapleCore", "WapleLibrary", "WapleRender"]
        ),
        .executableTarget(
            name: "WapleCompat",
            dependencies: ["WapleCore", "WapleRender"]
        ),
        .testTarget(name: "WapleCoreTests", dependencies: ["WapleCore"]),
        .testTarget(name: "WapleLibraryTests", dependencies: ["WapleLibrary", "WapleCore"]),
        .testTarget(name: "WapleRenderTests", dependencies: ["WapleRender", "WapleCore"]),
        .testTarget(name: "WapleAppTests", dependencies: ["Waple", "WapleCore", "WapleLibrary", "WapleRender"]),
    ]
)
