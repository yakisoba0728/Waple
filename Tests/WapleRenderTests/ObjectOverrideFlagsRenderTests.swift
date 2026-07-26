import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// C⑧a: 오브젝트 레벨 nointerpolation 오버라이드가 파싱만 되고 렌더는 텍스처 헤더 플래그만 쓰던 결함.
/// 헤더가 linear(noInterpolation=false, solidTex 기본)인데 오브젝트가 nointerpolation:true 를 요구하면
/// 종전에는 무시됐다(GPULayer.noInterp == false) — OR-결합으로 오브젝트 요청이 반영돼야 한다(발산
/// 47쌍 실측 — 헤더 true·오브젝트 false 는 없어 OR 가 안전: 헤더발 nearest 는 그대로 보존, 오브젝트발
/// true 만 추가로 반영).
final class ObjectOverrideFlagsRenderTests: XCTestCase {
    func testImageLayerObjectNoInterpolationOverridesLinearHeader() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64}},
         "objects":[{"id":1,"image":"models/x.json","origin":"32 32 0","size":"8 8",
           "nointerpolation":true}]}
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/x.json", Data(#"{"material":"materials/m.json"}"#.utf8)),
            ("materials/m.json", Data(#"{"passes":[{"textures":["tex"]}]}"#.utf8)),
            ("materials/tex.tex", solidTex(255, 0, 0)),  // TEXV0005 기본 헤더 = flags 0(선형, noInterpolation=false)
        ]
        let package = ScenePackage.assemble(files)
        let doc = try SceneDocument.parse(package: package)
        // 픽스처 새너티: 파스는 이미 오브젝트 오버라이드를 캡처한다(이 항목의 결함은 렌더 소비 쪽).
        XCTAssertTrue(doc.layers[0].noInterpolation, "파스 픽스처 새너티")
        let renderer = SceneRenderer()
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)
        let layers = renderer.buildLayers(doc: doc, package: package, device: device, sceneID: "test")
        XCTAssertEqual(layers.count, 1)
        XCTAssertTrue(layers[0].noInterp,
                      "오브젝트 nointerpolation:true 가 (헤더 linear 임에도) GPULayer.noInterp 에 반영돼야")
    }

    /// 무회귀: 오브젝트가 nointerpolation 을 요청하지 않으면(기본 false) 종전대로 헤더만 따른다.
    func testImageLayerNoObjectOverrideKeepsHeaderOnly() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64}},
         "objects":[{"id":1,"image":"models/x.json","origin":"32 32 0","size":"8 8"}]}
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/x.json", Data(#"{"material":"materials/m.json"}"#.utf8)),
            ("materials/m.json", Data(#"{"passes":[{"textures":["tex"]}]}"#.utf8)),
            ("materials/tex.tex", solidTex(255, 0, 0)),
        ]
        let package = ScenePackage.assemble(files)
        let doc = try SceneDocument.parse(package: package)
        XCTAssertFalse(doc.layers[0].noInterpolation)
        let renderer = SceneRenderer()
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)
        let layers = renderer.buildLayers(doc: doc, package: package, device: device, sceneID: "test")
        XCTAssertFalse(layers[0].noInterp, "오브젝트 오버라이드 미저작 + 헤더 linear → 종전대로 linear(무회귀)")
    }
}
