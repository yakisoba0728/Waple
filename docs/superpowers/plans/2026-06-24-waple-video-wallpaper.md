# Waple Video Wallpaper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wallpaper Engine 동영상 배경화면 폴더를 macOS 데스크탑 라이브 배경으로 재생하는 네이티브 메뉴바 앱(Waple)의 MVP를 만든다.

**Architecture:** Swift Package Manager 멀티 타깃. 순수 로직(`WapleCore` 파서, `WapleLibrary` 스토어)은 TDD로, AppKit/AVFoundation/SwiftUI 기반 창·영상·UI는 수동 검증으로 구축한다. `WallpaperRenderer` 프로토콜 + `RendererFactory`를 확장 이음새로 두어 씬/웹을 추후 추가할 수 있게 한다. 모든 화면에 데스크탑-레벨 NSWindow를 띄우고 그 위에 렌더러를 mount한다.

**Tech Stack:** Swift 5.9+, Swift Package Manager, AppKit, AVFoundation, SwiftUI, XCTest. 비샌드박스(Developer ID 경로) 전제로 일반 `URL.bookmarkData()` 사용.

## Global Constraints

- Swift tools 버전: `swift-tools-version:5.9`. 플랫폼 최소: `.macOS(.v13)`.
- 패키지 이름: `Waple`. 타깃: `WapleCore`, `WapleLibrary`, `WapleRender`, `Waple`(executable) + 각 테스트 타깃.
- WE `type` 비교는 **항상 소문자 정규화**. `type` 부재 → `.preset`.
- 동영상은 **기본 음소거**(`AVPlayer.isMuted = true`).
- 저장은 **원본 위치 참조**: 파일 복사 금지, `URL.bookmarkData()`로 경로 보존.
- 미지원 타입/코덱은 **크래시 없이 우아하게 강등**(메시지 표시 후 무시).
- `videoGravity = .resizeAspectFill` (세로형/비16:9 대응).
- 끊김 없는 루프는 `AVQueuePlayer` + `AVPlayerLooper` 사용(seek-to-zero 금지).
- 모든 GUI 수동 검증은 실제 macOS 데스크탑에서 `swift run Waple`로 수행(헤드리스 불가).

**전제 확인(작업 시작 전 1회):**
```bash
swift --version    # Swift 5.9 이상이 출력되어야 함
```

---

### Task 1: SPM 패키지 스캐폴드 + `WallpaperType`

**Files:**
- Create: `Package.swift`
- Create: `Sources/WapleCore/WallpaperType.swift`
- Create: `Sources/WapleLibrary/Placeholder.swift` (빈 타깃 빌드용, 추후 Task 3에서 대체)
- Create: `Sources/WapleRender/Placeholder.swift` (빈 타깃 빌드용, 추후 Task 4에서 대체)
- Create: `Sources/Waple/main.swift` (최소 실행, 추후 Task 5에서 대체)
- Test: `Tests/WapleCoreTests/WallpaperTypeTests.swift`

**Interfaces:**
- Produces:
  - `enum WallpaperType: Equatable { case video, scene, web, application, preset; case unknown(String) }`
  - `static func WallpaperType.from(_ raw: String?) -> WallpaperType`
  - `var WallpaperType.storageString: String`
  - `var WallpaperType.isSupportedInMVP: Bool`

- [ ] **Step 1: Package.swift 작성**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Waple",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "WapleCore"),
        .target(name: "WapleLibrary", dependencies: ["WapleCore"]),
        .target(name: "WapleRender", dependencies: ["WapleCore"]),
        .executableTarget(
            name: "Waple",
            dependencies: ["WapleCore", "WapleLibrary", "WapleRender"]
        ),
        .testTarget(name: "WapleCoreTests", dependencies: ["WapleCore"]),
        .testTarget(name: "WapleLibraryTests", dependencies: ["WapleLibrary", "WapleCore"]),
        .testTarget(name: "WapleRenderTests", dependencies: ["WapleRender", "WapleCore"]),
    ]
)
```

- [ ] **Step 2: 빈 타깃 빌드용 파일 생성**

`Sources/WapleLibrary/Placeholder.swift`:
```swift
// Replaced in Task 3.
enum WapleLibraryPlaceholder {}
```

`Sources/WapleRender/Placeholder.swift`:
```swift
// Replaced in Task 4.
enum WapleRenderPlaceholder {}
```

`Sources/Waple/main.swift`:
```swift
// Replaced in Task 5.
print("Waple")
```

- [ ] **Step 3: 실패하는 테스트 작성**

`Tests/WapleCoreTests/WallpaperTypeTests.swift`:
```swift
import XCTest
@testable import WapleCore

final class WallpaperTypeTests: XCTestCase {
    func testParsesKnownTypesCaseInsensitively() {
        XCTAssertEqual(WallpaperType.from("video"), .video)
        XCTAssertEqual(WallpaperType.from("Scene"), .scene)
        XCTAssertEqual(WallpaperType.from("WEB"), .web)
        XCTAssertEqual(WallpaperType.from("application"), .application)
        XCTAssertEqual(WallpaperType.from("preset"), .preset)
    }

    func testNilOrEmptyTypeBecomesPreset() {
        XCTAssertEqual(WallpaperType.from(nil), .preset)
        XCTAssertEqual(WallpaperType.from(""), .preset)
    }

    func testUnknownTypePreservesRawString() {
        XCTAssertEqual(WallpaperType.from("flux"), .unknown("flux"))
    }

    func testStorageStringRoundTrips() {
        for t: WallpaperType in [.video, .scene, .web, .application, .preset, .unknown("xyz")] {
            XCTAssertEqual(WallpaperType.from(t.storageString), t)
        }
    }

