import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 단일 실물 씬 프로브(회귀 분리용): WAPLE_PROBE_ID 지정 씬만 마운트+캡처하고 luma 를 로그.
/// GT 전수 대비 빠른 A/B 판정(드리프트 원인 이분). WAPLE_PROBE_ID 미지정 시 skip.
final class SingleSceneProbeTests: XCTestCase {
    func testProbeSingleScene() throws {
        guard let id = ProcessInfo.processInfo.environment["WAPLE_PROBE_ID"] else { throw XCTSkip("set WAPLE_PROBE_ID") }
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let base = NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds"
        let folder = URL(fileURLWithPath: base).appendingPathComponent(id)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw XCTSkip("no scene \(id)") }
        let assetsPath = NSHomeDirectory() + "/Downloads/wallpaper_dev/assets"
        if FileManager.default.fileExists(atPath: assetsPath + "/shaders/common.h") {
            BaseAssetsSettings.baseAssetsDirectory = URL(fileURLWithPath: assetsPath, isDirectory: true)
        }
        let out = URL(fileURLWithPath: "/tmp/waple_probe")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let project = try ProjectJSONParser.parse(folderURL: folder)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360)), project: project)
        let time = Float(ProcessInfo.processInfo.environment["WAPLE_PROBE_TIME"] ?? "") ?? 6.0
        // 골든 대조용 고해상 오버라이드(WAPLE_THUMB_W/H) — 미지정 시 640×360.
        let capW = ProcessInfo.processInfo.environment["WAPLE_THUMB_W"].flatMap(Int.init) ?? 640
        let capH = ProcessInfo.processInfo.environment["WAPLE_THUMB_H"].flatMap(Int.init) ?? 360
        let urls = r.captureFrames(width: capW, height: capH, times: [time], toDir: out)
        for u in urls {
            let tag = ProcessInfo.processInfo.environment["WAPLE_PROBE_TAG"] ?? "probe"
            let dst = out.appendingPathComponent("\(id)_\(tag).png")
            try? FileManager.default.removeItem(at: dst)
            try? FileManager.default.moveItem(at: u, to: dst)
            let l = RealPackagesGroundTruthTests.meanLuma(dst) ?? -1
            NSLog("%@", "[Probe] \(id) luma=\(l) \(dst.path)")
        }
        r.teardown()
    }
}
