# Waple Scene SP1 (Static Image Compositor) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wallpaper Engine `type:"scene"` 정적 이미지 씬을 `.pkg→.tex→scene.json→Metal`로 데스크탑에 렌더하는 SP1 기반을 만든다(체인 검증 + 이후 SP의 토대).

**Architecture:** 순수 파싱(`ScenePackage`/`TexImage`/`SceneDocument`)은 `WapleCore`에서 TDD, 디코드(`TexDecoder`, ImageIO)·Metal 컴포지터(`SceneRenderer`, MTKView)는 `WapleRender`. Metal 셰이더는 런타임 컴파일용 Swift 문자열로 임베드. `.scene`은 실험 플래그 뒤에서만 라우팅(사용자 미노출).

**Tech Stack:** Swift 5.9, Metal/MetalKit, ImageIO/CoreGraphics, AppKit, XCTest. 새 의존성·새 타깃·리소스 번들 없음.

## Global Constraints

- 기존 SPM 패키지에 추가. **새 타깃·서드파티 의존성·리소스 번들 없음.** tools 5.9, macOS 13+.
- `.pkg` 포맷: `int32 versionLen; ascii "PKGV00NN"; int32 entryCount; entryCount×{int32 nameLen; name; int32 offset; int32 size}; blob_base=테이블 직후; bytes=buf[blob_base+offset ..< +size]`.
- `.tex`: `"TEXV0005\0""TEXI0001\0"` + `int32 format(@18)` + flags(@22) + texW(@26) texH(@30) imgW(@34) imgH(@38) + `"TEXB000x\0"` 밉. 페이로드 종류는 시그니처로 판별(PNG `\x89PNG`, JPEG `\xFF\xD8\xFF`, 비디오 `ftyp`, format==9→BC3, 그 외 raw RGBA8888).
- 색상 문자열 = 공백 구분 0~1 실수("r g b"). 좌표 = 씬 픽셀, object `alignment:"center"`면 origin=쿼드 중심.
- SP1 디코드: **PNG/JPEG/raw RGBA8888만**. BC3·비디오·unknown 페이로드는 nil→레이어 스킵.
- `.scene`은 `RendererFactory.experimentalSceneEnabled`(기본 false)일 때만 SceneRenderer로 라우팅. 라이브러리 미노출.
- MTKView 정적 드로우(`isPaused=true`+`enableSetNeedsDisplay=true`).

**전제:** main에서 시작, `swift build`/`swift test` 그린. 검증용 실제 씬: `/Users/yakisoba/Downloads/packages/2899965423`(1 PNG), `.../2188368235`(2 PNG).

---

### Task 1: `ScenePackage` (.pkg 언패커)

**Files:**
- Create: `Sources/WapleCore/ScenePackage.swift`
- Test: `Tests/WapleCoreTests/ScenePackageTests.swift`

**Interfaces:**
- Produces:
  - `struct ScenePackage { var entries: [Entry]; func data(for name: String) -> Data?; static func parse(_ data: Data) throws -> ScenePackage }`
  - `struct ScenePackage.Entry: Equatable { let name: String; let offset: Int; let size: Int }`
  - `enum ScenePackageError: Error, Equatable { case malformed }`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/WapleCoreTests/ScenePackageTests.swift`:
```swift
import XCTest
@testable import WapleCore

final class ScenePackageTests: XCTestCase {
    /// 포맷대로 합성 .pkg 바이트 생성.
    static func makePkg(_ files: [(String, Data)], version: String = "PKGV0001") -> Data {
        func i32(_ v: Int) -> [UInt8] {
            let u = UInt32(truncatingIfNeeded: v)
            return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
        }
        let ver = Array(version.utf8)
        var out = i32(ver.count) + ver + i32(files.count)
        var offset = 0
        for (name, data) in files {
            let nm = Array(name.utf8)
            out += i32(nm.count) + nm + i32(offset) + i32(data.count)
            offset += data.count
        }
        for (_, data) in files { out += [UInt8](data) }
        return Data(out)
    }