    func testOnlyVideoIsSupportedInMVP() {
        XCTAssertTrue(WallpaperType.video.isSupportedInMVP)
        XCTAssertFalse(WallpaperType.scene.isSupportedInMVP)
        XCTAssertFalse(WallpaperType.web.isSupportedInMVP)
    }
}
```

- [ ] **Step 4: 테스트 실패 확인**

Run: `swift test --filter WallpaperTypeTests`
Expected: 컴파일 에러 또는 FAIL ("cannot find 'WallpaperType'").

- [ ] **Step 5: 최소 구현 작성**

`Sources/WapleCore/WallpaperType.swift`:
```swift
import Foundation

public enum WallpaperType: Equatable {
    case video
    case scene
    case web
    case application
    case preset
    case unknown(String)

    /// project.json 의 "type" 값(부재 가능)을 정규화한다. 부재/빈 문자열은 프리셋으로 본다.
    public static func from(_ raw: String?) -> WallpaperType {
        guard let raw = raw, !raw.isEmpty else { return .preset }
        switch raw.lowercased() {
        case "video": return .video
        case "scene": return .scene
        case "web": return .web
        case "application": return .application
        case "preset": return .preset
        default: return .unknown(raw)
        }
    }

    /// 라이브러리 인덱스에 저장할 안정적인 문자열. `from` 과 왕복 가능.
    public var storageString: String {
        switch self {
        case .video: return "video"
        case .scene: return "scene"
        case .web: return "web"
        case .application: return "application"
        case .preset: return "preset"
        case .unknown(let s): return s
        }
    }

    public var isSupportedInMVP: Bool { self == .video }
}
```

- [ ] **Step 6: 테스트 통과 확인**

Run: `swift test --filter WallpaperTypeTests`
Expected: PASS (5 tests). 또한 `swift build` 가 전체 타깃에서 성공해야 함.

- [ ] **Step 7: 커밋**

```bash
git add Package.swift Sources Tests
git commit -m "feat: SPM scaffold and WallpaperType enum"
```

---

### Task 2: `WallpaperProject` 모델 + `ProjectJSONParser`

**Files:**
- Create: `Sources/WapleCore/WallpaperProject.swift`
- Create: `Sources/WapleCore/ProjectJSONParser.swift`
- Test: `Tests/WapleCoreTests/ProjectJSONParserTests.swift`

**Interfaces:**
- Consumes: `WallpaperType.from(_:)`
- Produces:
  - `struct WallpaperProject: Equatable { let id, type, fileName, previewName, title, tags, contentRating, workshopId, dependency, folderURL }`
  - `enum ProjectParseError: Error, Equatable { case fileNotFound, invalidJSON }`
  - `static func ProjectJSONParser.parse(folderURL: URL) throws -> WallpaperProject`
  - `static func ProjectJSONParser.parse(data: Data, folderURL: URL) throws -> WallpaperProject`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/WapleCoreTests/ProjectJSONParserTests.swift`:
```swift
import XCTest
@testable import WapleCore

final class ProjectJSONParserTests: XCTestCase {
    private func parse(_ json: String, folder: String = "/tmp/123") throws -> WallpaperProject {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        return try ProjectJSONParser.parse(data: Data(json.utf8), folderURL: url)
    }

    func testParsesVideoProject() throws {
        let p = try parse(#"{"type":"video","file":"wallpaper.mp4","preview":"preview.jpg","title":"Test"}"#)
        XCTAssertEqual(p.type, .video)
        XCTAssertEqual(p.fileName, "wallpaper.mp4")
        XCTAssertEqual(p.previewName, "preview.jpg")
        XCTAssertEqual(p.title, "Test")
        XCTAssertEqual(p.id, "123")
    }

    func testParsesCapitalSceneType() throws {
        let p = try parse(#"{"type":"Scene","file":"scene.json","preview":"preview.gif","title":"S"}"#)
        XCTAssertEqual(p.type, .scene)
    }

    func testParsesPresetWithoutTypeButWithDependency() throws {
        let p = try parse(#"{"preview":"preview.jpg","title":"P","dependency":"2593802559"}"#)
        XCTAssertEqual(p.type, .preset)
        XCTAssertEqual(p.dependency, "2593802559")
        XCTAssertNil(p.fileName)
    }

    func testMissingTitleFallsBackToFolderName() throws {
        let p = try parse(#"{"type":"video"}"#, folder: "/tmp/999")
        XCTAssertEqual(p.title, "999")
    }

    func testParsesTagsAndContentRatingAndWorkshopId() throws {
        let p = try parse(#"{"type":"video","tags":["Anime","Game"],"contentrating":"Everyone","workshopid":"2913506072"}"#)
        XCTAssertEqual(p.tags, ["Anime", "Game"])
        XCTAssertEqual(p.contentRating, "Everyone")
        XCTAssertEqual(p.workshopId, "2913506072")
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try parse("not json {")) { error in
            XCTAssertEqual(error as? ProjectParseError, .invalidJSON)
        }
    }

    func testMissingFileThrowsFileNotFound() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)", isDirectory: true)
        XCTAssertThrowsError(try ProjectJSONParser.parse(folderURL: url)) { error in
            XCTAssertEqual(error as? ProjectParseError, .fileNotFound)
        }
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter ProjectJSONParserTests`
Expected: 컴파일 에러 ("cannot find 'ProjectJSONParser'").

- [ ] **Step 3: 모델 구현**

`Sources/WapleCore/WallpaperProject.swift`:
```swift
import Foundation

public struct WallpaperProject: Equatable {
    public let id: String          // 폴더명 (워크샵 ID)
    public let type: WallpaperType
    public let fileName: String?   // project.json "file"
    public let previewName: String?// project.json "preview"
    public let title: String
    public let tags: [String]
    public let contentRating: String?
    public let workshopId: String?
    public let dependency: String? // 프리셋 전용
    public let folderURL: URL

    public init(id: String, type: WallpaperType, fileName: String?, previewName: String?,
                title: String, tags: [String], contentRating: String?, workshopId: String?,
                dependency: String?, folderURL: URL) {
        self.id = id
        self.type = type
        self.fileName = fileName
        self.previewName = previewName
        self.title = title
        self.tags = tags
        self.contentRating = contentRating
        self.workshopId = workshopId
        self.dependency = dependency
        self.folderURL = folderURL
    }
}
```

