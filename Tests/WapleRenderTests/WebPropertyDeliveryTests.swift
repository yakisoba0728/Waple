import XCTest
import WebKit
@testable import WapleCore
@testable import WapleRender

/// WE 의미론: wallpaperPropertyListener 를 **문서 로드 후(async)에 등록해도** 속성을 받아야 한다.
/// (WE 는 등록 즉시 전달; 현 구현은 didFinish 1회 직접 호출이라 늦은 등록이 유실 — RED 재현.)
final class WebPropertyDeliveryTests: XCTestCase {
    override func tearDown() {
        UserPropertyStore.reset(id: "waple_web_reload")
        super.tearDown()
    }

    func testLateRegisteredListenerReceivesProperties() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_web_late", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let html = """
        <html><body><script>
        window.__got = null;
        setTimeout(function() {
          window.wallpaperPropertyListener = {
            applyUserProperties: function(p) { window.__got = p; }
          };
        }, 300);
        </script></body></html>
        """
        try html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let projectJSON = """
        {"type":"web","file":"index.html","title":"late","general":{"properties":{"speed":{"type":"slider","value":7}}}}
        """
        try projectJSON.write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let project = try ProjectJSONParser.parse(folderURL: dir)
        let r = WebRenderer(mode: .web)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        try r.mount(in: container, project: project)
        defer { r.teardown() }
        guard let web = container.subviews.compactMap({ $0 as? WKWebView }).first else {
            XCTFail("no webview"); return
        }
        // 리스너는 300ms 후 등록 — 그 뒤에도 속성이 도착해야 한다(최대 5초 폴링).
        let deadline = Date(timeIntervalSinceNow: 5)
        var got: Any? = nil
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            let sem = DispatchSemaphore(value: 0)
            web.evaluateJavaScript("JSON.stringify(window.__got)") { v, _ in got = v; sem.signal() }
            _ = sem.wait(timeout: .now() + 1)
            if let s = got as? String, s != "null" { break }
        }
        let s = try XCTUnwrap(got as? String)
        XCTAssertTrue(s.contains("speed"), "늦게 등록한 리스너가 속성을 받아야: \(s)")
        XCTAssertTrue(s.contains("7"), s)
    }

    func testReloadReceivesSavedUserPropertiesAgain() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_web_reload", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        UserPropertyStore.set(.number(11), key: "speed", id: dir.lastPathComponent)
        let html = """
        <html><body><script>
        window.__propsSeen = Number(sessionStorage.getItem('propsSeen') || '0');
        window.__lastSpeed = Number(sessionStorage.getItem('lastSpeed') || '0');
        window.wallpaperPropertyListener = {
          applyUserProperties: function(p) {
            if (p.speed) {
              var seen = Number(sessionStorage.getItem('propsSeen') || '0') + 1;
              sessionStorage.setItem('propsSeen', String(seen));
              sessionStorage.setItem('lastSpeed', String(p.speed.value));
              window.__propsSeen = seen;
              window.__lastSpeed = p.speed.value;
              if (sessionStorage.getItem('didReload') !== '1') {
                sessionStorage.setItem('didReload', '1');
                setTimeout(function() { window.location.reload(); }, 0);
              }
            }
          }
        };
        </script></body></html>
        """
        try html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let projectJSON = """
        {"type":"web","file":"index.html","title":"reload","general":{"properties":{"speed":{"type":"slider","value":7}}}}
        """
        try projectJSON.write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let project = try ProjectJSONParser.parse(folderURL: dir)
        let renderer = WebRenderer(mode: .web)
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { renderer.teardown() }

        let got = try waitForJSON(renderer.webViewForTesting, script: """
        JSON.stringify({
          seen: Number(sessionStorage.getItem('propsSeen') || '0'),
          lastSpeed: Number(sessionStorage.getItem('lastSpeed') || '0'),
          didReload: sessionStorage.getItem('didReload') === '1'
        })
        """) { obj in
            (obj["seen"] as? Int ?? 0) >= 2
        }
        XCTAssertEqual(got["seen"] as? Int, 2)
        XCTAssertEqual(got["lastSpeed"] as? Int, 11)
        XCTAssertEqual(got["didReload"] as? Bool, true)
    }

    func testSameOriginFrameReceivesBridgeAndProperties() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_web_frame_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        <html><body><iframe id="child" src="child.html"></iframe></body></html>
        """.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try """
        <html><body><script>
        window.__hasBridge = typeof window.wallpaperRequestRandomFileForProperty === 'function';
        window.__childGot = null;
        window.wallpaperPropertyListener = {
          applyUserProperties: function(p) { window.__childGot = p.speed && p.speed.value; }
        };
        </script></body></html>
        """.write(to: dir.appendingPathComponent("child.html"), atomically: true, encoding: .utf8)
        try """
        {"type":"web","file":"index.html","title":"frame","general":{"properties":{"speed":{"type":"slider","value":7}}}}
        """.write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let project = try ProjectJSONParser.parse(folderURL: dir)
        let renderer = WebRenderer(mode: .web)
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { renderer.teardown() }

