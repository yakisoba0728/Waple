import XCTest
@testable import WapleCore

/// D1: combo 프로퍼티로 전환되는 오브젝트 가시성은 nested `{"user":{"condition":"<옵션값>","name":"<키>"}}`
/// 문법으로 인코딩된다(bare-string bool 바인딩과 별개). resolveUserBindings 가 nested 를 스킵하면
/// 저작 시점 default variant 가 영구 고착 — 유저가 콤보를 바꿔도 화면이 안 바뀐다.
final class SceneComboVisibleTests: XCTestCase {
    private let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
    private let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#
    private let particleDef = #"{"renderer":[{"name":"sprite"}],"maxcount":1,"material":"materials/pm.json"}"#
    private let particleMaterial = #"{"passes":[{"textures":["particle/snow"]}]}"#

    /// 실물 3299228616 축소판(파티클 경유 체인): `543 Moving Stars_02 → 540 Blinking Stars_01(파티클,
    /// visible true) → 239 LonelyCAT VIE(콤보 조건 false)`. 종전에는 parentOf 를 nodes3D + layers +
    /// texts 로만 채워 **파티클 id 가 아예 없었고**, 그래서 부모가 가시 파티클인 자식은 조상 탐색이
    /// parentOf[부모] 부재로 즉시 끝나 조건이 꺼져 있어도 계속 그려졌다(비가시 파티클은 invNode 로
    /// nodes3D 에 들어가 우연히 동작 — 갭이 "가시 파티클 경유"에만 숨어 있었다).
    func testHiddenAncestorPropagatesThroughVisibleParticleParent() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":239,"name":"LonelyCAT VIE","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "visible":{"user":{"condition":"2","name":"language"},"value":false}},
           {"id":540,"name":"Blinking Stars_01","particle":"particles/p.json","parent":239,
            "visible":{"user":"starreactive1","value":true}},
           {"id":543,"name":"Moving Stars_02","particle":"particles/p.json","parent":540}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material),
                         ("particles/p.json", particleDef), ("materials/pm.json", particleMaterial)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let mid = try XCTUnwrap(doc.particles.first { $0.id == 540 }, "중간 파티클은 배열에 남아야(드롭 금지)")
        let leaf = try XCTUnwrap(doc.particles.first { $0.id == 543 })
        XCTAssertFalse(mid.visible, "부모(239)가 콤보로 꺼져 있으므로 중간 파티클도 숨어야")
        XCTAssertFalse(leaf.visible, "파티클(540)을 **거쳐** 비가시 조상(239)에 닿으므로 잎도 숨어야")
    }

    /// 대조군: 같은 체인에서 조상만 켜지면 파티클 두 개가 모두 보여야 한다(무회귀 — 새 parentOf 항목이
    /// 가시 체인을 잘못 끄지 않음을 고정).
    func testVisibleAncestorKeepsParticleChainVisible() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":239,"name":"LonelyCAT VIE","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "visible":{"user":{"condition":"2","name":"language"},"value":true}},
           {"id":540,"name":"Blinking Stars_01","particle":"particles/p.json","parent":239},
           {"id":543,"name":"Moving Stars_02","particle":"particles/p.json","parent":540}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material),
                         ("particles/p.json", particleDef), ("materials/pm.json", particleMaterial)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        XCTAssertTrue(try XCTUnwrap(doc.particles.first { $0.id == 540 }).visible)
        XCTAssertTrue(try XCTUnwrap(doc.particles.first { $0.id == 543 }).visible)
    }

    /// W3-①(C8): 실물 3299228616 축소판 — 부모 그룹('Clock Layer 2')이 clocklocation 콤보로 꺼진 채,
    /// 자식('number.am.pm')은 **다른** 콤보(clock24hformat)에 바인딩돼 자기 자신은 true 로 풀린다.
    /// 종전엔 파스가 부모 체인을 전혀 안 봐서 자식이 계속 그려졌다 — 부모가 꺼지면 자식도 숨어야 한다.
    func testInvisibleComboGroupHidesChildWithUnrelatedVisibleCondition() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"clockLayer2","visible":{"user":{"condition":"2","name":"clocklocation"},"value":false}},
           {"id":2,"name":"ampm","image":"models/x.json","parent":1,"origin":"50 50 0","size":"10 10",
            "visible":{"user":"clock24hformat","value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let child = try XCTUnwrap(doc.layers.first { $0.name == "ampm" }, "드롭 금지 — JS 인덱스 정합상 배열엔 남아야 함")
        XCTAssertFalse(child.initialVisible, "비가시 부모 상속으로 initialVisible=false 여야 함")
    }

    /// 대조군: 부모가 켜져 있으면(콤보 선택값 일치) 동일 구조의 자식이 그대로 보여야 한다(무회귀).
    func testVisibleComboGroupKeepsChildVisible() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"clockLayer1","visible":{"user":{"condition":"1","name":"clocklocation"},"value":true}},
           {"id":2,"name":"ampm","image":"models/x.json","parent":1,"origin":"50 50 0","size":"10 10",
            "visible":{"user":"clock24hformat","value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let child = try XCTUnwrap(doc.layers.first { $0.name == "ampm" })
        XCTAssertTrue(child.initialVisible, "가시 부모의 자식은 그대로 보여야 함(무회귀)")
    }

    /// imageLayerCompositeIDs 카브아웃 — composelayer 오프스크린 합성 소스로 참조되는 레이어(다른
    /// json 이 `_rt_imageLayerComposite_<id>` 텍스처명으로 참조, referencedImageLayerCompositeIDs)는
    /// 부모가 꺼져 있어도 숨기면 안 된다(:845 카브아웃과 동형 — 자체 화면 표시가 아니라 합성 재료용).
    func testCompositeSourceLayerNotHiddenByInvisibleParent() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"offGroup","visible":{"user":{"condition":"2","name":"clocklocation"},"value":false}},
           {"id":2,"name":"compositeSrc","image":"models/x.json","parent":1,"origin":"50 50 0","size":"10 10",
            "visible":true}]}
        """
        // 다른 이펙트 패스가 이 레이어(id=2)를 _rt_imageLayerComposite_2 텍스처명으로 참조 — 실물
        // composelayer 배선과 동일한 매직 스트링 규약(referencedImageLayerCompositeIDs 정규식).
        let composeRef = #"{"passes":[{"textures":["_rt_imageLayerComposite_2"]}]}"#
        let p = try pkg([
            ("scene.json", scene), ("models/x.json", model), ("materials/m.json", material),
            ("effects/composelayer/effect.json", composeRef),
        ])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let child = try XCTUnwrap(doc.layers.first { $0.name == "compositeSrc" })
        XCTAssertTrue(child.initialVisible, "composelayer 소스는 부모 비가시에도 숨지 않아야")
    }

    /// 유저가 combo `style`="1" 을 고르면 condition="1" variant 는 보이고 "2" variant 는 숨는다.
    /// 저작 스냅샷은 반대(A=false, B=true)라, nested 미해석이면 A 드롭·B 유지로 red.
    func testComboVisibleNestedSelectsChosenVariant() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"variantA","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "visible":{"user":{"condition":"1","name":"style"},"value":false}},
           {"id":2,"name":"variantB","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "visible":{"user":{"condition":"2","name":"style"},"value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: ["style": "1"])
        XCTAssertTrue(doc.layers.contains { $0.name == "variantA" }, "선택한 콤보값(1) variant 표시")
        XCTAssertFalse(doc.layers.contains { $0.name == "variantB" }, "비선택 콤보값(2) variant 숨김")
    }

    /// 회귀: bare-string user 바인딩(bool)은 기존대로 override 로 갱신된다(if 분기 불변).
    /// toggle=false 오버라이드 → 스크립트 없는 정적 false → 레이어 드롭.
    func testBareStringUserBindingStillResolves() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"toggled","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "visible":{"user":"toggle","value":true}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        XCTAssertEqual(try SceneDocument.parse(package: p, userProps: ["toggle": false]).layers.count, 0)
    }

    /// 효과 visible=false(정적 bool + 사용자 토글 OFF)는 미적용(WE 규약). 종전엔 무시 → 꺼진
    /// post-process(3489263099 halftone=bwhalftone OFF)가 적용돼 전화면 흑화. {user,value} 는
    /// resolveUserBindings 가 정적 value 로 해석하므로 파스 시점 필터가 정답.
    func testDisabledEffectsAreDroppedAtParse() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"L","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "effects":[
              {"file":"effects/on1/effect.json"},
              {"file":"effects/off1/effect.json","visible":false},
              {"file":"effects/on2/effect.json","visible":true},
              {"file":"effects/off2/effect.json","visible":{"user":"bwhalftone","value":false}}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let layer = try XCTUnwrap(doc.layers.first { $0.name == "L" })
        XCTAssertEqual(layer.effects.count, 2, "visible=false 효과 2개(off1 정적·off2 유저OFF) 제외")
        XCTAssertTrue(layer.effects.contains { $0.file.contains("on1") }, "visible 부재=활성")
        XCTAssertTrue(layer.effects.contains { $0.file.contains("on2") }, "visible=true 유지")
        XCTAssertFalse(layer.effects.contains { $0.file.contains("off") }, "꺼진 효과는 미적용")
    }

    /// color 프로퍼티 스크립트의 저장 `scriptproperties`(사용자 오버라이드)를 파스가 보존하는지 —
    /// 미보존 시 스크립트가 소스 기본값(흰색 fallback)을 반환해 전화면 백화(3300031038). {user,value}
    /// 바인딩은 정적 value 로 해석(스크립트는 정적 값을 기대 — resolveUserBindings 규약).
    func testColorScriptPropertiesPreservedAtParse() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"L","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "color":{"script":"export function update(v){return v;}","value":"0.3 0.2 0.4",
                     "scriptproperties":{"fallbackColor":"0.3 0.2 0.4","useFallbackColor":false,
                                         "enabled":{"user":"musicplayer","value":true}}}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let layer = try XCTUnwrap(doc.layers.first { $0.name == "L" })
        let json = try XCTUnwrap(layer.propertyScriptProps["color"], "color scriptproperties 보존")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["fallbackColor"] as? String, "0.3 0.2 0.4")
        XCTAssertEqual(obj["useFallbackColor"] as? Bool, false)
        XCTAssertEqual(obj["enabled"] as? Bool, true, "{user,value} 바인딩 → 정적 value 로 해석")
    }

    /// 텍스트 스크립트의 저장 `scriptproperties`(사용자 오버라이드)를 parseText 가 보존하는지 —
    /// 미보존 시 시계 스크립트가 소스 기본값(24h·초숨김)으로 폴백(코퍼스 117씬 패턴). 평문 텍스트는 nil(무회귀).
    func testTextScriptPropertiesPreservedAtParse() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"Clock","font":"systemfont_arial","origin":"50 50 0","pointsize":16,
            "text":{"script":"export function update(v){return v;}","value":"12:00",
                    "scriptproperties":{"showSeconds":true,"delimiter":"-","use24hFormat":{"user":"h","value":false}}}},
           {"id":2,"name":"Plain","font":"systemfont_arial","origin":"10 10 0","text":"static"}]}
        """
        let p = try pkg([("scene.json", scene)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let clock = try XCTUnwrap(doc.texts.first { $0.name == "Clock" })
        let json = try XCTUnwrap(clock.scriptProps, "text scriptproperties 보존")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["showSeconds"] as? Bool, true)
        XCTAssertEqual(obj["delimiter"] as? String, "-")
        XCTAssertEqual(obj["use24hFormat"] as? Bool, false, "{user,value} 바인딩 → 정적 value 로 해석")
        // 무회귀: 스크립트 없는 평문 텍스트는 오버라이드 없음(nil → 소스 무주입).
        let plain = try XCTUnwrap(doc.texts.first { $0.name == "Plain" })
        XCTAssertNil(plain.scriptProps, "평문 텍스트는 scriptProps nil")
    }

    /// 효과 상수 스크립트(constantshadervalues 바인딩)의 저장 `scriptproperties`를 parseEffects 가 보존하는지.
    /// 벡터 value("r g b" 컬러 — float 단일파스 실패로 dict 브랜치 도달, 실물 3388330010 color 패턴)에서
    /// 스크립트가 캡처되므로 그 자리에 scriptProps 보존. 스크립트 없는 정적 상수는 미포함(무회귀).
    /// (F390 정정: 위 주의는 fcd85fc 도입 당시엔 사실이었으나 같은 날 6a5b75b(스칼라 효과 상수
    /// {value,script} 스크립트 미캡처 수정 — parseEffects 의 float(v) 언랩 short-circuit 을 스크립트
    /// 캡처보다 뒤로 호이스트)로 해소됨. 지금은 스칼라도 정상 캡처된다 — 반증은
    /// SceneDocumentTests.testScalarConstantScriptCaptured/testScalarConstantScriptPropertiesInjected.)
    func testEffectConstantScriptPropertiesPreservedAtParse() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"L","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "effects":[{"file":"effects/fx/effect.json","passes":[
              {"constantshadervalues":{
                 "g_Color":{"script":"export function update(v){return v;}","value":"1 1 1",
                            "scriptproperties":{"timer":1,"gain":{"user":"g","value":0.9}}},
                 "plain":0.25}}]}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let layer = try XCTUnwrap(doc.layers.first { $0.name == "L" })
        let pass = try XCTUnwrap(layer.effects.first?.passList.first)
        let json = try XCTUnwrap(pass.constantScriptProps["g_Color"], "effect const scriptproperties 보존")
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((obj["timer"] as? NSNumber)?.doubleValue, 1)
        XCTAssertEqual((obj["gain"] as? NSNumber)?.doubleValue ?? 0, 0.9, accuracy: 1e-6, "{user,value} 바인딩 → 정적 value")
        // 무회귀: 스크립트 없는 정적 상수는 constantScriptProps 에 미포함.
        XCTAssertNil(pass.constantScriptProps["plain"], "정적 상수는 오버라이드 없음")
    }

    /// 검증 지적 대응: WAPLE_VIS_INHERIT=0 이면 C8 전파 패스 전체를 건너뛴다(WapleCompat --vis-blast
    /// 의 코퍼스 블라스트 반경 측정용 진단 게이트 — 기본은 항상 켜짐, 이 테스트는 게이트가 실제로
    /// 두 파스 결과를 분기시키는지 고정). off(env=0) 는 종전(버그) 동작과 동일해야 한다.
    func testVisInheritEnvGateDisablesPropagation() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"offGroup","visible":false},
           {"id":2,"name":"child","image":"models/x.json","parent":1,"origin":"50 50 0","size":"10 10",
            "visible":true}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        setenv("WAPLE_VIS_INHERIT", "0", 1)
        let off = try SceneDocument.parse(package: p, userProps: [:])
        unsetenv("WAPLE_VIS_INHERIT")
        let on = try SceneDocument.parse(package: p, userProps: [:])
        XCTAssertTrue(try XCTUnwrap(off.layers.first { $0.name == "child" }).initialVisible,
                      "WAPLE_VIS_INHERIT=0: 전파 꺼짐 — 자식은 종전처럼 계속 보임")
        XCTAssertFalse(try XCTUnwrap(on.layers.first { $0.name == "child" }).initialVisible,
                       "기본(env 미설정): 전파 켜짐 — 자식이 숨어야 함")
    }

    /// 검증 지적 대응(① 런타임 토글 한계 여부): 이 마킹은 파스-타임 정적 스냅샷이지만, 라이브 유저
    /// 프로퍼티 변경은 SceneRenderer.mount 가 항상 SceneDocument.parse 를 새 userProps 로 재실행하므로
    /// (reapplyIfCurrent → onApply → mount, 코드 경로 확인 — in-place 패치 경로 없음) "옵션을 켜도
    /// 자식이 계속 숨는" 고착은 없다. 여기서는 parse 자체가 userProps 스냅샷에 반응해 동일 씬을 다르게
    /// 마킹함을 고정(= remount 가 재파스인 이상 반드시 갱신됨을 뒷받침).
    func testVisibilityInheritanceRespondsToUserPropsSnapshot() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"comboGroup","visible":{"user":{"condition":"1","name":"opt"},"value":false}},
           {"id":2,"name":"child","image":"models/x.json","parent":1,"origin":"50 50 0","size":"10 10",
            "visible":true}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        // "꺼짐" 스냅샷(옵션 미선택) — 자식도 숨어야.
        let off = try SceneDocument.parse(package: p, userProps: ["opt": "0"])
        XCTAssertFalse(try XCTUnwrap(off.layers.first { $0.name == "child" }).initialVisible)
        // 유저가 옵션을 "켜면"(라이브 재적용 = 새 userProps 로 재파스) 부모가 true 로 풀려 자식도 복귀.
        let on = try SceneDocument.parse(package: p, userProps: ["opt": "1"])
        XCTAssertTrue(try XCTUnwrap(on.layers.first { $0.name == "child" }).initialVisible,
                     "재파스(remount) 로 옵션이 켜지면 정적 마킹이 고착되지 않고 갱신돼야 함")
    }

    /// 실물 3299228616 축소판(이펙트 캐리어 quad): lightshafts 쿼드가 언어 변형 이미지에 parent 로
    /// 매달려 있고 그 부모는 language 콤보가 선택하지 않은 값이라 false 로 굳는다. effectQuadLayer 는
    /// 풀스크린 승격 때문에 `parent` 를 버리므로 종전에는 조상 체인이 아예 없었고, 부모가 꺼져 있어도
    /// 쿼드가 계속 그려졌다(코퍼스 5오브젝트/1씬 — 6개 언어 변형 중 5개가 겹쳐 그려짐).
    /// `visibilityParent` 로 가시성 축만 되살린다 — 지오메트리는 여전히 풀스크린 고정이어야 한다.
    func testEffectQuadInheritsVisibilityFromInvisibleParent() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":239,"name":"LonelyCAT VIE","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "visible":{"user":{"condition":"2","name":"language"},"value":false}},
           {"id":259,"name":"Light shafts - linear","shape":"quad","parent":239,
            "origin":"-129.7 706.5 0.0","scale":"2.06 2.06 2.06",
            "effects":[{"file":"effects/lightshafts/effect.json","passes":[{"combos":{"DIRECTDRAW":1}}]}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let quad = try XCTUnwrap(doc.layers.first { $0.id == 259 }, "드롭 금지 — JS 인덱스 정합상 배열엔 남아야 함")
        XCTAssertEqual(quad.visibilityParent, 239, "저작 parent 를 가시성 축에는 남겨야")
        XCTAssertNil(quad.parent, "지오메트리 축은 그대로 풀스크린 고정(부모 체인 재배치 금지)")
        XCTAssertEqual(quad.origin, Vec2(x: 50, y: 50), "승격된 풀스크린 중심 — 저작 origin 미반영")
        XCTAssertFalse(quad.initialVisible, "부모(239)가 콤보로 꺼져 있으므로 이펙트 쿼드도 숨어야")
    }

    /// 대조군: 같은 구조에서 부모 콤보가 켜지면 쿼드는 그대로 그려져야 한다(무회귀 — 새 parentOf
    /// 항목이 가시 체인을 잘못 끄지 않음을 고정). 실물 3299228616 의 ENG 변형이 이 경우다.
    func testEffectQuadStaysVisibleUnderVisibleParent() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":246,"name":"LonelyCAT ENG","image":"models/x.json","origin":"50 50 0","size":"10 10",
            "visible":{"user":{"condition":"1","name":"language"},"value":true}},
           {"id":601,"name":"Light shafts - linear","shape":"quad","parent":246,
            "effects":[{"file":"effects/lightshafts/effect.json","passes":[{"combos":{"DIRECTDRAW":1}}]}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let quad = try XCTUnwrap(doc.layers.first { $0.id == 601 })
        XCTAssertTrue(quad.initialVisible, "가시 부모의 이펙트 쿼드는 그대로 그려져야 함")
    }

    /// 부모 없는 이펙트 쿼드(코퍼스 41개 중 25개)는 visibilityParent 가 nil 이라 이 패스와 무관해야 한다.
    func testParentlessEffectQuadUnaffected() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"offGroup","visible":false},
           {"id":2,"name":"child","image":"models/x.json","parent":1,"origin":"50 50 0","size":"10 10"},
           {"id":3,"name":"shafts","shape":"quad",
            "effects":[{"file":"effects/lightshafts/effect.json","passes":[{"combos":{"DIRECTDRAW":1}}]}]}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let quad = try XCTUnwrap(doc.layers.first { $0.id == 3 })
        XCTAssertNil(quad.visibilityParent)
        XCTAssertTrue(quad.initialVisible, "루트 쿼드는 다른 서브트리의 비가시와 무관")
        XCTAssertFalse(try XCTUnwrap(doc.layers.first { $0.id == 2 }).initialVisible, "센티넬: 패스가 실제로 돌았다")
    }

    /// C8 잔여 갭 해소: 자기 `visible` **스크립트**를 가진 자식은 종전에 상속에서 면제됐다.
    /// 그 보류의 근거(스크립트가 런타임에 가시성을 소유한다)는 맞지만, 그래서 필요한 수단은
    /// `initialVisible` 시드가 아니라 하드 게이트다 — 시드는 프레임 인코더의
    /// `evaluateBool(current:) ?? cur` 가 스크립트 반환값으로 덮어쓴다.
    /// 조상 집합은 "정적 false + 스크립트 없음" 뿐이라 이 마운트 동안 절대 켜지지 않으므로,
    /// 자식은 스크립트가 무엇을 반환하든 그려지면 안 된다(WE 계층 AND).
    /// 코퍼스 도달 116오브젝트 / 17씬(2D).
    func testScriptVisibleChildIsHardHiddenByInvisibleAncestor() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"offGroup","visible":{"user":{"condition":"2","name":"clocklocation"},"value":false}},
           {"id":2,"name":"scriptChild","image":"models/x.json","parent":1,"origin":"50 50 0","size":"10 10",
            "visible":{"value":true,"script":"'use strict';\\nexport function update(v) { return true; }"}},
           {"id":3,"name":"scriptText","text":"hi","parent":1,"origin":"50 50 0",
            "visible":{"value":true,"script":"'use strict';\\nexport function update(v) { return true; }"}},
           {"id":4,"name":"scriptParticle","particle":"particles/p.json","parent":1,
            "visible":{"value":true,"script":"'use strict';\\nexport function update(v) { return true; }"}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material),
                         ("particles/p.json", particleDef), ("materials/pm.json", particleMaterial)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let child = try XCTUnwrap(doc.layers.first { $0.name == "scriptChild" }, "드롭 금지 — JS 인덱스 정합")
        XCTAssertTrue(child.hiddenByAncestor, "비가시 조상 아래의 스크립트 자식은 하드 게이트로 가려야")
        XCTAssertTrue(child.initialVisible,
                      "시드는 건드리지 않는다 — 스크립트가 어차피 덮어쓰므로 시드로는 못 막는다(수단 구분)")
        XCTAssertNotNil(child.propertyScripts["visible"], "스크립트는 그대로 보존(사이드이펙트 평가 유지)")
        let text = try XCTUnwrap(doc.texts.first { $0.name == "scriptText" })
        XCTAssertTrue(text.hiddenByAncestor)
        let particle = try XCTUnwrap(doc.particles.first { $0.id == 4 })
        XCTAssertTrue(particle.hiddenByAncestor)
        XCTAssertTrue(particle.visible, "파티클도 시드는 유지 — 게이트만 선다")
    }

    /// 대조군: 조상이 켜져 있으면 스크립트 자식에 하드 게이트가 서면 안 된다(무회귀).
    func testScriptVisibleChildNotGatedUnderVisibleAncestor() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"onGroup","visible":{"user":{"condition":"1","name":"clocklocation"},"value":true}},
           {"id":2,"name":"scriptChild","image":"models/x.json","parent":1,"origin":"50 50 0","size":"10 10",
            "visible":{"value":true,"script":"'use strict';\\nexport function update(v) { return true; }"}}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let child = try XCTUnwrap(doc.layers.first { $0.name == "scriptChild" })
        XCTAssertFalse(child.hiddenByAncestor)
        XCTAssertTrue(child.initialVisible)
    }

    /// 조상이 **자기 visible 스크립트를 가지면** 하드 게이트를 세우지 않는다 — 그 조상은 런타임에
    /// 켜질 수 있어 "이 마운트 동안 영구 비가시" 전제가 깨지기 때문이다(남은 잔여 갭의 경계 고정).
    func testScriptedAncestorDoesNotHardHideChild() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"scriptedGroup",
            "visible":{"value":false,"script":"'use strict';\\nexport function update(v) { return true; }"}},
           {"id":2,"name":"child","image":"models/x.json","parent":1,"origin":"50 50 0","size":"10 10"}]}
        """
        let p = try pkg([("scene.json", scene), ("models/x.json", model), ("materials/m.json", material)])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let child = try XCTUnwrap(doc.layers.first { $0.name == "child" })
        XCTAssertFalse(child.hiddenByAncestor, "스크립트 보유 조상은 영구 비가시가 아니다")
        XCTAssertTrue(child.initialVisible)
    }

    /// composelayer 소스 카브아웃은 하드 게이트에도 그대로 적용돼야 한다(오프스크린 합성 재료).
    func testCompositeSourceLayerNotHardHidden() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"offGroup","visible":false},
           {"id":2,"name":"compositeSrc","image":"models/x.json","parent":1,"origin":"50 50 0","size":"10 10",
            "visible":{"value":true,"script":"'use strict';\\nexport function update(v) { return true; }"}}]}
        """
        let composeRef = #"{"passes":[{"textures":["_rt_imageLayerComposite_2"]}]}"#
        let p = try pkg([
            ("scene.json", scene), ("models/x.json", model), ("materials/m.json", material),
            ("effects/composelayer/effect.json", composeRef),
        ])
        let doc = try SceneDocument.parse(package: p, userProps: [:])
        let child = try XCTUnwrap(doc.layers.first { $0.name == "compositeSrc" })
        XCTAssertFalse(child.hiddenByAncestor, "합성 소스는 부모 비가시에도 하드 게이트 대상이 아니다")
    }
}