- [ ] **Step 4: 파서 구현**

`Sources/WapleCore/ProjectJSONParser.swift`:
```swift
import Foundation

public enum ProjectParseError: Error, Equatable {
    case fileNotFound
    case invalidJSON
}

public enum ProjectJSONParser {
    public static func parse(folderURL: URL) throws -> WallpaperProject {
        let projectURL = folderURL.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: projectURL) else {
            throw ProjectParseError.fileNotFound
        }
        return try parse(data: data, folderURL: folderURL)
    }

    public static func parse(data: Data, folderURL: URL) throws -> WallpaperProject {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProjectParseError.invalidJSON
        }
        let id = folderURL.lastPathComponent
        let type = WallpaperType.from(obj["type"] as? String)
        let rawTitle = obj["title"] as? String
        let title = (rawTitle?.isEmpty == false) ? rawTitle! : id
        let tags = (obj["tags"] as? [String]) ?? []
        return WallpaperProject(
            id: id,
            type: type,
            fileName: obj["file"] as? String,
            previewName: obj["preview"] as? String,
            title: title,
            tags: tags,
            contentRating: obj["contentrating"] as? String,
            workshopId: obj["workshopid"] as? String,
            dependency: obj["dependency"] as? String,
            folderURL: folderURL
        )
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter ProjectJSONParserTests`
Expected: PASS (7 tests).

- [ ] **Step 6: 커밋**

```bash
git add Sources/WapleCore Tests/WapleCoreTests
git commit -m "feat: WallpaperProject model and project.json parser"
```

---

### Task 3: `LibraryStore` — 임포트 / 북마크 / 영속화

**Files:**
- Create: `Sources/WapleLibrary/LibraryEntry.swift`
- Create: `Sources/WapleLibrary/LibraryStore.swift`
- Delete: `Sources/WapleLibrary/Placeholder.swift`
- Test: `Tests/WapleLibraryTests/LibraryStoreTests.swift`

**Interfaces:**
- Consumes: `ProjectJSONParser.parse(folderURL:)`, `WallpaperType`, `WallpaperProject`
- Produces:
  - `struct LibraryEntry: Codable, Equatable { let id, title, typeRaw, fileName, previewName, bookmark }`
  - `final class LibraryStore`
    - `init(baseDirectory: URL)`
    - `static func defaultBaseDirectory() -> URL`
    - `var entries: [LibraryEntry]` (get)
    - `var selectedId: String?` (get)
    - `@discardableResult func importFolder(_ folderURL: URL) throws -> LibraryEntry`
    - `@discardableResult func importParent(_ parentURL: URL) -> [LibraryEntry]`
    - `func select(_ id: String)`
    - `func resolveFolderURL(for entry: LibraryEntry) -> URL?`

- [ ] **Step 1: Placeholder 삭제**

```bash
git rm Sources/WapleLibrary/Placeholder.swift
```

- [ ] **Step 2: 실패하는 테스트 작성**

`Tests/WapleLibraryTests/LibraryStoreTests.swift`:
```swift
import XCTest
@testable import WapleLibrary

final class LibraryStoreTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WapleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// 임시 배경 폴더(project.json + 더미 자산) 생성.
    private func makeWallpaperFolder(id: String, type: String = "video") throws -> URL {
        let folder = tmp.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"type":"\#(type)","file":"wallpaper.mp4","preview":"preview.jpg","title":"\#(id)"}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
        try Data("dummy".utf8).write(to: folder.appendingPathComponent("wallpaper.mp4"))
        return folder
    }

    private func base() -> URL { tmp.appendingPathComponent("store", isDirectory: true) }

    func testImportFolderAddsEntry() throws {
        let folder = try makeWallpaperFolder(id: "111")
        let store = LibraryStore(baseDirectory: base())
        let entry = try store.importFolder(folder)
        XCTAssertEqual(entry.id, "111")
        XCTAssertEqual(entry.typeRaw, "video")
        XCTAssertEqual(store.entries.count, 1)
    }

    func testImportFolderIsIdempotentById() throws {
        let folder = try makeWallpaperFolder(id: "111")
        let store = LibraryStore(baseDirectory: base())
        try store.importFolder(folder)
        try store.importFolder(folder)
        XCTAssertEqual(store.entries.count, 1)
    }

    func testImportParentSkipsInvalidSubfolders() throws {
        _ = try makeWallpaperFolder(id: "111")
        _ = try makeWallpaperFolder(id: "222")
        // project.json 없는 폴더 → 스킵 대상
        let bad = tmp.appendingPathComponent("333", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)

        let store = LibraryStore(baseDirectory: base())
        let imported = store.importParent(tmp)
        // tmp 안에는 store 디렉터리도 있으나 project.json 없으므로 스킵됨
        XCTAssertEqual(Set(imported.map(\.id)), ["111", "222"])
    }

    func testEntriesPersistAcrossInstances() throws {
        let folder = try makeWallpaperFolder(id: "111")
        let store1 = LibraryStore(baseDirectory: base())
        try store1.importFolder(folder)
        store1.select("111")

        let store2 = LibraryStore(baseDirectory: base())
        XCTAssertEqual(store2.entries.map(\.id), ["111"])
        XCTAssertEqual(store2.selectedId, "111")
    }

    func testResolveFolderURLReturnsOriginalLocation() throws {
        let folder = try makeWallpaperFolder(id: "111")
        let store = LibraryStore(baseDirectory: base())
        let entry = try store.importFolder(folder)
        let resolved = store.resolveFolderURL(for: entry)
        XCTAssertEqual(resolved?.standardizedFileURL, folder.standardizedFileURL)
    }
}
```

