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

    /// 실물 웹 배경(matrix, setInterval 기반)에 프로덕션 pause 경로를 관통시켜 hard pause 실동작 검증.
    /// renderer.pause() → __wapleSetPaused(WallpaperBridgeJS) → __wapleHardPauseController.setPaused(565줄)
    /// 배선을 실 WKWebView 에서 확인한다. 헤드리스 호스트는 visibilityState==hidden(디스플레이/컴포지터
    /// 없음) → 실 rAF/CSS 모션은 전진하지 않으므로, 관측 가능한 타이머 동결/재개 + pause 중 스케줄
    /// 미발화 + CSS 정지 클래스 구조만 채점하고, 모션 전진 검증은 WebHardPauseTests(결정론 프리루드)에 위임.
    func testRealWebHardPauseFreezesSchedulersWhenAvailable() throws {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let folder = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("2421744801", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path) else {
            throw XCTSkip("no matrix real web wallpaper")
        }
        let project = try ProjectJSONParser.parse(folderURL: folder)
        let result = try loadAndProbe(project: project)
        defer { result.renderer.teardown() }
        XCTAssertTrue(result.ok, "\(project.id): mount probe=\(result.last)")
        let web = result.web

        func waitUntil(_ timeout: TimeInterval = 3, _ predicate: () -> Bool) -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline {
                if predicate() { return true }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            return predicate()
        }

        // 프로덕션 분기 확정: WallpaperBridgeJS 가 __wapleSetPaused 를 노출 → setPausedJS 는 폴백이 아닌
        // 이 경로를 탄다(→ setHardPaused → __wapleHardPauseController). 실 페이지에 브리지가 실제로
        // 실렸는지를 못박아 "프로덕션 경로" 주장을 확실히 한다.
        XCTAssertEqual(pumpEvalJS(web, "typeof window.__wapleSetPaused") as? String, "function",
                       "production bridge must expose __wapleSetPaused so pause routes through it, not the fallback")

        // 헤드리스 호스트 특성 기록(동결 검증의 신뢰성 게이트). 타이머는 돎, rAF/CSS 모션은 미전진 예상.
        let visibility = pumpEvalJS(web, "document.visibilityState") as? String ?? "?"
        _ = pumpEvalJS(web, """
        window.__probe = { interval: 0, rafBaseline: 0 };
        window.__probeInterval = setInterval(function () { window.__probe.interval += 1; }, 40);
        requestAnimationFrame(function () { window.__probe.rafBaseline += 1; });
        """)
        // 주입 setInterval 이 실제 발화해야 동결 검증이 의미를 갖는다(헤드리스에서 타이머는 돌아야 함).
        XCTAssertTrue(waitUntil { (pumpEvalJS(web, "window.__probe.interval") as? Int ?? 0) >= 2 },
                      "setInterval must fire in headless host to make freeze test meaningful (visibility=\(visibility))")

        // 헤드리스 특성 실측 진단(보고용): visibilityState 와 pause 전 스케줄한 baseline rAF 발화 여부.
        NSLog("%@", "[WapleWebPauseProbe] visibility=\(visibility) " +
              "rafBaselineFired=\(pumpEvalJS(web, "window.__probe.rafBaseline") as? Int ?? -1) " +
              "intervalBeforePause=\(pumpEvalJS(web, "window.__probe.interval") as? Int ?? -1)")

        // 프로덕션 경로로 정지: renderer.pause() → __wapleSetPaused → hard pause controller.
        result.renderer.pause()
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "!!window.__wapleHardPauseController && window.__wapleHardPauseController.isPaused()") as? Bool == true
        }, "production __wapleSetPaused path must engage the hard pause controller")

        let frozen = pumpEvalJS(web, "window.__probe.interval") as? Int ?? -1
        _ = pumpEvalJS(web, """
        window.__probe.pausedRAF = 0; window.__probe.pausedInterval = 0;
        requestAnimationFrame(function () { window.__probe.pausedRAF += 1; });
        setInterval(function () { window.__probe.pausedInterval += 1; }, 40);
        """)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.30))
        XCTAssertEqual(pumpEvalJS(web, "window.__probe.interval") as? Int, frozen,
                       "existing setInterval must freeze under hard pause")
        XCTAssertEqual(pumpEvalJS(web, "window.__probe.pausedInterval") as? Int, 0,
                       "setInterval scheduled while paused must not fire")
        // 주의: rAF 는 헤드리스(visibilityState=hidden)에서 pause 여부와 무관하게 미발화(rafBaselineFired=0).
        // 따라서 이 assert 는 판별력이 약하다(app-host 에서만 유의미) — 유지하되 실 rAF 후킹의 행동 검증은
        // testSchedulersFreezeAndResumeExactlyOnce(프리루드가 rAF→setTimeout 스왑)에 귀속한다.
        XCTAssertEqual(pumpEvalJS(web, "window.__probe.pausedRAF") as? Int, 0,
                       "rAF scheduled while paused must not fire (weak headless; strong signal is app-host)")
        // CSS/WAAPI 정지 메커니즘 — 모션은 헤드리스 미관측이라 구조만 채점.
        XCTAssertEqual(pumpEvalJS(web, "document.documentElement.classList.contains('__waple-hard-paused')") as? Bool, true,
                       "hard pause must apply the CSS animation-play-state freeze class")

        // 재개: 기존 interval 재발화 + 정지 클래스 해제.
        result.renderer.resume()
        XCTAssertTrue(waitUntil { (pumpEvalJS(web, "window.__probe.interval") as? Int ?? 0) > frozen },
                      "setInterval must resume after hard pause release")
        XCTAssertEqual(pumpEvalJS(web, "document.documentElement.classList.contains('__waple-hard-paused')") as? Bool, false,
                       "resume must remove the CSS freeze class")
    }

    /// 실물 웹 배경(2830814490, 엔트리에 <video muted autoplay loop src='./pv.webm'>)의 실제
    /// DOM <video> 에 프로덕션 경로(renderer.pause/resume → __wapleSetPaused → hard pause
    /// controller)로 HTMLMediaElement 하드정지를 검증. 실측 제약: WKURLSchemeHandler 경유
    /// 미디어는 소스 선택이 실패해(networkState=NO_SOURCE, webm MIME 미등록 + Range 미지원)
    /// 재생 프레임/currentTime 전진은 이 환경에서 관측 불가 — HTMLMediaElement 의 paused
    /// 속성은 소스와 무관하게 play()/pause() 로 동기 전이(스펙)하므로 실물 DOM 에 play() 를
    /// 걸어 정지→유지→재개 의미론을 채점하고, currentTime 동결/전진 검증은
    /// WebHardPauseTests(src 없는 미디어 유닛)와 동일 근거에 위임한다.
    func testRealWebHardPauseFreezesVideoElementWhenAvailable() throws {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let folder = URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent("2830814490", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path) else {
            throw XCTSkip("no video-bearing real web wallpaper")
        }
        let project = try ProjectJSONParser.parse(folderURL: folder)
        let result = try loadAndProbe(project: project)
        defer { result.renderer.teardown() }
        XCTAssertTrue(result.ok, "\(project.id): mount probe=\(result.last)")
        let web = result.web

        func waitUntil(_ timeout: TimeInterval = 5, _ predicate: () -> Bool) -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline {
                if predicate() { return true }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            return predicate()
        }

        // 실물 DOM 의 <video> 를 재생 상태로 만든다(소스 로드 실패 환경에서도 paused 는 false 로 전이).
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, """
            (function () {
              var v = document.querySelector('video');
              if (!v) { return false; }
              if (v.paused) { v.play().catch(function () {}); }
              return !v.paused;
            })()
            """) as? Bool == true
        }, "real page <video> must report playing before the freeze test")

        result.renderer.pause()
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "document.querySelector('video').paused") as? Bool == true
        }, "production pause path must pause the playing real-page <video>")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.30))
        XCTAssertEqual(
            pumpEvalJS(web, "document.querySelector('video').paused") as? Bool, true,
            "real-page <video> must stay paused for the whole hard pause"
        )

        result.renderer.resume()
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "document.querySelector('video').paused") as? Bool == false
        }, "resume must replay the real-page <video> Waple paused")
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
