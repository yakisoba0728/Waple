import Foundation
import XCTest
@testable import WapleCore

/// 씬 문서/포맷 파스 갭 수정(F690~F697) 회귀 테스트 — 실물 코퍼스 근거:
/// 3554161528/3596044309(TEXS frametime 0), 3351179520(라이트 parent), 1081733658(대입 조건식),
/// 3019043758/3047405322(general.zoom), 3113287126/3151551777(dependencies), 19씬(perspective).
final class CoreParseSceneFixRegressionTests: XCTestCase {
    private func d(_ s: String) -> Data { s.data(using: .utf8)! }

    // MARK: F690 — TEXS frametime==0 프레임은 유효(시트 폐기 금지)

    func testZeroFrametimeTEXSFramesAreKept() {
        // 실물 3554161528 materials/particle/3.tex 패턴(13프레임 전부 frametime 0)의 2프레임 축약.
        var texs: [UInt8] = Array("TEXS0003".utf8) + [0]
        texs += i32(2) + i32(4) + i32(4)  // count, gifWidth, gifHeight
        for i in 0..<2 {
            texs += i32(i) + f32(0) + f32(0) + f32(0) + f32(4) + f32(0) + f32(0) + f32(4)
        }
        let t = TexImage.parse(TexImageTests.makeTex(format: 0, w: 8, h: 4, payload: [0, 0, 0, 0] + texs))
        XCTAssertEqual(t?.frames.count, 2, "frametime==0 프레임이 시트 전체 폐기(return [])로 이어지면 안 됨")
        XCTAssertEqual(t?.frames.map { $0.time }, [0, 0])
        // 소비처 안전: 0 프레임 시트도 프레임 인덱스 산출이 범위 내(1e-4 클램프 경로 — 부동소수
        // 경계값은 프레임마다 달라질 수 있어 구체 인덱스가 아니라 범위만 단정).
        if let frames = t?.frames {
            let idx = TexImage.spriteFrameIndex(frames: frames, time: 1.0)
            XCTAssertTrue(idx >= 0 && idx < frames.count)
        }
    }

    // MARK: F691 — 2D 포워드 라이트 parent 체인 합성