- [ ] **Step 3: 테스트 실패 확인**

Run: `swift test --filter LibraryStoreTests`
Expected: 컴파일 에러 ("cannot find 'LibraryStore'").

- [ ] **Step 4: LibraryEntry 구현**

`Sources/WapleLibrary/LibraryEntry.swift`:
```swift
import Foundation

public struct LibraryEntry: Codable, Equatable {
    public let id: String
    public let title: String
    public let typeRaw: String
    public let fileName: String?
    public let previewName: String?
    public let bookmark: Data

    public init(id: String, title: String, typeRaw: String,
                fileName: String?, previewName: String?, bookmark: Data) {
        self.id = id
        self.title = title
        self.typeRaw = typeRaw
        self.fileName = fileName
        self.previewName = previewName
        self.bookmark = bookmark
    }
}
```

- [ ] **Step 5: LibraryStore 구현**

`Sources/WapleLibrary/LibraryStore.swift`:
```swift
import Foundation
import WapleCore

public final class LibraryStore {
    private let baseDirectory: URL
    private let indexURL: URL
    public private(set) var entries: [LibraryEntry] = []
    public private(set) var selectedId: String?

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        self.indexURL = baseDirectory.appendingPathComponent("library.json")
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        load()
    }

    public static func defaultBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Waple", isDirectory: true)
    }

    private struct Index: Codable {
        var entries: [LibraryEntry]
        var selectedId: String?
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let idx = try? JSONDecoder().decode(Index.self, from: data) else { return }
        entries = idx.entries
        selectedId = idx.selectedId
    }

    private func save() {
        let idx = Index(entries: entries, selectedId: selectedId)
        if let data = try? JSONEncoder().encode(idx) {
            try? data.write(to: indexURL)
        }
    }

    @discardableResult
    public func importFolder(_ folderURL: URL) throws -> LibraryEntry {
        let project = try ProjectJSONParser.parse(folderURL: folderURL)
        let bookmark = try folderURL.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        let entry = LibraryEntry(
            id: project.id,
            title: project.title,
            typeRaw: project.type.storageString,
            fileName: project.fileName,
            previewName: project.previewName,
            bookmark: bookmark
        )
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        save()
        return entry
    }

    @discardableResult
    public func importParent(_ parentURL: URL) -> [LibraryEntry] {
        let fm = FileManager.default
        let subs = (try? fm.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var imported: [LibraryEntry] = []
        for sub in subs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let entry = try? importFolder(sub) { imported.append(entry) }
        }
        return imported
    }

    public func select(_ id: String) {
        selectedId = id
        save()
    }

    public func resolveFolderURL(for entry: LibraryEntry) -> URL? {
        var stale = false
        return try? URL(
            resolvingBookmarkData: entry.bookmark,
            options: [], relativeTo: nil, bookmarkDataIsStale: &stale
        )
    }
}
```

- [ ] **Step 6: 테스트 통과 확인**

Run: `swift test --filter LibraryStoreTests`
Expected: PASS (5 tests).

- [ ] **Step 7: 커밋**

```bash
git add Sources/WapleLibrary Tests/WapleLibraryTests
git commit -m "feat: LibraryStore with reference-in-place import and persistence"
```

---

### Task 4: 렌더러 추상화 + `RendererFactory` + `VideoRenderer`

**Files:**
- Create: `Sources/WapleRender/WallpaperRenderer.swift`
- Create: `Sources/WapleRender/RendererFactory.swift`
- Create: `Sources/WapleRender/VideoRenderer.swift`
- Delete: `Sources/WapleRender/Placeholder.swift`
- Test: `Tests/WapleRenderTests/RendererFactoryTests.swift`

**Interfaces:**
- Consumes: `WallpaperType`, `WallpaperProject`
- Produces:
  - `protocol WallpaperRenderer: AnyObject { func mount(in:project:) throws; func pause(); func resume(); func teardown() }`
  - `enum RendererError: Error, Equatable { case unsupportedType, unsupportedCodec, assetMissing }`
  - `enum RendererFactory { static func makeRenderer(for: WallpaperType) -> WallpaperRenderer? }`
  - `final class VideoRenderer: WallpaperRenderer`
    - `static func isSupportedContainer(_ url: URL) -> Bool`

- [ ] **Step 1: Placeholder 삭제**

```bash
git rm Sources/WapleRender/Placeholder.swift
```

- [ ] **Step 2: 실패하는 테스트 작성**

`Tests/WapleRenderTests/RendererFactoryTests.swift`:
```swift
import XCTest
@testable import WapleRender
import WapleCore

final class RendererFactoryTests: XCTestCase {
    func testFactoryReturnsVideoRendererForVideoType() {
        let renderer = RendererFactory.makeRenderer(for: .video)
        XCTAssertTrue(renderer is VideoRenderer)
    }

    func testFactoryReturnsNilForUnsupportedTypes() {
        XCTAssertNil(RendererFactory.makeRenderer(for: .scene))
        XCTAssertNil(RendererFactory.makeRenderer(for: .web))
        XCTAssertNil(RendererFactory.makeRenderer(for: .preset))
        XCTAssertNil(RendererFactory.makeRenderer(for: .application))
        XCTAssertNil(RendererFactory.makeRenderer(for: .unknown("flux")))
    }

    func testSupportedContainers() {
        XCTAssertTrue(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.mp4")))
        XCTAssertTrue(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.MP4")))
        XCTAssertTrue(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.mov")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.webm")))
        XCTAssertFalse(VideoRenderer.isSupportedContainer(URL(fileURLWithPath: "/a/x.mkv")))
    }
}
```

- [ ] **Step 3: 테스트 실패 확인**

