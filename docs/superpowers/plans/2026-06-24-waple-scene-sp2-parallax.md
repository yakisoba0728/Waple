# Waple Scene SP2 (Mouse Parallax) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** SP1이 렌더하는 다층 정적 씬에 마우스 기반 깊이 패럴랙스를 추가한다(레이어가 `parallaxDepth`에 비례해 마우스 오프셋만큼 이동).

**Architecture:** `SceneDocument`가 per-layer `parallaxDepth`와 general 패럴랙스 설정을 파싱, `ParallaxController`가 전역 마우스 모니터로 정규화 오프셋을 공급, `SceneRenderer`가 cameraOffset 유니폼을 버텍스 셰이더에 전달해 `pos += cameraOffset * parallaxDepth`로 이동. 마우스 이동 시에만 redraw(연속 루프 없음).

**Tech Stack:** Swift 5.9, Metal(기존 QuadShaders), AppKit(NSEvent), XCTest. 새 의존성 없음.

## Global Constraints

- 기존 SPM 패키지에 추가. **새 타깃·서드파티 의존성 없음.** tools 5.9, macOS 13+.
- 패럴랙스는 Metal 이미지-레이어 경로에만 적용(비디오-텍스처/단일 레이어 무관).
- `general.cameraparallax == false` 또는 마우스 정보 없음 → cameraOffset 0(정적).
- 셰이더 버텍스: `pos.xy += cameraOffset * parallaxDepth` (cameraOffset=buffer1, parallaxDepth=buffer2, 둘 다 `float2`).
- cameraOffset(NDC) = 정규화오프셋 × `cameraparallaxamount` × `cameraparallaxmouseinfluence` × `MAX_SHIFT(0.04)`.
- 마우스 전역 모니터(`NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)`)는 권한 불필요. 온디맨드 redraw(가림 스로틀링 무관).

**전제:** main에서 시작(SP1.5 병합), `swift build`/`swift test` 그린.

---

### Task 1: `SceneDocument` 패럴랙스 필드 파싱

**Files:**
- Modify: `Sources/WapleCore/SceneDocument.swift`
- Modify: `Tests/WapleCoreTests/SceneDocumentTests.swift` (테스트 추가)

**Interfaces:**
- Produces: `SceneLayer.parallaxDepth: Vec2` (기본 (1,1)); `SceneDocument.parallaxEnabled: Bool`, `.parallaxAmount: Float`, `.parallaxMouseInfluence: Float`

- [ ] **Step 1: 실패하는 테스트 추가**

`Tests/WapleCoreTests/SceneDocumentTests.swift` 의 `SceneDocumentTests` 클래스에 메서드 추가:
```swift
    func testParsesParallaxDepthAndGeneral() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0",
                    "cameraparallax":true,"cameraparallaxamount":0.5,"cameraparallaxmouseinfluence":0.25},
         "objects":[{"image":"models/x.json","origin":"960 540 0","size":"1920 1080","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,
                     "parallaxDepth":"1.5 0.5","visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertTrue(doc.parallaxEnabled)
        XCTAssertEqual(doc.parallaxAmount, 0.5, accuracy: 1e-6)
        XCTAssertEqual(doc.parallaxMouseInfluence, 0.25, accuracy: 1e-6)
        XCTAssertEqual(doc.layers.first?.parallaxDepth, Vec2(x: 1.5, y: 0.5))
    }

    func testParallaxDefaultsWhenAbsent() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"image":"models/x.json","origin":"50 50 0","size":"10 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p)
        XCTAssertFalse(doc.parallaxEnabled)
        XCTAssertEqual(doc.parallaxAmount, 1, accuracy: 1e-6)
        XCTAssertEqual(doc.layers.first?.parallaxDepth, Vec2(x: 1, y: 1))
    }
```
(이 테스트들은 기존 `SceneDocumentTests`의 `pkg(_:)` 헬퍼와 `model`/`material` 프로퍼티를 재사용한다.)

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter SceneDocumentTests`
Expected: 컴파일 에러 (`parallaxEnabled`/`parallaxDepth` 멤버 없음).

- [ ] **Step 3: SceneLayer / SceneDocument 필드 추가**

`Sources/WapleCore/SceneDocument.swift` 의 `SceneLayer` 와 `SceneDocument` 구조체를 다음으로 교체:
```swift
public struct SceneLayer: Equatable {
    public let textureEntryName: String
    public let origin: Vec2
    public let size: Vec2
    public let scale: Vec2
    public let angleZ: Float
    public let alpha: Float
    public let color: Vec3
    public let brightness: Float
    public let parallaxDepth: Vec2
}

