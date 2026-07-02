import XCTest
import WebKit
@testable import WapleCore
@testable import WapleRender

/// 실물 웹 배경 전수(env-guarded): mount → 브리지 존재 + 속성 전달 + body 렌더 확인 + 스냅샷 PNG.
final class RealWebGroundTruthTests: XCTestCase {
    func testAllRealWebWallpapersLoad() throws {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/backgrounds")
        guard FileManager.default.fileExists(atPath: base) else { throw XCTSkip("no real pkgs dir") }
        let folders = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: base), includingPropertiesForKeys: nil)
        let outDir = URL(fileURLWithPath: "/tmp/waple_gt_web")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var tested = 0, failed: [String] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let project = try? ProjectJSONParser.parse(folderURL: folder), project.type == .web else { continue }
            let r = WebRenderer(mode: .web)
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
            do { try r.mount(in: container, project: project) } catch { failed.append("\(project.id): \(error)"); continue }
            guard let web = container.subviews.compactMap({ $0 as? WKWebView }).first else { failed.append(project.id); continue }
            // 로드 + 브리지/속성/DOM 확인(최대 10초).
            let probe = """
            JSON.stringify({
              bridge: typeof window.wallpaperRegisterAudioListener === 'function',
              delivered: window.__waplePropsDelivered === true,
              body: (document.body && document.body.innerHTML.length > 0)
            })
            """
            let deadline = Date(timeIntervalSinceNow: 10)
            var ok = false, last = ""
            while Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
                let sem = DispatchSemaphore(value: 0)
                web.evaluateJavaScript(probe) { v, _ in last = (v as? String) ?? ""; sem.signal() }
                _ = sem.wait(timeout: .now() + 1)
                if last.contains("\"bridge\":true"), last.contains("\"body\":true") { ok = true; break }
            }
            if ok {
                tested += 1
                NSLog("%@", "[WapleGT] web \(project.id): \(last)")
                var snapDone = false  // 콜백은 메인 큐 — 세마포어 대기는 교착, RunLoop 스핀으로 대기.
                web.takeSnapshot(with: nil) { img, _ in
                    if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: outDir.appendingPathComponent("\(project.id).png"))
                    }
                    snapDone = true
                }
                let snapDeadline = Date(timeIntervalSinceNow: 5)
                while !snapDone, Date() < snapDeadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
            } else {
                failed.append("\(project.id): probe=\(last)")
            }
            r.teardown()
        }
        NSLog("%@", "[WapleGT] web ok=\(tested) failed=\(failed)")
        XCTAssertGreaterThan(tested, 0)
        XCTAssertEqual(failed.count, 0, "\(failed)")
    }
}
