import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 실측 ground-truth 하네스: 사용자 제공 실제 WE 배경 폴더(기본 ~/Downloads/backgrounds,
/// WAPLE_REAL_PKGS 환경변수로 재지정)를 전수 마운트+캡처한다. 폴더가 없으면 skip — CI 안전.
/// 하드 어서션은 "마운트가 크래시/스로우 없이 되고 PNG 가 나온다"까지만. 효과 번역 성공/폴백 통계는
/// 렌더러의 NSLog 라인(effect via GLSL→MSL translator / translate failed / MSL compile failed / skipped)을
/// 러너 stderr 에서 수집해 판단한다(사람/에이전트가 grep).
final class RealPackagesGroundTruthTests: XCTestCase {
    func testMountAndCaptureAllRealScenes() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/backgrounds")
        let baseURL = URL(fileURLWithPath: base)
        guard FileManager.default.fileExists(atPath: base) else { throw XCTSkip("no real pkgs dir: \(base)") }
        let outDir = URL(fileURLWithPath: "/tmp/waple_gt")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var mounted = 0, captured = 0, failed: [String] = []
        let folders = (try FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil))
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("scene.pkg").path)
                   || FileManager.default.fileExists(atPath: $0.appendingPathComponent("gifscene.pkg").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for folder in folders {
            let id = folder.lastPathComponent
            NSLog("%@", "[WapleGT] ===== scene \(id) =====")
            do {
                let project = try ProjectJSONParser.parse(folderURL: folder)
                let r = SceneRenderer()
                try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360)), project: project)
                mounted += 1
                let urls = r.captureFrames(width: 640, height: 360, times: [0.5], toDir: outDir)
                if let u = urls.first {
                    let dst = outDir.appendingPathComponent("\(id).png")
                    try? FileManager.default.removeItem(at: dst)
                    try? FileManager.default.moveItem(at: u, to: dst)
                    captured += 1
                }
                r.teardown()
            } catch {
                failed.append("\(id): \(error)")
                NSLog("%@", "[WapleGT] mount FAILED \(id): \(error)")
            }
        }
        NSLog("%@", "[WapleGT] SUMMARY mounted=\(mounted)/\(folders.count) captured=\(captured) failed=\(failed)")
        XCTAssertGreaterThan(mounted, 0, "실측 씬이 하나도 마운트되지 않음")
        XCTAssertEqual(failed.count, 0, "mount 실패: \(failed)")
    }
}
