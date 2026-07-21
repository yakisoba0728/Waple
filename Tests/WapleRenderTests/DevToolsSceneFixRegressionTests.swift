import XCTest
import WebKit
@testable import WapleCore
@testable import WapleRender

/// 개발 도구/잔여 그룹(fix-s9) 씬 갭 수정 회귀 테스트.
/// - F680/F681(WapleCompat 실행 타깃 — inventory 공유 에셋 리졸버, deep-scan ogg 시간 예산)은
///   유닛 import 가 불가해 CLI 실측으로 검증한다(3706286085 layers 0→36, ogg skipped 표기).
/// - F682(웹 Page Visibility 스푸핑)는 여기서 실 WKWebView 로 검증한다.
final class DevToolsSceneFixRegressionTests: XCTestCase {

    // MARK: F682 — 브리지 소스 구조(결정론 가드)

    func testBridgeInstallsVisibilitySpoof() {
        let s = WallpaperBridgeJS.source
        XCTAssertTrue(s.contains("spoofedHidden"), "visibility 스푸핑 상태 변수")
        XCTAssertTrue(s.contains("fireVisibilityChange"), "visibilitychange 디스패치")
        XCTAssertTrue(s.contains("webkitVisibilityState"), "레거시 webkit 별칭도 스푸핑")
        // __wapleSetPaused 가 pause 상태를 hidden 으로 매핑하는 배선.
        XCTAssertTrue(s.contains("spoofedHidden = paused"), "pause → hidden 매핑")
    }

    // MARK: F682 — 실 WKWebView: 초기 가시성 + pause/resume 전이

    /// 헤드리스 호스트의 네이티브 document.visibilityState 는 'hidden' 이다(WebHardPauseTests 실측 주석).
    /// WE 는 로드 시 페이지가 visible 이므로, 스푸핑 전이라면 document.hidden==true 가 관측돼 RED.
    func testVisibilitySpoofFollowsPauseState() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_vis_spoof_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = """
        <html><body><script>
        window.__visEvents = [];
        document.addEventListener('visibilitychange', function () {
          window.__visEvents.push(document.hidden);
        });
        </script></body></html>
        """
        try html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try """
        {"type":"web","file":"index.html","title":"vis"}
        """.write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let project = try ProjectJSONParser.parse(folderURL: dir)
        let renderer = WebRenderer(mode: .web)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        try renderer.mount(in: container, project: project)
        defer { renderer.teardown() }
        let web = try XCTUnwrap(renderer.webViewForTesting, "no webview")

        func waitUntil(_ timeout: TimeInterval = 3, _ predicate: () -> Bool) -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline {
                if predicate() { return true }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            return predicate()
        }

        // 브리지 주입 대기(__wapleSetPaused 노출 = 프로덕션 pause 경로 사용 가능).
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "typeof window.__wapleSetPaused") as? String == "function"
        }, "production bridge must install __wapleSetPaused")

        // 초기: WE 처럼 visible 보고(네이티브 헤드리스 hidden 과 무관).
        XCTAssertEqual(pumpEvalJS(web, "document.hidden") as? Bool, false,
                       "initial document.hidden must be spoofed visible (headless native is hidden)")
        XCTAssertEqual(pumpEvalJS(web, "document.visibilityState") as? String, "visible")
        XCTAssertEqual(pumpEvalJS(web, "document.webkitVisibilityState") as? String, "visible")

        // pause(가림/수동정지) → hidden=true + visibilitychange 발화.
        renderer.pause()
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "document.hidden") as? Bool == true
        }, "pause must flip spoofed document.hidden to true")
        XCTAssertEqual(pumpEvalJS(web, "document.visibilityState") as? String, "hidden")
        XCTAssertEqual(pumpEvalJS(web, "JSON.stringify(window.__visEvents)") as? String, "[true]",
                       "visibilitychange must fire exactly once with hidden=true")

        // resume → visible 복귀 + 두 번째 이벤트.
        renderer.resume()
        XCTAssertTrue(waitUntil {
            pumpEvalJS(web, "document.hidden") as? Bool == false
        }, "resume must flip spoofed document.hidden back to false")
        XCTAssertEqual(pumpEvalJS(web, "JSON.stringify(window.__visEvents)") as? String, "[true,false]")
    }
}
