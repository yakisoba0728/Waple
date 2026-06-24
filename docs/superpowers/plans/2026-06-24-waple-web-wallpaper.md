# Waple Web Wallpaper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wallpaper Engine `type: "web"` 배경화면을 WKWebView 로 데스크탑에 렌더하고, AVFoundation 이 못 여는 webm 영상은 같은 WebRenderer 로 폴백 재생한다.

**Architecture:** 기존 `WallpaperRenderer` 이음새에 `WebRenderer`(WKWebView)를 추가한다. 로컬 자산은 `WKURLSchemeHandler` 로 단일 커스텀 스킴에 same-origin 서빙해 JS `fetch` 가 동작하게 한다. 속성 파싱은 순수 `WapleCore` 로, 실시간 오디오 스펙트럼은 ScreenCaptureKit+vDSP 로 만든다. 빌드는 bare 실행 파일로 검증 가능한 Phase 1 과 `.app`+서명이 필요한 오디오 Phase 2 로 나눈다.

**Tech Stack:** Swift 5.9, WebKit(WKWebView/WKURLSchemeHandler), ScreenCaptureKit, Accelerate(vDSP), AppKit, XCTest. 새 의존성·새 타깃 없음.

## Global Constraints

- 기존 SPM 패키지에 추가. **새 타깃·서드파티 의존성 없음.** `swift-tools-version:5.9`, `.macOS(.v13)`.
- 커스텀 스킴 `waple-asset`, 호스트 `wallpaper` (`waple-asset://wallpaper/<상대경로>`).
- 색상 속성 값은 **공백 구분 0–1 실수 3개 문자열** (`"0.61 0.48 0.30"`).
- 브릿지 미디어 리스너는 **no-op**. 시스템 하드웨어 스탯은 제공하지 않음.
- general.properties 는 **기본값만 주입**(편집 UI 없음).
- 영상 wallpaper 의 자체 오디오는 **음소거**. 시스템 오디오는 스펙트럼용으로 읽기 전용 캡처.
- `type:"video"` + 미지원 코덱(webm/mkv) → `WebRenderer(mode: .videoFallback)`.
- Phase 1 은 **bare 실행 파일(`swift run`)로 검증 가능**해야 함. 오디오(Phase 2)는 `.app` + ad-hoc 서명 필요(번들 ID `kr.yaki.waple`).
- 브릿지 JS 는 리소스 번들이 아니라 **Swift 문자열 상수**로 임베드(경로 이슈·`.app` 리소스 복사 회피).

**전제(작업 전 1회):** 현재 브랜치 `waple-video-mvp`, `swift build`/`swift test` 그린 상태에서 시작.

---

## Phase 1 — bare 실행 파일로 검증 (오디오 제외)

### Task 1: `WallpaperProperties` (general.properties 파싱 + WE JSON 인코딩)

**Files:**
- Create: `Sources/WapleCore/WallpaperProperties.swift`
- Test: `Tests/WapleCoreTests/WallpaperPropertiesTests.swift`

**Interfaces:**
- Consumes: `ProjectParseError` (기존 WapleCore)
- Produces:
  - `enum PropertyValue: Equatable { case string(String); case bool(Bool); case number(Double); case none }`
  - `struct WallpaperProperty: Equatable { key: String; type: String; value: PropertyValue; order: Int?; condition: String? }`
  - `enum WallpaperProperties`
    - `static func parse(generalProperties: [String: Any]) -> [WallpaperProperty]`
    - `static func parse(folderURL: URL) throws -> [WallpaperProperty]`
    - `static func weUserPropertiesJSON(_ props: [WallpaperProperty]) -> String`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/WapleCoreTests/WallpaperPropertiesTests.swift`:
```swift
import XCTest
@testable import WapleCore

final class WallpaperPropertiesTests: XCTestCase {
    func testParsesColorBoolSliderCombo() {
        let general: [String: Any] = [
            "bg":   ["type": "color",  "value": "0.6 0.4 0.3", "order": 0],
            "flag": ["type": "bool",   "value": true,          "order": 1],
            "amt":  ["type": "slider", "value": 0.5,           "order": 2],
            "mode": ["type": "combo",  "value": "a",           "order": 3],
        ]
        let props = WallpaperProperties.parse(generalProperties: general)
        let byKey = Dictionary(uniqueKeysWithValues: props.map { ($0.key, $0) })
        XCTAssertEqual(byKey["bg"]?.value, .string("0.6 0.4 0.3"))
        XCTAssertEqual(byKey["flag"]?.value, .bool(true))
        XCTAssertEqual(byKey["amt"]?.value, .number(0.5))
        XCTAssertEqual(byKey["mode"]?.value, .string("a"))
    }

    func testSortsByOrderThenKey() {
        let general: [String: Any] = [
            "z": ["type": "bool", "value": false, "order": 0],
            "a": ["type": "bool", "value": false, "order": 1],
        ]
        let props = WallpaperProperties.parse(generalProperties: general)
        XCTAssertEqual(props.map(\.key), ["z", "a"])
    }

    func testPreservesCondition() {
        let general: [String: Any] = [
            "x": ["type": "bool", "value": true, "condition": "y.value == true"]
        ]
        let props = WallpaperProperties.parse(generalProperties: general)
        XCTAssertEqual(props.first?.condition, "y.value == true")
    }

