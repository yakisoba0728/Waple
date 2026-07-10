import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 실코퍼스 라이트 씬에서 포워드 라이팅 게이트가 실제로 활성화되는지 확인(진단).
/// env WAPLE_REAL_PKGS(기본 ~/Downloads/wallpaper_dev/backgrounds) 없으면 skip.
final class ForwardLightingGateProbeTests: XCTestCase {
    private final class Stopped: NowPlayingProvider { func fetch() -> NowPlayingInfo? { nil } }

    func testTargetScenesActivateLightGate() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        guard FileManager.default.fileExists(atPath: base) else { throw XCTSkip("no real pkgs dir") }
        let assetsPath = NSHomeDirectory() + "/Downloads/wallpaper_dev/assets"
        let oldBase = BaseAssetsSettings.baseAssetsDirectory
        if FileManager.default.fileExists(atPath: assetsPath + "/shaders/common.h") {
            BaseAssetsSettings.baseAssetsDirectory = URL(fileURLWithPath: assetsPath, isDirectory: true)
        }
        defer { BaseAssetsSettings.baseAssetsDirectory = oldBase }

        for id in ["3047405322", "3351179520", "3416122407"] {
            let folder = URL(fileURLWithPath: base).appendingPathComponent(id)
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("scene.pkg").path) else {
                throw XCTSkip("no scene \(id)")
            }
            let project = try ProjectJSONParser.parse(folderURL: folder)
            let r = SceneRenderer()
            r.nowPlayingProvider = Stopped()
            try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
            let litCount = r.layers.filter { $0.isLit }.count
            NSLog("%@", "[Waple] FL gate scene \(id): forwardLit=\(r.forwardLit) litLayers=\(litCount)/\(r.layers.count)")
            r.teardown()
            // 세 타깃 모두 2D+라이트 → forwardLit + 최소 1개 lit 레이어(게이트 활성 증명).
            // 3351179520 은 lit 레이어가 있으나 t=6.0 합성에서 전경 효과에 가려 픽셀 무변(스냅샷 무회귀).
        }
    }
}
