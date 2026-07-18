import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 3D v3 개발용 시각 캡처 하네스(에이전트 자가판정). 실물 3D 씬을 지정 시점들에서 캡처해
/// /tmp/waple_3dv3/<scene>_t<..>.png 로 저장한다. WAPLE_3DV3=1 일 때만 동작(평소 skip).
/// 판정: 젤다 캐릭터 애니(두 시점 차이), 솔라 플레어(additive), 소닉 카메라.
final class ThreeDV3CaptureTests: XCTestCase {
    func testCapture3DScenes() throws {
        guard ProcessInfo.processInfo.environment["WAPLE_3DV3"] == "1" else { throw XCTSkip("set WAPLE_3DV3=1") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let base = NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds"
        guard FileManager.default.fileExists(atPath: base) else { throw XCTSkip("no real pkgs") }
        let assetsPath = NSHomeDirectory() + "/Downloads/wallpaper_dev/assets"
        // F409: BaseAssetsSettings.baseAssetsDirectory 는 UserDefaults.standard 에 영속되는 프로세스
        // 전역 static — 복원 없이 바꾸면 개발자 실앱 설정에 영구 기록되고 동일 프로세스(swift test)의
        // 후속 테스트로 누수된다. 형제 하네스(RealPackagesGroundTruthTests/ForwardLightingGateProbeTests)
        // 는 이미 oldBase 저장+defer 복원을 쓴다 — 이 테스트만 비대칭이었다.
        let oldBase = BaseAssetsSettings.baseAssetsDirectory
        defer { BaseAssetsSettings.baseAssetsDirectory = oldBase }
        if FileManager.default.fileExists(atPath: assetsPath + "/shaders/common.h") {
            BaseAssetsSettings.baseAssetsDirectory = URL(fileURLWithPath: assetsPath, isDirectory: true)
        }
        let out = URL(fileURLWithPath: "/tmp/waple_3dv3")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let tag = ProcessInfo.processInfo.environment["WAPLE_3DV3_TAG"] ?? ""
        // scene id → capture times
        let scenes: [(String, [Float])] = [
            ("3737268876", [0.0, 0.5, 1.0, 1.5]),   // zelda: 스킨 애니 시점차
            ("3662790108", [0.5]),                   // solar: 플레어 additive
            ("3706286085", [0.0, 1.0]),              // sonic: 카메라
        ]
        for (id, times) in scenes {
            let folder = URL(fileURLWithPath: base).appendingPathComponent(id)
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("scene.pkg").path) else { continue }
            do {
                let project = try ProjectJSONParser.parse(folderURL: folder)
                let r = SceneRenderer()
                try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720)), project: project)
                let urls = r.captureFrames(width: 1280, height: 720, times: times, toDir: out)
                for u in urls {
                    let name = "\(id)\(tag.isEmpty ? "" : "_" + tag)_\(u.lastPathComponent)"
                    let dst = out.appendingPathComponent(name)
                    try? FileManager.default.removeItem(at: dst)
                    try? FileManager.default.moveItem(at: u, to: dst)
                    NSLog("%@", "[3DV3] \(dst.path)")
                }
                r.teardown()
            } catch {
                NSLog("%@", "[3DV3] \(id) FAILED: \(error)")
            }
        }
    }
}