    func testWEUserPropertiesJSONIsDeterministicAndTyped() {
        let props = [
            WallpaperProperty(key: "bg", type: "color", value: .string("0.6 0.4 0.3"), order: 0, condition: nil),
            WallpaperProperty(key: "x", type: "bool", value: .bool(true), order: 1, condition: nil),
        ]
        let json = WallpaperProperties.weUserPropertiesJSON(props)
        XCTAssertEqual(json, #"{"bg":{"type":"color","value":"0.6 0.4 0.3"},"x":{"type":"bool","value":true}}"#)
    }

    func testParseFolderReadsGeneralProperties() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WPProps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"type":"web","general":{"properties":{"bg":{"type":"color","value":"1 0 0","order":0}}}}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("project.json"))
        let props = try WallpaperProperties.parse(folderURL: dir)
        XCTAssertEqual(props.first?.key, "bg")
        XCTAssertEqual(props.first?.value, .string("1 0 0"))
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter WallpaperPropertiesTests`
Expected: 컴파일 에러 ("cannot find 'WallpaperProperties'").

- [ ] **Step 3: 구현 작성**

`Sources/WapleCore/WallpaperProperties.swift`:
```swift
import Foundation

public enum PropertyValue: Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case none
}

public struct WallpaperProperty: Equatable {
    public let key: String
    public let type: String
    public let value: PropertyValue
    public let order: Int?
    public let condition: String?

    public init(key: String, type: String, value: PropertyValue, order: Int?, condition: String?) {
        self.key = key
        self.type = type
        self.value = value
        self.order = order
        self.condition = condition
    }
}

public enum WallpaperProperties {
    public static func parse(generalProperties: [String: Any]) -> [WallpaperProperty] {
        var result: [WallpaperProperty] = []
        for (key, raw) in generalProperties {
            guard let dict = raw as? [String: Any] else { continue }
            let type = (dict["type"] as? String) ?? ""
            result.append(WallpaperProperty(
                key: key,
                type: type,
                value: parseValue(dict["value"], type: type),
                order: dict["order"] as? Int,
                condition: dict["condition"] as? String
            ))
        }
        return result.sorted {
            ($0.order ?? Int.max, $0.key) < ($1.order ?? Int.max, $1.key)
        }
    }

    private static func parseValue(_ raw: Any?, type: String) -> PropertyValue {
        switch type {
        case "bool", "checkbox":
            return .bool((raw as? Bool) ?? false)
        case "slider":
            return .number((raw as? Double) ?? 0)
        default:
            if let s = raw as? String { return .string(s) }
            if let b = raw as? Bool { return .bool(b) }
            if let n = raw as? Double { return .number(n) }
            return .none
        }
    }

