# WE 2D Additive Blending Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 일반 2D 이미지 레이어의 `passes[0].blending == "additive"`를 premultiplied source와 destination의 정확한 가산 블렌딩으로 렌더한다.

**Architecture:** 기존 파서의 `SceneLayer.blendMode`를 `GPULayer.blendAdditive`로 축약해 전달하고, `v_main`/`f_main`과 `accPixelFormat`을 공유하는 전용 Metal 파이프라인을 추가한다. 특수 렌더 경로 뒤의 일반 분기에서만 이 파이프라인을 선택해 lit, object `colorBlendMode`, framebuffer composition의 기존 우선순위와 폴백을 보존한다.

**Tech Stack:** Swift 5.9, Swift Package Manager, AppKit, Metal/MetalKit, XCTest, macOS 14+

## Global Constraints

- 지원 범위는 lowercase material `blending: "additive"` 하나뿐이다.
- `normal`, `translucent`, blending 생략은 기존 premultiplied alpha-over를 유지한다.
- `alphatocoverage`와 `normal`/`translucent`의 네이티브 차이는 구현하지 않는다.
- additive는 lit, object `colorBlendMode`, framebuffer composition과 중첩하지 않는다.
- 새 의존성을 추가하지 않는다.
- 전체 `swift test`와 전수 코퍼스 캡처를 실행하지 않는다. 이 계획에 적힌 영향 테스트만 실행한다.
- 사용자 변경 `.vscode/launch.json`은 수정·스테이징·커밋하지 않는다.
- 설계 정본은 `docs/superpowers/specs/2026-07-14-we-2d-additive-blending-design.md`다.

## File Map

- Create `Tests/WapleRenderTests/SceneMaterialBlendRenderTests.swift`: LDR/HDR additive 픽셀 오라클과 non-additive 무회귀 fixture.
- Modify `Sources/WapleCore/SceneDocument.swift`: `blendMode`의 2D 소비 범위를 설명하는 주석만 갱신.
- Modify `Sources/WapleRender/SceneRenderer.swift`: `GPULayer.blendAdditive`, `layerAdditivePipeline`, Metal blend state 생성과 teardown.
- Modify `Sources/WapleRender/SceneRendererResources.swift`: `SceneLayer.blendMode`를 `GPULayer.blendAdditive`로 전달.
- Modify `Sources/WapleRender/SceneRendererFrameEncoder.swift`: 특수 경로 뒤에서 additive 파이프라인 선택.

---

### Task 1: 2D material blending 픽셀 오라클 고정

**Files:**
- Create: `Tests/WapleRenderTests/SceneMaterialBlendRenderTests.swift`
- Reuse: `Tests/WapleRenderTests/TestSupport.swift:28-50`

**Interfaces:**
- Consumes: `encodePkg(_:)`, `solidTex(_:_:_:alpha:w:h:)`, `SceneRenderer.mount(in:project:)`, `SceneRenderer.captureFrames(width:height:times:toDir:)`, internal `SceneRenderer.hdrActive`.
- Produces: `SceneMaterialBlendRenderTests`의 세 회귀 테스트. Task 2가 이 테스트를 green으로 만든다.

- [ ] **Step 1: LDR additive 실패 테스트와 공용 fixture 작성**

Create `Tests/WapleRenderTests/SceneMaterialBlendRenderTests.swift` with:

```swift
import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// material passes[0].blending 고정기능 상태 오라클.
/// 불투명 초록 dst + alpha 0.5 빨강 src:
/// additive = (0.5, 1.0, 0), over = (0.5, 0.5, 0).
final class SceneMaterialBlendRenderTests: XCTestCase {
    private func centerPixel(blending: String?, hdr: Bool = false, tag: String) throws -> NSColor {
        let blendField = blending.map { ",\"blending\":\"\($0)\"" } ?? ""
        let foregroundMaterial = "{\"passes\":[{\"textures\":[\"fg\"]\(blendField)}]}"
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0","hdr":\(hdr)},
         "objects":[
           {"id":1,"image":"models/bg.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/fg.json","origin":"960 540 0","size":"1920 1080","alpha":0.5}]}
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/bg.json", #"{"material":"materials/bg.json"}"#.data(using: .utf8)!),
            ("materials/bg.json", #"{"passes":[{"textures":["bg"]}]}"#.data(using: .utf8)!),
            ("materials/bg.tex", solidTex(0, 255, 0)),
            ("models/fg.json", #"{"material":"materials/fg.json"}"#.data(using: .utf8)!),
            ("materials/fg.json", foregroundMaterial.data(using: .utf8)!),
            ("materials/fg.tex", solidTex(255, 0, 0)),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_material_blend_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "material-blend-\(tag)", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir
        )
        let renderer = SceneRenderer()
        try renderer.mount(
            in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)),
            project: project
        )
        defer { renderer.teardown() }
        if hdr {
            XCTAssertTrue(renderer.hdrActive, "fixture must exercise rgba16Float accumulation")
        }
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_material_blend_out_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(
            renderer.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first
        )
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        return try XCTUnwrap(rep.colorAt(x: 32, y: 18))
    }

    func testAdditiveMaterialAddsPremultipliedSourceInLDR() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let color = try centerPixel(blending: "additive", tag: "additive-ldr")
        XCTAssertEqual(color.redComponent, 0.5, accuracy: 0.06)
        XCTAssertEqual(color.greenComponent, 1.0, accuracy: 0.06)
        XCTAssertEqual(color.blueComponent, 0.0, accuracy: 0.06)
    }
}
```

- [ ] **Step 2: 첫 테스트를 실행해 기존 over 오동작 확인**

Run:

```bash
swift test --filter 'WapleRenderTests.SceneMaterialBlendRenderTests/testAdditiveMaterialAddsPremultipliedSourceInLDR'
```

Expected: FAIL. `greenComponent`가 기대값 `1.0`이 아니라 약 `0.5`다. Metal이 없는 환경에서 SKIP이면 구현 전 실패 증명이 되지 않으므로 Metal 사용 가능한 현재 macOS 호스트에서 다시 실행한다.

- [ ] **Step 3: non-additive와 HDR 회귀 테스트 추가**

Insert before the final `}` of `SceneMaterialBlendRenderTests`:

```swift
    func testNormalTranslucentAndOmittedMaterialsKeepOverInLDR() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let modes: [String?] = ["normal", "translucent", nil]
        for mode in modes {
            let name = mode ?? "omitted"
            let color = try centerPixel(blending: mode, tag: "over-\(name)")
            XCTAssertEqual(color.redComponent, 0.5, accuracy: 0.06, name)
            XCTAssertEqual(color.greenComponent, 0.5, accuracy: 0.06, name)
            XCTAssertEqual(color.blueComponent, 0.0, accuracy: 0.06, name)
        }
    }

    func testAdditiveMaterialUsesHDRAccumulatorFormat() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let color = try centerPixel(blending: "additive", hdr: true, tag: "additive-hdr")
        XCTAssertGreaterThan(color.redComponent, 0.45)
        XCTAssertGreaterThan(color.greenComponent, color.redComponent + 0.10)
        XCTAssertLessThan(color.blueComponent, 0.05)
    }
```

- [ ] **Step 4: 신규 테스트 클래스를 실행해 RED 상태 확인**

Run:

```bash
swift test --filter 'WapleRenderTests.SceneMaterialBlendRenderTests'
```

Expected: 3 tests executed. LDR additive와 HDR additive 테스트는 FAIL하고, `normal`/`translucent`/omitted over 테스트는 PASS한다.

- [ ] **Step 5: 실패 오라클 커밋**

```bash
git add Tests/WapleRenderTests/SceneMaterialBlendRenderTests.swift
git commit -m "테스트(render): 2D material additive 픽셀 오라클 추가"
```

Expected: `.vscode/launch.json`은 staged changes에 포함되지 않는다.

---

### Task 2: additive 상태 전달·파이프라인·선택 배선

