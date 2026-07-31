# Waple Scene SP1.5 (Video-Texture + Scene Surfacing) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** WE 씬의 `.tex`에 내장된 MP4를 추출해 AVFoundation으로 재생하고, 씬 타입을 라이브러리에 정식 노출(부분 렌더 포함)한다.

**Architecture:** `SceneRenderer.mount`가 비디오-텍스처 레이어를 감지하면 내장 MP4를 캐시로 추출해 기존 `VideoRenderer`에 위임, 아니면 기존 Metal 이미지 컴포지터. `.scene`은 실험 플래그를 제거하고 항상 라우팅, `isSupportedInMVP`/라이브러리 배지로 노출.

**Tech Stack:** Swift 5.9, AVFoundation(기존 VideoRenderer 재사용), Metal(기존), XCTest. 새 의존성·새 타깃 없음.

## Global Constraints

- 기존 SPM 패키지에 추가. **새 타깃·서드파티 의존성 없음.** tools 5.9, macOS 13+.
- 비디오 페이로드 판별: `TexImage.parse(...).payload == .video`, MP4 바이트 = `texData.subdata(in: payloadRange)`(`ftyp` 박스로 시작).
- 추출 캐시: `~/Library/Application Support/Waple/cache/<sceneID>.mp4`(존재 시 재사용).
- 비디오는 **음소거·끊김없는 루프·resizeAspectFill**(VideoRenderer 기본).
- `.scene`은 실험 플래그 없이 항상 `SceneRenderer`로 라우팅. 라이브러리 노출, 씬 배지 = `scene · 부분`.
- 비디오 + 이펙트 씬은 비디오만(부분), BC3-only/이펙트-only 씬은 블랭크/부분(사용자 수용), 무크래시.

**전제:** main에서 시작(SP1 병합됨), `swift build`/`swift test` 그린. 검증 씬: `/Users/yakisoba/Downloads/packages/2958411739`.

---

### Task 1: `WallpaperType.isSupportedInMVP` 에 scene 추가

**Files:**
- Modify: `Sources/WapleCore/WallpaperType.swift`
- Modify: `Tests/WapleCoreTests/WallpaperTypeTests.swift`

**Interfaces:**
- Produces: `WallpaperType.scene.isSupportedInMVP == true`

- [ ] **Step 1: 테스트 교체(실패)**

`Tests/WapleCoreTests/WallpaperTypeTests.swift` 의 `testVideoAndWebAreSupportedInMVP` 를 다음으로 교체:
```swift
    func testVideoWebSceneAreSupportedInMVP() {
        XCTAssertTrue(WallpaperType.video.isSupportedInMVP)
        XCTAssertTrue(WallpaperType.web.isSupportedInMVP)
        XCTAssertTrue(WallpaperType.scene.isSupportedInMVP)
        XCTAssertFalse(WallpaperType.preset.isSupportedInMVP)
        XCTAssertFalse(WallpaperType.application.isSupportedInMVP)
    }
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter WallpaperTypeTests`
Expected: FAIL (scene.isSupportedInMVP == false).

- [ ] **Step 3: 구현 수정**

`Sources/WapleCore/WallpaperType.swift` 의 `isSupportedInMVP` 를 다음으로 교체:
```swift
    public var isSupportedInMVP: Bool { self == .video || self == .web || self == .scene }
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter WallpaperTypeTests`
Expected: PASS.

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleCore/WallpaperType.swift Tests/WapleCoreTests/WallpaperTypeTests.swift
git commit -m "feat: mark scene type as supported in library"
```

---

### Task 2: `VideoTextureExtractor` (비디오 레이어 탐지 + MP4 추출)

**Files:**
- Create: `Sources/WapleRender/VideoTextureExtractor.swift`
- Test: `Tests/WapleRenderTests/VideoTextureExtractorTests.swift`

**Interfaces:**
- Consumes: `ScenePackage`, `SceneDocument`, `TexImage` (WapleCore)
- Produces:
  - `enum VideoTextureExtractor`
    - `static func videoLayer(in doc: SceneDocument, package: ScenePackage) -> String?`
    - `static func extractMP4(textureEntryName: String, package: ScenePackage, sceneID: String, cacheDir: URL) -> URL?`
    - `static func defaultCacheDir() -> URL`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/WapleRenderTests/VideoTextureExtractorTests.swift`:
```swift
import XCTest
@testable import WapleRender
@testable import WapleCore

final class VideoTextureExtractorTests: XCTestCase {
    private func i32(_ v: Int) -> [UInt8] {
        let u = UInt32(truncatingIfNeeded: v)
        return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
    }
    /// TEX 헤더 + 임의 페이로드.
    private func makeTex(format: Int, w: Int, h: Int, payload: [UInt8]) -> Data {
        var b: [UInt8] = []
        b += Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(format) + i32(0) + i32(w) + i32(h) + i32(w) + i32(h)
        b += Array("TEXB0001".utf8) + [0] + payload
        return Data(b)
    }
    private func makePkg(_ files: [(String, Data)]) -> Data {
        let ver = Array("PKGV0001".utf8)
        var out = i32(ver.count) + ver + i32(files.count)
        var off = 0
        for (name, data) in files {
            let nm = Array(name.utf8)
            out += i32(nm.count) + nm + i32(off) + i32(data.count); off += data.count
        }
        for (_, data) in files { out += [UInt8](data) }
        return Data(out)
    }
    private func scenePkg(videoTex: Bool) throws -> ScenePackage {
        let scene = Data(#"{"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},"objects":[{"image":"models/m.json","origin":"50 50 0","size":"100 100","scale":"1 1 1","angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}]}"#.utf8)
        let model = Data(#"{"material":"materials/mat.json"}"#.utf8)
        let material = Data(#"{"passes":[{"shader":"genericimage2","textures":["v"]}]}"#.utf8)
        let mp4: [UInt8] = i32(0x18) + Array("ftypisom".utf8) + [1, 2, 3]
        let tex = makeTex(format: 0, w: 100, h: 100, payload: videoTex ? mp4 : [0x89, 0x50, 0x4E, 0x47, 1, 2])
        return try ScenePackage.parse(makePkg([
            ("scene.json", scene), ("models/m.json", model), ("materials/mat.json", material), ("materials/v.tex", tex),
        ]))
    }

    func testDetectsVideoLayer() throws {
        let pkg = try scenePkg(videoTex: true)
        let doc = try SceneDocument.parse(package: pkg)
        XCTAssertEqual(VideoTextureExtractor.videoLayer(in: doc, package: pkg), "materials/v.tex")
    }

    func testNoVideoLayerForImageTex() throws {
        let pkg = try scenePkg(videoTex: false)
        let doc = try SceneDocument.parse(package: pkg)
        XCTAssertNil(VideoTextureExtractor.videoLayer(in: pkg.isEmpty ? doc : doc, package: pkg))
    }

    func testExtractsMP4Bytes() throws {
        let pkg = try scenePkg(videoTex: true)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WapleMP4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(VideoTextureExtractor.extractMP4(textureEntryName: "materials/v.tex", package: pkg, sceneID: "42", cacheDir: dir))
        XCTAssertEqual(url.lastPathComponent, "42.mp4")
        let bytes = [UInt8](try Data(contentsOf: url))
        // mp4 박스: [size 4][ftyp...]
        XCTAssertEqual(Array(bytes[4..<8]), Array("ftyp".utf8))
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter VideoTextureExtractorTests`
Expected: 컴파일 에러 ("cannot find 'VideoTextureExtractor'").

- [ ] **Step 3: 구현 작성**

`Sources/WapleRender/VideoTextureExtractor.swift`:
```swift
import Foundation
import WapleCore

public enum VideoTextureExtractor {
    /// 씬의 첫 비디오-텍스처 레이어 entry name(없으면 nil).
    public static func videoLayer(in doc: SceneDocument, package: ScenePackage) -> String? {
        for layer in doc.layers {
            guard let texData = package.data(for: layer.textureEntryName),
                  let tex = TexImage.parse(texData) else { continue }
            if tex.payload == .video { return layer.textureEntryName }
        }
        return nil
    }

    /// 비디오 .tex의 내장 MP4 바이트를 캐시 파일로 추출(있으면 재사용) → URL.
    public static func extractMP4(textureEntryName: String, package: ScenePackage, sceneID: String, cacheDir: URL) -> URL? {
        guard let texData = package.data(for: textureEntryName),
              let tex = TexImage.parse(texData), tex.payload == .video else { return nil }
        let url = cacheDir.appendingPathComponent("\(sceneID).mp4")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let mp4 = texData.subdata(in: tex.payloadRange)
        guard (try? mp4.write(to: url)) != nil else { return nil }
        return url
    }

    public static func defaultCacheDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Waple/cache", isDirectory: true)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter VideoTextureExtractorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleRender/VideoTextureExtractor.swift Tests/WapleRenderTests/VideoTextureExtractorTests.swift
git commit -m "feat: VideoTextureExtractor (detect + extract embedded MP4)"
```

