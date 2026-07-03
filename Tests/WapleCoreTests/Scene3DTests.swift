import XCTest
@testable import WapleCore

/// 3D 씬(카메라 eye/center/up + fov, .mdl 모델 오브젝트) 파싱 — 합성 pkg 단위 테스트.
final class Scene3DTests: XCTestCase {
    private func pkg(_ files: [(String, String)]) throws -> ScenePackage {
        try ScenePackage.parse(ScenePackageTests.makePkg(files.map { ($0.0, Data($0.1.utf8)) }))
    }

    /// orthogonalprojection == null + camera{eye,center,up} + fov 존재 → camera3D 세팅.
    func testDetects3DCameraWhenOrthographicAbsent() throws {
        let scene = """
        {"camera":{"eye":"0.1 2.2 -1.5","center":"0.2 2.0 -0.5","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.01,"farz":10000.0,"clearcolor":"0 0 0"},
         "objects":[]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        let cam = try XCTUnwrap(doc.camera3D)
        XCTAssertEqual(cam.eye, Vec3(x: 0.1, y: 2.2, z: -1.5))
        XCTAssertEqual(cam.center, Vec3(x: 0.2, y: 2.0, z: -0.5))
        XCTAssertEqual(cam.up, Vec3(x: 0, y: 1, z: 0))
        XCTAssertEqual(cam.fov, 50.0)
        XCTAssertEqual(cam.nearZ, 0.01, accuracy: 1e-6)
        XCTAssertEqual(cam.farZ, 10000.0)
    }

    /// 2D 씬(orthogonalprojection 딕셔너리)은 camera3D 가 nil — 무회귀.
    func test2DSceneHasNilCamera3D() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        XCTAssertNil(doc.camera3D)
        XCTAssertTrue(doc.objects3D.isEmpty)
    }

    /// fov 가 스크립트 프로퍼티 객체 {"script":...,"value":50} 로 오는 경우(젤다 실물) — value 언랩.
    func testScriptedFovUnwrapped() throws {
        let scene = """
        {"camera":{"eye":"10 1 0","center":"9 1 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,
                    "fov":{"script":"export function update(v){return v;}","value":50.0},
                    "nearz":0.1,"farz":10000.0,"clearcolor":"0 0 0"},
         "objects":[]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        let cam = try XCTUnwrap(doc.camera3D)
        XCTAssertEqual(cam.fov, 50.0)
    }

    /// 모델 오브젝트: .mdl 직접 참조 + 3성분 origin/angles/scale 보존.
    func testParses3DModelObject() throws {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":42,"name":"Sonic","model":"models/RioSonicLite/RioSonicLite.mdl",
            "origin":"1 2 3","angles":"0 -0.17453 0","scale":"0.02 0.02 0.02",
            "castshadow":true,"solid":true},
           {"id":43,"name":"Hidden","model":"models/x.mdl","origin":"0 0 0",
            "angles":"0 0 0","scale":"1 1 1","visible":false}
         ]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.objects3D.count, 1, "invisible 모델은 제외")
        let o = doc.objects3D[0]
        XCTAssertEqual(o.id, 42)
        XCTAssertEqual(o.name, "Sonic")
        XCTAssertEqual(o.model, "models/RioSonicLite/RioSonicLite.mdl")
        XCTAssertEqual(o.origin, Vec3(x: 1, y: 2, z: 3))
        XCTAssertEqual(o.angles, Vec3(x: 0, y: -0.17453, z: 0))
        XCTAssertEqual(o.scale, Vec3(x: 0.02, y: 0.02, z: 0.02))
        XCTAssertTrue(o.castShadow)
    }

    /// 모델 오브젝트의 parent(트랜스폼 계층) 보존.
    func testModelParentPreserved() throws {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":10,"name":"Child","model":"models/a.mdl","origin":"0 0 0",
            "angles":"0 0 0","scale":"1 1 1","parent":7}
         ]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.objects3D.count, 1)
        XCTAssertEqual(doc.objects3D[0].parent, 7)
    }

    /// 트랜스폼-온리 그룹(콘텐츠 키 없음): nodes3D 로 기록 — 비가시 그룹도 포함(서브트리 판정용).
    func testTransformOnlyNodesCaptured() throws {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":7,"name":"Root","origin":"0 10 0","angles":"0 1.5708 0","scale":"2 2 2"},
           {"id":8,"name":"HiddenGroup","parent":7,"visible":false},
           {"id":9,"name":"ScriptGroup","parent":8,
            "visible":{"value":true,"script":"export function update(v){return v;}"}},
           {"id":10,"name":"Child","model":"models/a.mdl","parent":7}
         ]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.nodes3D.count, 3)
        let root = try XCTUnwrap(doc.nodes3D.first { $0.id == 7 })
        XCTAssertEqual(root.origin, Vec3(x: 0, y: 10, z: 0))
        XCTAssertEqual(root.angles, Vec3(x: 0, y: 1.5708, z: 0))
        XCTAssertEqual(root.scale, Vec3(x: 2, y: 2, z: 2))
        XCTAssertNil(root.parent)
        XCTAssertTrue(root.visible)
        let hidden = try XCTUnwrap(doc.nodes3D.first { $0.id == 8 })
        XCTAssertFalse(hidden.visible, "정적 비가시 그룹도 기록(visible=false)")
        XCTAssertEqual(hidden.parent, 7)
        let scripted = try XCTUnwrap(doc.nodes3D.first { $0.id == 9 })
        XCTAssertTrue(scripted.visible, "스크립트 바인딩은 초기 value")
        // 모델 오브젝트는 nodes3D 가 아니라 objects3D 로.
        XCTAssertEqual(doc.objects3D.count, 1)
        XCTAssertEqual(doc.objects3D[0].parent, 7)
    }

    /// 2D 씬 무회귀: 그룹 노드 기록이 레이어/파티클 파싱에 영향 없음.
    func test2DSceneUnaffectedByNodeCapture() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"name":"group"}]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        XCTAssertTrue(doc.layers.isEmpty)
        XCTAssertEqual(doc.nodes3D.count, 1)
    }

    /// 라이트 오브젝트(lpoint/ldirectional) 최소 파싱.
    func testParses3DLights() throws {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"Torch","light":"lpoint","origin":"-4 0 -1",
            "angles":"0 0 0","color":"1 0.69 0","radius":5.0,"castshadow":true}
         ]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        XCTAssertEqual(doc.lights3D.count, 1)
        let l = doc.lights3D[0]
        XCTAssertEqual(l.type, "lpoint")
        XCTAssertEqual(l.color, Vec3(x: 1, y: 0.69, z: 0))
        XCTAssertEqual(l.radius, 5.0)
        XCTAssertTrue(l.castShadow)
    }
}

