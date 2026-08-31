import XCTest
import WebKit
@testable import WapleCore
@testable import WapleRender

/// WE 가 웹 월페이퍼에 **무조건 주입하는 전역**의 존재·의미론 고정.
///
/// 원본 근거는 `bin/webwallpaper64.exe`(imagebase 0x140000000) 의 CEF `OnContextCreated`
/// 0x140013280–0x1400143f7 이다. 여기서 등록되는 네이티브 전역 10개와, 같은 함수 끝에서
/// `CefV8Context::Eval` 로 평가되는 `___STAHP` 스크립트(문자열 파일오프셋 0x119ca0, 5936바이트)가
/// 웹 월페이퍼가 볼 수 있는 표면 전부다. 자세한 전표는 `docs/re/web-wallpaper-bridge.md`.
///
/// 여기서 존재를 못 박는 이유: 없는 전역을 페이지가 부르면 `ReferenceError` 로 **스크립트 하나가
/// 통째로 중단**된다. 도달 수가 0 이어도 존재 자체가 규약이다.
final class WebWallpaperInjectedAPITests: XCTestCase {

    /// 네이티브 등록 전역 10개(0x14001340f·0x1400135a0·0x140013731·0x1400138c2·0x140013a52·
    /// 0x140013be2·0x140013d73·0x140013f04·0x140014097·0x140014226 순).
    func testBridgeDeclaresEveryNativeInjectedGlobal() {
        let s = WallpaperBridgeJS.source
        for name in [
            "wallpaperRegisterAudioListener",
            "wallpaperRegisterMediaPropertiesListener",
            "wallpaperRegisterMediaThumbnailListener",
            "wallpaperRegisterMediaPlaybackListener",
            "wallpaperRegisterMediaTimelineListener",
            "wallpaperRegisterMediaStatusListener",
            "wallpaperGetUtilities",
            "wallpaperRequestRandomFileForProperty",
            "wallpaperOnVideoEnded",
            "wallpaperRequestTakeScreenshotResponse",
        ] {
            XCTAssertTrue(s.contains("'\(name)'"), "WE 네이티브 주입 전역 누락: \(name)")
        }
    }

    /// `___STAHP` 스크립트가 만드는 페이지 가시 전역.
    func testBridgeDeclaresStahpVisibleGlobals() {
        let s = WallpaperBridgeJS.source
        XCTAssertTrue(s.contains("___wpxShared"), "WE ___STAHP 의 onLoad 훅")
        XCTAssertTrue(s.contains("wallpaperMediaIntegration"))
    }

    /// 페이지가 구현하는 `wallpaperPropertyListener` 콜백 5종의 배달 경로가 전부 있어야 한다
    /// (브라우저 프로세스가 만드는 JS 원문: 0x140019a16 applyUserProperties,
    ///  0x140020764 applyGeneralProperties, 0x140020240 setPaused,
    ///  0x140009ccb userDirectoryFilesAddedOrChanged, 0x14000a128 userDirectoryFilesRemoved).
    func testBridgeDeliversEveryPropertyListenerCallback() {
        let s = WallpaperBridgeJS.source
        for name in ["applyUserProperties", "applyGeneralProperties", "setPaused",
                     "userDirectoryFilesAddedOrChanged", "userDirectoryFilesRemoved"] {
            XCTAssertTrue(s.contains("listener.\(name)"), "리스너 콜백 배달 경로 누락: \(name)")
        }
    }

    /// WE 동영상 래퍼(주입 원문 @0x1198f0)의 복구·종료 훅.
    func testVideoFallbackMirrorsWEWrapperHooks() {
        let html = VideoFallbackHTML.html(forVideoFile: "clip.webm")
        XCTAssertTrue(html.contains("v.onerror"), "WE 원문의 src 재설정 복구 훅")
        XCTAssertTrue(html.contains("v.onended"))
        XCTAssertTrue(html.contains("wallpaperOnVideoEnded"))
    }

    // MARK: - 실런타임(WKWebView)

    /// 실제 주입 경로에서 새 전역이 살아 있고 값이 WE 와 같은지.
    /// (브리지는 waple-asset 오리진 가드가 있어 `loadHTMLString` 으로는 안 켜진다 — mount 경로 사용.)
    func testInjectedGlobalsAreLiveInWebView() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_injected_api_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "<html><body>ok</body></html>"
            .write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try #"{"type":"web","file":"index.html","title":"api"}"#
            .write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let project = try ProjectJSONParser.parse(folderURL: dir)
        let renderer = WebRenderer(mode: .web)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        try renderer.mount(in: container, project: project)
        defer { renderer.teardown() }
        let web = try XCTUnwrap(renderer.webViewForTesting)

        var ready = false
        let deadline = Date(timeIntervalSinceNow: 5)
        while !ready, Date() < deadline {
            ready = pumpEvalJS(web, "typeof window.wallpaperGetUtilities === 'function'") as? Bool == true
        }
        XCTAssertTrue(ready, "브리지 주입 실패")