---

### Task 3: `RendererFactory` — 실험 플래그 제거, scene 항상 라우팅

**Files:**
- Modify: `Sources/WapleRender/RendererFactory.swift` (전체 교체)
- Modify: `Tests/WapleRenderTests/RendererFactoryTests.swift` (scene 테스트 교체)

**Interfaces:**
- Produces: `.scene` → `SceneRenderer` (무조건). `experimentalSceneEnabled` 제거.

- [ ] **Step 1: 테스트 교체(실패)**

`Tests/WapleRenderTests/RendererFactoryTests.swift` 의 `testSceneNilByDefaultRendersWhenExperimentalEnabled` 를 다음으로 교체:
```swift
    func testSceneAlwaysReturnsSceneRenderer() {
        XCTAssertTrue(RendererFactory.makeRenderer(for: project(type: .scene, file: "scene.json")) is SceneRenderer)
    }
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter RendererFactoryTests`
Expected: FAIL — 아직 팩토리가 `.scene`을 `experimentalSceneEnabled`(기본 false) 뒤로 막아 `nil`을 반환하므로 `is SceneRenderer`가 거짓. (컴파일은 됨: 교체된 테스트는 더 이상 `experimentalSceneEnabled`를 참조하지 않음.)

- [ ] **Step 3: 팩토리 교체**

`Sources/WapleRender/RendererFactory.swift` 전체를 다음으로 교체:
```swift
import Foundation
import WapleCore

public enum RendererFactory {
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
        case .scene:
            return SceneRenderer()
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: 테스트·빌드 확인**

Run: `swift test --filter RendererFactoryTests` → PASS. `swift build` 성공.
(만약 다른 곳에서 `experimentalSceneEnabled`를 참조하면 컴파일 에러 — 본 플랜엔 그 참조가 Task 5의 임시 검증뿐이므로 정식 코드엔 없음.)

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleRender/RendererFactory.swift Tests/WapleRenderTests/RendererFactoryTests.swift
git commit -m "feat: route scene to SceneRenderer unconditionally"
```

---

### Task 4: `SceneRenderer` 비디오-텍스처 분기

자동 테스트 불가(AVFoundation/GUI). **`swift build` 성공까지**; 재생은 Task 5.

**Files:**
- Modify: `Sources/WapleRender/SceneRenderer.swift`

**Interfaces:**
- Consumes: `VideoTextureExtractor`, `VideoRenderer`, `WallpaperProject`
- Produces: SceneRenderer가 비디오-텍스처 씬을 VideoRenderer로 위임

- [ ] **Step 1: 비디오 프로퍼티 추가**

`Sources/WapleRender/SceneRenderer.swift` 의 `private var mtkView: MTKView?` 위(프로퍼티 영역)에 추가:
```swift
    private var videoRenderer: VideoRenderer?
```

- [ ] **Step 2: mount에 비디오 분기 삽입**

`mount(in:project:)` 에서 `package`/`doc` 파싱 guard 직후(`guard let device = MTLCreateSystemDefaultDevice()` 바로 앞)에 삽입:
```swift
        // 비디오-텍스처 씬 → 내장 MP4 추출 후 VideoRenderer 위임.
        if let videoName = VideoTextureExtractor.videoLayer(in: doc, package: package),
           let mp4URL = VideoTextureExtractor.extractMP4(textureEntryName: videoName, package: package,
                                                         sceneID: project.id, cacheDir: VideoTextureExtractor.defaultCacheDir()) {
            let synthetic = WallpaperProject(
                id: project.id, type: .video, fileName: mp4URL.lastPathComponent, previewName: nil,
                title: project.title, tags: [], contentRating: nil, workshopId: nil, dependency: nil,
                folderURL: mp4URL.deletingLastPathComponent())
            let vr = VideoRenderer()
            try vr.mount(in: container, project: synthetic)
            self.videoRenderer = vr
            return
        }
```

- [ ] **Step 3: pause/resume/teardown 위임**

`pause()`/`resume()`/`teardown()` 를 다음으로 교체:
```swift
    public func pause() { videoRenderer?.pause() }
    public func resume() {
        if let videoRenderer { videoRenderer.resume() } else { mtkView?.needsDisplay = true }
    }
    public func teardown() {
        videoRenderer?.teardown(); videoRenderer = nil
        mtkView?.removeFromSuperview()
        mtkView = nil; layers = []; pipeline = nil; queue = nil; device = nil
    }
```