    func testLightParentTransformComposed2D() throws {
        // 실물 3351179520: lpoint(-44.48,299.59,735) + 부모 노드(2560,720) → 월드 ≈(2515.5,1019.6,735).
        let scene = """
        {"general":{"orthogonalprojection":{"width":5120,"height":1440}},
         "objects":[
           {"id":657,"name":"bg","origin":"2560 720 0"},
           {"id":2496,"light":"lpoint","origin":"-44.48486 299.58801 735.00000","parent":657,"radius":1477.52,"intensity":25}
         ]}
        """
        let pkg = ScenePackage.assemble([("scene.json", d(scene))])
        let doc = try SceneDocument.parse(package: pkg)
        let light = try XCTUnwrap(doc.lights3D.first)
        XCTAssertEqual(light.origin.x, 2515.52, accuracy: 0.01)
        XCTAssertEqual(light.origin.y, 1019.59, accuracy: 0.01)
        XCTAssertEqual(light.origin.z, 735, accuracy: 0.001)
        // 합성값이 포워드 유니폼 팩에도 그대로 도달해야 한다.
        let u = SceneLight3D.forwardUniforms(doc.lights3D, ambient: Vec3(x: 0, y: 0, z: 0), skylight: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(u.positions[0].x, 2515.52, accuracy: 0.01)
        XCTAssertEqual(u.positions[0].y, 1019.59, accuracy: 0.01)
    }

    func testLightParentTransformComposedWithParentScale() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[
           {"id":1,"name":"g","origin":"100 50 0","scale":"2 3 1"},
           {"id":2,"light":"lpoint","origin":"10 10 7","parent":1,"radius":10,"intensity":1}
         ]}
        """
        let pkg = ScenePackage.assemble([("scene.json", d(scene))])
        let doc = try SceneDocument.parse(package: pkg)
        let light = try XCTUnwrap(doc.lights3D.first)
        XCTAssertEqual(light.origin.x, 120, accuracy: 0.001)  // 100 + 2*10
        XCTAssertEqual(light.origin.y, 80, accuracy: 0.001)   // 50 + 3*10
        XCTAssertEqual(light.origin.z, 7, accuracy: 0.001)    // z 는 부모 z(0) 누산만
    }

    func testLightParentNotComposedIn3DScene() throws {
        // 3D 씬은 렌더러(resolveLights)가 월드행렬 합성 — 파스는 로컬 유지(이중 합성 방지).
        let scene = """
        {"general":{"fov":50},
         "camera":{"eye":"0 0 10","center":"0 0 0","up":"0 1 0"},
         "objects":[
           {"id":1,"name":"g","origin":"100 50 0"},
           {"id":2,"light":"lpoint","origin":"10 10 7","parent":1,"radius":10,"intensity":1}
         ]}
        """
        let pkg = ScenePackage.assemble([("scene.json", d(scene))])
        let doc = try SceneDocument.parse(package: pkg)
        XCTAssertNotNil(doc.camera3D)
        let light = try XCTUnwrap(doc.lights3D.first)
        XCTAssertEqual(light.origin, Vec3(x: 10, y: 10, z: 7))
    }

    // MARK: F692 — perspective:true + general.perspectiveoverridefov 파스·보존

    func testParsesLayerPerspectiveAndOverrideFov() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"perspectiveoverridefov":95},
         "objects":[{"id":1,"name":"p","image":"models/x.json","perspective":true}]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("models/x.json", d(#"{"material":"materials/x.json"}"#)),
            ("materials/x.json", d(#"{"passes":[{"textures":["x"]}]}"#)),
            ("materials/x.tex", d("not-a-real-tex")),
        ])
        let doc = try SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.perspectiveOverrideFov, 95)
        XCTAssertEqual(try XCTUnwrap(doc.layers.first).perspective, true)
    }

    func testPerspectiveDefaultsAreNeutral() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"name":"p","image":"models/x.json"}]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("models/x.json", d(#"{"material":"materials/x.json"}"#)),
            ("materials/x.json", d(#"{"passes":[{"textures":["x"]}]}"#)),
            ("materials/x.tex", d("not-a-real-tex")),
        ])
        let doc = try SceneDocument.parse(package: pkg)
        XCTAssertNil(doc.perspectiveOverrideFov)
        XCTAssertEqual(try XCTUnwrap(doc.layers.first).perspective, false)
    }

    // MARK: F693 — 텍스트 오브젝트 effects[] 파스·보존

    func testParsesTextObjectEffects() throws {
        // 실물 3151551777 패턴: 텍스트에 blurprecise 2패스 이펙트.
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"name":"t","text":"hello","effects":[
           {"file":"effects/blurprecise/effect.json","visible":true,"passes":[
             {"constantshadervalues":{"scale":"0.7 0.7"}},
             {"combos":{"ENABLEMASK":1,"VERTICAL":1},"constantshadervalues":{"scale":"0.7 0.7"}}
           ]}
         ]}]}
        """
        let pkg = ScenePackage.assemble([("scene.json", d(scene))])
        let doc = try SceneDocument.parse(package: pkg)
        let text = try XCTUnwrap(doc.texts.first)
        XCTAssertEqual(text.effects.count, 1)
        let eff = try XCTUnwrap(text.effects.first)
        XCTAssertEqual(eff.name, "blurprecise")
        XCTAssertEqual(eff.passList.count, 2)
        XCTAssertEqual(eff.passList[1].combos["VERTICAL"], 1)
    }

    // MARK: F694 — 대입식 삼항 조건은 WE(JS)와 같이 truthy 관용

    func testAssignmentTernaryConditionIsTruthyRegardlessOfGuard() {
        // 실물 1081733658: `clock_enable.value ? clock_enable.text = … : clock_enable.text = …`
        // — WE(JS)는 대입 결과(비어있지 않은 문자열)가 항상 truthy → 토글 항상 표시.
        let values: [String: PropertyValue] = ["clock_enable": .bool(false)]
        XCTAssertEqual(
            PropertyConditionEvaluator.evaluate(
                "clock_enable.value ? clock_enable.text = clock_enable.text.replace('Disabled','Enabled') : clock_enable.text = clock_enable.text.replace('Enabled','Disabled')",
                values: values),
            true, "guard false 여도 대입 갈래 삼항은 WE 와 같이 truthy 여야 한다(토글 영구 은닉 방지)")
    }

    func testAssignmentTernaryWithLiteralFalseBranchKeepsGuardValue() {
        // 실물 1081733658 background_effect: `: false` 말단은 guard 가 곧 결과(WE 동치) — 회귀 방지.
        let values: [String: PropertyValue] = ["background_enable": .bool(false), "background_type": .number(2)]
        XCTAssertEqual(
            PropertyConditionEvaluator.evaluate(
                "background_enable.value && !(background_type.value == 1) ? background_effect.text = 'x' : false",
                values: values),
            false)
        // 근사 사용 시 canEvaluate 는 계속 false(F423 analyzer 경로 유지).
        XCTAssertFalse(PropertyConditionEvaluator.canEvaluate(
            "clock_enable.value ? clock_enable.text = 'a' : clock_enable.text = 'b'"))
    }

    func testAssignmentTernaryKeepsToggleVisible() {
        let props = [
            WallpaperProperty(key: "clock_enable", type: "bool", value: .bool(false), order: 0,
                              condition: "clock_enable.value ? clock_enable.text = 'a' : clock_enable.text = 'b'"),
        ]
        XCTAssertEqual(PropertyConditionEvaluator.visibleIndices(in: props), [0])
    }

    // MARK: F695 — general.zoom 파스

    func testParsesGeneralZoom() throws {
        let variants: [(String, Float)] = [
            (#""zoom":1.05"#, 1.05),                                    // 평문(3047405322)
            (#""zoom":{"user":"camerazoon","value":1.03}"#, 1.03),      // {user,value} 바인딩(3019043758)
        ]
        for (zoomJson, expected) in variants {
            let scene = "{\"general\":{\"orthogonalprojection\":{\"width\":100,\"height\":100},\(zoomJson)},\"objects\":[]}"
            let pkg = ScenePackage.assemble([("scene.json", d(scene))])
            let doc = try SceneDocument.parse(package: pkg)
            XCTAssertEqual(doc.zoom, expected, accuracy: 0.0001, zoomJson)
        }
        let plain = ScenePackage.assemble([("scene.json", d(#"{"general":{"orthogonalprojection":{"width":100,"height":100}},"objects":[]}"#))])
        XCTAssertEqual(try SceneDocument.parse(package: plain).zoom, 1)  // 부재 시 1(무회귀)
    }

    // MARK: F696 — dependencies 파스·보존(image + model)

    func testParsesDependenciesOnLayerAndModel() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[
           {"id":109,"name":"img","image":"models/x.json","dependencies":[30]},
           {"id":5,"name":"m","model":"models/y.mdl","dependencies":[109,"30"]}
         ]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("models/x.json", d(#"{"material":"materials/x.json"}"#)),
            ("materials/x.json", d(#"{"passes":[{"textures":["x"]}]}"#)),
            ("materials/x.tex", d("not-a-real-tex")),
        ])
        let doc = try SceneDocument.parse(package: pkg)
        XCTAssertEqual(try XCTUnwrap(doc.layers.first).dependencies, [30])
        XCTAssertEqual(try XCTUnwrap(doc.objects3D.first).dependencies, [109, 30])  // 문자열 id 관용 포함
    }

    // MARK: F697 — 이펙트 패스 usertextures 파스·보존

    func testParsesEffectPassUserTextures() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"name":"img","image":"models/x.json","effects":[
           {"file":"effects/tint/effect.json","visible":true,"passes":[
             {"textures":["a"],"usertextures":[null,"usertexture1",{"name":"$mediaThumbnail","type":"system"}]}
           ]}
         ]}]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("models/x.json", d(#"{"material":"materials/x.json"}"#)),
            ("materials/x.json", d(#"{"passes":[{"textures":["x"]}]}"#)),
            ("materials/x.tex", d("not-a-real-tex")),
        ])
        let doc = try SceneDocument.parse(package: pkg)
        let eff = try XCTUnwrap(doc.layers.first?.effects.first)
        let pass = try XCTUnwrap(eff.passList.first)
        XCTAssertEqual(pass.userTextureNames.count, 3)
        XCTAssertNil(pass.userTextureNames[0])
        XCTAssertEqual(pass.userTextureNames[1], "usertexture1")
        XCTAssertEqual(pass.userTextureNames[2], "$mediaThumbnail")  // {name,type} 는 name 정규화
    }

    // MARK: E1 — 2D text·particle parent 체인 합성 + 각도 라디안 정정 + disablepropagation 스킵

    /// 텍스트 오브젝트는 종전 SceneTextLayer 에 parent 필드 자체가 없어 부모 붙은 텍스트가 저작
    /// 로컬 좌표(대개 화면 밖) 그대로 렌더됐다. 레이어/라이트와 동일 규약으로 합성돼야 한다.
    func testTextParentTransformComposed2D() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[
           {"id":1,"name":"g","origin":"500 300 0","scale":"2 2 1"},
           {"id":2,"name":"clock","text":"00:00","parent":1,"origin":"10 10 0"}
         ]}
        """
        let pkg = ScenePackage.assemble([("scene.json", d(scene))])
        let doc = try SceneDocument.parse(package: pkg)
        let text = try XCTUnwrap(doc.texts.first)
        XCTAssertEqual(text.origin.x, 520, accuracy: 0.001)  // 500 + 2*10
        XCTAssertEqual(text.origin.y, 320, accuracy: 0.001)  // 300 + 2*10
        XCTAssertEqual(text.scale.x, 2, accuracy: 0.001)     // 부모 scale(2) × 자신 scale(기본 1)
    }

    /// 파티클 오브젝트도 2D 정사영 경로(origin/scale Vec2)에서 부모 체인이 전혀 합성되지 않아
    /// 부모에 붙은 파티클 시스템이 로컬 좌표(대개 화면 좌상단 근처)에 그려졌다.
    func testParticleParentTransformComposed2D() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080}},
         "objects":[
           {"id":1,"name":"g","origin":"400 200 0"},
           {"id":2,"name":"snow","particle":"particles/snow.json","parent":1,"origin":"5 5 0"}
         ]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("particles/snow.json", d(#"{"renderer":[{"name":"sprite"}],"maxcount":1}"#)),
        ])
        let doc = try SceneDocument.parse(package: pkg)
        let p = try XCTUnwrap(doc.particles.first)
        XCTAssertEqual(p.origin.x, 405, accuracy: 0.001)  // 400 + 5
        XCTAssertEqual(p.origin.y, 205, accuracy: 0.001)  // 200 + 5
    }

    /// A1(852473d) 라디안 정정은 렌더 인코더(SceneRendererFrameEncoder.swift:405)만 고쳤고 이 파스-시
    /// 합성부(composeParentTransforms)는 미동기라 부모 회전이 `*.pi/180` 으로 재차 축소됐다. scene.json
    /// angles 는 이미 라디안이므로, 부모 angleZ=π/2(90°)면 자식 오프셋이 정확히 90° 회전해야 한다
    /// (종전 버그는 π/2 를 "도(°)"로 오인해 사실상 무회전에 가깝게 축소했다).
    func testLayerParentRotationUsesRadiansNotDegrees() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1000,"height":1000}},
         "objects":[
           {"id":1,"name":"g","origin":"500 500 0","angles":"0 0 1.5707963"},
           {"id":2,"name":"child","image":"models/x.json","parent":1,"origin":"10 0 0"}
         ]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("models/x.json", d(#"{"material":"materials/x.json"}"#)),
            ("materials/x.json", d(#"{"passes":[{"textures":["x"]}]}"#)),
            ("materials/x.tex", d("not-a-real-tex")),
        ])
        let doc = try SceneDocument.parse(package: pkg)
        let layer = try XCTUnwrap(doc.layers.first { $0.name == "child" })
        // 로컬 (10,0) 을 부모 각 π/2 로 회전 → (0,10) 만큼의 오프셋(부모 원점 500,500 기준).
        XCTAssertEqual(layer.origin.x, 500, accuracy: 0.01)
        XCTAssertEqual(layer.origin.y, 510, accuracy: 0.01)
    }

    /// disablepropagation:true 인 레이어는 부모 트랜스폼 상속을 차단 — 저작 로컬 좌표를 그대로 유지해야
    /// 한다(코퍼스 실측 34건, 전부 parent 보유). 종전엔 플래그를 검사하지 않고 무조건 합성했다.
    func testDisablePropagationSkipsParentTransformComposition() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1000,"height":1000}},
         "objects":[
           {"id":1,"name":"g","origin":"500 500 0","scale":"2 2 1"},
           {"id":2,"name":"child","image":"models/x.json","parent":1,"origin":"10 10 0",
            "disablepropagation":true}
         ]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("models/x.json", d(#"{"material":"materials/x.json"}"#)),
            ("materials/x.json", d(#"{"passes":[{"textures":["x"]}]}"#)),
            ("materials/x.tex", d("not-a-real-tex")),
        ])
        let doc = try SceneDocument.parse(package: pkg)
        let layer = try XCTUnwrap(doc.layers.first { $0.name == "child" })
        XCTAssertEqual(layer.origin, Vec2(x: 10, y: 10))  // 부모 미합성 — 저작 로컬 그대로
        XCTAssertEqual(layer.scale, Vec2(x: 1, y: 1))
    }

    /// X-③: 이펙트 패스 usertextures 의 비-시스템(유저) 키는 파스 시점에 userProps 값으로 해석돼
    /// textureNames 슬롯을 덮어써야 한다(레이어 material usertextures 와 동일 규약) — 종전엔
    /// userTextureNames 에 원문 키만 남고 소비처가 0건이라 이펙트 슬롯이 상시 미바인드였다.
    /// `$` 로 시작하는 시스템 키($mediaThumbnail)는 여기서 해석하지 않고(동적, 렌더 시점 결속) 그대로 보존.
    func testEffectPassUserTextureNonSystemKeyResolvesFromUserProps() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"name":"img","image":"models/x.json","effects":[
           {"file":"effects/tint/effect.json","visible":true,"passes":[
             {"usertextures":[null,"customimage",{"name":"$mediaThumbnail","type":"system"}]}
           ]}
         ]}]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("models/x.json", d(#"{"material":"materials/x.json"}"#)),
            ("materials/x.json", d(#"{"passes":[{"textures":["x"]}]}"#)),
            ("materials/x.tex", d("not-a-real-tex")),
        ])
        let doc = try SceneDocument.parse(package: pkg, userProps: ["customimage": "materials/custom.tex"])
        let eff = try XCTUnwrap(doc.layers.first?.effects.first)
        let pass = try XCTUnwrap(eff.passList.first)
        XCTAssertEqual(pass.textureNames.count, 2, "usertextures[1] 오버라이드로 textureNames 가 슬롯1까지 확장돼야 함")
        XCTAssertEqual(pass.textureNames[1], "materials/custom.tex", "비-시스템 유저 키는 userProps 값으로 즉시 해석")
        XCTAssertEqual(pass.userTextureNames[2], "$mediaThumbnail", "시스템 키는 원문 보존(동적 렌더-시점 결속용)")
    }

    // MARK: X-⑦ — 이펙트 패스 constantshadervalues {animation} 키프레임 파스

    /// X-⑦: constantshadervalues 의 {"animation":{...}} 키프레임 바인딩(55씬/287건)이 파스 단계에서
    /// 통째로 소실되지 않고 SceneEffectPass.constantAnimations 에 보존돼야 한다. 정적 value 도 병존
    /// 캡처(애니 없을 때 기본값/기준값).
    func testParsesEffectPassConstantAnimation() throws {
        let scene = """
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}}, "objects": [{"id": 1, "name": "img", "image": "models/x.json", "effects": [{"file": "effects/pulse/effect.json", "visible": true, "passes": [{"constantshadervalues": {"multiply": {"value": 0.5, "animation": {"c0": [{"frame": 0, "value": 0.0, "front": {"enabled": false, "x": 0, "y": 0}, "back": {"enabled": false, "x": 0, "y": 0}}, {"frame": 30, "value": 1.0, "front": {"enabled": false, "x": 0, "y": 0}, "back": {"enabled": false, "x": 0, "y": 0}}], "options": {"fps": 30, "mode": "single"}}}}}]}]}]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("models/x.json", d(#"{"material":"materials/x.json"}"#)),
            ("materials/x.json", d(#"{"passes":[{"textures":["x"]}]}"#)),
            ("materials/x.tex", d("not-a-real-tex")),
        ])
        let doc = try SceneDocument.parse(package: pkg)
        let eff = try XCTUnwrap(doc.layers.first?.effects.first)
        let pass = try XCTUnwrap(eff.passList.first)
        let anim = try XCTUnwrap(pass.constantAnimations["multiply"], "animation 바인딩이 파스 단계에서 소실됨")
        XCTAssertEqual(anim.value(component: 0, atTime: 0, base: 0), 0, accuracy: 1e-4)
        XCTAssertEqual(anim.value(component: 0, atTime: 1, base: 0), 1, accuracy: 1e-4, "1초=30프레임(fps 30) 시점 = 마지막 키프레임값")
        XCTAssertEqual(pass.constants["multiply"], [0.5], "정적 value 도 병존 캡처(기본값)")
    }
}