**Files:**
- Modify: `Sources/WapleCore/SceneDocument.swift:68-70`
- Modify: `Sources/WapleRender/SceneRenderer.swift:8,443-449,652-663,1092`
- Modify: `Sources/WapleRender/SceneRendererResources.swift:172-180`
- Modify: `Sources/WapleRender/SceneRendererFrameEncoder.swift:482-498`
- Test: `Tests/WapleRenderTests/SceneMaterialBlendRenderTests.swift`

**Interfaces:**
- Consumes: existing `SceneLayer.blendMode: String`, `QuadShaders.v_main`, `QuadShaders.f_main`, `SceneRenderer.accPixelFormat`.
- Produces: immutable `GPULayer.blendAdditive: Bool`, optional `SceneRenderer.layerAdditivePipeline: MTLRenderPipelineState?`, and guarded ordinary-layer pipeline selection.

- [ ] **Step 1: `SceneLayer` 계약 주석과 `GPULayer` 플래그 추가**

Replace the `SceneLayer.blendMode` comment in `Sources/WapleCore/SceneDocument.swift` with:

```swift
    /// 머티리얼 블렌드 모드("normal"|"additive"|"alphatocoverage"…). 3D 씬 빌보드가 파이프라인 선택에 사용
    /// (플레어/글로우 = additive). 2D는 additive만 전용 고정기능 파이프라인으로 소비하고 나머지는 premult-over 유지.
    public var blendMode: String = "normal"
```

In the one-line `GPULayer` declaration in `Sources/WapleRender/SceneRenderer.swift`, replace the `order`/`uid` segment with:

```swift
let order: Int; let uid: Int /* doc.layers 인덱스 기반 고유 키(scriptVisible 용 — order 는 중복 가능) */; let blendAdditive: Bool /* material passes[0].blending == "additive" */;
```

Add the pipeline property immediately after `var pipeline`:

```swift
    var pipeline: MTLRenderPipelineState?
    /// 일반 2D material additive용 v_main/f_main 파이프라인. nil이면 기본 over로 폴백.
    var layerAdditivePipeline: MTLRenderPipelineState?
    var blendPipeline: MTLRenderPipelineState?
```

- [ ] **Step 2: `buildLayers`에서 additive 플래그 전달**

Update the `GPULayer` construction in `Sources/WapleRender/SceneRendererResources.swift` so its tail is:

```swift
            out.append(GPULayer(texture: mtl, vertexBuffer: vbuf, tint: tint,
                                parallaxDepth: SIMD2<Float>(layer.parallaxDepth.x, layer.parallaxDepth.y),
                                effects: effects, texWidth: effW, texHeight: effH,
                                order: layer.order, uid: uid,
                                blendAdditive: layer.blendMode == "additive",
                                isFrameBuffer: layer.isFrameBuffer,
                                def: (layer.animations.isEmpty && puppetModel == nil && propScripts.isEmpty) ? nil : layer,
                                puppet: puppetModel, propScripts: propScripts,
                                initialVisible: layer.initialVisible,
                                colorBlendMode: layer.colorBlendMode, frames: frames,
                                isLit: layerLit, litRect: lrect))
```

- [ ] **Step 3: 기본 2D descriptor로 additive pipeline state 생성**

Replace the existing base pipeline creation line in `Sources/WapleRender/SceneRenderer.swift` with this block:

```swift
        self.pipeline = try device.makeRenderPipelineState(descriptor: pdesc)
        // 같은 v_main/f_main + accPixelFormat. premultiplied source를 destination에 그대로 더한다.
        att.destinationRGBBlendFactor = .one
        att.destinationAlphaBlendFactor = .one
        self.layerAdditivePipeline = try? device.makeRenderPipelineState(descriptor: pdesc)
```

Keep the existing settings immediately above it unchanged:

```swift
        att.pixelFormat = accPixelFormat
        att.isBlendingEnabled = true
        att.rgbBlendOperation = .add; att.alphaBlendOperation = .add
        att.sourceRGBBlendFactor = .one; att.sourceAlphaBlendFactor = .one
        att.destinationRGBBlendFactor = .oneMinusSourceAlpha; att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
```

The first `makeRenderPipelineState` captures the over descriptor. Mutating `att` afterward affects only the second, additive state.