Run: `swift test --filter RendererFactoryTests`
Expected: 컴파일 에러 ("cannot find 'RendererFactory'").

- [ ] **Step 4: 프로토콜 + 에러 구현**

`Sources/WapleRender/WallpaperRenderer.swift`:
```swift
import AppKit
import WapleCore

public protocol WallpaperRenderer: AnyObject {
    /// 컨테이너 뷰에 배경을 mount 하고 재생을 시작한다.
    func mount(in container: NSView, project: WallpaperProject) throws
    func pause()
    func resume()
    func teardown()
}

public enum RendererError: Error, Equatable {
    case unsupportedType
    case unsupportedCodec
    case assetMissing
}
```

- [ ] **Step 5: 팩토리 구현**

`Sources/WapleRender/RendererFactory.swift`:
```swift
import WapleCore

public enum RendererFactory {
    /// MVP: video 만 지원. 나머지 타입은 nil(미지원).
    public static func makeRenderer(for type: WallpaperType) -> WallpaperRenderer? {
        switch type {
        case .video: return VideoRenderer()
        default: return nil
        }
    }
}
```

- [ ] **Step 6: VideoRenderer 구현**

`Sources/WapleRender/VideoRenderer.swift`:
```swift
import AppKit
import AVFoundation
import WapleCore

public final class VideoRenderer: WallpaperRenderer {
    /// AVFoundation 이 디코드하지 못하는 컨테이너 확장자.
    public static let unsupportedExtensions: Set<String> = ["webm", "mkv"]

    public static func isSupportedContainer(_ url: URL) -> Bool {
        !unsupportedExtensions.contains(url.pathExtension.lowercased())
    }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?

    public init() {}

    public func mount(in container: NSView, project: WallpaperProject) throws {
        guard let fileName = project.fileName else { throw RendererError.assetMissing }
        let url = project.folderURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw RendererError.assetMissing }
        guard VideoRenderer.isSupportedContainer(url) else { throw RendererError.unsupportedCodec }

        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        let looper = AVPlayerLooper(player: queue, templateItem: item)
        queue.isMuted = true

        let layer = AVPlayerLayer(player: queue)
        layer.videoGravity = .resizeAspectFill
        container.wantsLayer = true
        layer.frame = container.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        container.layer?.addSublayer(layer)
        queue.play()

        self.player = queue
        self.looper = looper
        self.playerLayer = layer
    }

    public func pause() { player?.pause() }
    public func resume() { player?.play() }

    public func teardown() {
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        player = nil
        looper = nil
        playerLayer = nil
    }
}
```

- [ ] **Step 7: 테스트 통과 확인**

Run: `swift test --filter RendererFactoryTests`
Expected: PASS (3 tests). `swift build` 전체 성공.

- [ ] **Step 8: 커밋**

```bash
git add Sources/WapleRender Tests/WapleRenderTests
git commit -m "feat: renderer protocol, factory, and AVFoundation VideoRenderer"
```

---

### Task 5: 최소 메뉴바 실행 파일

자동 테스트 불가(GUI). **수동 검증**으로 진행한다.

**Files:**
- Create: `Sources/Waple/AppDelegate.swift`
- Modify: `Sources/Waple/main.swift` (전체 교체)

**Interfaces:**
- Produces: `final class AppDelegate: NSObject, NSApplicationDelegate`

- [ ] **Step 1: main.swift 교체**

`Sources/Waple/main.swift`:
```swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // Dock 아이콘 없는 메뉴바(액세서리) 앱
app.run()
```

- [ ] **Step 2: AppDelegate 작성**

`Sources/Waple/AppDelegate.swift`:
```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖼"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Quit Waple",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem.menu = menu
    }
}
```

- [ ] **Step 3: 빌드 확인**

Run: `swift build`
Expected: 성공.

- [ ] **Step 4: 수동 검증**

Run: `swift run Waple`
관찰(모두 충족해야 통과):
- 메뉴바 우측에 🖼 아이콘이 나타난다.
- **Dock 에는 아이콘이 생기지 않는다.**
- 🖼 클릭 → "Quit Waple" 메뉴가 보이고, 클릭하면 앱이 종료된다.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Waple
git commit -m "feat: minimal menu bar (accessory) app"
```

---

### Task 6: `DesktopWindowController` — 데스크탑-레벨 창 (핵심 OS 검증 게이트)

자동 테스트 불가. **수동 검증.** 이 태스크가 "신규 macOS에서 데스크탑 창 레벨이 동작하는가"를 실증한다.

**Files:**
- Create: `Sources/WapleRender/DesktopWindow.swift`
- Create: `Sources/WapleRender/DesktopWindowController.swift`
- Modify: `Sources/Waple/AppDelegate.swift`

**Interfaces:**
- Produces:
  - `final class DesktopWindow: NSWindow { init(screen: NSScreen) }`
  - `final class DesktopWindowController`
    - `func rebuild()`
    - `var contentViews: [NSView]` (get)
    - `func teardown()`

- [ ] **Step 1: DesktopWindow 작성**

`Sources/WapleRender/DesktopWindow.swift`:
```swift
import AppKit

public final class DesktopWindow: NSWindow {
    public init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        // 시작점: 아이콘 뒤·정적 배경 위. Step 4 에서 실측 검증할 것.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        setFrame(screen.frame, display: true)

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        contentView = content
    }
}
```

- [ ] **Step 2: DesktopWindowController 작성**

`Sources/WapleRender/DesktopWindowController.swift`:
```swift
import AppKit

public final class DesktopWindowController {
    private var windows: [DesktopWindow] = []

    public init() {}

