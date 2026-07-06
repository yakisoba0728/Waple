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
        XCTAssertEqual(doc.objects3D.count, 1, "스크립트 없는 invisible 모델은 제외")
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

    // ── 3D v2: 프로퍼티 스크립트 바인딩 + 빌보드(레이어) originZ/parent ──────────────

    /// 3D 오브젝트/그룹의 origin/angles/scale/visible 스크립트가 propertyScripts 로 캡처(정적 value 는 언랩 유지).
    func testObjectAndNodePropertyScriptsCaptured() throws {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":5,"name":"Pivot","parent":9,
            "origin":{"value":"0 0 0","script":"export function update(v){return v;}"},
            "angles":{"value":"0 0 0","script":"export function update(v){return v;}"}},
           {"id":6,"name":"Planet","model":"models/p.mdl","parent":5,
            "scale":{"value":"0.02 0.02 0.02","script":"export function update(v){return v;}"},
            "visible":{"value":true,"script":"export function update(v){return v;}"}}
         ]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        let pivot = try XCTUnwrap(doc.nodes3D.first { $0.id == 5 })
        XCTAssertNotNil(pivot.propertyScripts["origin"])
        XCTAssertNotNil(pivot.propertyScripts["angles"])
        XCTAssertNil(pivot.propertyScripts["scale"], "스크립트 없는 키는 미포함")
        let planet = try XCTUnwrap(doc.objects3D.first { $0.id == 6 })
        XCTAssertNotNil(planet.propertyScripts["scale"])
        XCTAssertNotNil(planet.propertyScripts["visible"])
        // 정적 value 는 여전히 언랩되어 기본 트랜스폼에 반영.
        XCTAssertEqual(planet.scale, Vec3(x: 0.02, y: 0.02, z: 0.02))
    }

    /// visible=false 여도 visible 스크립트가 있으면 런타임 토글 대상이므로 3D 모델을 파싱에서 보존한다.
    func testHiddenScripted3DModelIsPreserved() throws {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":6,"name":"AltCharacter","model":"models/alt.mdl",
            "visible":{"value":false,"script":"export function update(v){ return shared.showAlt === true; }"},
            "origin":"0 0 0","angles":"0 0 0","scale":"1 1 1"}
         ]}
        """
        let doc = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        let model = try XCTUnwrap(doc.objects3D.first)
        XCTAssertEqual(model.name, "AltCharacter")
        XCTAssertNotNil(model.propertyScripts["visible"])
    }

    /// 3D 씬 이미지 레이어(빌보드): origin 의 z 성분과 parent 계층 보존.
    func test3DBillboardLayerPreservesOriginZAndParent() throws {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":20,"name":"star","image":"models/star.json","parent":9,
            "origin":"-2.5 1.5 0.3","size":"256 256","scale":"0.01 0.01 0.01",
            "color":"1 1 1","alpha":1}
         ]}
        """
        // star.json → material → texture 해석: 최소 머티리얼 동봉.
        let doc = try SceneDocument.parse(package: pkg([
            ("scene.json", scene),
            ("models/star.json", "{\"material\":\"materials/star.json\"}"),
            ("materials/star.json", "{\"passes\":[{\"textures\":[\"star\"]}]}"),
        ]))
        XCTAssertEqual(doc.layers.count, 1)
        let l = doc.layers[0]
        XCTAssertEqual(l.origin, Vec2(x: -2.5, y: 1.5))
        XCTAssertEqual(l.originZ, 0.3, accuracy: 1e-6, "origin 3성분째(월드 z) 보존")
        XCTAssertEqual(l.parent, 9, "빌보드 부모 계층 보존")
    }

    /// 3D 씬 빌보드는 파스에서 부모 트랜스폼을 **합성하지 않는다** — 렌더러(encodeBillboard)가
    /// 부모 월드행렬을 매 프레임 적용하므로, 파스-시 합성은 이중 적용이 된다(실물 3662790108:
    /// scale 0.1 그룹 체인 아래 hud/ruler 빌보드 + 라디안 각을 도(°)로 오독하는 단위 문제 포함).
    func test3DBillboardLayerKeepsLocalTransformWithExistingParent() throws {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":5,"name":"pivot","origin":"3 4 0","angles":"0 1.5708 0","scale":"0.1 0.1 0.1"},
           {"id":20,"name":"hud","image":"models/star.json","parent":5,
            "origin":"2 0 0.5","size":"256 256","scale":"1 1 1","color":"1 1 1","alpha":1}
         ]}
        """
        let doc = try SceneDocument.parse(package: pkg([
            ("scene.json", scene),
            ("models/star.json", "{\"material\":\"materials/star.json\"}"),
            ("materials/star.json", "{\"passes\":[{\"textures\":[\"star\"]}]}"),
        ]))
        XCTAssertNotNil(doc.camera3D)
        let l = try XCTUnwrap(doc.layers.first)
        XCTAssertEqual(l.parent, 5, "부모 계층은 보존(렌더러가 합성)")
        XCTAssertEqual(l.origin, Vec2(x: 2, y: 0), "3D 빌보드 origin 은 로컬 유지(파스 합성 금지)")
        XCTAssertEqual(l.scale, Vec2(x: 1, y: 1), "3D 빌보드 scale 은 로컬 유지(파스 합성 금지)")
        XCTAssertEqual(l.originZ, 0.5, accuracy: 1e-6)
    }

    /// 2D 씬 무회귀: originZ 기본 0, parent 기본 nil(2D 경로는 origin.xy 만 사용).
    func test2DLayerOriginZDefaultsZeroNoParent() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"bg","image":"models/bg.json","origin":"960 540","size":"1920 1080"}
         ]}
        """
        let doc = try SceneDocument.parse(package: pkg([
            ("scene.json", scene),
            ("models/bg.json", "{\"material\":\"materials/bg.json\"}"),
            ("materials/bg.json", "{\"passes\":[{\"textures\":[\"bg\"]}]}"),
        ]))
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.layers[0].originZ, 0)
        XCTAssertNil(doc.layers[0].parent)
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
/// 실측(2026-07-07): 3662790108=70모델/1라이트, 3706286085=9모델/2라이트, 3737268876=148모델/6라이트.
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
        XCTAssertEqual(doc.objects3D.count, 148)
        XCTAssertEqual(doc.lights3D.count, 6)
        // 카메라 fov 는 {"script":…,"value":50} → cameraScripts["fov"] 캡처(eye/center/up 은 정적).
        XCTAssertNotNil(doc.cameraScripts["fov"], "젤다 fov 스크립트 캡처")
        // animationlayers: 가시 스키닝 캐릭터는 활성 베이스 애니(Idle, blend 1.0) 를 가진다.
        // visible=false 여도 스크립트가 붙은 3D 모델은 런타임 표시 전환을 위해 보존된다.
        let animated = doc.objects3D.filter { $0.animation != nil }
        XCTAssertFalse(animated.isEmpty, "스키닝 캐릭터는 activationlayers 활성 애니 보유")
        XCTAssertTrue(animated.contains { $0.animation?.name == "Idle" }, "Idle(blend 1.0) 베이스 애니 존재")
        // rate 는 레이어별 상이(0.7~1.0) — 양수 검증.
        XCTAssertTrue(animated.allSatisfy { ($0.animation?.rate ?? 0) > 0 }, "재생 rate 양수")
    }
}