- [ ] **Step 4: 일반 경로에서만 additive를 선택하고 teardown에 포함**

Replace the pipeline-selection block in `Sources/WapleRender/SceneRendererFrameEncoder.swift` with:

```swift
        // 파이프라인 선택: lit > colorBlendMode > framebuffer compose > material additive > 기본 over.
        // additive는 특수 경로가 아닌 일반 f_main 레이어에만 적용한다.
        if layer.isLit, let litPipeline {
            enc.setRenderPipelineState(litPipeline)
        } else if let blendSnapshot, let blendPipeline, layer.colorBlendMode != 0 {
            // colorBlendMode: 스냅샷 dst 대비 셰이더 블렌드(f_blend). 스냅샷 없으면 일반 합성 폴백.
            enc.setRenderPipelineState(blendPipeline)
            enc.setFragmentTexture(blendSnapshot, index: 1)
            var mode = Int32(layer.colorBlendMode)
            enc.setFragmentBytes(&mode, length: MemoryLayout<Int32>.stride, index: 1)
        } else if layer.isFrameBuffer, let composePipeline {
            // 컴포지션(_rt_FullFrameBuffer): texture=프레임버퍼 스냅샷을 화면좌표로 샘플(f_compose).
            // 부분 쿼드도 뒤 화면을 1:1 통과 → stretch 회색 덩어리 제거(E1). 나머지 바인딩은 f_main 동일.
            enc.setRenderPipelineState(composePipeline)
        } else if layer.blendAdditive,
                  !layer.isLit,
                  layer.colorBlendMode == 0,
                  !layer.isFrameBuffer,
                  let layerAdditivePipeline {
            enc.setRenderPipelineState(layerAdditivePipeline)
        } else {
            enc.setRenderPipelineState(pipeline)
        }
```

The three negative guards preserve the existing over fallback if a lit, color-blend, or framebuffer special pipeline is unavailable.

In `SceneRenderer.teardown()`, replace the final resource line with:

```swift
        pipeline = nil; layerAdditivePipeline = nil; queue = nil; device = nil
```

- [ ] **Step 5: 신규 테스트를 실행해 GREEN 확인**

Run:

```bash
swift test --filter 'WapleRenderTests.SceneMaterialBlendRenderTests'
```

Expected: 3 tests executed, 0 failures. HDR test의 `renderer.hdrActive` assertion도 통과한다.

- [ ] **Step 6: 영향받는 기존 특수·over 경로만 빠르게 검증**

Run these commands individually:

```bash
swift test --filter 'WapleRenderTests.SceneCompositeConventionTests/testSemiTransparentLayerCompositesCorrectly'
swift test --filter 'WapleRenderTests.SceneCompositeConventionTests/testFrameBufferPassthroughIsIdentity'
swift test --filter 'WapleRenderTests.BlendModeLayerTests'
swift test --filter 'WapleRenderTests.SceneForwardLightingRenderTests/testLightColorReactivity'
```

Expected: 6 existing tests executed across the four commands, 0 failures. Do not run any broader suite or corpus command.

- [ ] **Step 7: 변경 경계와 사용자 파일 보존 확인**

Run:

```bash
git diff --check
git status --short
git diff -- Sources/WapleCore/SceneDocument.swift Sources/WapleRender/SceneRenderer.swift Sources/WapleRender/SceneRendererResources.swift Sources/WapleRender/SceneRendererFrameEncoder.swift
```

Expected: whitespace errors 없음. Production 변경은 명시한 네 파일뿐이며 `.vscode/launch.json`은 별도의 unstaged 사용자 변경으로 남는다.

- [ ] **Step 8: production 변경 커밋**

```bash
git add Sources/WapleCore/SceneDocument.swift \
        Sources/WapleRender/SceneRenderer.swift \
        Sources/WapleRender/SceneRendererResources.swift \
        Sources/WapleRender/SceneRendererFrameEncoder.swift
git diff --cached --check
git commit -m "수정(render): 2D additive material 블렌딩 배선"
```

Expected: 테스트 커밋과 production 커밋이 분리되고 `.vscode/launch.json`은 커밋되지 않는다.