public struct SceneDocument: Equatable {
    public let projectionWidth: Int
    public let projectionHeight: Int
    public let clearColor: Vec3
    public let parallaxEnabled: Bool
    public let parallaxAmount: Float
    public let parallaxMouseInfluence: Float
    public let layers: [SceneLayer]
}
```

- [ ] **Step 4: parse 갱신**

`Sources/WapleCore/SceneDocument.swift` 의 `parse(package:)` 에서:

(a) `let clear = vec3(...)` 다음 줄에 추가:
```swift
        let parallaxEnabled = (general["cameraparallax"] as? Bool) ?? false
        let parallaxAmount = float(general["cameraparallaxamount"]) ?? 1
        let parallaxMouseInfluence = float(general["cameraparallaxmouseinfluence"]) ?? 1
```

(b) `layers.append(SceneLayer(...))` 의 `brightness: float(obj["brightness"]) ?? 1` 다음에 인자 추가:
```swift
                brightness: float(obj["brightness"]) ?? 1,
                parallaxDepth: vec2(obj["parallaxDepth"] as? String) ?? Vec2(x: 1, y: 1)
```

(c) 마지막 `return SceneDocument(...)` 을 다음으로 교체:
```swift
        return SceneDocument(projectionWidth: pw, projectionHeight: ph, clearColor: clear,
                             parallaxEnabled: parallaxEnabled, parallaxAmount: parallaxAmount,
                             parallaxMouseInfluence: parallaxMouseInfluence, layers: layers)
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter SceneDocumentTests`
Expected: PASS (기존 + 신규 2개). `swift build` 성공(SceneRenderer.buildLayers는 SceneLayer를 읽기만 하므로 영향 없음).

- [ ] **Step 6: 커밋**

```bash
git add Sources/WapleCore/SceneDocument.swift Tests/WapleCoreTests/SceneDocumentTests.swift
git commit -m "feat: parse parallaxDepth and camera parallax settings"
```

---

### Task 2: `ParallaxController` (전역 마우스 → 정규화 오프셋)

**Files:**
- Create: `Sources/WapleRender/ParallaxController.swift`
- Test: `Tests/WapleRenderTests/ParallaxControllerTests.swift`

**Interfaces:**
- Produces:
  - `final class ParallaxController { var onOffset: ((CGPoint) -> Void)?; func start(); func stop(); static func normalizedOffset(mouse: CGPoint, screenFrame: CGRect) -> CGPoint }`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/WapleRenderTests/ParallaxControllerTests.swift`:
```swift
import XCTest
@testable import WapleRender

final class ParallaxControllerTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 800) // center (500,400)

    func testCenterIsZero() {
        let o = ParallaxController.normalizedOffset(mouse: CGPoint(x: 500, y: 400), screenFrame: frame)
        XCTAssertEqual(o.x, 0, accuracy: 1e-6); XCTAssertEqual(o.y, 0, accuracy: 1e-6)
    }
    func testEdgesAreUnit() {
        XCTAssertEqual(ParallaxController.normalizedOffset(mouse: CGPoint(x: 1000, y: 400), screenFrame: frame).x, 1, accuracy: 1e-6)
        XCTAssertEqual(ParallaxController.normalizedOffset(mouse: CGPoint(x: 0, y: 400), screenFrame: frame).x, -1, accuracy: 1e-6)
        XCTAssertEqual(ParallaxController.normalizedOffset(mouse: CGPoint(x: 500, y: 800), screenFrame: frame).y, 1, accuracy: 1e-6)
    }
    func testClampsOutside() {
        let o = ParallaxController.normalizedOffset(mouse: CGPoint(x: 5000, y: -5000), screenFrame: frame)
        XCTAssertEqual(o.x, 1, accuracy: 1e-6); XCTAssertEqual(o.y, -1, accuracy: 1e-6)
    }
    func testZeroFrameSafe() {
        let o = ParallaxController.normalizedOffset(mouse: CGPoint(x: 10, y: 10), screenFrame: .zero)
        XCTAssertEqual(o.x, 0); XCTAssertEqual(o.y, 0)
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter ParallaxControllerTests`
Expected: 컴파일 에러 ("cannot find 'ParallaxController'").

- [ ] **Step 3: 구현 작성**