    /// 모든 화면에 대해 데스크탑 창을 다시 만든다.
    public func rebuild() {
        teardown()
        for screen in NSScreen.screens {
            let window = DesktopWindow(screen: screen)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    public var contentViews: [NSView] {
        windows.compactMap { $0.contentView }
    }

    public func teardown() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}
```

- [ ] **Step 3: AppDelegate 에 디버그 색 채우기 연결**

`Sources/Waple/AppDelegate.swift` 전체를 다음으로 교체:
```swift
import AppKit
import WapleRender

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let desktopController = DesktopWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖼"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Quit Waple",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem.menu = menu

        // 디버그: 데스크탑 창이 보이는지 확인용 반투명 빨강. Task 7 에서 영상으로 대체.
        desktopController.rebuild()
        for view in desktopController.contentViews {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.5).cgColor
        }
    }
}
```

- [ ] **Step 4: 수동 검증 (핵심 게이트)**

Run: `swift run Waple`
관찰(모두 충족해야 통과):
- 데스크탑 전체에 **반투명 빨강 틴트**가 깔린다.
- 빨강은 **바탕화면 아이콘보다 뒤**에 있다(아이콘이 빨강 위에 보임).
- 창에 마우스 클릭이 막히지 않는다(아이콘/Finder 정상 클릭).
- **Mission Control** 진입 후 복귀 시에도 빨강이 유지된다.
- **"데스크탑 보기"(F11/핫코너)** 및 **Stage Manager** 토글 시 동작 확인.
- 멀티 모니터면 **모든 화면**에 빨강이 깔린다.

**검증 실패 시 대처(레벨 조정 후 Step 3의 컨트롤러 재실행):**
- 빨강이 아이콘을 **덮으면** 레벨이 너무 높음 → `DesktopWindow` 의 `level` 을
  `NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)` 로 변경.
- 빨강이 **안 보이면**(배경에 묻힘) → 위 `desktopIconWindow - 1` 또는
  `Int(CGWindowLevelForKey(.desktopWindow)) + 1` 로 상향 조정.
- 동작하는 값을 찾으면 `DesktopWindow.swift` 에 그 값으로 확정하고 주석으로 근거를 남긴다.

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleRender Sources/Waple
git commit -m "feat: desktop-level windows across all screens (debug fill)"
```

---

### Task 7: VideoRenderer 를 데스크탑 창에 연결 (폴더 적용)

자동 테스트 불가. **수동 검증.** 디버그 빨강을 실제 영상 재생으로 대체하고, 폴더 선택으로 적용한다.

**Files:**
- Modify: `Sources/Waple/AppDelegate.swift`

**Interfaces:**
- Consumes: `ProjectJSONParser.parse(folderURL:)`, `RendererFactory.makeRenderer(for:)`, `WallpaperRenderer`, `DesktopWindowController`
- Produces: `AppDelegate.apply(folderURL: URL)` (private), "Apply Folder…" 메뉴

- [ ] **Step 1: AppDelegate 교체 (영상 적용 로직 추가)**

`Sources/Waple/AppDelegate.swift` 전체를 다음으로 교체:
```swift
import AppKit
import WapleCore
import WapleRender

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let desktopController = DesktopWindowController()
    private var renderers: [WallpaperRenderer] = []
    private var currentFolderURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖼"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Apply Folder…",
                                action: #selector(chooseFolder), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Waple",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        desktopController.rebuild()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            apply(folderURL: url)
        }
    }

    private func apply(folderURL: URL) {
        do {
            let project = try ProjectJSONParser.parse(folderURL: folderURL)
            guard RendererFactory.makeRenderer(for: project.type) != nil else {
                notify("지원하지 않는 타입입니다: \(project.type.storageString)")
                return
            }
            renderers.forEach { $0.teardown() }
            renderers.removeAll()
            for view in desktopController.contentViews {
                guard let renderer = RendererFactory.makeRenderer(for: project.type) else { continue }
                try renderer.mount(in: view, project: project)
                renderers.append(renderer)
            }
            currentFolderURL = folderURL
        } catch {
            notify("적용 실패: \(error)")
        }
    }

    private func notify(_ message: String) {
        NSLog("[Waple] \(message)")
    }
}
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build`
Expected: 성공.

- [ ] **Step 3: 수동 검증**

Run: `swift run Waple`
- 🖼 → "Apply Folder…" → **실제 동영상 폴더** 선택(예: `/Users/yakisoba/Downloads/packages/2411966322`).
관찰:
- 동영상이 데스크탑 전체에 **끊김 없이 루프** 재생된다.
- **소리가 나지 않는다**(음소거).
- 아이콘이 영상 위에 정상 표시·클릭된다.
- (선택) `2913506072`(세로형)로도 적용 → 화면을 가득 채운다(aspect-fill).
- (선택) webm 폴더가 있다면 적용 시 `notify` 로그에 코덱 미지원 메시지가 남고 크래시하지 않는다.

- [ ] **Step 4: 커밋**

```bash
git add Sources/Waple
git commit -m "feat: apply video wallpaper to desktop windows via folder picker"
```

---

### Task 8: SwiftUI 라이브러리 창 (그리드 + 임포트 + 적용)

자동 테스트 불가. **수동 검증(엔드투엔드).** 메뉴바에서 라이브러리 창을 열고, 폴더를 일괄 임포트해 썸네일 그리드에서 적용한다.

**Files:**
- Create: `Sources/Waple/LibraryViewModel.swift`
- Create: `Sources/Waple/LibraryView.swift`
- Modify: `Sources/Waple/AppDelegate.swift`

**Interfaces:**
- Consumes: `LibraryStore`, `LibraryEntry`, `WallpaperType`, `AppDelegate.apply(folderURL:)`
- Produces:
  - `final class LibraryViewModel: ObservableObject`
    - `init(store: LibraryStore)`
    - `@Published var entries: [LibraryEntry]`
    - `var onApply: ((URL) -> Void)?`
    - `func importParent(_ url: URL)`
    - `func apply(_ entry: LibraryEntry)`
    - `func previewURL(for entry: LibraryEntry) -> URL?`
  - `struct LibraryView: View { init(viewModel: LibraryViewModel) }`