        let got = try waitForJSON(renderer.webViewForTesting, script: """
        JSON.stringify((function() {
          var frame = document.getElementById('child');
          var w = frame && frame.contentWindow;
          return { hasBridge: !!(w && w.__hasBridge), childGot: w && w.__childGot };
        })())
        """) { obj in
            (obj["hasBridge"] as? Bool) == true && (obj["childGot"] as? Int) == 7
        }
        XCTAssertEqual(got["hasBridge"] as? Bool, true)
        XCTAssertEqual(got["childGot"] as? Int, 7)
    }

    func testRandomFileRequestCallsBackWithContainedDirectoryFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_web_random_\(UUID().uuidString)", isDirectory: true)
        let assets = dir.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let expected = assets.appendingPathComponent("only.txt")
        let expectedPath = expected.resolvingSymlinksInPath().path
        try "ok".write(to: expected, atomically: true, encoding: .utf8)
        try? FileManager.default.createSymbolicLink(at: assets.appendingPathComponent("escape.txt"),
                                                    withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))
        let html = """
        <html><body><script>
        window.__random = null;
        window.wallpaperRequestRandomFileForProperty('images', function(name, filePath) {
          window.__random = { name: name, filePath: filePath };
        });
        </script></body></html>
        """
        try html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let projectJSON = """
        {"type":"web","file":"index.html","title":"random","general":{"properties":{"images":{"type":"directory","value":"assets"}}}}
        """
        try projectJSON.write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let project = try ProjectJSONParser.parse(folderURL: dir)
        let renderer = WebRenderer(mode: .web)
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { renderer.teardown() }

        let got = try waitForJSON(renderer.webViewForTesting, script: "JSON.stringify(window.__random)") { obj in
            obj["filePath"] as? String == expectedPath
        }
        XCTAssertEqual(got["name"] as? String, "images")
        XCTAssertEqual(got["filePath"] as? String, expectedPath)
        XCTAssertTrue(WallpaperPathSecurity.contains(URL(fileURLWithPath: got["filePath"] as? String ?? ""),
                                                     in: dir.resolvingSymlinksInPath()))
    }

    func testRandomFileRequestCallsBackForContainedFileProperty() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_web_file_\(UUID().uuidString)", isDirectory: true)
        let assets = dir.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let expected = assets.appendingPathComponent("picked.txt")
        let expectedPath = expected.resolvingSymlinksInPath().path
        try "ok".write(to: expected, atomically: true, encoding: .utf8)
        let html = """
        <html><body><script>
        window.__random = null;
        window.wallpaperRequestRandomFileForProperty('single', function(name, filePath) {
          window.__random = { name: name, filePath: filePath };
        });
        </script></body></html>
        """
        try html.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let projectJSON = """
        {"type":"web","file":"index.html","title":"file","general":{"properties":{"single":{"type":"file","value":"assets/picked.txt"}}}}
        """
        try projectJSON.write(to: dir.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let project = try ProjectJSONParser.parse(folderURL: dir)
        let renderer = WebRenderer(mode: .web)
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { renderer.teardown() }

        let got = try waitForJSON(renderer.webViewForTesting, script: "JSON.stringify(window.__random)") { obj in
            obj["filePath"] as? String == expectedPath
        }
        XCTAssertEqual(got["name"] as? String, "single")
        XCTAssertEqual(got["filePath"] as? String, expectedPath)
    }

    private func waitForJSON(_ web: WKWebView?, script: String,
                             timeout: TimeInterval = 5,
                             until predicate: ([String: Any]) -> Bool) throws -> [String: Any] {
        let web = try XCTUnwrap(web)
        let deadline = Date(timeIntervalSinceNow: timeout)
        var last: [String: Any] = [:]
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            let sem = DispatchSemaphore(value: 0)
            web.evaluateJavaScript(script) { value, _ in
                if let string = value as? String,
                   let data = string.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    last = obj
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 1)
            if predicate(last) { return last }
        }
        return last
    }
}