    public static func parse(folderURL: URL) throws -> [WallpaperProperty] {
        let url = folderURL.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: url) else { throw ProjectParseError.fileNotFound }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProjectParseError.invalidJSON
        }
        let general = (obj["general"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        return parse(generalProperties: general)
    }

    public static func weUserPropertiesJSON(_ props: [WallpaperProperty]) -> String {
        var dict: [String: Any] = [:]
        for p in props {
            var inner: [String: Any] = ["type": p.type]
            switch p.value {
            case .string(let s): inner["value"] = s
            case .bool(let b):   inner["value"] = b
            case .number(let n): inner["value"] = n
            case .none:          break
            }
            dict[p.key] = inner
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter WallpaperPropertiesTests`
Expected: PASS (5 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleCore/WallpaperProperties.swift Tests/WapleCoreTests/WallpaperPropertiesTests.swift
git commit -m "feat: WallpaperProperties parser and WE user-properties JSON encoder"
```

---

### Task 2: `VideoFallbackHTML` (webm용 HTML 생성기)

**Files:**
- Create: `Sources/WapleRender/VideoFallbackHTML.swift`
- Test: `Tests/WapleRenderTests/VideoFallbackHTMLTests.swift`

**Interfaces:**
- Produces: `enum VideoFallbackHTML { static func html(forVideoFile name: String) -> String }`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/WapleRenderTests/VideoFallbackHTMLTests.swift`:
```swift
import XCTest
@testable import WapleRender

final class VideoFallbackHTMLTests: XCTestCase {
    func testContainsLoopingMutedVideoTag() {
        let html = VideoFallbackHTML.html(forVideoFile: "clip.webm")
        XCTAssertTrue(html.contains("<video"))
        XCTAssertTrue(html.contains("autoplay"))
        XCTAssertTrue(html.contains("loop"))
        XCTAssertTrue(html.contains("muted"))
        XCTAssertTrue(html.contains("object-fit:cover") || html.contains("object-fit: cover"))
    }

    func testUsesSchemeURLWithPercentEncodedName() {
        let html = VideoFallbackHTML.html(forVideoFile: "my clip.webm")
        XCTAssertTrue(html.contains("waple-asset://wallpaper/my%20clip.webm"))
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter VideoFallbackHTMLTests`
Expected: 컴파일 에러 ("cannot find 'VideoFallbackHTML'").

- [ ] **Step 3: 구현 작성**

`Sources/WapleRender/VideoFallbackHTML.swift`:
```swift
import Foundation

public enum VideoFallbackHTML {
    public static func html(forVideoFile name: String) -> String {
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;width:100%;height:100%;background:#000;overflow:hidden}
        video{width:100%;height:100%;object-fit:cover}</style></head>
        <body><video src="waple-asset://wallpaper/\(encoded)" autoplay loop muted playsinline></video></body></html>
        """
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter VideoFallbackHTMLTests`
Expected: PASS (2 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleRender/VideoFallbackHTML.swift Tests/WapleRenderTests/VideoFallbackHTMLTests.swift
git commit -m "feat: VideoFallbackHTML generator for webm wallpapers"
```

---

### Task 3: `WallpaperSchemeHandler` (커스텀 스킴 + 경로 이탈 방지)

**Files:**
- Create: `Sources/WapleRender/WallpaperSchemeHandler.swift`
- Test: `Tests/WapleRenderTests/WallpaperSchemeHandlerTests.swift`

**Interfaces:**
- Produces:
  - `final class WallpaperSchemeHandler: NSObject, WKURLSchemeHandler`
    - `static let scheme = "waple-asset"`, `static let host = "wallpaper"`
    - `init(rootURL: URL)`
    - `static func fileURL(forRequestPath path: String, root: URL) -> URL?` (순수, 경로 이탈 시 nil)

- [ ] **Step 1: 실패하는 테스트 작성 (순수 경로 로직)**

`Tests/WapleRenderTests/WallpaperSchemeHandlerTests.swift`:
```swift
import XCTest
@testable import WapleRender

final class WallpaperSchemeHandlerTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/wp", isDirectory: true)

    func testResolvesNormalPath() {
        let u = WallpaperSchemeHandler.fileURL(forRequestPath: "/index.html", root: root)
        XCTAssertEqual(u?.path, "/tmp/wp/index.html")
    }

    func testResolvesNestedPath() {
        let u = WallpaperSchemeHandler.fileURL(forRequestPath: "/js/a.js", root: root)
        XCTAssertEqual(u?.path, "/tmp/wp/js/a.js")
    }

    func testRejectsPathTraversal() {
        XCTAssertNil(WallpaperSchemeHandler.fileURL(forRequestPath: "/../etc/passwd", root: root))
        XCTAssertNil(WallpaperSchemeHandler.fileURL(forRequestPath: "/../../secret", root: root))
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter WallpaperSchemeHandlerTests`
Expected: 컴파일 에러 ("cannot find 'WallpaperSchemeHandler'").

- [ ] **Step 3: 구현 작성**

`Sources/WapleRender/WallpaperSchemeHandler.swift`:
```swift
import Foundation
import WebKit
import UniformTypeIdentifiers

public final class WallpaperSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "waple-asset"
    public static let host = "wallpaper"

    private let root: URL

    public init(rootURL: URL) {
        self.root = rootURL.standardizedFileURL
        super.init()
    }

    /// 요청 경로를 루트 하위 파일 URL 로 안전하게 변환. 루트를 벗어나면 nil.
    public static func fileURL(forRequestPath path: String, root: URL) -> URL? {
        let root = root.standardizedFileURL
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let candidate = root.appendingPathComponent(rel).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else { return nil }
        return candidate
    }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url,
              let fileURL = WallpaperSchemeHandler.fileURL(forRequestPath: url.path, root: root),
              let data = try? Data(contentsOf: fileURL) else {
            respond(task, url: task.request.url, status: 404, mime: "text/plain", data: Data())
            return
        }
        respond(task, url: url, status: 200, mime: mimeType(for: fileURL), data: data)
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func respond(_ task: WKURLSchemeTask, url: URL?, status: Int, mime: String, data: Data) {
        let target = url ?? URL(string: "waple-asset://wallpaper/")!
        let response = HTTPURLResponse(
            url: target, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*"]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter WallpaperSchemeHandlerTests`
Expected: PASS (3 tests). `swift build` 성공.

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleRender/WallpaperSchemeHandler.swift Tests/WapleRenderTests/WallpaperSchemeHandlerTests.swift
git commit -m "feat: WKURLSchemeHandler serving wallpaper folder same-origin"
```

---

### Task 4: `WallpaperBridgeJS` + `WebRenderer` (오디오 제외, 빌드 전용)

자동 테스트 불가(WKWebView). 이 태스크는 **`swift build` 성공**까지. 시각 검증은 Task 6.

**Files:**
- Create: `Sources/WapleRender/WallpaperBridgeJS.swift`
- Create: `Sources/WapleRender/WebRenderer.swift`

**Interfaces:**
- Consumes: `WallpaperRenderer`, `RendererError` (기존), `WallpaperSchemeHandler`, `VideoFallbackHTML`, `WallpaperProperties` (WapleCore), `WallpaperProject` (WapleCore)
- Produces:
  - `enum WallpaperBridgeJS { static let source: String }`
  - `final class WebRenderer: NSObject, WallpaperRenderer { enum Mode { case web; case videoFallback }; init(mode: Mode) }`

- [ ] **Step 1: 브릿지 JS 작성**

`Sources/WapleRender/WallpaperBridgeJS.swift`:
```swift
enum WallpaperBridgeJS {
    static let source = #"""
    (function () {
      var audioCb = null;
      window.wallpaperRegisterAudioListener = function (cb) { audioCb = cb; };
      window.__wapleAudio = function (arr) {
        if (audioCb) { try { audioCb(arr); } catch (e) {} }
      };
      window.wallpaperRequestRandomFileForProperty = function (name, cb) {
        try { window.webkit.messageHandlers.waple.postMessage({ type: 'randomFile', name: name }); } catch (e) {}
      };
      var noop = function () {};
      window.wallpaperRegisterMediaStatusListener = noop;
      window.wallpaperRegisterMediaPropertiesListener = noop;
      window.wallpaperRegisterMediaThumbnailListener = noop;
      window.wallpaperRegisterMediaTimelineListener = noop;
      window.wallpaperRegisterMediaPlaybackListener = noop;
    })();
    """#
}
```

- [ ] **Step 2: WebRenderer 작성**

`Sources/WapleRender/WebRenderer.swift`:
```swift
import AppKit
import WebKit
import WapleCore

public final class WebRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate, WKScriptMessageHandler {
    public enum Mode { case web; case videoFallback }

    private let mode: Mode
    private var webView: WKWebView?
    private var pendingUserPropertiesJSON: String?

    public init(mode: Mode) {
        self.mode = mode
        super.init()
    }

    public func mount(in container: NSView, project: WallpaperProject) throws {
        guard let fileName = project.fileName else { throw RendererError.assetMissing }
        let fileURL = project.folderURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { throw RendererError.assetMissing }

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(WallpaperSchemeHandler(rootURL: project.folderURL),
                                   forURLScheme: WallpaperSchemeHandler.scheme)
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: WallpaperBridgeJS.source,
                                       injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(self, name: "waple")
        config.userContentController = ucc

        let web = WKWebView(frame: container.bounds, configuration: config)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.addSubview(web)

        let encoded = fileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileName
        let base = "\(WallpaperSchemeHandler.scheme)://\(WallpaperSchemeHandler.host)/"

        switch mode {
        case .web:
            let props = (try? WallpaperProperties.parse(folderURL: project.folderURL)) ?? []
            pendingUserPropertiesJSON = WallpaperProperties.weUserPropertiesJSON(props)
            web.load(URLRequest(url: URL(string: base + encoded)!))
        case .videoFallback:
            web.loadHTMLString(VideoFallbackHTML.html(forVideoFile: fileName),
                               baseURL: URL(string: base)!)
        }

        self.webView = web
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let json = pendingUserPropertiesJSON else { return }
        let js = """
        if (window.wallpaperPropertyListener && window.wallpaperPropertyListener.applyUserProperties) {
          window.wallpaperPropertyListener.applyUserProperties(\(json));
        }
        if (window.wallpaperPropertyListener && window.wallpaperPropertyListener.applyGeneralProperties) {
          window.wallpaperPropertyListener.applyGeneralProperties({ fps: 30 });
        }
        """
        webView.evaluateJavaScript(js)
    }

    public func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        // MVP: randomFile 등 메시지 수신만(랜덤 파일 소스 없음 → no-op).
    }

    public func pause() {
        webView?.evaluateJavaScript(
            "if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener.setPaused)window.wallpaperPropertyListener.setPaused(true);")
    }

    public func resume() {
        webView?.evaluateJavaScript(
            "if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener.setPaused)window.wallpaperPropertyListener.setPaused(false);")
    }

    public func teardown() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "waple")
        webView?.removeFromSuperview()
        webView = nil
    }
}
```

- [ ] **Step 3: 빌드 확인**

Run: `swift build`
Expected: 성공.

- [ ] **Step 4: 커밋**

```bash
git add Sources/WapleRender/WallpaperBridgeJS.swift Sources/WapleRender/WebRenderer.swift
git commit -m "feat: WebRenderer (WKWebView) with WE bridge and property injection"
```

---

### Task 5: `RendererFactory` 리팩터 + `.web` 적용 가능화 + AppDelegate 배선

**Files:**
- Modify: `Sources/WapleRender/RendererFactory.swift` (전체 교체)
- Modify: `Sources/WapleCore/WallpaperType.swift` (`isSupportedInMVP`)
- Modify: `Sources/Waple/AppDelegate.swift` (`apply` 의 팩토리 호출)
- Modify: `Tests/WapleRenderTests/RendererFactoryTests.swift` (전체 교체)
- Modify: `Tests/WapleCoreTests/WallpaperTypeTests.swift` (`isSupportedInMVP` 테스트)

**Interfaces:**
- Consumes: `WebRenderer`, `VideoRenderer.isSupportedContainer(_:)`, `WallpaperProject`
- Produces: `static func RendererFactory.makeRenderer(for project: WallpaperProject) -> WallpaperRenderer?`

- [ ] **Step 1: 팩토리 테스트 전체 교체(실패 상태)**

`Tests/WapleRenderTests/RendererFactoryTests.swift` 전체를 다음으로 교체:
```swift
import XCTest
@testable import WapleRender
import WapleCore

final class RendererFactoryTests: XCTestCase {
    private func project(type: WallpaperType, file: String?) -> WallpaperProject {
        WallpaperProject(id: "x", type: type, fileName: file, previewName: nil,
                         title: "t", tags: [], contentRating: nil, workshopId: nil,
                         dependency: nil, folderURL: URL(fileURLWithPath: "/tmp/x", isDirectory: true))
    }

    func testWebTypeReturnsWebRenderer() {
        XCTAssertTrue(RendererFactory.makeRenderer(for: project(type: .web, file: "index.html")) is WebRenderer)
    }

    func testSupportedVideoReturnsVideoRenderer() {
        XCTAssertTrue(RendererFactory.makeRenderer(for: project(type: .video, file: "a.mp4")) is VideoRenderer)
    }

    func testUnsupportedCodecVideoReturnsWebRenderer() {
        XCTAssertTrue(RendererFactory.makeRenderer(for: project(type: .video, file: "a.webm")) is WebRenderer)
    }

    func testSceneAndOthersReturnNil() {
        XCTAssertNil(RendererFactory.makeRenderer(for: project(type: .scene, file: "scene.json")))
        XCTAssertNil(RendererFactory.makeRenderer(for: project(type: .preset, file: nil)))
        XCTAssertNil(RendererFactory.makeRenderer(for: project(type: .unknown("z"), file: nil)))
    }

    func testSupportedContainers() {
        XCTAssertTrue(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.mp4")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.webm")))
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter RendererFactoryTests`
Expected: 컴파일 에러(기존 `makeRenderer(for: .video)` 시그니처 불일치).

- [ ] **Step 3: 팩토리 구현 교체**

`Sources/WapleRender/RendererFactory.swift` 전체를 다음으로 교체:
```swift
import Foundation
import WapleCore

public enum RendererFactory {
    /// 타입 + 코덱으로 렌더러를 라우팅. MVP: video / web 지원, webm 등 미지원 코덱은 WebRenderer 폴백.
    public static func makeRenderer(for project: WallpaperProject) -> WallpaperRenderer? {
        switch project.type {
        case .web:
            return WebRenderer(mode: .web)
        case .video:
            if let file = project.fileName {
                let url = project.folderURL.appendingPathComponent(file)
                return VideoRenderer.isSupportedContainer(url) ? VideoRenderer() : WebRenderer(mode: .videoFallback)
            }
            return VideoRenderer()
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: `isSupportedInMVP` 에 web 추가 (테스트 먼저)**

`Tests/WapleCoreTests/WallpaperTypeTests.swift` 의 `testOnlyVideoIsSupportedInMVP` 를 다음으로 교체:
```swift
    func testVideoAndWebAreSupportedInMVP() {
        XCTAssertTrue(WallpaperType.video.isSupportedInMVP)
        XCTAssertTrue(WallpaperType.web.isSupportedInMVP)
        XCTAssertFalse(WallpaperType.scene.isSupportedInMVP)
        XCTAssertFalse(WallpaperType.preset.isSupportedInMVP)
    }
```

`Sources/WapleCore/WallpaperType.swift` 의 `isSupportedInMVP` 를 다음으로 교체:
```swift
    public var isSupportedInMVP: Bool { self == .video || self == .web }
```

- [ ] **Step 5: AppDelegate 팩토리 호출 교체**

`Sources/Waple/AppDelegate.swift` 의 `apply(folderURL:)` 안 두 곳의
`RendererFactory.makeRenderer(for: project.type)` 를 `RendererFactory.makeRenderer(for: project)` 로 교체.
교체 후 `apply` 는 다음과 같아야 한다:
```swift
    private func apply(folderURL: URL) {
        do {
            let project = try ProjectJSONParser.parse(folderURL: folderURL)
            guard RendererFactory.makeRenderer(for: project) != nil else {
                notify("지원하지 않는 타입입니다: \(project.type.storageString)")
                return
            }
            renderers.forEach { $0.teardown() }
            renderers.removeAll()
            for view in desktopController.contentViews {
                guard let renderer = RendererFactory.makeRenderer(for: project) else { continue }
                try renderer.mount(in: view, project: project)
                renderers.append(renderer)
            }
            currentFolderURL = folderURL
        } catch {
            notify("적용 실패: \(error)")
        }
    }
```

- [ ] **Step 6: 테스트·빌드 통과 확인**

Run: `swift test` (전체)
Expected: 모든 번들 PASS (기존 + 신규). `swift build` 성공.

- [ ] **Step 7: 커밋**

```bash
git add Sources/WapleRender/RendererFactory.swift Sources/WapleCore/WallpaperType.swift Sources/Waple/AppDelegate.swift Tests/WapleRenderTests/RendererFactoryTests.swift Tests/WapleCoreTests/WallpaperTypeTests.swift
git commit -m "feat: route web/webm wallpapers via project-based RendererFactory"
```

---

### Task 6: Phase 1 수동 게이트 (G1 서빙 · webm 폴백 · G2 가림 스로틀링)

자동 테스트 불가. **수동 검증.** Darwin 27 에서 실제 동작을 실증한다.

**Files:** 없음(검증 전용). G2 실패 시에만 `Sources/WapleRender/WebRenderer.swift` 수정.

- [ ] **Step 1: 빌드 후 실행**

Run: `swift run Waple`
🖼 → "라이브러리 열기" → "폴더 가져오기…" → `/Users/yakisoba/Downloads/packages`.

- [ ] **Step 2: G1 — 웹 배경 로드 + fetch 검증**

라이브러리에서 웹 배경(`3115349801`) 타일 클릭(이제 "지원 예정" 배지 없이 클릭 가능해야 함).
관찰(모두 충족):
- 데스크탑에 웹 배경이 렌더된다(정적 자산·폰트·`wallpaper.jpg` 표시).
- 콘솔(`NSLog`/Web Inspector)에서 origin/CORS/`file://` fetch 에러가 없다.
  - 필요 시 Web Inspector: `swift run` 중 Safari ▸ 개발자 ▸ 해당 WKWebView 콘솔 확인.

- [ ] **Step 3: webm 폴백 검증**

(webm 배경이 없으면 임의 webm 폴더를 만들어 검증: `project.json`=`{"type":"video","file":"x.webm","preview":"p.jpg","title":"w"}` + 실제 webm + p.jpg → 라이브러리 임포트 → 클릭.)
관찰:
- webm 영상이 데스크탑에 루프·음소거로 재생된다(aspect-fill).

- [ ] **Step 4: G2 — 가림 스로틀링 검증 (핵심 게이트)**

웹 배경 적용 상태에서 **모든 앱 창을 최소화/숨겨 데스크탑이 보이게** 한 뒤 관찰:
- 웹 배경 애니메이션이 **계속 갱신**되는가(얼지 않는가)? (스크린샷 한 장으론 모름 — 수 초간 움직임을 눈으로 확인.)

**G2 실패(데스크탑이 보이는데도 얼음) 시 완화 적용:**
`WebRenderer.mount` 의 `container.addSubview(web)` 직후에 추가:
```swift
        // WKWebView 가림-스로틀링 비활성화(비공개 SPI). 데스크탑-레벨 창 오인 방지.
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if web.responds(to: sel) {
            web.perform(sel, with: false as NSNumber)
        }
```
재빌드·재실행 후 Step 4 재확인. 동작하면 주석으로 근거를 남긴다.
(완화로도 안 되면: 적용 중인 데스크탑 창에 1pt 투명 보조 뷰를 항상 갱신하는 대안을 별도 이슈로 기록 — 본 사이클 차단 아님.)

- [ ] **Step 5: 정리 + 커밋(수정이 있었던 경우만)**

앱 종료(🖼 → Quit). G2 완화 코드를 넣었다면:
```bash
git add Sources/WapleRender/WebRenderer.swift
git commit -m "fix: disable WKWebView occlusion throttling for desktop window (Darwin 27)"
```

---

## Phase 2 — `.app` 패키징 + 실시간 오디오

### Task 7: `.app` 패키징 스크립트 + ad-hoc 서명

자동 테스트 불가. **수동 검증.**

**Files:**
- Create: `scripts/package-app.sh`

**Interfaces:** 없음(빌드 도구)

- [ ] **Step 1: 패키징 스크립트 작성**

`scripts/package-app.sh`:
```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
swift build -c "$CONFIG"

APP="$PWD/Waple.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/Waple" "$APP/Contents/MacOS/Waple"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Waple</string>
  <key>CFBundleDisplayName</key><string>Waple</string>
  <key>CFBundleIdentifier</key><string>kr.yaki.waple</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key><string>Waple</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - --identifier kr.yaki.waple "$APP"
echo "Built $APP"
```

- [ ] **Step 2: 실행 권한 + 패키징**

Run:
```bash
chmod +x scripts/package-app.sh && ./scripts/package-app.sh
```
Expected: `Built .../Waple.app` 출력, 에러 없음.

- [ ] **Step 3: 수동 검증**

Run: `open ./Waple.app`
관찰:
- 메뉴바 🖼 아이콘 등장, Dock 아이콘 없음(LSUIElement).
- 라이브러리에서 동영상/웹 적용이 Phase 1 과 동일하게 동작.

- [ ] **Step 4: 커밋**

```bash
git add scripts/package-app.sh
git commit -m "build: package Waple.app with ad-hoc signing (stable bundle id)"
```

> 참고: ad-hoc 서명은 리빌드 시 cdhash 변동으로 화면 기록 권한을 다시 물을 수 있다(정상). `.gitignore` 에 `Waple.app/` 은 이미 `*.xcodeproj` 외 미포함이므로 추가로 무시하려면 다음 단계에서 함께 처리.

- [ ] **Step 5: 빌드 산출물 무시(선택)**

`.gitignore` 에 `Waple.app/` 한 줄 추가 후:
```bash
git add .gitignore && git commit -m "chore: ignore packaged Waple.app"
```

---

### Task 8: `AudioSpectrum.spectrum(fromMagnitudes:)` (순수 빈 매핑)

**Files:**
- Create: `Sources/WapleRender/AudioSpectrum.swift`
- Test: `Tests/WapleRenderTests/AudioSpectrumTests.swift`

**Interfaces:**
- Produces: `enum AudioSpectrum { static func spectrum(fromMagnitudes: [Float], binCount: Int = 128) -> [Float] }`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/WapleRenderTests/AudioSpectrumTests.swift`:
```swift
import XCTest
@testable import WapleRender

final class AudioSpectrumTests: XCTestCase {
    func testEmptyInputYieldsZeroFilledBins() {
        let out = AudioSpectrum.spectrum(fromMagnitudes: [], binCount: 128)
        XCTAssertEqual(out.count, 128)
        XCTAssertTrue(out.allSatisfy { $0 == 0 })
    }

    func testZeroBinCountYieldsEmpty() {
        XCTAssertTrue(AudioSpectrum.spectrum(fromMagnitudes: [1, 2, 3], binCount: 0).isEmpty)
    }

    func testOutputLengthMatchesBinCount() {
        let mags = (0..<256).map { Float($0) }
        XCTAssertEqual(AudioSpectrum.spectrum(fromMagnitudes: mags, binCount: 128).count, 128)
    }

    func testNormalizedToMaxOne() {
        let mags = (1...256).map { Float($0) }
        let out = AudioSpectrum.spectrum(fromMagnitudes: mags, binCount: 64)
        XCTAssertEqual(out.max() ?? 0, 1.0, accuracy: 1e-5)
        XCTAssertTrue(out.allSatisfy { $0 >= 0 && $0 <= 1.0001 })
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter AudioSpectrumTests`
Expected: 컴파일 에러 ("cannot find 'AudioSpectrum'").

- [ ] **Step 3: 구현 작성**

`Sources/WapleRender/AudioSpectrum.swift`:
```swift
import Foundation

public enum AudioSpectrum {
    /// FFT 크기 배열을 binCount 개로 평균·정규화(최댓값=1)한다. WE audio listener 입력용.
    public static func spectrum(fromMagnitudes magnitudes: [Float], binCount: Int = 128) -> [Float] {
        guard binCount > 0 else { return [] }
        guard !magnitudes.isEmpty else { return Array(repeating: 0, count: binCount) }

        let n = magnitudes.count
        var out = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            let start = i * n / binCount
            let end = max(start + 1, (i + 1) * n / binCount)
            var sum: Float = 0
            var count = 0
            for j in start..<min(end, n) { sum += magnitudes[j]; count += 1 }
            out[i] = count > 0 ? sum / Float(count) : 0
        }
        if let m = out.max(), m > 0 {
            for i in 0..<binCount { out[i] /= m }
        }
        return out
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter AudioSpectrumTests`
Expected: PASS (4 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleRender/AudioSpectrum.swift Tests/WapleRenderTests/AudioSpectrumTests.swift
git commit -m "feat: AudioSpectrum bin mapping and normalization"
```

---

### Task 9: `SystemAudioSpectrumProvider` + WebRenderer 오디오 배선 + G3

자동 테스트 불가(ScreenCaptureKit + 권한). **수동 검증.** 빌드 성공 + G3 실측.

**Files:**
- Create: `Sources/WapleRender/SystemAudioSpectrumProvider.swift`
- Modify: `Sources/WapleRender/WebRenderer.swift` (오디오 필드·시작/정지·프레임 푸시)

**Interfaces:**
- Consumes: `AudioSpectrum.spectrum(fromMagnitudes:binCount:)`
- Produces:
  - `final class SystemAudioSpectrumProvider: NSObject` — `var onFrame: (([Float]) -> Void)?`, `func start()`, `func stop()`

- [ ] **Step 1: 오디오 프로바이더 작성**

`Sources/WapleRender/SystemAudioSpectrumProvider.swift`:
```swift
import Foundation
import ScreenCaptureKit
import AVFoundation
import Accelerate

/// 시스템 출력 오디오를 SCStream 으로 캡처해 FFT 스펙트럼(128 bin)을 onFrame 으로 전달.
/// 권한 거부/실패 시 0 배열을 공급(배경은 계속 렌더). 메인 스레드 콜백.
public final class SystemAudioSpectrumProvider: NSObject, SCStreamOutput {
    public var onFrame: (([Float]) -> Void)?

    private var stream: SCStream?
    private let fftSize = 1024
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var running = false

    public override init() {
        log2n = vDSP_Length(round(log2(Double(fftSize))))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        super.init()
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    public func start() {
        guard !running else { return }
        running = true
        Task { await startCapture() }
    }

    public func stop() {
        running = false
        stream?.stopCapture { _ in }
        stream = nil
    }

    private func startCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { feedZeros(); return }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            // 최소 비디오 캡처 비용(오디오만 쓰지만 SCStream 은 비디오 구성 요구)
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "waple.audio"))
            try await stream.startCapture()
            self.stream = stream
        } catch {
            feedZeros()
        }
    }

    private func feedZeros() {
        let zeros = [Float](repeating: 0, count: 128)
        DispatchQueue.main.async { [weak self] in self?.onFrame?(zeros) }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, running else { return }
        guard let samples = Self.floatSamples(from: sampleBuffer, maxCount: fftSize) else { return }
        let mags = magnitudes(from: samples)
        let bins = AudioSpectrum.spectrum(fromMagnitudes: mags, binCount: 128)
        let frame = bins + bins   // WE 포맷: 128(64L + 64R). 모노를 좌우 복제.
        let clamped = Array(frame.prefix(128))
        DispatchQueue.main.async { [weak self] in self?.onFrame?(clamped) }
    }

    /// CMSampleBuffer(PCM Float32) 첫 채널에서 최대 maxCount 샘플 추출.
    private static func floatSamples(from sampleBuffer: CMSampleBuffer, maxCount: Int) -> [Float]? {
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(&abl)
        guard let first = buffers.first, let data = first.mData else { return nil }
        let count = min(Int(first.mDataByteSize) / MemoryLayout<Float>.size, maxCount)
        guard count > 0 else { return nil }
        let ptr = data.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    private func magnitudes(from samples: [Float]) -> [Float] {
        var input = samples
        if input.count < fftSize { input += [Float](repeating: 0, count: fftSize - input.count) }
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        var result = [Float](repeating: 0, count: half)
        vvsqrtf(&result, mags, [Int32(half)])
        return result
    }
}
```

- [ ] **Step 2: WebRenderer 에 오디오 배선 (수정)**

`Sources/WapleRender/WebRenderer.swift` 를 다음 4곳 수정:

(a) 프로퍼티 추가 — `private var pendingUserPropertiesJSON: String?` 아래에:
```swift
    private var audioProvider: SystemAudioSpectrumProvider?
```

(b) `mount` 의 `case .web:` 블록 끝(`web.load(...)` 다음)에 추가:
```swift
            let provider = SystemAudioSpectrumProvider()
            provider.onFrame = { [weak self] frame in
                let csv = frame.map { String(format: "%.3f", $0) }.joined(separator: ",")
                self?.webView?.evaluateJavaScript("if(window.__wapleAudio)window.__wapleAudio([\(csv)]);")
            }
            audioProvider = provider
```

(c) `didFinish` 의 `webView.evaluateJavaScript(js)` 다음 줄에 추가:
```swift
        audioProvider?.start()
```

(d) `pause()` 끝에 `audioProvider?.stop()`, `resume()` 끝에 `audioProvider?.start()`,
`teardown()` 시작에 `audioProvider?.stop()` 추가. 교체 후 세 메서드:
```swift
    public func pause() {
        webView?.evaluateJavaScript(
            "if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener.setPaused)window.wallpaperPropertyListener.setPaused(true);")
        audioProvider?.stop()
    }

    public func resume() {
        webView?.evaluateJavaScript(
            "if(window.wallpaperPropertyListener&&window.wallpaperPropertyListener.setPaused)window.wallpaperPropertyListener.setPaused(false);")
        audioProvider?.start()
    }

    public func teardown() {
        audioProvider?.stop()
        audioProvider = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "waple")
        webView?.removeFromSuperview()
        webView = nil
    }
```

- [ ] **Step 3: 빌드 + 패키징**

Run:
```bash
swift build && ./scripts/package-app.sh
```
Expected: 빌드·패키징 성공.

- [ ] **Step 4: G3 — 오디오 비주얼라이저 검증**

Run: `open ./Waple.app`
- 음악/영상을 재생(시스템 출력 소리 발생).
- 라이브러리에서 웹 배경(`3115349801`) 적용.
- 최초 1회 **"Waple이(가) 화면을 기록하려 합니다"** 권한 프롬프트 → 허용 → 앱 재실행(`open ./Waple.app`).
관찰:
- 오디오 비주얼라이저가 소리에 **반응**한다.
- 권한 거부 시에도 배경은 렌더되며 비주얼라이저만 정지(크래시 X).

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleRender/SystemAudioSpectrumProvider.swift Sources/WapleRender/WebRenderer.swift
git commit -m "feat: real-time system audio spectrum fed to web wallpapers"
```

---

## Self-Review (작성자 체크리스트 결과)

**1. 스펙 커버리지**
- 커스텀 스킴 same-origin 서빙(§2,§5.2) → Task 3 ✅
- general.properties 파싱 + WE JSON 기본값 주입(§5.1,§5.3,§5.4) → Task 1 + Task 4 ✅
- WebRenderer(WKWebView) + 브릿지(propertyListener/audioListener/requestRandomFile/미디어 no-op)(§5.3,§5.4) → Task 4 ✅
- 팩토리 라우팅 `makeRenderer(for: project)` + isSupportedContainer 순수 유지(§5.7) → Task 5 ✅
- webm 폴백(§5.6) → Task 2 + Task 5 + Task 6 ✅
- 가림 스로틀링 게이트 G2(§9,§12) → Task 6 ✅
- `.app` 패키징 + ad-hoc 서명(§2,§8) → Task 7 ✅
- 실시간 오디오(SCStream+vDSP→128)(§5.5) → Task 8(순수) + Task 9(캡처/배선) ✅
- 우아한 강등(오디오 권한 거부 시 0 공급, 로드 실패 무크래시)(§7) → Task 9 Step1 `feedZeros` / Task 4 ✅
- 미디어 no-op·시스템 스탯 미제공(§2) → Task 4 브릿지 ✅
- Phase 분할(§8) → Phase 1(Task 1–6) / Phase 2(Task 7–9) ✅
- 조기 게이트 G1/G2/G3(§9) → Task 6, Task 9 ✅

**2. 플레이스홀더 스캔:** TBD/모호 지시 없음. GUI/오디오는 구체적 관찰 항목으로 검증. SCStream 코드는 완전(런타임 미세조정은 G3 수동 검증에서). ✅

**3. 타입 일관성:** `WallpaperProperty`/`PropertyValue`/`WallpaperProperties.parse·weUserPropertiesJSON`,
`VideoFallbackHTML.html(forVideoFile:)`, `WallpaperSchemeHandler.scheme·host·fileURL(forRequestPath:root:)`,
`WallpaperBridgeJS.source`, `WebRenderer.Mode(.web/.videoFallback)`·`init(mode:)`,
`RendererFactory.makeRenderer(for:WallpaperProject)`, `WallpaperType.isSupportedInMVP`,
`AudioSpectrum.spectrum(fromMagnitudes:binCount:)`, `SystemAudioSpectrumProvider.onFrame/start/stop`,
스킴 URL `waple-asset://wallpaper/` — 태스크 간 명칭/시그니처 일치 확인. ✅

**범위 밖(스펙 §11) 의도적 미포함:** 미디어 지금-재생(MediaRemote), 시스템 하드웨어 스탯, 속성 편집 UI, Scene 타입, 자원 절약, Core Audio process tap.