- [ ] **Step 1: LibraryViewModel 작성**

`Sources/Waple/LibraryViewModel.swift`:
```swift
import Foundation
import Combine
import WapleCore
import WapleLibrary

final class LibraryViewModel: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published var selectedId: String?

    /// 적용 요청을 AppDelegate 로 전달한다(폴더 URL).
    var onApply: ((URL) -> Void)?

    private let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
        self.entries = store.entries
        self.selectedId = store.selectedId
    }

    func importParent(_ url: URL) {
        store.importParent(url)
        entries = store.entries
    }

    func apply(_ entry: LibraryEntry) {
        guard let folder = store.resolveFolderURL(for: entry) else { return }
        store.select(entry.id)
        selectedId = entry.id
        onApply?(folder)
    }

    func previewURL(for entry: LibraryEntry) -> URL? {
        guard let folder = store.resolveFolderURL(for: entry),
              let preview = entry.previewName else { return nil }
        return folder.appendingPathComponent(preview)
    }

    func isSupported(_ entry: LibraryEntry) -> Bool {
        WallpaperType.from(entry.typeRaw).isSupportedInMVP
    }
}
```

- [ ] **Step 2: LibraryView 작성**

`Sources/Waple/LibraryView.swift`:
```swift
import SwiftUI
import AppKit
import WapleLibrary

struct LibraryView: View {
    @ObservedObject var viewModel: LibraryViewModel

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Waple 라이브러리").font(.headline)
                Spacer()
                Button("폴더 가져오기…") { importFolder() }
            }
            .padding()

            if viewModel.entries.isEmpty {
                Spacer()
                Text("‘폴더 가져오기…’로 Wallpaper Engine 폴더를 추가하세요.")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(viewModel.entries, id: \.id) { entry in
                            tile(for: entry)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    @ViewBuilder
    private func tile(for entry: LibraryEntry) -> some View {
        let supported = viewModel.isSupported(entry)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                previewImage(for: entry)
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .cornerRadius(8)
                Text(supported ? entry.typeRaw : "지원 예정")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(supported ? Color.accentColor : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(4)
                    .padding(6)
            }
            Text(entry.title).font(.caption).lineLimit(1)
        }
        .opacity(supported ? 1.0 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture {
            if supported { viewModel.apply(entry) }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(viewModel.selectedId == entry.id ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    @ViewBuilder
    private func previewImage(for entry: LibraryEntry) -> some View {
        if let url = viewModel.previewURL(for: entry), let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(Color.gray.opacity(0.3))
        }
    }

    private func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Wallpaper Engine 폴더(또는 여러 배경을 담은 상위 폴더)를 선택하세요."
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.importParent(url)
        }
    }
}
```

> 참고: `importParent` 는 선택한 폴더의 하위 폴더들을 스캔한다. 단일 배경 폴더를 직접
> 고르면 그 폴더 안에 배경 하위폴더가 없으므로 비게 된다 — 사용자는 보통 `packages` 같은
> **상위 폴더**를 고른다. (단일 폴더 직접 임포트는 향후 옵션.)

- [ ] **Step 3: AppDelegate 에 라이브러리 창 연결**

`Sources/Waple/AppDelegate.swift` 전체를 다음으로 교체:
```swift
import AppKit
import SwiftUI
import WapleCore
import WapleLibrary
import WapleRender

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let desktopController = DesktopWindowController()
    private var renderers: [WallpaperRenderer] = []
    private var currentFolderURL: URL?

    private let store = LibraryStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private lazy var libraryVM = LibraryViewModel(store: store)
    private var libraryWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖼"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "라이브러리 열기",
                                action: #selector(openLibrary), keyEquivalent: "l"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Waple",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        libraryVM.onApply = { [weak self] folder in self?.apply(folderURL: folder) }

        desktopController.rebuild()
    }

    @objc private func openLibrary() {
        if libraryWindow == nil {
            let hosting = NSHostingController(rootView: LibraryView(viewModel: libraryVM))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Waple"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 760, height: 500))
            libraryWindow = window
        }
        libraryWindow?.center()
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func apply(folderURL: URL) {
        do {
            let project = try ProjectJSONParser.parse(folderURL: folderURL)
            guard RendererFactory.makeRenderer(for: project.type) != nil else {
                notify("지원하지 않는 타입입니다: \(project.type.storageString)")
                return
            }
            renderers.forEach { $0.teardown() }
            renderers.removeAll()
            for view in desktopController.contentViews {
                guard let renderer = RendererFactory.makeRenderer(for: project.type) else { continue }
                try renderer.mount(in: view, project: project)
                renderers.append(renderer)
            }
            currentFolderURL = folderURL
        } catch {
            notify("적용 실패: \(error)")
        }
    }

    private func notify(_ message: String) {
        NSLog("[Waple] \(message)")
    }
}
```

- [ ] **Step 4: 빌드 확인**

Run: `swift build`
Expected: 성공.

- [ ] **Step 5: 수동 검증 (엔드투엔드)**

Run: `swift run Waple`
- 🖼 → "라이브러리 열기" → 창이 뜬다.
- "폴더 가져오기…" → `/Users/yakisoba/Downloads/packages` 선택.
관찰:
- 그리드에 배경들이 썸네일과 함께 나타난다(동영상 9개 + 씬/웹/프리셋).
- 동영상이 아닌 항목은 **"지원 예정" 배지 + 흐리게** 표시되고 클릭해도 적용되지 않는다.
- 동영상 타일을 클릭하면 데스크탑에 영상이 적용되고, 타일에 선택 테두리가 생긴다.

- [ ] **Step 6: 커밋**

```bash
git add Sources/Waple
git commit -m "feat: SwiftUI library window with grid, import, and apply"
```

---

### Task 9: 실행 시 복원 + 화면 변경 대응

