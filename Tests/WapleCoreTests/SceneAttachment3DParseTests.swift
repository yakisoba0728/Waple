import XCTest
@testable import WapleCore

/// M(⑤): 오브젝트 `attachment`(이름 본-슬롯 부착) 를 SceneNode3D(그룹)/SceneObject3D(모델)/SceneParticle
/// 에도 SceneLayer 와 동형으로 파스한다 — 종전엔 SceneLayer 한 곳만 필드가 있어 실물 젤다류 퍼펫 씬
/// (마스크/머리 액세서리 그룹, 3737268876 등)의 attachment 가 파스 시점에 소실됐다.
/// **범위**: 파스만. 3D 렌더 소비(본 추종 배선)는 별건(wf8 id 66) — 5씬 재현 그룹은 camera3D 부재(2D
/// 퍼펫 씬)라 SceneRenderer3D 를 타지 않고, 소비는 2D PuppetAttach 경로의 몫이다.
final class SceneAttachment3DParseTests: XCTestCase {

    /// 콘텐츠 키 없는 그룹(마스크류) — attachment 가 SceneNode3D 까지 보존돼야 한다.
    func testGroupNodeParsesAttachment() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1170,"name":"Masks","attachment":"Head","origin":"0 0 0","angles":"0 0 0","scale":"1 1 1"}
         ]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        let node = try XCTUnwrap(doc.nodes3D.first { $0.id == 1170 })
        XCTAssertEqual(node.attachment, "Head")
    }

    /// attachment 없는 그룹은 종전대로 nil(무회귀).
    func testGroupNodeWithoutAttachmentStaysNil() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"id":5,"name":"Plain","origin":"0 0 0","angles":"0 0 0","scale":"1 1 1"}]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        let node = try XCTUnwrap(doc.nodes3D.first { $0.id == 5 })
        XCTAssertNil(node.attachment)
    }

    /// 3D 모델 오브젝트(.mdl 직접 참조) — attachment 가 SceneObject3D 까지 보존돼야 한다.
    func testModelObjectParsesAttachment() throws {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":7,"name":"fairy","model":"models/fairy.mdl","attachment":"Center",
            "origin":"0 0 0","angles":"0 0 0","scale":"1 1 1"}
         ]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        let obj = try XCTUnwrap(doc.objects3D.first { $0.id == 7 })
        XCTAssertEqual(obj.attachment, "Center")
    }

    /// 파티클 오브젝트도 attachment 를 보존해야 한다(SceneParticle).
    func testParticleObjectParsesAttachment() throws {
        let particleDef = #"{"maxcount":1,"emitters":[],"initializers":[],"operators":[]}"#
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":9,"name":"sparkles","particle":"particles/sparkles.json","attachment":"Center",
            "origin":"0 0 0"}
         ]}
        """
        let doc = try SceneDocument.parse(package: pkg([
            ("scene.json", scene),
            ("particles/sparkles.json", particleDef),
        ]))
        let p = try XCTUnwrap(doc.particles.first)
        XCTAssertEqual(p.attachment, "Center")
    }
}
