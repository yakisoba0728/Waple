import XCTest
import AppKit
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

/// 원근 3D 빌보드의 커서 훅 소유권과 히트 기하 배선.
///
/// 2D 레이어와 달리 3D 이미지/텍스트는 `build3D`에서 별도 `Billboard3D`로 다시 만들어진다.
/// 이 경계에서 descriptor index를 잃으면 바인드 스크립트가 `.unbound`가 되어 화면 어디를
/// 클릭해도 발화한다. 또한 히트 쿼드는 저작 world 좌표가 아니라 실제 카메라로 투영된 화면 위치여야 한다.
final class Scene3DPointerTargetTests: XCTestCase {
    private func package(_ scene: String) -> ScenePackage {
        ScenePackage.assemble([
            ("scene.json", Data(scene.utf8)),
            ("models/x.json", Data(#"{"material":"materials/x.json"}"#.utf8)),
            ("materials/x.json", Data(#"{"passes":[{"textures":["x"]}]}"#.utf8)),
            ("materials/x.tex", solidTex(255, 255, 255)),
        ])
    }

    private func project(_ scene: String, id: String, container: NSView? = nil) throws -> (SceneRenderer, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(id)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", Data(scene.utf8)),
            ("models/x.json", Data(#"{"material":"materials/x.json"}"#.utf8)),
            ("materials/x.json", Data(#"{"passes":[{"textures":["x"]}]}"#.utf8)),
            ("materials/x.tex", solidTex(255, 255, 255)),
        ]).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
            title: id, tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(
            in: container ?? NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)),
            project: project)
        return (renderer, root)
    }

    /// 이미지와 텍스트가 이름을 공유해도 각 프로퍼티 스크립트는 `thisScene.layers`의 자기
    /// descriptor index를 보존해야 한다. 이름 조회나 nil(unbound) 폴백은 둘 다 오배달을 만든다.
    func test3DBillboardScriptsKeepImageAndTextDescriptorIdentity() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let hook = "export function cursorClick(e) {}\nexport function cursorEnter(e) {}"
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50,"clearcolor":"0 0 0"},
         "objects":[
           {"id":90,"model":"models/missing.mdl"},
           {"id":1,"name":"dup","image":"models/x.json","origin":"-1 0 0","size":"1 1",
            "visible":{"value":true,"script":\(String(reflecting: hook))}},
           {"id":2,"name":"dup","text":"T","font":"systemfont_arial","pointsize":24,
            "origin":"1 0 0","scale":"0.02 0.02 0.02",
            "visible":{"value":true,"script":\(String(reflecting: hook))}}
         ]}
        """
        let pkg = package(scene)
        let doc = try SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.texts.count, 1)

        let renderer = SceneRenderer()
        renderer.sceneScript = try XCTUnwrap(SceneScriptContext(
            layers: SceneRenderer.sceneScriptLayers(from: doc)))
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)
        renderer.build3D(doc: doc, package: pkg, device: device)

        XCTAssertEqual(renderer.billboards.map(\.layerIndex), [0, 1],
                       "텍스트도 image-count + uid descriptor index를 가져야 한다")
        XCTAssertEqual(renderer.pointerEngineOwners.map(\.descriptorIndex), [0, 1])
        XCTAssertEqual(renderer.hoverEngineOwners.map(\.descriptorIndex), [0, 1])
    }

    /// 앞선 image descriptor가 텍스처 로드 실패로 billboard 배열에서 빠져도, 남은 image와
    /// 별도 text-content 엔진은 압축된 billboard 인덱스가 아니라 원래 thisScene.layers 인덱스를 쓴다.
    func test3DDescriptorIdentitySurvivesSkippedImageAndTextContentEngine() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let imageHook = "export function cursorClick(e) {} export function cursorEnter(e) {}"
        let textHook = "export function update(v) { return v; } export function cursorClick(e) {} export function cursorEnter(e) {}"
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50,"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/missing.json","origin":"-2 0 0","size":"1 1"},
           {"id":2,"image":"models/x.json","origin":"0 0 0","size":"1 1",
            "visible":{"value":true,"script":\(String(reflecting: imageHook))}},
           {"id":3,"text":{"value":"T","script":\(String(reflecting: textHook))},
            "font":"systemfont_arial","pointsize":24,"origin":"1 0 0","scale":"0.02 0.02 0.02"}
         ]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", Data(scene.utf8)),
            ("models/missing.json", Data(#"{"material":"materials/missing.json"}"#.utf8)),
            ("materials/missing.json", Data(#"{"passes":[{"textures":["missing"]}]}"#.utf8)),
            ("models/x.json", Data(#"{"material":"materials/x.json"}"#.utf8)),
            ("materials/x.json", Data(#"{"passes":[{"textures":["x"]}]}"#.utf8)),
            ("materials/x.tex", solidTex(255, 255, 255)),
        ])
        let doc = try SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.layers.count, 2)
        XCTAssertEqual(doc.texts.count, 1)

        let renderer = SceneRenderer()
        renderer.sceneScript = try XCTUnwrap(SceneScriptContext(
            layers: SceneRenderer.sceneScriptLayers(from: doc)))
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)
        renderer.build3D(doc: doc, package: pkg, device: device)

        XCTAssertEqual(renderer.billboards.map(\.layerIndex), [1, 2])
        XCTAssertEqual(renderer.pointerEngineOwners.map(\.descriptorIndex), [1, 2])
        XCTAssertEqual(renderer.hoverEngineOwners.map(\.descriptorIndex), [1, 2])
    }

    /// 첫 렌더가 끝나면 저작 world origin이 아니라 encodeBillboard가 실제로 그린 월드 코너의
    /// 카메라 투영을 히트 쿼드로 승격해야 한다. 그 결과 화면 밖 클릭은 바인드 훅에 배달되지 않는다.
    @MainActor
    func test3DBillboardClickUsesPresentedProjectedQuadInsteadOfGlobalDelivery() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50,"clearcolor":"0 0 0"},
         "objects":[
           {"id":90,"model":"models/missing.mdl"},
           {"id":2,"name":"target","text":"Hit","font":"systemfont_arial","pointsize":32,
            "origin":"0 0 0","scale":"0.02 0.02 0.02",
            "visible":{"value":true,"script":"export function cursorClick(e) { shared.hit = (shared.hit || 0) + 1; } export function cursorEnter(e) {}"}}
         ]}
        """
        let (renderer, root) = try project(scene, id: "waple_3d_pointer_projected")
        defer {
            renderer.teardown()
            try? FileManager.default.removeItem(at: root)
        }

        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try XCTUnwrap(renderer.captureFrames(width: 200, height: 200, times: [0],
                                                 toDir: output).first)

        let target = try XCTUnwrap(renderer.pointerTargets.first)
        XCTAssertEqual(target.descriptorIndex, 0)
        guard case .object(let quad) = target.scope else {
            return XCTFail("표시된 3D 빌보드가 투영 히트 쿼드로 승격되지 않았다: \(target.scope)")
        }
        let center = try XCTUnwrap(renderer.pointerHookTargetCenter(hook: "cursorClick"))
        XCTAssertEqual(center.x, quad.center.x, accuracy: 1e-4)
        XCTAssertEqual(center.y, quad.center.y, accuracy: 1e-4)
        XCTAssertTrue(renderer.pointerTargetCovers(0, center))
        XCTAssertFalse(renderer.pointerTargetCovers(0, SIMD2<Float>(0, 0)))

        renderer.simulateCursorClick(x: center.x, y: center.y)
        renderer.simulateCursorClick(x: 0, y: 0)
        let hits = renderer.sceneScript?.context.evaluateScript("shared.hit || 0")?.toInt32()
        XCTAssertEqual(hits, 1, "쿼드 밖 클릭이 바인드 스크립트에 브로드캐스트되면 안 된다")

        let hover = try XCTUnwrap(renderer.hoverTargets.first)
        guard case .object = hover.scope else {
            return XCTFail("cursorEnter 소유 대상도 같은 투영 기하를 받아야 한다: \(hover.scope)")
        }
    }

    /// 같은 billboard의 origin update가 표시 프레임마다 다시 투영되어야 한다. mount 정적 쿼드나
    /// 직전 프레임 쿼드를 계속 쓰면 두 중심이 같게 남는다.
    func test3DScriptedOriginUpdatesPresentedHitGeometryEveryFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let script = "export function cursorClick(e) {} export function update(v) { v.x = engine.runtime < 1 ? -1 : 1; return v; }"
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50,"clearcolor":"0 0 0"},
         "objects":[
           {"id":90,"model":"models/missing.mdl"},
           {"id":1,"image":"models/x.json","origin":{"value":"0 0 0","script":\(String(reflecting: script))},
            "size":"1 1","scale":"1 1 1"}
         ]}
        """
        let (renderer, root) = try project(scene, id: "waple_3d_pointer_dynamic")
        defer {
            renderer.teardown()
            try? FileManager.default.removeItem(at: root)
        }
        let out0 = root.appendingPathComponent("capture0", isDirectory: true)
        let out1 = root.appendingPathComponent("capture1", isDirectory: true)
        try FileManager.default.createDirectory(at: out0, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out1, withIntermediateDirectories: true)
        _ = try XCTUnwrap(renderer.captureFrames(width: 200, height: 200, times: [0], toDir: out0).first)
        let first = try XCTUnwrap(renderer.pointerHookTargetCenter(hook: "cursorClick"))
        _ = try XCTUnwrap(renderer.captureFrames(width: 200, height: 200, times: [1], toDir: out1).first)
        let second = try XCTUnwrap(renderer.pointerHookTargetCenter(hook: "cursorClick"))
        XCTAssertGreaterThan(second.x, first.x + 300,
                             "world x -1→+1의 현재 프레임 투영이 hit center에 반영돼야 한다")
        XCTAssertEqual(second.y, first.y, accuracy: 1e-4)
    }

    /// `solid:false`는 렌더 여부와 독립인 포인터 광선 순회 게이트다. 투영 쿼드를 만들었다고
    /// 비-solid 소유 스크립트를 다시 활성화하면 안 된다.
    @MainActor
    func test3DNonSolidBillboardRemainsUnhittableAfterProjection() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50,"clearcolor":"0 0 0"},
         "objects":[
           {"id":90,"model":"models/missing.mdl"},
           {"id":1,"image":"models/x.json","origin":"0 0 0","size":"2 2","solid":false,
            "visible":{"value":true,"script":"export function cursorClick(e) { shared.hit = 1; }"}}
         ]}
        """
        let (renderer, root) = try project(scene, id: "waple_3d_pointer_nonsolid")
        defer {
            renderer.teardown()
            try? FileManager.default.removeItem(at: root)
        }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try XCTUnwrap(renderer.captureFrames(width: 200, height: 200, times: [0],
                                                 toDir: output).first)
        XCTAssertEqual(try XCTUnwrap(renderer.pointerTargets.first).scope, .unhittable)
        renderer.simulateCursorClick(x: 960, y: 540)
        XCTAssertEqual(renderer.sceneScript?.context.evaluateScript("shared.hit || 0")?.toInt32(), 0)
    }

    /// WE의 히트 순회는 `solid`만 참가 게이트로 쓰고 `visible`은 disablePropagation 판정에만 쓴다.
    /// 따라서 그리지 않는 solid billboard도 자기 월드 기하에서 커서 훅을 계속 받아야 한다.
    @MainActor
    func test3DInvisibleSolidBillboardStillReceivesPointerHooks() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50,"clearcolor":"0 0 0"},
         "objects":[
           {"id":90,"model":"models/missing.mdl"},
           {"id":1,"image":"models/x.json","origin":"0 0 0","size":"2 2","solid":true,
            "visible":{"value":true,"script":"export function update(v) { return false; } export function cursorClick(e) { shared.hit = 1; }"}}
         ]}
        """
        let (renderer, root) = try project(scene, id: "waple_3d_pointer_invisible_solid")
        defer {
            renderer.teardown()
            try? FileManager.default.removeItem(at: root)
        }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try XCTUnwrap(renderer.captureFrames(width: 200, height: 200, times: [0],
                                                 toDir: output).first)
        let center = try XCTUnwrap(renderer.pointerHookTargetCenter(hook: "cursorClick"))
        XCTAssertTrue(renderer.pointerTargetCovers(0, center))
        renderer.simulateCursorClick(x: center.x, y: center.y)
        XCTAssertEqual(renderer.sceneScript?.context.evaluateScript("shared.hit || 0")?.toInt32(), 1)
    }

    /// 3D 텍스트도 2D와 같은 `inkBox + 2*padding` 히트 크기를 쓴다. draw glyph raster만
    /// 투영하면 opaque/effected 텍스트의 보이는 배경 테두리가 클릭 불가가 된다.
    func test3DPaddedTextHitUsesExpandedInteractionSize() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50,"clearcolor":"0 0 0"},
         "objects":[
           {"id":90,"model":"models/missing.mdl"},
           {"id":1,"text":"Pad","font":"systemfont_arial","pointsize":32,
            "origin":"0 0 0","scale":"0.02 0.02 0.02","padding":"20 10","opaquebackground":true,
            "visible":{"value":true,"script":"export function cursorClick(e) {}"}}
         ]}
        """
        let (renderer, root) = try project(scene, id: "waple_3d_pointer_text_padding")
        defer {
            renderer.teardown()
            try? FileManager.default.removeItem(at: root)
        }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try XCTUnwrap(renderer.captureFrames(width: 200, height: 200, times: [0],
                                                 toDir: output).first)

        let bb = try XCTUnwrap(renderer.billboards.first(where: { $0.layerIndex == 0 }))
        XCTAssertEqual(bb.interactionSize.x, bb.size.x + 40, accuracy: 1e-4)
        XCTAssertEqual(bb.interactionSize.y, bb.size.y + 20, accuracy: 1e-4)
        let target = try XCTUnwrap(renderer.pointerTargets.first)
        guard case .object(let quad) = target.scope else {
            return XCTFail("padded 3D text가 투영 hit quad를 갖지 않는다: \(target.scope)")
        }
        let drawRatio = bb.size.x / bb.interactionSize.x
        let paddedOnlyPoint = quad.center + quad.axisX * (0.25 * (1 + drawRatio))
        XCTAssertTrue(renderer.pointerTargetCovers(0, paddedOnlyPoint),
                      "glyph draw 폭 밖이지만 활성 padding 안인 점도 텍스트 소유 범위다")
    }

    /// alpha/color의 시각 update를 3D 텍스트에서 보류하더라도, 그 바인딩에 export된 커서 훅
    /// 인스턴스까지 버리면 안 된다. 훅은 프로퍼티 종류와 무관하게 같은 text descriptor 소유다.
    @MainActor
    func test3DTextAlphaBoundCursorHookKeepsDescriptorIdentity() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50,"clearcolor":"0 0 0"},
         "objects":[
           {"id":90,"model":"models/missing.mdl"},
           {"id":1,"text":"A","font":"systemfont_arial","pointsize":32,
            "origin":"0 0 0","scale":"0.02 0.02 0.02",
            "alpha":{"value":1,"script":"export function cursorClick(e) { shared.hit = 1; }"}}
         ]}
        """
        let (renderer, root) = try project(scene, id: "waple_3d_pointer_text_alpha_hook")
        defer {
            renderer.teardown()
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertEqual(renderer.pointerEngineOwners.map(\.descriptorIndex), [0])
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try XCTUnwrap(renderer.captureFrames(width: 200, height: 200, times: [0],
                                                 toDir: output).first)
        let center = try XCTUnwrap(renderer.pointerHookTargetCenter(hook: "cursorClick"))
        renderer.simulateCursorClick(x: center.x, y: center.y)
        XCTAssertEqual(renderer.sceneScript?.context.evaluateScript("shared.hit || 0")?.toInt32(), 1)
    }

    /// 원근 3D는 target aspect로 직접 투영해 결과 텍스처를 꽉 채운다. 2D `.fit` scale을
    /// 투영 쿼드나 포인터 역매핑에 다시 적용하면 실제로 보이는 상하 영역이 클릭 불가가 된다.
    @MainActor
    func test3DFitModeInputMatchesFullTargetProjection() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let oldFit = SceneRenderSettings.fitMode
        SceneRenderSettings.fitMode = .fit
        defer { SceneRenderSettings.fitMode = oldFit }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50,"clearcolor":"0 0 0"},
         "objects":[
           {"id":90,"model":"models/missing.mdl"},
           {"id":1,"image":"models/x.json","origin":"0 1.8 0","size":"1 1","solid":true,
            "visible":{"value":true,"script":"export function cursorClick(e) {}"}}
         ]}
        """
        let (renderer, root) = try project(scene, id: "waple_3d_pointer_fit_target")
        defer {
            renderer.teardown()
            try? FileManager.default.removeItem(at: root)
        }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try XCTUnwrap(renderer.captureFrames(width: 200, height: 200, times: [0],
                                                 toDir: output).first)

        let view = Scene3DMath.lookAt(eye: SIMD3<Float>(0, 0, 5), center: .zero,
                                      up: SIMD3<Float>(0, 1, 0))
        let proj = Scene3DMath.perspective(fovYDegrees: 50, aspect: 1,
                                           nearZ: 0.1, farZ: 10000)
        let expected = try XCTUnwrap(SceneRenderer.projectedBillboardHitQuad(
            tl: SIMD3(-0.5, 2.3, 0), tr: SIMD3(0.5, 2.3, 0),
            br: SIMD3(0.5, 1.3, 0), bl: SIMD3(-0.5, 1.3, 0),
            viewProj: proj * view, projW: renderer.projW, projH: renderer.projH,
            interactionScale: SIMD2<Float>(1, 1)))
        let actual = try XCTUnwrap(renderer.pointerTargets.first)
        guard case .object(let actualQuad) = actual.scope else {
            return XCTFail("3D billboard hit quad가 투영되지 않았다: \(actual.scope)")
        }
        XCTAssertEqual(actualQuad.center.x, expected.center.x, accuracy: 0.1)
        XCTAssertEqual(actualQuad.center.y, expected.center.y, accuracy: 0.1)

        let viewPoint = CGPoint(x: CGFloat(expected.center.x / renderer.projW * 200),
                                y: CGFloat(expected.center.y / renderer.projH * 200))
        let mapped = try XCTUnwrap(renderer.sceneCoordsForPresentedFrame(
            viewPoint: viewPoint, viewSize: CGSize(width: 200, height: 200)))
        XCTAssertEqual(mapped.x, expected.center.x, accuracy: 0.1)
        XCTAssertEqual(mapped.y, expected.center.y, accuracy: 0.1)
    }

    /// `captureFrames`는 라이브 렌더러에도 공개돼 있다. 별도 크기/시각의 오프스크린 프레임이
    /// 라이브 창에 마지막으로 표시된 포인터·호버 기하를 덮으면 다음 물리 입력이 캡처 위치로 샌다.
    @MainActor
    func testOffscreenCapturePreservesLivePresentedInteractionGeometry() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let script = "export function cursorClick(e) {} export function cursorEnter(e) {} "
            + "export function update(v) { v.x = engine.runtime < 1 ? -1 : 1; return v; }"
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50,"clearcolor":"0 0 0"},
         "objects":[
           {"id":90,"model":"models/missing.mdl"},
           {"id":1,"image":"models/x.json","origin":{"value":"0 0 0","script":\(String(reflecting: script))},
            "size":"1 1","scale":"1 1 1"}
         ]}
        """
        // 앱의 정식 lifecycle처럼 window가 없는 컨테이너에 먼저 mount한 뒤 창에 붙인다.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let (renderer, root) = try project(scene, id: "waple_3d_pointer_live_capture",
                                           container: container)
        defer {
            renderer.teardown()
            try? FileManager.default.removeItem(at: root)
        }
        let liveFrame = root.appendingPathComponent("live-frame", isDirectory: true)
        let offscreenFrame = root.appendingPathComponent("offscreen-frame", isDirectory: true)
        try FileManager.default.createDirectory(at: liveFrame, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: offscreenFrame, withIntermediateDirectories: true)

        _ = try XCTUnwrap(renderer.captureFrames(width: 200, height: 200, times: [0],
                                                 toDir: liveFrame).first)
        let livePointerScope = try XCTUnwrap(renderer.pointerTargets.first).scope
        let liveHoverScope = try XCTUnwrap(renderer.hoverTargets.first).scope
        renderer.hoverTargets[0].inside = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = container
        let view = try XCTUnwrap(renderer.mtkView)
        XCTAssertNotNil(view.window, "mount 이후 라이브 창에 붙는 경로를 실제로 타야 한다")

        _ = try XCTUnwrap(renderer.captureFrames(width: 320, height: 160, times: [1],
                                                 toDir: offscreenFrame).first)
        XCTAssertEqual(try XCTUnwrap(renderer.pointerTargets.first).scope, livePointerScope)
        XCTAssertEqual(try XCTUnwrap(renderer.hoverTargets.first).scope, liveHoverScope)
        XCTAssertTrue(try XCTUnwrap(renderer.hoverTargets.first).inside)
        XCTAssertTrue(renderer.pendingInteractionGeometry.isEmpty)
    }
}