`Sources/WapleRender/ParallaxController.swift`:
```swift
import AppKit

public final class ParallaxController {
    public var onOffset: ((CGPoint) -> Void)?
    private var monitor: Any?

    public init() {}

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.emit()
        }
        emit()
    }

    public func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func emit() {
        let frame = NSScreen.main?.frame ?? .zero
        onOffset?(ParallaxController.normalizedOffset(mouse: NSEvent.mouseLocation, screenFrame: frame))
    }

    /// 화면 중심=0, 가장자리=±1, 밖은 클램프. (순수)
    public static func normalizedOffset(mouse: CGPoint, screenFrame: CGRect) -> CGPoint {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return .zero }
        let nx = (mouse.x - screenFrame.midX) / (screenFrame.width / 2)
        let ny = (mouse.y - screenFrame.midY) / (screenFrame.height / 2)
        return CGPoint(x: min(max(nx, -1), 1), y: min(max(ny, -1), 1))
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter ParallaxControllerTests`
Expected: PASS (4 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/WapleRender/ParallaxController.swift Tests/WapleRenderTests/ParallaxControllerTests.swift
git commit -m "feat: ParallaxController global mouse to normalized offset"
```

---

### Task 3: `QuadShaders` + `SceneRenderer` 패럴랙스 통합

자동 테스트 불가(Metal/GUI). **`swift build` 성공까지**; 시각 검증은 Task 4.

**Files:**
- Modify: `Sources/WapleRender/QuadShaders.swift`
- Modify: `Sources/WapleRender/SceneRenderer.swift`

**Interfaces:**
- Consumes: `ParallaxController`, `SceneDocument.parallax*`, `SceneLayer.parallaxDepth`

- [ ] **Step 1: 셰이더 버텍스 교체**

`Sources/WapleRender/QuadShaders.swift` 의 `v_main` 함수를 다음으로 교체:
```swift
    vertex VOut v_main(uint vid [[vertex_id]],
                       const device float4* verts [[buffer(0)]],
                       constant float2& cameraOffset [[buffer(1)]],
                       constant float2& parallaxDepth [[buffer(2)]]) {
        float4 v = verts[vid];
        float2 p = v.xy + cameraOffset * parallaxDepth;
        VOut o; o.pos = float4(p.x, p.y, 0.0, 1.0); o.uv = float2(v.z, v.w); return o;
    }
```

- [ ] **Step 2: GPULayer + 프로퍼티 추가**

`Sources/WapleRender/SceneRenderer.swift`:

(a) `GPULayer` 구조체를 다음으로 교체:
```swift
    private struct GPULayer { let texture: MTLTexture; let vertexBuffer: MTLBuffer; let tint: SIMD4<Float>; let parallaxDepth: SIMD2<Float> }
```

(b) `private var clearColor = ...` 다음 줄에 프로퍼티 추가:
```swift
    private var cameraOffset = SIMD2<Float>(0, 0)
    private var parallaxEnabled = false
    private var parallaxAmount: Float = 1
    private var parallaxMouseInfluence: Float = 1
    private let parallax = ParallaxController()
    private let maxShift: Float = 0.04
```

- [ ] **Step 3: buildLayers에서 parallaxDepth 채우기**

`buildLayers` 의 `out.append(GPULayer(...))` 를 다음으로 교체:
```swift
            out.append(GPULayer(texture: mtl, vertexBuffer: vbuf, tint: tint,
                                parallaxDepth: SIMD2<Float>(layer.parallaxDepth.x, layer.parallaxDepth.y)))
```

- [ ] **Step 4: mount에서 패럴랙스 시작**

`mount` 의 마지막 `view.needsDisplay = true` 다음에 추가:
```swift

        parallaxEnabled = doc.parallaxEnabled
        parallaxAmount = doc.parallaxAmount
        parallaxMouseInfluence = doc.parallaxMouseInfluence
        if parallaxEnabled {
            parallax.onOffset = { [weak self] off in self?.updateParallax(off) }
            parallax.start()
        }
```

- [ ] **Step 5: updateParallax + draw + teardown**

(a) `mtkView(_:drawableSizeWillChange:)` 위에 메서드 추가:
```swift
    private func updateParallax(_ off: CGPoint) {
        let s = parallaxAmount * parallaxMouseInfluence * maxShift
        cameraOffset = SIMD2<Float>(Float(off.x) * s, Float(off.y) * s)
        mtkView?.needsDisplay = true
    }
```

(b) `draw(in:)` 의 for 루프를 다음으로 교체:
```swift
        var camOffset = cameraOffset
        for layer in layers {
            var tint = layer.tint
            var depth = layer.parallaxDepth
            enc.setVertexBuffer(layer.vertexBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&camOffset, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            enc.setVertexBytes(&depth, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            enc.setFragmentTexture(layer.texture, index: 0)
            enc.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
```

(c) `teardown()` 의 `videoRenderer?.teardown(); videoRenderer = nil` 다음 줄에 추가:
```swift
        parallax.stop()
```

- [ ] **Step 6: 빌드 확인**

Run: `swift build`
Expected: 성공.

- [ ] **Step 7: 커밋**

```bash
git add Sources/WapleRender/QuadShaders.swift Sources/WapleRender/SceneRenderer.swift
git commit -m "feat: SceneRenderer mouse parallax via cameraOffset uniform"
```

---

### Task 4: 패럴랙스 시각 게이트 (자율 검증)

자동 테스트 불가. **수동/자율 검증.** cameraOffset를 좌/우로 주입해 레이어 이동을 스크린샷 비교.

**Files:** 없음(검증). 스케일/부호가 어색하면 `SceneRenderer.maxShift`/부호 조정.

- [ ] **Step 1: 임시 주입 진입점**

검증을 위해 `Sources/WapleRender/SceneRenderer.swift` 의 `mount` 마지막에 임시 추가(커밋 금지):
```swift
        // [TEMP VERIFY] 패럴랙스 렌더 확인용 고정 오프셋(환경변수로 좌/우 전환).
        if let v = ProcessInfo.processInfo.environment["WAPLE_PARALLAX"], let f = Float(v) {
            cameraOffset = SIMD2<Float>(f * maxShift, 0); mtkView?.needsDisplay = true
        }
```
그리고 `Sources/Waple/AppDelegate.swift` 끝에 임시 적용(커밋 금지):
```swift
        apply(folderURL: URL(fileURLWithPath: "/Users/yakisoba/Downloads/packages/2188368235", isDirectory: true))
```

- [ ] **Step 2: 두 오프셋 캡처·비교**

Run:
```bash
swift build
WAPLE_PARALLAX=1 .build/debug/Waple >/tmp/p.log 2>&1 &  # 우측 최대
# (데스크탑 보이게 한 뒤) screencapture -x /tmp/par_right.png ; pkill -f debug/Waple
WAPLE_PARALLAX=-1 .build/debug/Waple >/tmp/p.log 2>&1 & # 좌측 최대
# screencapture -x /tmp/par_left.png ; pkill -f debug/Waple
```
관찰: 다층 씬의 레이어들이 두 컷 사이에 **이동**(parallaxDepth가 다르면 차등 이동)하는가? 자연스러우면 통과.
- 어색(과/소·역방향) 시 `maxShift`(0.04 기준)·부호 조정 후 재확인.

- [ ] **Step 3: 임시 코드 제거 + 커밋(조정 시만)**

```bash
git checkout -- Sources/WapleRender/SceneRenderer.swift Sources/Waple/AppDelegate.swift
grep -rn "TEMP VERIFY" Sources/ || echo clean
# 스케일/부호 조정이 있었다면 그 변경만 다시 적용 후:
# git add Sources/WapleRender/SceneRenderer.swift && git commit -m "fix: tune parallax scale/direction (empirical)"
swift build && swift test 2>&1 | grep -E "Test Suite '.*xctest' (passed|failed)"
```

---

## Self-Review (작성자 체크리스트 결과)

**1. 스펙 커버리지**
- parallaxDepth + general 파싱(§4) → Task 1 ✅
- ParallaxController 매핑+모니터(§4) → Task 2 ✅
- 셰이더 cameraOffset*depth + SceneRenderer 통합·온디맨드 redraw(§3,§5) → Task 3 ✅
- 정적/비디오/단일 레이어 강등(§7) → Task 3(`parallaxEnabled` 가드, 비디오 경로 early return) ✅
- 스케일/부호 실측 게이트(§6) → Task 4 ✅
- TDD(§8) → Task 1,2 ✅; 자율 시각 게이트 → Task 4 ✅

**2. 플레이스홀더 스캔:** 없음. Metal/튜닝은 구체 절차. ✅

**3. 타입 일관성:** `SceneLayer.parallaxDepth: Vec2`, `SceneDocument.parallaxEnabled/Amount/MouseInfluence`,
`ParallaxController.normalizedOffset/onOffset/start/stop`, `GPULayer.parallaxDepth: SIMD2<Float>`,
셰이더 buffer1=cameraOffset/buffer2=parallaxDepth, `SceneRenderer.updateParallax/cameraOffset/maxShift` — 일치. ✅

**범위 밖(스펙 §9):** 자동 드리프트, 카메라 셰이크, perspective, 화면별 오프셋, 깊이맵, BC3/효과/파티클/오디오.
