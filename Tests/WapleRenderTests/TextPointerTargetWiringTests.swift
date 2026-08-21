import XCTest
@testable import WapleCore
@testable import WapleRender

/// 텍스트 오브젝트 커서 히트 쿼드 배선 회귀 (BD, 2026-08-21 — `docs/re/text-layer.md` §11.2 ②,
/// `docs/re/pointer-interaction.md` §7.2c).
///
/// `buildPointerTargets(doc:)` 는 **Metal 이 필요 없다** — 래스터 결과(`GPUText.rasterWidth`/
/// `rasterHeight`)만 읽는다. 그래서 `textLayers` 를 손으로 채워 마운트 없이 부른다.
/// (`WapleCoreTests/TextLayerHitBoxTests` 가 잠그는 것은 순수 산술이고, **조립부가 그 산술을
/// 실제로 부르는지**를 잠그는 자리가 여기다.)
final class TextPointerTargetWiringTests: XCTestCase {

    private func doc(_ scene: String) throws -> SceneDocument {
        try SceneDocument.parse(package: ScenePackage.assemble(
            [(name: "scene.json", data: Data(scene.utf8))]))
    }

    private func gpuText(_ def: SceneTextLayer, uid: Int, w: Float, h: Float) -> SceneRenderer.GPUText {
        var g = SceneRenderer.GPUText(texture: nil, vertexBuffer: nil,
                                      tint: SIMD4<Float>(1, 1, 1, 1), order: def.order,
                                      engine: nil, lastText: def.text, fontData: nil,
                                      systemFontName: "systemfont_arial", def: def, uid: uid)
        g.rasterWidth = w; g.rasterHeight = h
        return g
    }

    private func target(scene: String, raster: SIMD2<Float>) throws
        -> (SceneRenderer, SceneDocument, PointerHit.DeliveryScope) {
        let d = try doc(scene)
        let r = SceneRenderer()
        r.textLayers = d.texts.enumerated().map {
            gpuText($0.element, uid: $0.offset, w: raster.x, h: raster.y)
        }
        let engine = try XCTUnwrap(r.makeScriptEngine(
            "export function cursorClick(e) { shared.n = (shared.n || 0) + 1; }",
            layerName: d.texts[0].name.isEmpty ? nil : d.texts[0].name,
            currentLayerIndex: d.layers.count))
        r.pointerEngineOwners = [(engine, d.layers.count)]
        r.buildPointerTargets(doc: d)
        return (r, d, try XCTUnwrap(r.pointerTargets.first).scope)
    }

    /// 종전엔 이 자리가 `.geometryUnknown`(전건 배달)이었다. 이제 래스터 크기 쿼드가 나온다.
    func testTextOwnerGetsARotatedQuadFromTheRasterSize() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"id":1,"name":"t","text":"hi","font":"systemfont_arial","pointsize":32,
                     "origin":"100 200 0","scale":"1 1","padding":0,
                     "horizontalalign":"center","verticalalign":"center"}]}
        """
        let (_, _, scope) = try target(scene: scene, raster: SIMD2<Float>(100, 40))
        guard case .object(let q) = scope else { return XCTFail("텍스트가 .object 로 안 떨어졌다: \(scope)") }
        XCTAssertEqual(q.center, SIMD2<Float>(100, 200))
        XCTAssertEqual(q.axisX, SIMD2<Float>(100, 0))
        XCTAssertEqual(q.axisY, SIMD2<Float>(0, 40))
        XCTAssertTrue(PointerHit.delivers(scope, to: SIMD2<Float>(140, 210)))
        XCTAssertFalse(PointerHit.delivers(scope, to: SIMD2<Float>(160, 210)), "상자 밖은 배달 안 된다")
    }

    /// `solid`(bit13, ctor 기본 true) 가 꺼지면 히트 순회에 아예 안 들어간다 — `0x14018a02d`.
    func testNonSolidTextIsUnhittable() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"id":1,"name":"t","text":"hi","font":"systemfont_arial","pointsize":32,
                     "origin":"100 200 0","scale":"1 1","solid":false}]}
        """
        let (_, _, scope) = try target(scene: scene, raster: SIMD2<Float>(100, 40))
        XCTAssertEqual(scope, .unhittable)
    }

    /// 래스터가 없으면(빈 텍스트 = 드로우 스킵) 상자를 만들 근거가 없다 → 종전 전건 배달 유지.
    func testEmptyRasterKeepsTheLegacyBroadcast() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"id":1,"name":"t","text":"","font":"systemfont_arial","pointsize":32,
                     "origin":"100 200 0","scale":"1 1"}]}
        """
        let (_, _, scope) = try target(scene: scene, raster: SIMD2<Float>(0, 0))
        XCTAssertEqual(scope, .geometryUnknown)
    }

    /// 패딩 게이트가 켜지면 상자가 축당 `2·clamp(padding,512)` 만큼 넓어진다(`0x140258900`).
    func testOpaqueBackgroundWidensTheQuadByTwicePadding() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"id":1,"name":"t","text":"hi","font":"systemfont_arial","pointsize":32,
                     "origin":"100 200 0","scale":"1 1","padding":"8 4","opaquebackground":true}]}
        """
        let (_, _, scope) = try target(scene: scene, raster: SIMD2<Float>(100, 40))
        guard case .object(let q) = scope else { return XCTFail("기대: .object") }
        XCTAssertEqual(q.axisX, SIMD2<Float>(116, 0), "100 + 2·8")
        XCTAssertEqual(q.axisY, SIMD2<Float>(0, 48), "40 + 2·4")
    }

    /// 정렬 앵커는 그리기와 **같은** 함수를 탄다 — `textAlignmentString` → `alignedCenter`.
    func testAlignmentAnchorMatchesTheDrawPath() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[{"id":1,"name":"t","text":"hi","font":"systemfont_arial","pointsize":32,
                     "origin":"100 200 0","scale":"1 1","padding":0,
                     "horizontalalign":"right","verticalalign":"top"}]}
        """
        let (_, _, scope) = try target(scene: scene, raster: SIMD2<Float>(100, 40))
        guard case .object(let q) = scope else { return XCTFail("기대: .object") }
        let expected = SceneRenderer.layerHitQuad(origin: Vec2(x: 100, y: 200),
                                                  size: Vec2(x: 100, y: 40),
                                                  scale: Vec2(x: 1, y: 1), angleZ: 0,
                                                  alignment: SceneRenderer.textAlignmentString(
                                                      h: "right", v: "top"))
        XCTAssertEqual(q, expected)
        XCTAssertEqual(q.center, SIMD2<Float>(50, 180), "right → origin.x−hw · top → origin.y−hh")
    }
}
