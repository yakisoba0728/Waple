import XCTest
import WebKit
@testable import WapleCore
@testable import WapleRender

/// 실물 웹 배경 전수(env-guarded): mount → 브리지 존재 + 속성 전달 + body 렌더 확인 + 스냅샷 PNG.
final class RealWebGroundTruthTests: XCTestCase {
    func testMatrixWallpaperProbeLoadsWhenAvailable() throws {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let folder = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("2421744801", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path) else {
            throw XCTSkip("no matrix real web wallpaper")
        }
        let project = try ProjectJSONParser.parse(folderURL: folder)
        let result = try loadAndProbe(project: project)
        defer { result.renderer.teardown() }
        XCTAssertTrue(result.ok, "\(project.id): probe=\(result.last)")
    }

    func testMatrixWallpaperHTMLRespondsWithoutPropertiesWhenAvailable() throws {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let sourceFolder = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("2421744801", isDirectory: true)
        let sourceHTML = sourceFolder.appendingPathComponent("matrix_effect.html")
        guard FileManager.default.fileExists(atPath: sourceHTML.path) else {
            throw XCTSkip("no matrix real web wallpaper")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_matrix_no_props_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: sourceHTML, to: dir.appendingPathComponent("matrix_effect.html"))
        try """
        {"type":"web","file":"matrix_effect.html","title":"matrix"}
        """.write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let project = try ProjectJSONParser.parse(folderURL: dir)
        let result = try loadAndProbe(project: project)
        defer { result.renderer.teardown() }
        XCTAssertTrue(result.ok, "no-props probe=\(result.last)")
    }

    func testAllRealWebWallpapersLoad() throws {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        guard FileManager.default.fileExists(atPath: base) else { throw XCTSkip("no real pkgs dir") }
        let folders = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: base), includingPropertiesForKeys: nil)
        let outDir = URL(fileURLWithPath: "/tmp/waple_gt_web")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var tested = 0, failed: [String] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let project = try? ProjectJSONParser.parse(folderURL: folder), project.type == .web else { continue }
            let result: (ok: Bool, last: String, web: WKWebView, renderer: WebRenderer)
            do { result = try loadAndProbe(project: project) } catch { failed.append("\(project.id): \(error)"); continue }
            if result.ok {
                tested += 1
                NSLog("%@", "[WapleGT] web \(project.id): \(result.last)")
                var snapDone = false  // 콜백은 메인 큐 — 세마포어 대기는 교착, RunLoop 스핀으로 대기.
                result.web.takeSnapshot(with: nil) { img, _ in
                    if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: outDir.appendingPathComponent("\(project.id).png"))
                    }
                    snapDone = true
                }
                let snapDeadline = Date(timeIntervalSinceNow: 5)
                while !snapDone, Date() < snapDeadline { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
            } else {
                failed.append("\(project.id): probe=\(result.last)")
            }
            result.renderer.teardown()
        }
        NSLog("%@", "[WapleGT] web ok=\(tested) failed=\(failed)")
        XCTAssertGreaterThan(tested, 0)
        XCTAssertEqual(failed.count, 0, "\(failed)")
    }

    private func loadAndProbe(project: WallpaperProject) throws -> (ok: Bool, last: String, web: WKWebView, renderer: WebRenderer) {
        let r = WebRenderer(mode: .web)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        do { try r.mount(in: container, project: project) } catch { throw error }
        guard let web = container.subviews.compactMap({ $0 as? WKWebView }).first else {
            return (false, "missing-webview", WKWebView(), r)
        }
        // 로드 + 브리지/속성/DOM 확인(최대 10초).
        let probe = """
        JSON.stringify({
          href: location.href,
          ready: document.readyState,
          bridge: typeof window.wallpaperRegisterAudioListener === 'function',
          delivered: window.__waplePropsDelivered === true,
          body: (document.body && document.body.innerHTML.length > 0)
        })
        """
        let deadline = Date(timeIntervalSinceNow: 10)
        var ok = false, last = ""
        var probeInFlight = false
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
            if !probeInFlight {
                probeInFlight = true
                web.evaluateJavaScript(probe) { v, error in
                    if let error {
                        last = "ERROR: \(error)"
                    } else {
                        last = (v as? String) ?? "NONSTRING: \(String(describing: v))"
                    }
                    probeInFlight = false
                }
            }
            if last.contains("\"bridge\":true"), last.contains("\"body\":true") { ok = true; break }
        }
        if last.isEmpty {
            last = "NO_CALLBACK url=\(web.url?.absoluteString ?? "nil") loading=\(web.isLoading)"
        }
        return (ok, last, web, r)
    }
}