        XCTAssertEqual(pumpEvalJS(web, "window.wallpaperGetUtilities().isWallpaper()") as? Bool, true)
        XCTAssertEqual(pumpEvalJS(web, "window.wallpaperGetUtilities().isScreensaver()") as? Bool, false,
                       "Waple 은 스크린세이버 모드가 없다")
        XCTAssertEqual(pumpEvalJS(web, "typeof window.wallpaperOnVideoEnded") as? String, "function")
        XCTAssertEqual(pumpEvalJS(web, "typeof window.wallpaperRequestTakeScreenshotResponse") as? String,
                       "function")
        XCTAssertEqual(pumpEvalJS(web, "typeof window.___wpxShared.onLoad") as? String, "function")

        // applyGeneralProperties 는 WE 처럼 language 를 담아야 한다(0x1400206d9).
        _ = pumpEvalJS(web, """
        window.__lastGeneral = null;
        window.wallpaperPropertyListener = { applyGeneralProperties: function (g) { window.__lastGeneral = g; } };
        window.__wapleApplyProps({}, { fps: 30 });
        """)
        XCTAssertEqual(pumpEvalJS(web, "typeof window.__lastGeneral.language") as? String, "string")
        XCTAssertEqual(pumpEvalJS(web, "window.__lastGeneral.fps") as? Int, 30)

        // 삭제 통지도 배달돼야 한다(0x14000a128 의 대칭).
        _ = pumpEvalJS(web, """
        window.__removed = null;
        window.wallpaperPropertyListener = {
          userDirectoryFilesRemoved: function (n, f) { window.__removed = n + ':' + f.join(','); }
        };
        window.__wapleDirectoryFilesRemoved('userdir', ['a.png', 'b.png']);
        """)
        XCTAssertEqual(pumpEvalJS(web, "window.__removed") as? String, "userdir:a.png,b.png")
    }
}

/// zcompat 호환성 패치가 **스킴 핸들러 응답에 실제로 반영되는지**.
/// 스키마·치환 규칙 자체의 고정은 `WapleCoreTests/WebCompatPatchTests`(리눅스 레인)에 있다.
@MainActor
final class WallpaperSchemeHandlerCompatPatchTests: XCTestCase {

    /// 동봉 `zcompat/web/780658164.json` 의 액션이 걸린 파일은 패치된 본문으로 서빙돼야 한다.
    func testPatchedFileIsServedRewritten() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_zcompat_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("js"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("js/index.min.js")
        try "function u(t,e){t.texImage2D(3553,0,e);}".write(to: target, atomically: true, encoding: .utf8)

        let patches = WebCompatPatch.PatchSet(actions: [
            .init(file: "js/index.min.js",
                  replace: "u(t,e){t.texImage2D",
                  insert: "u(t,e){if(e!=null)t.texImage2D")
        ])
        let handler = WallpaperSchemeHandler(rootURL: dir, compatPatches: patches)
        let body = try XCTUnwrap(schemeBody(handler, path: "/js/index.min.js"))
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       "function u(t,e){if(e!=null)t.texImage2D(3553,0,e);}")

        // 디스크는 그대로여야 한다 — WE 와 달리 Waple 은 사용자 파일을 덮어쓰지 않는다.
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8),
                       "function u(t,e){t.texImage2D(3553,0,e);}")
    }

    /// 액션이 없는 파일은 종전 스트리밍 경로 그대로(무회귀).
    func testUnpatchedFileIsUntouched() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_zcompat_pass_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "u(t,e){t.texImage2D}".write(to: dir.appendingPathComponent("other.js"),
                                         atomically: true, encoding: .utf8)
        let patches = WebCompatPatch.PatchSet(actions: [
            .init(file: "js/index.min.js", replace: "u(t,e){t.texImage2D",
                  insert: "u(t,e){if(e!=null)t.texImage2D")
        ])
        let handler = WallpaperSchemeHandler(rootURL: dir, compatPatches: patches)
        let body = try XCTUnwrap(schemeBody(handler, path: "/other.js"))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "u(t,e){t.texImage2D}")
    }

    /// 스킴 태스크를 흉내 내 본문 바이트를 모은다.
    private func schemeBody(_ handler: WallpaperSchemeHandler, path: String) -> Data? {
        let url = URL(string: "\(WallpaperSchemeHandler.scheme)://\(WallpaperSchemeHandler.host)\(path)")!
        let task = FakeSchemeTask(request: URLRequest(url: url))
        handler.webView(WKWebView(), start: task)
        let deadline = Date(timeIntervalSinceNow: 3)
        while !task.finished, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return task.finished ? task.body : nil
    }
}

/// `WKURLSchemeTask` 스텁. 테스트 룰룹의 완료 관찰과 콜백 상태 갱신을 락으로 지킨다.
private final class FakeSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    private let lock = NSLock()
    private var _body = Data()
    private var _finished = false

    init(request: URLRequest) { self.request = request }

    var body: Data { lock.lock(); defer { lock.unlock() }; return _body }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }

    func didReceive(_ response: URLResponse) {}
    func didReceive(_ data: Data) { lock.lock(); _body.append(data); lock.unlock() }
    func didFinish() { lock.lock(); _finished = true; lock.unlock() }
    func didFailWithError(_ error: any Error) { lock.lock(); _finished = true; lock.unlock() }
}