    func testParsesEntriesAndExtractsData() throws {
        let scene = Data(#"{"version":1}"#.utf8)
        let mat = Data("MAT".utf8)
        let pkg = Self.makePkg([("scene.json", scene), ("materials/x.json", mat)])
        let p = try ScenePackage.parse(pkg)
        XCTAssertEqual(p.entries.map(\.name), ["scene.json", "materials/x.json"])
        XCTAssertEqual(p.data(for: "scene.json"), scene)
        XCTAssertEqual(p.data(for: "materials/x.json"), mat)
        XCTAssertNil(p.data(for: "nope"))
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try ScenePackage.parse(Data([0x08, 0x00]))) { e in
            XCTAssertEqual(e as? ScenePackageError, .malformed)
        }
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter ScenePackageTests`
Expected: 컴파일 에러 ("cannot find 'ScenePackage'").

- [ ] **Step 3: 구현 작성**

`Sources/WapleCore/ScenePackage.swift`:
```swift
import Foundation

public enum ScenePackageError: Error, Equatable { case malformed }

public struct ScenePackage {
    public struct Entry: Equatable {
        public let name: String
        public let offset: Int
        public let size: Int
    }

    public let entries: [Entry]
    private let blob: Data
    private let blobBase: Int

    private init(entries: [Entry], blob: Data, blobBase: Int) {
        self.entries = entries
        self.blob = blob
        self.blobBase = blobBase
    }

    public static func parse(_ data: Data) throws -> ScenePackage {
        let b = [UInt8](data)
        func i32(_ o: Int) throws -> Int {
            guard o >= 0, o + 4 <= b.count else { throw ScenePackageError.malformed }
            return Int(UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
        }
        var p = 0
        let vlen = try i32(p); p += 4
        guard vlen >= 0, p + vlen <= b.count else { throw ScenePackageError.malformed }
        p += vlen
        let count = try i32(p); p += 4
        guard count >= 0, count < 1_000_000 else { throw ScenePackageError.malformed }
        var entries: [Entry] = []
        for _ in 0..<count {
            let nlen = try i32(p); p += 4
            guard nlen >= 0, p + nlen <= b.count else { throw ScenePackageError.malformed }
            let name = String(decoding: b[p..<p + nlen], as: UTF8.self); p += nlen
            let off = try i32(p); p += 4
            let sz = try i32(p); p += 4
            entries.append(Entry(name: name, offset: off, size: sz))
        }
        let blobBase = p
        for e in entries {
            guard e.offset >= 0, e.size >= 0, blobBase + e.offset + e.size <= b.count else {
                throw ScenePackageError.malformed
            }
        }
        return ScenePackage(entries: entries, blob: data, blobBase: blobBase)
    }

    public func data(for name: String) -> Data? {
        guard let e = entries.first(where: { $0.name == name }) else { return nil }
        let start = blob.startIndex + blobBase + e.offset
        return blob.subdata(in: start ..< start + e.size)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter ScenePackageTests`
Expected: PASS (2 tests).

- [ ] **Step 5: 오라클 수동 대조 (ground truth, 커밋 안 함)**

`/tmp/wepkg.py`(정찰 스크립트)가 있으면 실제 pkg와 대조해 가정이 아닌 ground truth를 검증한다.
임시 검증 파일 `/tmp/OracleCheck.swift`로:
```swift
import Foundation
// 실제 pkg를 ScenePackage로 파싱 → scene.json 첫 바이트가 '{' 인지 + entries 출력
let url = URL(fileURLWithPath: "/Users/yakisoba/Downloads/packages/2899965423/scene.pkg")
// (이 스니펫은 WapleCore를 링크해 실행하거나, 동일 파싱 로직을 인라인해 확인)
```
간단히는: 빌드 후 임시 main이나 LLDB로 `ScenePackage.parse(Data(contentsOf:))` → `data(for:"scene.json")`의 첫 바이트가 `0x7B('{')`, entries에 `scene.json`/`models/*`/`materials/*.tex` 포함 확인.
(정찰 결과 `2899965423`는 PKGV0018, scene.json·models/Untitled.json·materials/Untitled.json·materials/Untitled.tex 보유.) 일치하면 OK.

- [ ] **Step 6: 커밋**

```bash
git add Sources/WapleCore/ScenePackage.swift Tests/WapleCoreTests/ScenePackageTests.swift
git commit -m "feat: ScenePackage (.pkg) unpacker"
```

---

### Task 2: `TexImage` (.tex 헤더 + 페이로드 종류)

**Files:**
- Create: `Sources/WapleCore/TexImage.swift`
- Test: `Tests/WapleCoreTests/TexImageTests.swift`

**Interfaces:**
- Produces:
  - `struct TexImage { let width:Int; let height:Int; let format:Int; let payload:PayloadKind; let payloadRange:Range<Int>; static func parse(_ data: Data) -> TexImage? }`
  - `enum TexImage.PayloadKind: Equatable { case png, jpeg, rawRGBA8888, bc3, video, unknown }`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/WapleCoreTests/TexImageTests.swift`:
```swift
import XCTest
@testable import WapleCore

final class TexImageTests: XCTestCase {
    /// TEX 헤더 + 임의 페이로드로 합성 .tex 생성.
    static func makeTex(format: Int, w: Int, h: Int, payload: [UInt8]) -> Data {
        func i32(_ v: Int) -> [UInt8] {
            let u = UInt32(truncatingIfNeeded: v)
            return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
        }
        var b: [UInt8] = []
        b += Array("TEXV0005".utf8) + [0]
        b += Array("TEXI0001".utf8) + [0]
        b += i32(format) + i32(0) + i32(w) + i32(h) + i32(w) + i32(h)
        b += Array("TEXB0001".utf8) + [0]
        b += payload
        return Data(b)
    }

    func testDetectsPNG() {
        let t = TexImage.parse(Self.makeTex(format: 0, w: 4, h: 4, payload: [0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
        XCTAssertEqual(t?.payload, .png)
        XCTAssertEqual(t?.width, 4); XCTAssertEqual(t?.height, 4)
    }
    func testDetectsJPEG() {
        XCTAssertEqual(TexImage.parse(Self.makeTex(format: 0, w: 2, h: 2, payload: [0xFF, 0xD8, 0xFF, 0xE0]))?.payload, .jpeg)
    }
    func testDetectsVideo() {
        // mp4 box: [size 4][ftyp][...]
        let p: [UInt8] = [0,0,0,0x18] + Array("ftypisom".utf8)
        XCTAssertEqual(TexImage.parse(Self.makeTex(format: 0, w: 8, h: 8, payload: p))?.payload, .video)
    }
    func testDetectsBC3ByFormatEnum() {
        XCTAssertEqual(TexImage.parse(Self.makeTex(format: 9, w: 8, h: 8, payload: [0,0,0,0]))?.payload, .bc3)
    }
    func testDefaultsToRawRGBA() {
        XCTAssertEqual(TexImage.parse(Self.makeTex(format: 0, w: 2, h: 2, payload: [0,0,0,0]))?.payload, .rawRGBA8888)
    }
    func testRejectsNonTex() {
        XCTAssertNil(TexImage.parse(Data("nope".utf8)))
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter TexImageTests`
Expected: 컴파일 에러 ("cannot find 'TexImage'").

- [ ] **Step 3: 구현 작성**

`Sources/WapleCore/TexImage.swift`:
```swift
import Foundation

public struct TexImage {
    public enum PayloadKind: Equatable { case png, jpeg, rawRGBA8888, bc3, video, unknown }

    public let width: Int
    public let height: Int
    public let format: Int
    public let payload: PayloadKind
    public let payloadRange: Range<Int>

    public static func parse(_ data: Data) -> TexImage? {
        let b = [UInt8](data)
        guard b.count > 42, b[0..<8].elementsEqual(Array("TEXV0005".utf8)) else { return nil }
        func i32(_ o: Int) -> Int {
            Int(UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24)
        }
        let format = i32(18)
        let width = i32(34)
        let height = i32(38)
        let (kind, start) = detect(b, format: format)
        return TexImage(width: width, height: height, format: format, payload: kind, payloadRange: start..<b.count)
    }

    private static func detect(_ b: [UInt8], format: Int) -> (PayloadKind, Int) {
        func find(_ sig: [UInt8], limit: Int = 4096) -> Int? {
            let upper = min(b.count - sig.count, limit)
            guard upper >= 0 else { return nil }
            var i = 0
            while i <= upper {
                if Array(b[i..<i + sig.count]) == sig { return i }
                i += 1
            }
            return nil
        }
        if let p = find([0x89, 0x50, 0x4E, 0x47]) { return (.png, p) }
        if let p = find([0xFF, 0xD8, 0xFF]) { return (.jpeg, p) }
        if let p = find(Array("ftyp".utf8), limit: 512), p >= 4 { return (.video, p - 4) }
        if format == 9 { return (.bc3, 0) }
        return (.rawRGBA8888, 0)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter TexImageTests`
Expected: PASS (6 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleCore/TexImage.swift Tests/WapleCoreTests/TexImageTests.swift
git commit -m "feat: TexImage (.tex) header parse and payload classification"
```

---

### Task 3: `SceneDocument` (scene.json + 간접참조 해석)

**Files:**
- Create: `Sources/WapleCore/SceneGeometry.swift` (Vec2/Vec3)
- Create: `Sources/WapleCore/SceneDocument.swift`
- Test: `Tests/WapleCoreTests/SceneDocumentTests.swift`

**Interfaces:**
- Consumes: `ScenePackage`
- Produces:
  - `struct Vec2: Equatable { let x:Float; let y:Float }`, `struct Vec3: Equatable { let x:Float; let y:Float; let z:Float }`
  - `struct SceneLayer: Equatable { let textureEntryName:String; let origin:Vec2; let size:Vec2; let scale:Vec2; let angleZ:Float; let alpha:Float; let color:Vec3; let brightness:Float }`
  - `struct SceneDocument: Equatable { let projectionWidth:Int; let projectionHeight:Int; let clearColor:Vec3; let layers:[SceneLayer]; static func parse(package: ScenePackage) throws -> SceneDocument }`
  - `enum SceneDocumentError: Error, Equatable { case noScene }`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/WapleCoreTests/SceneDocumentTests.swift`:
```swift
import XCTest
@testable import WapleCore

final class SceneDocumentTests: XCTestCase {
    private func pkg(_ files: [(String, String)]) throws -> ScenePackage {
        try ScenePackage.parse(ScenePackageTests.makePkg(files.map { ($0.0, Data($0.1.utf8)) }))
    }

    private let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
    private let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#

    func testParsesSingleImageLayer() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0.7 0.7 0.7"},
         "objects":[{"image":"models/x.json","origin":"960 540 0","size":"1920 1080","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1.0,"color":"1 1 1","brightness":1.0,"visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.projectionWidth, 1920)
        XCTAssertEqual(doc.clearColor, Vec3(x: 0.7, y: 0.7, z: 0.7))
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.layers[0].textureEntryName, "materials/pic.tex")
        XCTAssertEqual(doc.layers[0].origin, Vec2(x: 960, y: 540))
        XCTAssertEqual(doc.layers[0].size, Vec2(x: 1920, y: 1080))
    }

    func testSkipsSoundAndInvisibleObjects() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"sound":["sounds/a.mp3"],"origin":"0 0 0"},
                    {"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":false}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        XCTAssertEqual(try SceneDocument.parse(package: p).layers.count, 0)
    }

    func testSkipsLayerWithMissingModel() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/missing.json","origin":"0 0 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene)])
        XCTAssertEqual(try SceneDocument.parse(package: p).layers.count, 0)
    }

    func testNoSceneThrows() throws {
        let p = try pkg([("other.json", "{}")])
        XCTAssertThrowsError(try SceneDocument.parse(package: p)) { e in
            XCTAssertEqual(e as? SceneDocumentError, .noScene)
        }
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter SceneDocumentTests`
Expected: 컴파일 에러 ("cannot find 'SceneDocument'").

- [ ] **Step 3: 기하 타입 작성**

`Sources/WapleCore/SceneGeometry.swift`:
```swift
public struct Vec2: Equatable {
    public let x: Float
    public let y: Float
    public init(x: Float, y: Float) { self.x = x; self.y = y }
}

public struct Vec3: Equatable {
    public let x: Float
    public let y: Float
    public let z: Float
    public init(x: Float, y: Float, z: Float) { self.x = x; self.y = y; self.z = z }
}
```

- [ ] **Step 4: SceneDocument 구현**

`Sources/WapleCore/SceneDocument.swift`:
```swift
import Foundation

public struct SceneLayer: Equatable {
    public let textureEntryName: String
    public let origin: Vec2
    public let size: Vec2
    public let scale: Vec2
    public let angleZ: Float
    public let alpha: Float
    public let color: Vec3
    public let brightness: Float
}

public struct SceneDocument: Equatable {
    public let projectionWidth: Int
    public let projectionHeight: Int
    public let clearColor: Vec3
    public let layers: [SceneLayer]
}

public enum SceneDocumentError: Error, Equatable { case noScene }

extension SceneDocument {
    public static func parse(package: ScenePackage) throws -> SceneDocument {
        guard let sceneData = package.data(for: "scene.json") ?? package.data(for: "gifscene.json"),
              let scene = (try? JSONSerialization.jsonObject(with: sceneData)) as? [String: Any] else {
            throw SceneDocumentError.noScene
        }
        let general = scene["general"] as? [String: Any] ?? [:]
        let proj = general["orthogonalprojection"] as? [String: Any] ?? [:]
        let pw = (proj["width"] as? Int) ?? 1920
        let ph = (proj["height"] as? Int) ?? 1080
        let clear = vec3(general["clearcolor"] as? String) ?? Vec3(x: 0, y: 0, z: 0)

        var layers: [SceneLayer] = []
        for case let obj as [String: Any] in (scene["objects"] as? [Any] ?? []) {
            guard let imagePath = obj["image"] as? String else { continue }
            if let vis = obj["visible"] as? [String: Any], (vis["value"] as? Bool) == false { continue }
            guard let tex = resolveTexture(imagePath: imagePath, package: package) else { continue }
            layers.append(SceneLayer(
                textureEntryName: tex,
                origin: vec2(obj["origin"] as? String) ?? Vec2(x: 0, y: 0),
                size: vec2(obj["size"] as? String) ?? Vec2(x: Float(pw), y: Float(ph)),
                scale: vec2(obj["scale"] as? String) ?? Vec2(x: 1, y: 1),
                angleZ: floats(obj["angles"] as? String).count >= 3 ? floats(obj["angles"] as? String)[2] : 0,
                alpha: float(obj["alpha"]) ?? 1,
                color: vec3(obj["color"] as? String) ?? Vec3(x: 1, y: 1, z: 1),
                brightness: float(obj["brightness"]) ?? 1
            ))
        }
        return SceneDocument(projectionWidth: pw, projectionHeight: ph, clearColor: clear, layers: layers)
    }

    /// image(model) → material → texture name → "materials/<name>.tex".
    private static func resolveTexture(imagePath: String, package: ScenePackage) -> String? {
        guard let modelData = package.data(for: imagePath),
              let model = (try? JSONSerialization.jsonObject(with: modelData)) as? [String: Any],
              let materialPath = model["material"] as? String,
              let materialData = package.data(for: materialPath),
              let material = (try? JSONSerialization.jsonObject(with: materialData)) as? [String: Any],
              let passes = material["passes"] as? [Any],
              let pass0 = passes.first as? [String: Any],
              let textures = pass0["textures"] as? [Any],
              let name = textures.first as? String, !name.isEmpty else { return nil }
        let candidate = name.contains("/") || name.hasSuffix(".tex") ? name : "materials/\(name).tex"
        return package.entries.contains(where: { $0.name == candidate }) ? candidate
            : (package.entries.contains(where: { $0.name == name }) ? name : nil)
    }

    private static func floats(_ s: String?) -> [Float] {
        (s ?? "").split(separator: " ").compactMap { Float($0) }
    }
    private static func float(_ v: Any?) -> Float? {
        if let d = v as? Double { return Float(d) }
        if let i = v as? Int { return Float(i) }
        return nil
    }
    private static func vec2(_ s: String?) -> Vec2? {
        let f = floats(s); return f.count >= 2 ? Vec2(x: f[0], y: f[1]) : nil
    }
    private static func vec3(_ s: String?) -> Vec3? {
        let f = floats(s); return f.count >= 3 ? Vec3(x: f[0], y: f[1], z: f[2]) : nil
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter SceneDocumentTests`
Expected: PASS (4 tests).

- [ ] **Step 6: 커밋**

```bash
git add Sources/WapleCore/SceneGeometry.swift Sources/WapleCore/SceneDocument.swift Tests/WapleCoreTests/SceneDocumentTests.swift
git commit -m "feat: SceneDocument parser with model->material->texture resolution"
```

---

### Task 4: `TexDecoder` (.tex → RGBA8888)

**Files:**
- Create: `Sources/WapleRender/TexDecoder.swift`
- Test: `Tests/WapleRenderTests/TexDecoderTests.swift`

**Interfaces:**
- Consumes: `TexImage` (WapleCore)
- Produces: `enum TexDecoder { static func rgba(from tex: TexImage, data: Data) -> (pixels: Data, width: Int, height: Int)? }`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/WapleRenderTests/TexDecoderTests.swift`:
```swift
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import WapleRender
import WapleCore

final class TexDecoderTests: XCTestCase {
    private func texHeader(format: Int, w: Int, h: Int) -> [UInt8] {
        func i32(_ v: Int) -> [UInt8] {
            let u = UInt32(truncatingIfNeeded: v)
            return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
        }
        return Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
            + i32(format) + i32(0) + i32(w) + i32(h) + i32(w) + i32(h)
            + Array("TEXB0001".utf8) + [0]
    }

    /// ImageIO로 2x2 PNG 생성(손으로 친 바이트 위험 회피).
    private func png2x2() -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let img = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
        return out as Data
    }

    func testDecodesEmbeddedPNG() throws {
        let data = Data(texHeader(format: 0, w: 2, h: 2)) + png2x2()
        let tex = try XCTUnwrap(TexImage.parse(data))
        let out = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data))
        XCTAssertEqual(out.width, 2); XCTAssertEqual(out.height, 2)
        XCTAssertEqual(out.pixels.count, 2 * 2 * 4)
    }

    func testDecodesRawRGBA() throws {
        let raw: [UInt8] = Array(repeating: 0, count: 1 * 1 * 4)  // 1x1
        let data = Data(texHeader(format: 0, w: 1, h: 1)) + Data(raw)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(tex.payload, .rawRGBA8888)
        let out = try XCTUnwrap(TexDecoder.rgba(from: tex, data: data))
        XCTAssertEqual(out.pixels.count, 4)
    }

    func testBC3ReturnsNil() throws {
        let data = Data(texHeader(format: 9, w: 4, h: 4)) + Data(repeating: 0, count: 16)
        let tex = try XCTUnwrap(TexImage.parse(data))
        XCTAssertNil(TexDecoder.rgba(from: tex, data: data))
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter TexDecoderTests`
Expected: 컴파일 에러 ("cannot find 'TexDecoder'").

- [ ] **Step 3: 구현 작성**

`Sources/WapleRender/TexDecoder.swift`:
```swift
import Foundation
import CoreGraphics
import ImageIO
import WapleCore

public enum TexDecoder {
    public static func rgba(from tex: TexImage, data: Data) -> (pixels: Data, width: Int, height: Int)? {
        switch tex.payload {
        case .png, .jpeg:
            let sub = data.subdata(in: tex.payloadRange)
            guard let src = CGImageSourceCreateWithData(sub as CFData, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return draw(img)
        case .rawRGBA8888:
            let w = tex.width, h = tex.height
            guard w > 0, h > 0 else { return nil }
            let need = w * h * 4
            let sub = data.subdata(in: tex.payloadRange)
            guard sub.count >= need else { return nil }
            return (sub.prefix(need), w, h)
        case .bc3, .video, .unknown:
            return nil
        }
    }

    private static func draw(_ img: CGImage) -> (Data, Int, Int)? {
        let w = img.width, h = img.height
        var pixels = Data(count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (pixels, w, h) : nil
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter TexDecoderTests`
Expected: PASS (3 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleRender/TexDecoder.swift Tests/WapleRenderTests/TexDecoderTests.swift
git commit -m "feat: TexDecoder (PNG/JPEG/raw RGBA) to RGBA8888"
```

---

### Task 5: `QuadShaders` + `SceneRenderer` (Metal 컴포지터)

자동 테스트 불가(Metal/GUI). **`swift build` 성공까지**; 시각 검증은 Task 7.

**Files:**
- Create: `Sources/WapleRender/QuadShaders.swift`
- Create: `Sources/WapleRender/SceneRenderer.swift`

**Interfaces:**
- Consumes: `ScenePackage`, `SceneDocument`, `SceneLayer`, `TexImage`, `TexDecoder`, `WallpaperRenderer`, `RendererError`, `WallpaperProject`
- Produces: `final class SceneRenderer: NSObject, WallpaperRenderer { override init() }`

- [ ] **Step 1: 셰이더 소스 작성**

`Sources/WapleRender/QuadShaders.swift`:
```swift
enum QuadShaders {
    // verts buffer: float4 per vertex = (ndc.x, ndc.y, uv.x, uv.y)
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut v_main(uint vid [[vertex_id]], const device float4* verts [[buffer(0)]]) {
        float4 v = verts[vid];
        VOut o; o.pos = float4(v.x, v.y, 0.0, 1.0); o.uv = float2(v.z, v.w); return o;
    }
    fragment float4 f_main(VOut in [[stage_in]],
                           texture2d<float> tex [[texture(0)]],
                           constant float4 &tint [[buffer(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float4 c = tex.sample(s, in.uv);
        return float4(c.rgb * tint.rgb, c.a * tint.a);
    }
    """
}
```

- [ ] **Step 2: SceneRenderer 작성**

`Sources/WapleRender/SceneRenderer.swift`:
```swift
import AppKit
import MetalKit
import WapleCore

public final class SceneRenderer: NSObject, WallpaperRenderer, MTKViewDelegate {
    private struct GPULayer { let texture: MTLTexture; let vertexBuffer: MTLBuffer; let tint: SIMD4<Float> }

    private var mtkView: MTKView?
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var layers: [GPULayer] = []
    private var clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    public override init() { super.init() }

    public func mount(in container: NSView, project: WallpaperProject) throws {
        let pkgURL = pkgURL(in: project.folderURL)
        guard let pkgURL, let data = try? Data(contentsOf: pkgURL),
              let package = try? ScenePackage.parse(data),
              let doc = try? SceneDocument.parse(package: package) else {
            throw RendererError.assetMissing
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw RendererError.unsupportedType }
        self.device = device
        self.queue = queue

        let library = try device.makeLibrary(source: QuadShaders.source, options: nil)
        let pdesc = MTLRenderPipelineDescriptor()
        pdesc.vertexFunction = library.makeFunction(name: "v_main")
        pdesc.fragmentFunction = library.makeFunction(name: "f_main")
        let att = pdesc.colorAttachments[0]!
        att.pixelFormat = .bgra8Unorm
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add; att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .one; att.sourceAlphaBlendFactor = .one
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha; att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.pipeline = try device.makeRenderPipelineState(descriptor: pdesc)

        clearColor = MTLClearColor(red: Double(doc.clearColor.x), green: Double(doc.clearColor.y),
                                   blue: Double(doc.clearColor.z), alpha: 1)
        layers = buildLayers(doc: doc, package: package, device: device)

        let view = MTKView(frame: container.bounds, device: device)
        view.autoresizingMask = [.width, .height]
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        container.wantsLayer = true
        container.addSubview(view)
        self.mtkView = view
        view.needsDisplay = true
    }

    private func pkgURL(in folder: URL) -> URL? {
        for name in ["scene.pkg", "gifscene.pkg"] {
            let u = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// 레이어를 후→전 순서(JSON 순서)로 GPU 리소스화. 디코드 실패 레이어는 스킵.
    private func buildLayers(doc: SceneDocument, package: ScenePackage, device: MTLDevice) -> [GPULayer] {
        let w = Float(doc.projectionWidth), h = Float(doc.projectionHeight)
        var out: [GPULayer] = []
        for layer in doc.layers {
            guard let texData = package.data(for: layer.textureEntryName),
                  let tex = TexImage.parse(texData),
                  let decoded = TexDecoder.rgba(from: tex, data: texData),
                  let mtl = makeTexture(decoded.pixels, decoded.width, decoded.height, device) else { continue }
            let verts = quadVertices(layer: layer, projW: w, projH: h)
            guard let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<SIMD4<Float>>.stride * verts.count) else { continue }
            let tint = SIMD4<Float>(layer.color.x * layer.brightness, layer.color.y * layer.brightness,
                                    layer.color.z * layer.brightness, layer.alpha)
            out.append(GPULayer(texture: mtl, vertexBuffer: vbuf, tint: tint))
        }
        return out
    }

    private func makeTexture(_ rgba: Data, _ w: Int, _ h: Int, _ device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        guard let t = device.makeTexture(descriptor: desc) else { return nil }
        rgba.withUnsafeBytes { ptr in
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: ptr.baseAddress!, bytesPerRow: w * 4)
        }
        return t
    }

    /// 씬 픽셀 좌표(좌상단 원점, Y-down 가정) → NDC. Y-flip은 Task 7에서 실측 보정.
    private func quadVertices(layer: SceneLayer, projW: Float, projH: Float) -> [SIMD4<Float>] {
        let hw = layer.size.x * layer.scale.x * 0.5
        let hh = layer.size.y * layer.scale.y * 0.5
        let a = layer.angleZ * .pi / 180
        let ca = cos(a), sa = sin(a)
        func corner(_ lx: Float, _ ly: Float) -> SIMD2<Float> {
            let rx = lx * ca - ly * sa, ry = lx * sa + ly * ca
            return SIMD2<Float>(layer.origin.x + rx, layer.origin.y + ry)
        }
        func ndc(_ p: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2<Float>(p.x / projW * 2 - 1, 1 - p.y / projH * 2)
        }
        let tl = ndc(corner(-hw, -hh)), tr = ndc(corner(hw, -hh))
        let br = ndc(corner(hw, hh)), bl = ndc(corner(-hw, hh))
        // uv: TL(0,0) TR(1,0) BR(1,1) BL(0,1)
        return [
            SIMD4<Float>(tl.x, tl.y, 0, 0), SIMD4<Float>(tr.x, tr.y, 1, 0), SIMD4<Float>(br.x, br.y, 1, 1),
            SIMD4<Float>(tl.x, tl.y, 0, 0), SIMD4<Float>(br.x, br.y, 1, 1), SIMD4<Float>(bl.x, bl.y, 0, 1),
        ]
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.needsDisplay = true }

    public func draw(in view: MTKView) {
        guard let queue, let pipeline,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        rpd.colorAttachments[0].clearColor = clearColor
        rpd.colorAttachments[0].loadAction = .clear
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        for layer in layers {
            var tint = layer.tint
            enc.setVertexBuffer(layer.vertexBuffer, offset: 0, index: 0)
            enc.setFragmentTexture(layer.texture, index: 0)
            enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    public func pause() {}
    public func resume() { mtkView?.needsDisplay = true }
    public func teardown() {
        mtkView?.removeFromSuperview()
        mtkView = nil; layers = []; pipeline = nil; queue = nil; device = nil
    }
}
```

- [ ] **Step 3: 빌드 확인**

Run: `swift build`
Expected: 성공.

- [ ] **Step 4: 커밋**

```bash
git add Sources/WapleRender/QuadShaders.swift Sources/WapleRender/SceneRenderer.swift
git commit -m "feat: SceneRenderer Metal compositor for static image layers"
```

---

### Task 6: `RendererFactory` 실험 라우팅

**Files:**
- Modify: `Sources/WapleRender/RendererFactory.swift` (전체 교체)
- Test: `Tests/WapleRenderTests/RendererFactoryTests.swift` (씬 케이스 추가)

**Interfaces:**
- Produces: `RendererFactory.experimentalSceneEnabled: Bool` (기본 false), `.scene` 라우팅

- [ ] **Step 1: 테스트 추가(실패)**

`Tests/WapleRenderTests/RendererFactoryTests.swift` 의 `testSceneAndOthersReturnNil` 를 다음으로 교체:
```swift
    func testSceneNilByDefaultRendersWhenExperimentalEnabled() {
        let scene = project(type: .scene, file: "scene.json")
        XCTAssertNil(RendererFactory.makeRenderer(for: scene))   // default off
        RendererFactory.experimentalSceneEnabled = true
        defer { RendererFactory.experimentalSceneEnabled = false }
        XCTAssertTrue(RendererFactory.makeRenderer(for: scene) is SceneRenderer)
    }

    func testOtherUnsupportedReturnNil() {
        XCTAssertNil(RendererFactory.makeRenderer(for: project(type: .preset, file: nil)))
        XCTAssertNil(RendererFactory.makeRenderer(for: project(type: .unknown("z"), file: nil)))
    }
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter RendererFactoryTests`
Expected: 컴파일 에러 (`experimentalSceneEnabled` 없음).

- [ ] **Step 3: 팩토리 교체**

`Sources/WapleRender/RendererFactory.swift` 전체:
```swift
import Foundation
import WapleCore

public enum RendererFactory {
    /// SP1: scene 은 실험 플래그 ON 일 때만 라우팅(부분 렌더 → 사용자 미노출).
    public static var experimentalSceneEnabled = false

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
            return experimentalSceneEnabled ? SceneRenderer() : nil
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: 테스트·빌드 확인**

Run: `swift test` (전체) — 모든 번들 PASS. `swift build` 성공.

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleRender/RendererFactory.swift Tests/WapleRenderTests/RendererFactoryTests.swift
git commit -m "feat: experimental scene routing behind RendererFactory flag"
```

---

### Task 7: 수동 시각 게이트 (좌표 규약 · 합성 · 오라클)

자동 테스트 불가. **수동 검증.** 실제 씬으로 렌더 확인 + 좌표 규약 보정.

**Files:** 없음(검증). 좌표가 뒤집히면 `Sources/WapleRender/SceneRenderer.swift`의 `quadVertices` 수정.

- [ ] **Step 1: 임시 검증 진입점**

검증을 위해 `Sources/Waple/AppDelegate.swift` 의 `applicationDidFinishLaunching` 끝(`restoreLastWallpaper()` 다음)에 임시 추가(커밋 금지):
```swift
        // [TEMP VERIFY — 커밋 금지]
        RendererFactory.experimentalSceneEnabled = true
        apply(folderURL: URL(fileURLWithPath: "/Users/yakisoba/Downloads/packages/2899965423", isDirectory: true))
```
`import WapleRender` 가 이미 있는지 확인(없으면 추가).

- [ ] **Step 2: 빌드·실행**

Run: `swift build && swift run Waple`
(GUI 실행 — 런루프 유지. 확인 후 종료.)

- [ ] **Step 3: G-S1 — 단일 이미지 좌표/방향 검증**

관찰: `2899965423`의 이미지가 데스크탑 전체에 **올바른 방향(상하/좌우 정상)·꽉 찬 크기**로 렌더되는가? 폴더의 `preview.gif`(또는 WE 워크샵 이미지)와 대조.
- **상하 반전 시**: `quadVertices`의 `ndc`에서 Y 식을 `p.y / projH * 2 - 1`(플립 제거)로 변경, 또는 uv의 v(0↔1)를 스왑. 한쪽만 바꿔 재확인(둘 다 바꾸면 원위치).
- **좌우 반전 시**: uv u(0↔1) 스왑.
- 위치 오프셋 시: origin 해석(중심 가정)과 alignment 확인.
정상 방향을 찾으면 그 값으로 확정하고 주석으로 근거 기록.

- [ ] **Step 4: G-S2 — 다층 합성 검증**

Step 1의 경로를 `.../2188368235`로 바꿔 재빌드·실행. 2개 PNG 레이어가 **JSON 순서대로 후→전 합성**되어 자연스럽게 겹치는지 확인.

- [ ] **Step 5: 오라클 재확인(Task 1 Step 5 미수행 시)**

`ScenePackage`가 실제 pkg에서 추출한 `scene.json`이 정상 JSON(`{`로 시작, 파싱됨)인지 1회 확인.

- [ ] **Step 6: 임시 코드 제거**

```bash
git checkout -- Sources/Waple/AppDelegate.swift
grep -rn "TEMP VERIFY" Sources/ || echo clean
swift build && swift test 2>&1 | grep -E "Test Suite '.*xctest' (passed|failed)"
```
좌표 보정이 있었다면 그 커밋만 유지:
```bash
git add Sources/WapleRender/SceneRenderer.swift
git commit -m "fix: correct scene quad orientation (empirical, Darwin 27)"
```

---

## Self-Review (작성자 체크리스트 결과)

**1. 스펙 커버리지**
- .pkg 언팩(§3.1,§5.1) → Task 1 ✅
- .tex 헤더+페이로드 판별(§3.2,§5.2) → Task 2 ✅
- scene.json+간접참조(§3.3,§5.3) → Task 3 ✅
- TexDecoder PNG/JPEG/raw, BC3/비디오 nil(§5.4) → Task 4 ✅
- Metal 정적 레이어 컴포지터(§5.5) → Task 5 ✅
- 실험 플래그 라우팅·미노출(§5.6) → Task 6 ✅
- 좌표/투영 실측 게이트(§7), 부분 렌더 graceful(§8) → Task 5(스킵 로직)+Task 7 ✅
- 오라클 ground-truth 대조(§9) → Task 1 Step 5 / Task 7 Step 5 ✅
- 단위 TDD(§9) → Task 1–4,6 ✅; 수동 게이트 G-S1/G-S2 → Task 7 ✅

**2. 플레이스홀더 스캔:** TBD/모호 지시 없음. Metal/좌표는 구체 관찰+보정 절차로 처리. ✅

**3. 타입 일관성:** `ScenePackage.parse/data(for:)/Entry`, `TexImage.parse/PayloadKind/payloadRange`,
`SceneDocument.parse/SceneLayer/Vec2/Vec3/textureEntryName`, `TexDecoder.rgba(from:data:)`,
`SceneRenderer()`(WallpaperRenderer mount/pause/resume/teardown), `RendererFactory.experimentalSceneEnabled/makeRenderer(for:)` — 일치. ✅

**범위 밖(스펙 §10):** 비디오-텍스처(SP1.5), BC3/LZ4·패럴랙스(SP2), 효과 셰이더(SP3), 파티클(SP4), 오디오(SP5), Heavy(SP6), gifscene, 3D/퍼펫, bloom, visible.script.
