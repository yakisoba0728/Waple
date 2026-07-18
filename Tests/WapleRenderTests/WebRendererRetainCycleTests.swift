import XCTest
import WebKit
@testable import WapleCore
@testable import WapleRender

/// F386 회귀 방지: WKUserContentController 는 등록된 메시지 핸들러를 강참조한다(Apple 문서 명시).
/// WebRenderer 가 mount() 에서 자신을 직접 등록(`ucc.add(self, ...)`)하면
/// self → webView → configuration → userContentController → self 순환이 생겨, teardown() 을 명시
/// 호출하지 않는 한(예: 누락된 정리 경로, 크래시 직전 등) `deinit { teardown() }` 안전망 자체가
/// 실행되지 않는다. 아래는 teardown() 을 '호출하지 않고' 유일한 강참조(로컬 변수)만 놓아, 순환이
/// 없다면 ARC 가 즉시 회수함을 직접 관찰한다.
final class WebRendererRetainCycleTests: XCTestCase {
    private func makeProject() throws -> (dir: URL, project: WallpaperProject) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_web_retain_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "<html><body>retain-cycle fixture</body></html>"
            .write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try #"{"type":"web","file":"index.html","title":"retain"}"#
            .write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        return (dir, try ProjectJSONParser.parse(folderURL: dir))
    }

    /// 핵심 회귀 단정: teardown() 을 부르지 않고 유일한 강참조를 내려놓으면 인스턴스가 회수돼야 한다.
    /// self→ucc 순환이 남아 있던 종전 코드였다면 container/webView 가 여전히 스코프 안에 살아 있는
    /// 이 시점에 witness 가 nil 이 되지 않았을 것이다(강한 순환은 teardown() 호출로만 끊겼다).
    func testDeallocatesWithoutExplicitTeardown_whenOnlyStrongReferenceIsDropped() throws {
        let (dir, project) = try makeProject()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        var renderer: WebRenderer? = WebRenderer(mode: .web)
        weak var witness: WebRenderer?
        witness = renderer
        try renderer?.mount(in: container, project: project)
        XCTAssertNotNil(witness, "마운트 직후엔 로컬 강참조가 살아있어 witness 도 살아있어야 한다")

        renderer = nil   // 의도적으로 teardown() 을 호출하지 않는다 — 유일한 외부 강참조만 제거.

        XCTAssertNil(witness, """
            F386: container/webView/userContentController 는 아직 스코프 안에 살아있는데도(강한 순환이 \
            있었다면 self 를 계속 붙잡았을 상황) teardown() 없이 인스턴스가 회수돼야 한다 — \
            ucc 가 self 대신 약한 프록시(WeakScriptMessageHandler)만 강참조하기 때문이다.
            """)
    }

    /// 대조: 정상 teardown() 경로는 종전처럼 계속 동작해야 한다(무회귀) — 명시 teardown 이 ucc 에서
    /// 핸들러를 제거하고 webView 참조도 내려놓으므로, 이 경로는 애초에 프록시 유무와 무관하게 항상
    /// 회수됐다. 그래도 회귀 감시 차원에서 함께 고정한다.
    func testDeallocatesAfterExplicitTeardown() throws {
        let (dir, project) = try makeProject()
        defer { try? FileManager.default.removeItem(at: dir) }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        var renderer: WebRenderer? = WebRenderer(mode: .web)
        weak var witness: WebRenderer?
        witness = renderer
        try renderer?.mount(in: container, project: project)
        renderer?.teardown()
        renderer = nil

        XCTAssertNil(witness, "명시 teardown() 후에는 종전에도 항상 회수됐다(무회귀)")
    }
}