자동 테스트 불가. **수동 검증.** 마지막 적용 배경을 실행 시 복원하고, 모니터 연결/해상도 변경 시 재렌더한다.

**Files:**
- Modify: `Sources/Waple/AppDelegate.swift`

**Interfaces:**
- Consumes: `LibraryStore.selectedId`, `LibraryStore.entries`, `LibraryStore.resolveFolderURL(for:)`, `NSApplication.didChangeScreenParametersNotification`

- [ ] **Step 1: AppDelegate 전체 교체 (복원 + 화면 변경 핸들러 추가)**

`Sources/Waple/AppDelegate.swift` 전체를 다음으로 교체:
```swift
import AppKit
import SwiftUI
import WapleCore
import WapleLibrary
import WapleRender

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let desktopController = DesktopWindowController()
    private var renderers: [WallpaperRenderer] = []
    private var currentFolderURL: URL?

    private let store = LibraryStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private lazy var libraryVM = LibraryViewModel(store: store)
    private var libraryWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🖼"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "라이브러리 열기",
                                action: #selector(openLibrary), keyEquivalent: "l"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Waple",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        libraryVM.onApply = { [weak self] folder in self?.apply(folderURL: folder) }

        desktopController.rebuild()

        // 화면 구성 변경(모니터 연결/해제/해상도) 시 창 재구성 후 재적용.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // 마지막 선택 배경 복원.
        restoreLastWallpaper()
    }

    @objc private func openLibrary() {
        if libraryWindow == nil {
            let hosting = NSHostingController(rootView: LibraryView(viewModel: libraryVM))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Waple"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 760, height: 500))
            libraryWindow = window
        }
        libraryWindow?.center()
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func apply(folderURL: URL) {
        do {
            let project = try ProjectJSONParser.parse(folderURL: folderURL)
            guard RendererFactory.makeRenderer(for: project.type) != nil else {
                notify("지원하지 않는 타입입니다: \(project.type.storageString)")
                return
            }
            renderers.forEach { $0.teardown() }
            renderers.removeAll()
            for view in desktopController.contentViews {
                guard let renderer = RendererFactory.makeRenderer(for: project.type) else { continue }
                try renderer.mount(in: view, project: project)
                renderers.append(renderer)
            }
            currentFolderURL = folderURL
        } catch {
            notify("적용 실패: \(error)")
        }
    }

    private func restoreLastWallpaper() {
        guard let id = store.selectedId,
              let entry = store.entries.first(where: { $0.id == id }),
              let folder = store.resolveFolderURL(for: entry) else { return }
        apply(folderURL: folder)
    }

    @objc private func screensChanged() {
        desktopController.rebuild()
        if let folder = currentFolderURL {
            apply(folderURL: folder)
        }
    }

    private func notify(_ message: String) {
        NSLog("[Waple] \(message)")
    }
}
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build`
Expected: 성공. (빌드 에러 시 중괄호 정합성부터 점검.)

- [ ] **Step 3: 수동 검증**

Run: `swift run Waple`
- 라이브러리에서 동영상 적용 → 앱 종료(🖼 → Quit).
- 다시 `swift run Waple` → **마지막 동영상이 자동으로 재생**된다.
- (멀티/외장 모니터가 있으면) 해상도 변경 또는 모니터 연결/해제 시 영상이 **모든 화면에 다시** 깔린다.

- [ ] **Step 4: 커밋**

```bash
git add Sources/Waple
git commit -m "feat: restore last wallpaper on launch and re-render on screen change"
```

---

## Self-Review (작성자 체크리스트 결과)

**1. 스펙 커버리지**
- project.json 파서/스키마(§3) → Task 2 ✅
- 모든 타입 인식 + 미지원 강등(§6) → Task 1(enum), Task 4(factory nil), Task 8(배지) ✅
- 원본 위치 참조 + 북마크 + 영속화(§2,§4.2) → Task 3 ✅
- 일괄 임포트(§4.2) → Task 3 `importParent` + Task 8 UI ✅
- 데스크탑-레벨 창 + 멀티모니터 동일(§4.3) → Task 6, Task 9 ✅
- 렌더러 추상화 + VideoRenderer(루프/음소거/aspect-fill/코덱)(§4.3) → Task 4 ✅
- 메뉴바 앱 + SwiftUI 라이브러리 창(§2,§4.4) → Task 5, Task 8 ✅
- 실행 복원(§4.4) → Task 9 ✅
- 코덱 미지원 우아한 강등(§6) → Task 4 `isSupportedContainer`/throw + Task 7 검증 ✅
- 데스크탑 창 레벨 실측 검증(§9) → Task 6 Step 4 게이트 ✅
- 단위 테스트(§7) → Task 1~4 ✅; 수동 통합 검증 → Task 5~9 ✅

**2. 플레이스홀더 스캔:** TBD/TODO/모호 지시 없음. GUI 태스크는 구체적 관찰 항목으로 검증. ✅

**3. 타입 일관성:** `WallpaperType.from/storageString/isSupportedInMVP`, `ProjectJSONParser.parse(folderURL:)`/`parse(data:folderURL:)`, `LibraryStore` 메서드 시그니처, `WallpaperRenderer.mount/pause/resume/teardown`, `RendererFactory.makeRenderer(for:)`, `VideoRenderer.isSupportedContainer`, `DesktopWindowController.rebuild/contentViews/teardown`, `LibraryViewModel.onApply/importParent/apply/previewURL/isSupported`, `AppDelegate.apply(folderURL:)` — 태스크 간 명칭/시그니처 일치 확인. ✅

**범위 밖(스펙 §8) 의도적 미포함:** 씬/웹/프리셋 렌더링, 자원 절약(가림/배터리), 오디오 토글, aspect fit 옵션, properties 설정 UI, 화면별 다른 배경, webm 폴백, 배포(서명/공증/자동업데이트).
