import XCTest
import WebKit
import Metal
@testable import WapleCore
@testable import WapleRender

@MainActor
final class Audit2DWebRegressionTests: XCTestCase {
    private enum Failure: Error { case timeout }

    private func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple-audit-2d-web-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func evaluate(_ script: String, in web: WKWebView) throws -> Any? {
        let completed = expectation(description: "JavaScript response")
        var result: Any?
        var failure: Error?
        web.evaluateJavaScript(script) { value, error in
            result = value
            failure = error
            completed.fulfill()
        }
        wait(for: [completed], timeout: 3)
        if let failure { throw failure }
        return result
    }

    private func waitForJavaScript(_ predicate: String, in web: WKWebView) throws {
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if (try? evaluate(predicate, in: web)) as? Bool == true { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        XCTFail("JavaScript condition timed out: \(predicate)")
        throw Failure.timeout
    }

    func testDynamicEffectUniformsUseSnapshotAndBothArtworkSizes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 auditVertex(uint i [[vertex_id]]) { return float4(0, 0, 0, 1); }
        fragment float4 auditFragment() { return float4(1); }
        """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "auditVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "auditFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        func texture(_ width: Int, _ height: Int) throws -> MTLTexture {
            try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)))
        }
        let fallback = try texture(1, 1)
        let source = try texture(8, 4)
        let snapshot = try texture(32, 16)
        let artwork = try texture(48, 24)
        let previous = try texture(64, 32)
        let pass = SceneRenderer.TranslatedPass(
            pipeline: pipeline, material: [], aux: [(1, fallback), (2, fallback), (3, fallback)],
            binds: [(0, -1)], target: nil, compose: false, usesAudio: false,
            texRes: Array(repeating: SIMD4<Float>(1, 1, 1, 1), count: 8),
            texWrap: [], texFilter: [], fullFrameSlots: [1], swapPair: nil,
            mediaArtworkSlots: [(2, false), (3, true)])
        let renderer = SceneRenderer()
        renderer.mediaArtworkTexture = artwork
        renderer.mediaPreviousArtworkTexture = previous
        let overrides = renderer.dynamicEffectTextures(for: pass, fullFrameSnapshot: snapshot)
        XCTAssertTrue(overrides.first { $0.slot == 1 }?.tex === snapshot)
        XCTAssertTrue(overrides.first { $0.slot == 2 }?.tex === artwork)
        XCTAssertTrue(overrides.first { $0.slot == 3 }?.tex === previous)
        let resolutions = renderer.runtimeTexRes(for: pass, src: source, fboTex: [], overrides: overrides)
        XCTAssertEqual(resolutions[0], SIMD4(8, 4, 8, 4))
        XCTAssertEqual(resolutions[1], SIMD4(32, 16, 32, 16))
        XCTAssertEqual(resolutions[2], SIMD4(48, 24, 48, 24))
        XCTAssertEqual(resolutions[3], SIMD4(64, 32, 64, 32))
        let uniform = renderer.engineUniform(time: 0, texRes: resolutions, targetRes: SIMD4(8, 4, 8, 4))
        XCTAssertEqual(Array(uniform[28..<32]), [32, 16, 32, 16])
        XCTAssertEqual(Array(uniform[32..<36]), [48, 24, 48, 24])
        XCTAssertEqual(Array(uniform[36..<40]), [64, 32, 64, 32])

        renderer.mediaArtworkTexture = nil
        renderer.mediaPreviousArtworkTexture = nil
        let missing = renderer.dynamicEffectTextures(for: pass, fullFrameSnapshot: nil)
        XCTAssertTrue(missing.isEmpty)
        XCTAssertEqual(renderer.runtimeTexRes(for: pass, src: source, fboTex: [], overrides: missing)[1],
                       SIMD4(1, 1, 1, 1), "missing live input retains the static fallback")
    }

    func testManyBlendTextsReuseSnapshotAndPreserveDifferencePixels() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var objects = [#"{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080"}"#]
        for index in 0..<7 {
            objects.append("""
            {"id":\(index + 2),"text":"HELLO","font":"systemfont_arial","pointsize":300,
             "color":"1 0 0","alpha":1,"horizontalalign":"center","verticalalign":"center",
             "origin":"960 540 0","size":"1 1","colorBlendMode":18}
            """)
        }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[\(objects.joined(separator: ","))]}
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/w.json", Data(#"{"material":"materials/w.json"}"#.utf8)),
            ("materials/w.json", Data(#"{"passes":[{"textures":["w"]}]}"#.utf8)),
            ("materials/w.tex", solidTex(255, 255, 255))
        ]
        try encodePkg(files).write(to: directory.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: UUID().uuidString, type: .scene, fileName: "scene.pkg",
            previewName: nil, title: "blend texts", tags: [], contentRating: nil,
            workshopId: nil, dependency: nil, folderURL: directory)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 128, height: 72)), project: project)
        defer { renderer.teardown() }
        let capture = try XCTUnwrap(renderer.captureFrames(width: 128, height: 72, times: [0.1],
                                                          toDir: directory).first)
        XCTAssertFalse(renderer.texturePool.keys.contains { $0.hasPrefix("b") || $0.hasPrefix("h") },
                       "text blending must not retain one full-frame pooled texture per text")
        let snapshot = try XCTUnwrap(renderer.blendModeSnapshotTexture)
        XCTAssertEqual(snapshot.width, 128)
        XCTAssertEqual(snapshot.height, 72)
        let pixels = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: capture)))
        let row = (0..<128).compactMap { pixels.colorAt(x: $0, y: 36) }
        let glyph = try XCTUnwrap(row.min { $0.redComponent < $1.redComponent })
        XCTAssertLessThan(glyph.redComponent, 0.3)
        XCTAssertGreaterThan(glyph.greenComponent, 0.7)
        XCTAssertGreaterThan(glyph.blueComponent, 0.7)
    }

    private final class HeldProvider: NowPlayingProvider, @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        var onFirstFetch: (() -> Void)?
        private let lock = NSLock()
        private var calls = 0
        func fetch() -> NowPlayingInfo? {
            lock.lock()
            calls += 1
            let first = calls == 1
            lock.unlock()
            if first {
                onFirstFetch?()
                _ = release.wait(timeout: .now() + 5)
            }
            return NowPlayingInfo(state: .playing, title: first ? "old" : "new")
        }
    }

    func testStoppedMediaPollDropsPendingFetch() {
        let entered = expectation(description: "first fetch entered")
        let provider = HeldProvider()
        provider.onFirstFetch = { entered.fulfill() }
        let poller = MediaPoller(provider: provider)
        defer { provider.release.signal(); poller.stop() }
        var titles: [String] = []
        poller.onProperties = { info in titles.append(info.title) }
        poller.start()
        wait(for: [entered], timeout: 3)
        poller.stop()
        provider.release.signal()
        let deadline = Date(timeIntervalSinceNow: 3)
        while poller.hasPendingPollForTesting, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertFalse(poller.hasPendingPollForTesting, "released fetch must complete before checking absence")
        XCTAssertTrue(titles.isEmpty)
        XCTAssertEqual(poller.deliveryCount, 0)
    }

    func testRestartedMediaPollDropsOldGenerationAndFetchesImmediately() {
        let entered = expectation(description: "first fetch entered")
        let provider = HeldProvider()
        provider.onFirstFetch = { entered.fulfill() }
        let poller = MediaPoller(provider: provider)
        defer { provider.release.signal(); poller.stop() }
        let delivered = expectation(description: "new generation delivered")
        var titles: [String] = []
        poller.onProperties = { info in titles.append(info.title); delivered.fulfill() }
        poller.start()
        wait(for: [entered], timeout: 3)
        poller.stop()
        poller.start()
        provider.release.signal()
        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(titles, ["new"])
        XCTAssertEqual(poller.deliveryCount, 1)
    }

    private func directoryProject(in directory: URL) throws -> WallpaperProject {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("assets"),
                                                withIntermediateDirectories: true)
        try "ok".write(to: directory.appendingPathComponent("assets/file.txt"), atomically: true, encoding: .utf8)
        try """
        <html><body><script>
        window.files = null;
        window.wallpaperPropertyListener = {
          userDirectoryFilesAddedOrChanged: function(key, files) { window.files = files; }
        };
        </script></body></html>
        """.write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try #"{"type":"web","file":"index.html","title":"directory","general":{"properties":{"images":{"type":"directory","value":"assets","mode":"fetchall"}}}}"#
            .write(to: directory.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        return try ProjectJSONParser.parse(folderURL: directory)
    }

    func testDirectoryWalkCompletionDoesNotCrossRemount() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try directoryProject(in: directory.appendingPathComponent("first"))
        let second = try directoryProject(in: directory.appendingPathComponent("second"))
        let entered = expectation(description: "old directory walk entered")
        let returned = expectation(description: "old directory walk returned")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let firstAssets = first.folderURL.appendingPathComponent("assets")
        let firstFile = firstAssets.appendingPathComponent("file.txt")
        let secondFile = second.folderURL.appendingPathComponent("assets/file.txt")
        let renderer = WebRenderer(mode: .web)
        renderer.directoryWalker = { url in
            if url == firstAssets {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                returned.fulfill()
                return [firstFile]
            }
            return [secondFile]
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        try renderer.mount(in: container, project: first)
        defer { renderer.teardown() }
        wait(for: [entered], timeout: 3)
        try renderer.mount(in: container, project: second)
        let web = try XCTUnwrap(renderer.webViewForTesting)
        try waitForJavaScript("window.files && window.files.length === 1", in: web)
        release.signal()
        wait(for: [returned], timeout: 3)
        let deadline = Date(timeIntervalSinceNow: 3)
        while renderer.directoryWalksInFlightForTesting != 0, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(renderer.directoryWalksInFlightForTesting, 0)
        let json = try XCTUnwrap(try evaluate("JSON.stringify(window.files)", in: web) as? String)
        let files = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String])
        XCTAssertEqual(files, [secondFile.resolvingSymlinksInPath().path])
    }

    func testSaturatedOldDirectoryWalksRetryCurrentFetchAllAfterRemount() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try directoryProject(in: directory.appendingPathComponent("first"))
        let second = try directoryProject(in: directory.appendingPathComponent("second"))
        let current = try directoryProject(in: directory.appendingPathComponent("current"))
        let firstEntered = expectation(description: "first old walk entered")
        let secondEntered = expectation(description: "second old walk entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); release.signal() }
        let firstAssets = first.folderURL.appendingPathComponent("assets")
        let secondAssets = second.folderURL.appendingPathComponent("assets")
        let currentFile = current.folderURL.appendingPathComponent("assets/file.txt")
        let renderer = WebRenderer(mode: .web)
        renderer.directoryWalker = { url in
            if url == firstAssets || url == secondAssets {
                (url == firstAssets ? firstEntered : secondEntered).fulfill()
                _ = release.wait(timeout: .now() + 10)
                return [url.appendingPathComponent("file.txt")]
            }
            return [currentFile]
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36))
        try renderer.mount(in: container, project: first)
        defer { renderer.teardown() }
        wait(for: [firstEntered], timeout: 3)
        try renderer.mount(in: container, project: second)
        wait(for: [secondEntered], timeout: 3)
        XCTAssertEqual(renderer.directoryWalksInFlightForTesting, 2)
        try renderer.mount(in: container, project: current)
        let web = try XCTUnwrap(renderer.webViewForTesting)
        try waitForJavaScript("document.readyState === 'complete' && window.files === null", in: web)
        // Invoke the real didFinish callback with both old workers still held, proving its queued branch.
        renderer.webView(web, didFinish: nil)
        XCTAssertEqual(renderer.directoryWalksInFlightForTesting, 2)
        release.signal()
        try waitForJavaScript("window.files && window.files.length === 1", in: web)
        let json = try XCTUnwrap(try evaluate("JSON.stringify(window.files)", in: web) as? String)
        let files = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String])
        XCTAssertEqual(files, [currentFile.resolvingSymlinksInPath().path])
        release.signal()
        let deadline = Date(timeIntervalSinceNow: 3)
        while renderer.directoryWalksInFlightForTesting != 0, Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertEqual(renderer.directoryWalksInFlightForTesting, 0)
        XCTAssertEqual(try evaluate("JSON.stringify(window.files)", in: web) as? String, json)
    }

    func testVideoFallbackDOMPreservesEntityFileNames() throws {
        let web = WKWebView(frame: .zero)
        defer { web.stopLoading() }
        web.loadHTMLString(VideoFallbackHTML.html(forVideoFile: "a&copy;?.webm"), baseURL: nil)
        try waitForJavaScript("!!document.querySelector('video')", in: web)
        let source = try XCTUnwrap(try evaluate("document.querySelector('video').getAttribute('src')", in: web) as? String)
        let url = try XCTUnwrap(URL(string: source))
        XCTAssertEqual(url.path.removingPercentEncoding, "/a&copy;?.webm")
        XCTAssertNil(url.query)
        XCTAssertNil(url.fragment)
    }

    func testProxyDOMKeysHaveIndependentPhysicalCodes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        <html><body><script>
        window.keys = [];
        document.addEventListener('keydown', function(e) { window.keys.push([e.key, e.code]); });
        window.ready = true;
        </script></body></html>
        """.write(to: directory.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try #"{"type":"web","file":"index.html","title":"keys"}"#
            .write(to: directory.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        let renderer = WebRenderer(mode: .web)
        let project = try ProjectJSONParser.parse(folderURL: directory)
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { renderer.teardown() }
        let web = try XCTUnwrap(renderer.webViewForTesting)
        try waitForJavaScript("window.ready === true && typeof window.__wapleEvent === 'function'", in: web)
        let proxy = WebInputProxyView(target: web)
        let inputs: [(UInt16, String)] = [(13, "w"), (49, " "), (123, "\u{f702}"), (13, "z")]
        for (keyCode, characters) in inputs {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
            proxy.keyDown(with: event)
        }
        try waitForJavaScript("window.keys.length === 4", in: web)
        let json = try XCTUnwrap(try evaluate("JSON.stringify(window.keys)", in: web) as? String)
        let keys = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String]])
        XCTAssertEqual(keys, [["w", "KeyW"], [" ", "Space"], ["ArrowLeft", "ArrowLeft"], ["z", "KeyW"]])
    }
}