- [ ] **Step 4: 빌드 확인**

Run: `swift build`
Expected: 성공.

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleRender/SceneRenderer.swift
git commit -m "feat: SceneRenderer plays video-texture scenes via VideoRenderer"
```

---

### Task 5: 라이브러리 씬 배지 + 수동 게이트

자동 테스트 불가(GUI). **수동 검증.**

**Files:**
- Modify: `Sources/Waple/LibraryView.swift`

**Interfaces:** 없음(UI)

- [ ] **Step 1: 씬 배지 라벨 수정**

`Sources/Waple/LibraryView.swift` 의 `tile(for:)` 안 배지 `Text(supported ? entry.typeRaw : "지원 예정")` 를 다음으로 교체:
```swift
                Text(badgeText(for: entry, supported: supported))
```
그리고 `LibraryView` 에 헬퍼 메서드 추가(다른 `private func` 옆):
```swift
    private func badgeText(for entry: LibraryEntry, supported: Bool) -> String {
        guard supported else { return "지원 예정" }
        return entry.typeRaw.lowercased() == "scene" ? "scene · 부분" : entry.typeRaw
    }
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build`
Expected: 성공.

- [ ] **Step 3: 수동 게이트 — 비디오-텍스처 재생**

검증을 위해 `Sources/Waple/AppDelegate.swift` 의 `applicationDidFinishLaunching` 끝(`restoreLastWallpaper()` 다음)에 임시 추가(커밋 금지):
```swift
        // [TEMP VERIFY — 커밋 금지]
        apply(folderURL: URL(fileURLWithPath: "/Users/yakisoba/Downloads/packages/2958411739", isDirectory: true))
```
Run: `swift build && swift run Waple`
관찰: `2958411739`의 내장 비디오가 데스크탑에 **루프·음소거**로 재생되는가? 캐시 파일
`~/Library/Application Support/Waple/cache/2958411739.mp4` 생성 확인.

- [ ] **Step 4: 수동 게이트 — 라이브러리 노출**

임시 코드 제거 후 `swift run Waple` → 🖼 → 라이브러리 열기 → 폴더 가져오기(`packages`).
관찰: 씬 타일이 **클릭 가능**하고 배지가 **`scene · 부분`**. 비디오-텍스처 씬 클릭 시 재생, 다른 씬은 정적/부분 렌더(크래시 X).

- [ ] **Step 5: 임시 코드 제거 + 커밋**

```bash
git checkout -- Sources/Waple/AppDelegate.swift
grep -rn "TEMP VERIFY" Sources/ || echo clean
git add Sources/Waple/LibraryView.swift
git commit -m "feat: surface scenes in library with partial-support badge"
```

---

## Self-Review (작성자 체크리스트 결과)

**1. 스펙 커버리지**
- 비디오-텍스처 탐지/추출(§3-A,§4) → Task 2 ✅
- SceneRenderer 비디오 위임(§3-A) → Task 4 ✅
- 팩토리 플래그 제거·항상 라우팅(§3-B) → Task 3 ✅
- isSupportedInMVP += scene(§3-B) → Task 1 ✅
- 라이브러리 배지 `scene · 부분`(§3-B) → Task 5 ✅
- 음소거·루프·캐시(§Global) → Task 2(캐시)+Task 4(VideoRenderer 위임) ✅
- 부분/블랭크 graceful(§6) → Task 4(비디오 미감지 시 Metal)+SP1 스킵 로직 ✅
- TDD(§7) → Task 1,2,3 ✅; 수동 게이트(§7) → Task 5 ✅

**2. 플레이스홀더 스캔:** 없음. GUI는 구체 관찰 항목. ✅

**3. 타입 일관성:** `VideoTextureExtractor.videoLayer(in:package:)/extractMP4(textureEntryName:package:sceneID:cacheDir:)/defaultCacheDir()`,
`SceneRenderer.videoRenderer`, `RendererFactory.makeRenderer(for:)`(scene→SceneRenderer), `WallpaperType.isSupportedInMVP`,
`WallpaperProject` 합성 init 인자, `LibraryView.badgeText(for:supported:)` — 일치. ✅

**범위 밖(스펙 §8):** 비디오+이펙트 합성(SP3/SP5), 비디오-as-Metal-텍스처, BC3/패럴랙스(SP2), 캐시 정리 정책.