/// 실물 스모크(env-guarded): 3개 3D 씬 파스 성공 + camera3D non-nil + 모델 오브젝트 > 0.
/// 실측(2026-07-03): 3662790108=70모델/1라이트, 3706286085=9모델/2라이트, 3737268876=40모델/6라이트.
final class Scene3DRealFileTests: XCTestCase {
    private func realPkg(_ id: String) throws -> ScenePackage {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"] ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        let url = URL(fileURLWithPath: base).appendingPathComponent("\(id)/scene.pkg")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("no real pkg: \(id)") }
        return try ScenePackage.parse(data)
    }

    func testSolarSystem3662790108() throws {
        let doc = try SceneDocument.parse(package: try realPkg("3662790108"))
        let cam = try XCTUnwrap(doc.camera3D, "3D 씬은 camera3D non-nil")
        XCTAssertEqual(cam.fov, 50.0)
        XCTAssertEqual(cam.farZ, 10000.0)
        XCTAssertGreaterThan(doc.objects3D.count, 0)
        XCTAssertEqual(doc.objects3D.count, 70)
        // 모든 모델 경로는 pkg 의 실제 .mdl 엔트리로 해석된다(직접 참조 — 2D image 인다이렉션 우회).
        for o in doc.objects3D {
            XCTAssertTrue(o.model.hasSuffix(".mdl"), o.model)
        }
        XCTAssertEqual(doc.lights3D.count, 1)
    }

    func testSonic3706286085() throws {
        let doc = try SceneDocument.parse(package: try realPkg("3706286085"))
        let cam = try XCTUnwrap(doc.camera3D)
        XCTAssertEqual(cam.fov, 50.0)
        XCTAssertEqual(doc.objects3D.count, 9)
        // Sonic 모델의 .mdl 이 pkg 에 실존(직접 참조 계약 검증).
        let pkg = try realPkg("3706286085")
        for o in doc.objects3D {
            XCTAssertTrue(pkg.entries.contains { $0.name == o.model }, "누락 .mdl: \(o.model)")
        }
        XCTAssertEqual(doc.lights3D.count, 2)
    }

    func testZeldaOoT3737268876() throws {
        let doc = try SceneDocument.parse(package: try realPkg("3737268876"))
        // fov 가 스크립트 프로퍼티 — value(50) 로 언랩되어야 camera3D non-nil.
        let cam = try XCTUnwrap(doc.camera3D, "스크립트 fov 도 camera3D 세팅")
        XCTAssertEqual(cam.fov, 50.0)
        XCTAssertGreaterThan(doc.objects3D.count, 0)
        XCTAssertEqual(doc.objects3D.count, 40)
        XCTAssertEqual(doc.lights3D.count, 6)
    }
}
