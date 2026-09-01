import XCTest
@testable import WapleCore
@testable import WapleRender

/// H6: 마운트 히트 기하(`SceneRenderer.interactionGeometry`)와 프레임 승격
/// (`SceneRendererFrameEncoder.encodeLayer` 의 `pendingInteractionGeometry` 블록)이 **같은 술어**를
/// 쓰는지 잠근다.
///
/// 종전 마운트 게이트는 저작 플래그 `orthographicScene` 이었는데, 승격 경로는 2D 인코더라
/// `is3D == false` 인 프레임에서만 돈다. 그래서 `orthographic == false && is3D == false`
/// (= 3D 자원이 하나도 안 올라온 projection-0 씬 = 2D 폴백 렌더)는 마운트에서 전건
/// `.unhittable` 인데 첫 프레임에 애니 레이어만 되살아나는 비대칭이 있었다.
final class InteractionGeometryProjectionGateTests: XCTestCase {
    private func projectionZeroDoc() throws -> SceneDocument {
        // `orthogonalprojection` 키가 없다 → `doc.orthographic == false`(projection-0).
        let scene = """
        {"general":{"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/red.json","origin":"50 50 0","size":"10 10",
                     "scale":"1 1 1","angles":"0 0 0","alpha":1,"color":"1 1 1",
                     "brightness":1,"visible":true}]}
        """
        let model = #"{"width":10,"height":10,"material":"materials/red.json"}"#
        let material = #"{"passes":[{"textures":["red"]}]}"#
        return try SceneDocument.parse(package: ScenePackage.assemble([
            (name: "scene.json", data: Data(scene.utf8)),
            (name: "models/red.json", data: Data(model.utf8)),
            (name: "materials/red.json", data: Data(material.utf8)),
        ]))
    }

    /// projection-0 이어도 2D 로 그려지는 씬(`is3D == false`)은 마운트에서도 픽셀 쿼드를 받아야
    /// 한다 — 승격 경로가 이미 같은 쿼드를 만들고 있으므로.
    func testProjectionZeroNon3DSceneGetsPixelHitQuadAtMount() throws {
        let doc = try projectionZeroDoc()
        XCTAssertFalse(doc.orthographic, "orthogonalprojection 부재 = projection-0")
        XCTAssertEqual(doc.layers.count, 1)

        let renderer = SceneRenderer()
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)
        renderer.orthographicScene = doc.orthographic
        renderer.is3D = false
        let g = renderer.interactionGeometry(descriptorIndex: 0, doc: doc,
                                             texts: [], leafByOrder: [:])
        guard case .object = g.scope else {
            return XCTFail("projection-0 + 2D 렌더는 마운트에서도 히트 쿼드를 받아야 한다: \(g.scope)")
        }
    }

    /// 실제 3D 렌더 경로(`is3D == true`)만 닫아 둔다 — 월드 단위 origin/size 를 2D 픽셀 상자로
    /// 읽으면 틀리고, `encodeBillboard` 가 실제 viewProj 로 투영한 쿼드를 뒤에 승격한다.
    func testActual3DSceneStaysUnhittableUntilBillboardPromotion() throws {
        let doc = try projectionZeroDoc()
        let renderer = SceneRenderer()
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)
        renderer.orthographicScene = doc.orthographic
        renderer.is3D = true
        let g = renderer.interactionGeometry(descriptorIndex: 0, doc: doc,
                                             texts: [], leafByOrder: [:])
        guard case .unhittable = g.scope else {
            return XCTFail("3D 렌더 경로는 첫 표시 프레임 전까지 닫혀 있어야 한다: \(g.scope)")
        }
    }
}
