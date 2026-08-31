import XCTest
import AppKit
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

/// 정사영 씬 안의 `perspective:true` image/text는 x/y 회전과 z 깊이 때문에 화면에서 사다리꼴이 된다.
/// 포인터 판정도 저작 XY 직사각형이 아니라 실제 projection/near-far clip 결과를 따라야 한다.
final class PerspectivePointerTargetTests: XCTestCase {
    private func project(scene: String, id: String) throws -> (SceneRenderer, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(id)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", Data(scene.utf8)),
            ("models/x.json", Data(#"{"material":"materials/x.json"}"#.utf8)),
            ("materials/x.json", Data(#"{"passes":[{"textures":["x"]}]}"#.utf8)),
            ("materials/x.tex", solidTex(255, 255, 255, w: 8, h: 8)),
        ]).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
            title: id, tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100)),
                           project: project)
        return (renderer, root)
    }

    private func scenePoint(_ vertex: SIMD4<Float>) -> SIMD2<Float> {
        SIMD2((vertex.x + 1) * 100, (vertex.y + 1) * 50)
    }

    private func triangleContains(_ p: SIMD2<Float>, _ a: SIMD2<Float>,
                                  _ b: SIMD2<Float>, _ c: SIMD2<Float>) -> Bool {
        func cross(_ x: SIMD2<Float>, _ y: SIMD2<Float>, _ z: SIMD2<Float>) -> Float {
            let u = y - x, v = z - x
            return u.x * v.y - u.y * v.x
        }
        let ab = cross(a, b, p), bc = cross(b, c, p), ca = cross(c, a, p)
        return (ab >= 0 && bc >= 0 && ca >= 0) || (ab <= 0 && bc <= 0 && ca <= 0)
    }

    private func renderedContains(_ p: SIMD2<Float>, vertices: [SIMD4<Float>]) -> Bool {
        stride(from: 0, to: vertices.count, by: 3).contains { i in
            triangleContains(p, scenePoint(vertices[i]), scenePoint(vertices[i + 1]),
                             scenePoint(vertices[i + 2]))
        }
    }

    /// yaw가 있는 이미지의 raw XY 직사각형에는 들어가지만 렌더된 사다리꼴에는 없는 점을 고른다.
    /// 그 점이 클릭 대상으로 남으면 draw와 hit가 서로 다른 geometry를 소비한다는 뜻이다.
    func testPerspectiveImageHitFollowsProjectedTrapezoid() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":100},
                    "perspectiveoverridefov":60,"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/x.json","origin":"100 50 25","size":"80 60",
                     "scale":"1 1 1","angles":"0 0.9 0","perspective":true,
                     "visible":{"value":true,"script":"export function cursorClick(e) {}"}}]}
        """
        let (renderer, root) = try project(scene: scene, id: "waple_perspective_image_hit")
        defer {
            renderer.teardown()
            try? FileManager.default.removeItem(at: root)
        }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try XCTUnwrap(renderer.captureFrames(width: 200, height: 100, times: [0],
                                                 toDir: output).first)
        guard case .projected = try XCTUnwrap(renderer.pointerTargets.first).scope else {
            return XCTFail("perspective image는 투영 다각형 scope여야 한다")
        }

        let verts = SceneRenderer.quadVertices(
            origin: Vec2(x: 100, y: 50), size: Vec2(x: 80, y: 60), scale: Vec2(x: 1, y: 1),
            angleZ: 0, alignment: "center", projW: 200, projH: 100,
            perspective: true, perspectiveFov: 60, originZ: 25, angleX: 0, angleY: 0.9)
        XCTAssertFalse(verts.isEmpty)
        let raw = SceneRenderer.layerHitQuad(origin: Vec2(x: 100, y: 50), size: Vec2(x: 80, y: 60),
                                             scale: Vec2(x: 1, y: 1), angleZ: 0,
                                             alignment: "center")
        let mismatch = (0..<100).lazy.flatMap { y in
            (0..<200).lazy.map { x in SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5) }
        }.first { PointerHit.contains(raw, $0) && !renderedContains($0, vertices: verts) }
        let inside = (0..<100).lazy.flatMap { y in
            (0..<200).lazy.map { x in SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5) }
        }.first { renderedContains($0, vertices: verts) }

        let outsideProjected = try XCTUnwrap(mismatch, "raw rect와 projected trapezoid가 갈리는 점이 필요")
        XCTAssertFalse(renderer.pointerTargetCovers(0, outsideProjected),
                       "렌더된 사다리꼴 밖이면 raw XY 직사각형 안이어도 배달하면 안 된다")
        XCTAssertTrue(renderer.pointerTargetCovers(0, try XCTUnwrap(inside)))
    }

    /// 텍스트는 저작 size가 아니라 실제 raster ink box(+활성 padding)를 투영해야 한다.
    /// image만 고치고 text가 raw raster 직사각형에 남는 복제 경로 회귀를 잡는다.
    func testPerspectiveTextHitProjectsRasterSizedTrapezoid() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":100},
                    "perspectiveoverridefov":60,"clearcolor":"0 0 0"},
         "objects":[{"id":1,"text":"MMMM","font":"systemfont_arial","pointsize":30,
                     "origin":"100 50 25","scale":"1 1 1","angles":"0 0.9 0",
                     "horizontalalign":"center","verticalalign":"center","perspective":true,
                     "visible":{"value":true,"script":"export function cursorClick(e) {}"}}]}
        """
        let (renderer, root) = try project(scene: scene, id: "waple_perspective_text_hit")
        defer {
            renderer.teardown()
            try? FileManager.default.removeItem(at: root)
        }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try XCTUnwrap(renderer.captureFrames(width: 200, height: 100, times: [0],
                                                 toDir: output).first)
        guard case .projected = try XCTUnwrap(renderer.pointerTargets.first).scope else {
            return XCTFail("perspective text는 투영 다각형 scope여야 한다")
        }

        let text = try XCTUnwrap(renderer.textLayers.first)
        let hitSize = PointerHit.textHitSize(
            inkBox: SIMD2(text.rasterWidth, text.rasterHeight),
            padding: SIMD2(text.def.padding.x, text.def.padding.y),
            paddingActive: PointerHit.textPaddingActive(
                hasEffects: !text.def.effects.isEmpty,
                opaqueBackground: text.def.opaqueBackground,
                colorBlendMode: text.def.colorBlendMode))
        let align = SceneRenderer.textAlignmentString(h: text.def.horizontalAlign,
                                                      v: text.def.verticalAlign)
        let verts = SceneRenderer.quadVertices(
            origin: text.def.origin, size: Vec2(x: hitSize.x, y: hitSize.y), scale: text.def.scale,
            angleZ: text.def.angleZ, alignment: align, projW: 200, projH: 100,
            perspective: true, perspectiveFov: 60, originZ: text.def.originZ,
            angleX: text.def.angleX, angleY: text.def.angleY)
        let raw = SceneRenderer.layerHitQuad(
            origin: text.def.origin, size: Vec2(x: hitSize.x, y: hitSize.y), scale: text.def.scale,
            angleZ: text.def.angleZ, alignment: align)
        let mismatch = (0..<100).lazy.flatMap { y in
            (0..<200).lazy.map { x in SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5) }
        }.first { PointerHit.contains(raw, $0) && !renderedContains($0, vertices: verts) }
        let inside = (0..<100).lazy.flatMap { y in
            (0..<200).lazy.map { x in SIMD2<Float>(Float(x) + 0.5, Float(y) + 0.5) }
        }.first { renderedContains($0, vertices: verts) }

        XCTAssertFalse(renderer.pointerTargetCovers(0, try XCTUnwrap(mismatch)))
        XCTAssertTrue(renderer.pointerTargetCovers(0, try XCTUnwrap(inside)))
    }

    /// perspective 시차는 화면 polygon을 균일 이동하는 게 아니라 object origin에 먼저 더한 뒤
    /// 각 꼭짓점을 나눠야 한다. yaw가 있으면 두 결과는 명확히 다르다.
    func testPerspectiveHitBakesLeafParallaxBeforeProjection() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":100},
                    "perspectiveoverridefov":60,"clearcolor":"0 0 0",
                    "cameraparallax":true,"cameraparallaxamount":0.5,
                    "cameraparallaxmouseinfluence":0,"cameraparallaxdelay":0},
         "objects":[{"id":1,"image":"models/x.json","origin":"50 50 25","size":"40 40",
                     "scale":"1 1 1","angles":"0 0.9 0","perspective":true,
                     "parallaxDepth":"1 1",
                     "visible":{"value":true,"script":"export function cursorClick(e) {}"}}]}
        """
        let (renderer, root) = try project(scene: scene, id: "waple_perspective_hit_parallax")
        defer {
            renderer.teardown()
            try? FileManager.default.removeItem(at: root)
        }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try XCTUnwrap(renderer.captureFrames(width: 200, height: 100, times: [0],
                                                 toDir: output).first)
        guard case .projected(let actual) = try XCTUnwrap(renderer.pointerTargets.first).scope else {
            return XCTFail("perspective hit polygon이 필요")
        }

        let bakedVertices = SceneRenderer.quadVertices(
            origin: Vec2(x: 25, y: 50), size: Vec2(x: 40, y: 40), scale: Vec2(x: 1, y: 1),
            angleZ: 0, alignment: "center", projW: 200, projH: 100,
            perspective: true, perspectiveFov: 60, originZ: 25, angleX: 0, angleY: 0.9)
        let expected = try XCTUnwrap(SceneRenderer.projectedHitPolygon(
            vertices: bakedVertices, projW: 200, projH: 100, ndcOffset: .zero))
        XCTAssertEqual(actual, expected)

        let unshiftedVertices = SceneRenderer.quadVertices(
            origin: Vec2(x: 50, y: 50), size: Vec2(x: 40, y: 40), scale: Vec2(x: 1, y: 1),
            angleZ: 0, alignment: "center", projW: 200, projH: 100,
            perspective: true, perspectiveFov: 60, originZ: 25, angleX: 0, angleY: 0.9)
        let postProjection = try XCTUnwrap(SceneRenderer.projectedHitPolygon(
            vertices: unshiftedVertices, projW: 200, projH: 100, ndcOffset: .zero))
            .translated(by: SIMD2(-25, 0))
        XCTAssertNotEqual(actual, postProjection,
                          "원근 나눗셈 뒤 균일 -25px 이동으로 되돌아가면 안 된다")
    }

    /// 꼭짓점 하나가 near 평면에 정확히 놓일 때 클리퍼가 같은 끝점을 보간값+원본으로 두 번
    /// 만들면, 미세한 가짜 변이 볼록 다각형의 half-plane이 되어 실제 fan 픽셀을 대량 배제한다.
    func testNearPlaneBoundaryDoesNotAddFalseClippingEdgeToHitPolygon() throws {
        let projW: Float = 400, projH: Float = 200
        let angles = SIMD3<Float>(0.7, 0.4, 0.2)
        let distance = SceneCameraMath.layerPerspectiveDistance(
            orthoHeight: projH, fovDegrees: 60)
        let clip = SceneCameraMath.layerPerspectiveClip(distance: distance)
        let rotation = Scene3DMath.modelMatrix(
            origin: .zero, angles: angles, scale: SIMD3<Float>(repeating: 1))
        let boundaryCorner = rotation * SIMD4<Float>(-50, -40, 0, 0)
        let originZ = distance - boundaryCorner.z - clip.near
        let vertices = SceneRenderer.quadVertices(
            origin: Vec2(x: 200, y: 100), size: Vec2(x: 100, y: 80),
            scale: Vec2(x: 1, y: 1), angleZ: angles.z, alignment: "center",
            projW: projW, projH: projH, perspective: true, perspectiveFov: 60,
            originZ: originZ, angleX: angles.x, angleY: angles.y)
        XCTAssertGreaterThanOrEqual(vertices.count, 3)

        func scenePoint(_ vertex: SIMD4<Float>) -> SIMD2<Float> {
            SIMD2((vertex.x + 1) * 0.5 * projW, (vertex.y + 1) * 0.5 * projH)
        }
        let renderedPoint = SIMD2<Float>(344.5, 0.5)
        XCTAssertTrue(triangleContains(renderedPoint, scenePoint(vertices[0]),
                                       scenePoint(vertices[1]), scenePoint(vertices[2])),
                      "선택점이 실제 Metal fan 첫 삼각형에 포함된다는 양성 오라클")
        let polygon = try XCTUnwrap(SceneRenderer.projectedHitPolygon(
            vertices: vertices, projW: projW, projH: projH, ndcOffset: .zero))
        XCTAssertTrue(PointerHit.contains(polygon, renderedPoint),
                      "실제로 그린 near-clipped 픽셀을 pointer polygon도 포함해야 한다")
    }

    /// finalizer가 실패하면 PNG/라이브 drawable은 갱신되지 않는다. 그보다 먼저 pending 기하를
    /// publish하면 포인터만 실패한 새 프레임 위치로 이동해 표시 픽셀과 갈라진다.
    func testFailed2DFinalizerDoesNotPublishUnpresentedInteractionGeometry() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let originScript = "export function cursorClick(e) {} "
            + "export function update(v) { v.x = engine.runtime < 1 ? 50 : 150; return v; }"
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":100},
                    "hdr":true,"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/x.json",
                     "origin":{"value":"50 50 0","script":\(String(reflecting: originScript))},
                     "size":"20 20","scale":"1 1 1"}]}
        """
        let (renderer, root) = try project(scene: scene, id: "waple_failed_finalizer_pointer")
        defer {
            renderer.teardown()
            try? FileManager.default.removeItem(at: root)
        }
        let firstDir = root.appendingPathComponent("first", isDirectory: true)
        let failedDir = root.appendingPathComponent("failed", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: failedDir, withIntermediateDirectories: true)

        _ = try XCTUnwrap(renderer.captureFrames(width: 200, height: 100, times: [0],
                                                 toDir: firstDir).first)
        let presentedScope = try XCTUnwrap(renderer.pointerTargets.first).scope
        XCTAssertTrue(renderer.hdrActive)
        XCTAssertNotNil(renderer.hdrPost)

        renderer.hdrPost = nil  // float source→BGRA target finalizer를 의도적으로 실패시킨다.
        XCTAssertTrue(renderer.captureFrames(width: 200, height: 100, times: [1],
                                             toDir: failedDir).isEmpty)
        XCTAssertEqual(try XCTUnwrap(renderer.pointerTargets.first).scope, presentedScope,
                       "표시되지 않은 프레임의 동적 origin을 pointer scope로 승격하면 안 된다")
    }
}
