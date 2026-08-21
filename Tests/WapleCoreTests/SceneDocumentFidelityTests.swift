import XCTest
@testable import WapleCore

/// `scene.json` 파스의 **실물 대조 계약** — `docs/re/scene-object-model.md` 의 갭 3건을 못으로 박는다.
///
/// 여기 있는 테스트는 전부 "동봉 코퍼스에는 도달이 0 이지만 규약은 확정돼 있는" 자리다.
/// 그래서 골든 스냅샷으로는 절대 안 잡히고, 이 파일이 유일한 회귀 방어선이다.
///
///  ① `text.spacing` / `image.spacing` 은 **vec2** 다 — 디스크립터 `0x1402594f4`
///     (`[desc+0x30]=1`=vec2, `[desc+0x34]=1272`=`+0x4f8`, 주입기 `0x1401a3fc0`).
///  ② bool 키는 **태그 5 게이트**다 — 태그가 5 가 아니면 값을 쓰지 않고 **생성자 기본값을 유지**한다
///     (`cmp byte [r8+8], 5` / `jne` @`0x1401e1a9d`·`0x1401e1ab7`). "거짓" 이 아니라 "유지" 인 것이
///     핵심이라, 기본값이 참인 키에 기본값 false 게이트를 걸면 **회귀**가 된다.
///  ③ `instanceoverride.controlpointangle0..7` — 등록 `0x14024e09f`… 타입 2(vec3),
///     `instance+0x150+12i`. 적용 게이트 `test [cp+0xC0], 0x10005` @`0x14022bf26`.
final class SceneDocumentFidelityTests: XCTestCase {
    private func d(_ s: String) -> Data { s.data(using: .utf8)! }
    private let modelJSON = #"{"width":100,"height":100,"material":"materials/m.json"}"#
    private let materialJSON = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#

    private func cameraScene(_ objExtra: String) throws -> SceneDocument {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":7,"camera":"default","fov":60\(objExtra)}]}
        """
        return try SceneDocument.parse(package: ScenePackage.assemble([("scene.json", d(scene))]))
    }

    private func imageScene(_ objExtra: String) throws -> SceneDocument {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"0 0 0"\(objExtra)}]}
        """
        return try SceneDocument.parse(package: ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("models/x.json", d(modelJSON)),
            ("materials/m.json", d(materialJSON)),
        ]))
    }

    private func textScene(_ objExtra: String) throws -> SceneDocument {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"text":"hi","font":"systemfont_arial","pointsize":16,
                     "origin":"0 0 0"\(objExtra)}]}
        """
        return try SceneDocument.parse(package: ScenePackage.assemble([("scene.json", d(scene))]))
    }

    // MARK: - ① text.spacing / image.spacing 은 vec2 다

    /// 워크샵 실측 형태(`spec/corpus/scene-schema.json` `text.spacing`: 13씬 171건 전건
    /// `"0.00000 0.00000"`)가 **2성분 문자열**이다. 종전 `float()` 는 `Float("0 0")` 이 nil 이라
    /// 171건을 전부 조용히 버렸다 — 이 테스트가 그 회귀를 막는다.
    func testTextSpacingIsVec2NotScalar() throws {
        let t = try XCTUnwrap(textScene(#","spacing":"3 4""#).texts.first)
        let s = try XCTUnwrap(t.spacing)
        XCTAssertEqual(s.x, 3, accuracy: 1e-5)
        XCTAssertEqual(s.y, 4, accuracy: 1e-5)
    }

    /// 워크샵 전건 값 `"0.00000 0.00000"` 이 **nil 이 아니라 (0,0)** 으로 보존돼야 한다.
    /// "값이 0 이라 어차피 같다" 가 아니다 — 미지정(nil)과 명시 0 은 소비처가 붙는 순간 갈린다.
    func testTextSpacingZeroVectorIsPreservedNotDropped() throws {
        let t = try XCTUnwrap(textScene(#","spacing":"0.00000 0.00000""#).texts.first)
        XCTAssertEqual(try XCTUnwrap(t.spacing), Vec2(x: 0, y: 0))
    }

    /// vec2 주입기 `0x1401a3fc0` 의 태그 1/2/3 경로: `asFloat`(`0x140086220`) 한 값을
    /// **두 성분에 브로드캐스트**한다(`0x1401a40a4` `movss [rdi+rsi+4]` / `0x1401a40aa` `movss [rdi+rsi]`).
    func testSpacingScalarBroadcastsToBothComponents() throws {
        let t = try XCTUnwrap(textScene(#","spacing":2.5"#).texts.first)
        XCTAssertEqual(try XCTUnwrap(t.spacing), Vec2(x: 2.5, y: 2.5))
    }

    /// 이미지 레이어 `spacing` 은 **엔진에 없는 유령 키**(등록부 `0x1401ee520` 12 프로퍼티에 부재,
    /// `"spacing"` 문자열 참조 2건이 둘 다 텍스트 등록부 안)지만, 파스하는 이상 형은 텍스트와 같아야 한다.
    func testImageSpacingKeepsSameVec2Shape() throws {
        let layer = try XCTUnwrap(imageScene(#","spacing":"5 6""#).layers.first)
        XCTAssertEqual(try XCTUnwrap(layer.spacing), Vec2(x: 5, y: 6))
    }

    // MARK: - ② bool 은 태그 5 게이트 (숫자 1 은 참이 아니다)

    /// 기본이 **참**인 키에서 숫자 0 은 거짓이 아니다 — 실물은 태그 5 가 아니면 스토어를 건너뛰어
    /// 생성자 값을 유지한다. `copybackground` `+0x304` bit6 · `clampuvs` bit15, ctor `0x8040`.
    func testNumericZeroDoesNotClearDefaultTrueFlags() throws {
        let layer = try XCTUnwrap(imageScene(#","copybackground":0,"clampuvs":0"#).layers.first)
        XCTAssertTrue(layer.copyBackground, "숫자 0 은 태그 5 가 아니라 기본 true 를 유지해야 한다")
        XCTAssertTrue(layer.clampUVs)
    }

    /// 기본이 **거짓**인 키에서 숫자 1 은 참이 아니다.
    /// `perspective` bit7 · `ledsource` `+0x304` bit8 · `disablepropagation` `+0x120` bit14.
    ///
    /// **정정(2026-08-21)**: 종전 이 테스트는 `solid` 도 "기본 거짓" 쪽에 넣고 `XCTAssertFalse(isSolid)`
    /// 를 걸었는데 그게 틀렸다 — `solid` 는 같은 워드 **bit13** 이고 기저 ctor 리터럴
    /// `mov word [r14+0x120], 0x2001`(`0x1401ddc72`)이 `0x2001` = bit0(`visible`) | **bit13** 을 깔아
    /// **기본 true** 다(bit14 는 안 서므로 `disablepropagation` 만 기본 false 가 맞다).
    /// 태그5 게이트가 실패하면 스토어를 건너뛰어 ctor 값이 남으므로 `"solid":1` 은 **true 로 남아야** 한다.
    /// 그래서 `solid` 단언은 아래 `testNumericOneDoesNotClearDefaultTrueSolid` 로 옮겼다.
    func testNumericOneDoesNotSetDefaultFalseFlags() throws {
        let layer = try XCTUnwrap(
            imageScene(#","perspective":1,"ledsource":1,"disablepropagation":1"#).layers.first)
        XCTAssertFalse(layer.perspective)
        XCTAssertFalse(layer.ledSource)
        XCTAssertFalse(layer.disablePropagation)
    }

    /// `solid` `+0x120` bit13(등록 `0x1401e1283`, 게터 `0x14019c600` `shr edx,0xd`)은 기본 **true** 다 —
    /// 숫자 1 도 문자열도 태그 5 가 아니라 스토어를 건너뛰고 ctor `0x2001` 의 bit13 이 그대로 남는다.
    /// (에디터 라벨: `ui_editor_properties_enable_click_events` = "Enable click events".)
    func testNumericOneDoesNotClearDefaultTrueSolid() throws {
        XCTAssertTrue(try XCTUnwrap(imageScene(#","solid":1"#).layers.first).isSolid)
        XCTAssertTrue(try XCTUnwrap(imageScene(#","solid":0"#).layers.first).isSolid,
                      "숫자 0 도 태그 5 가 아니라 ctor 기본 true 를 유지한다")
        XCTAssertFalse(try XCTUnwrap(imageScene(#","solid":false"#).layers.first).isSolid,
                       "평문 false 만 실제로 끈다")
    }

    /// 문자열 `"true"` 도 태그 4 라 참이 아니다(태그 5 만 통과).
    /// `solid` 는 기본이 true 라 "문자열이 못 덮는다" = **true 가 남는다**(위 테스트 주석의 ctor 근거).
    func testStringTrueIsNotBoolean() throws {
        let layer = try XCTUnwrap(imageScene(#","solid":"true","copybackground":"false""#).layers.first)
        XCTAssertTrue(layer.isSolid, "문자열은 기본값(true)을 못 덮는다")
        XCTAssertTrue(layer.copyBackground, "문자열은 기본값을 못 덮는다")
    }

    /// **회귀 방지 못**(`wraploop` 라운드의 실패 재현): `visible` 은 bit0 기본 **true** 다.
    /// 태그-5 게이트를 걸면서 실패 분기를 false 로 두면 `"visible": 1` 인 레이어가 통째로 사라진다.
    func testNonBooleanVisibleKeepsObjectVisible() throws {
        XCTAssertEqual(try imageScene(#","visible":1"#).layers.count, 1, "숫자 visible 은 기본 true 유지")
        XCTAssertEqual(try imageScene(#","visible":"yes""#).layers.count, 1)
        XCTAssertEqual(try imageScene(#","visible":null"#).layers.count, 1)
        XCTAssertEqual(try imageScene(#","visible":false"#).layers.count, 0, "평문 false 는 그대로 드롭")
    }

    /// 바인딩 객체는 `find("value")` 가 **태그 5 일 때만** 값을 쓴다(`0x1401e1b12`).
    /// `{"user":…,"value":1}` 은 숫자라 기본값 유지.
    func testBindingObjectValueAlsoNeedsTag5() throws {
        XCTAssertEqual(try imageScene(#","visible":{"user":"u","value":1}"#).layers.count, 1)
        XCTAssertEqual(try imageScene(#","visible":{"user":"u","value":false}"#).layers.count, 0)
        XCTAssertEqual(try imageScene(#","visible":{"user":"u"}"#).layers.count, 1, "value 부재 → 기본 유지")
    }

    /// `general` 플래그 워드 `scene+0xE0`(ctor `0x26` @`0x140186d1f`).
    /// `hdr` bit10=false · `clearenabled` bit5=**true** · `camerafade` bit2=**true** ·
    /// `windenabled` bit16=false(등록 `0x14019b3b7` — 이 5개는 `0x14000ddd0` 로 이름을 붙여서
    /// `0x14000f880` 만 훑는 덤프에 안 잡힌다. `general` 디스크립터는 42 가 아니라 **47** 개다).
    func testGeneralBoolFlagsUseTag5Gate() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},
          "hdr":1,"bloom":1,"clearenabled":0,"camerafade":0,"windenabled":1,
          "camerashake":1,"cameraparallax":1,"transparentsorting":1},"objects":[]}
        """
        let doc = try SceneDocument.parse(package: ScenePackage.assemble([("scene.json", d(scene))]))
        XCTAssertFalse(doc.hdr)
        XCTAssertFalse(doc.bloom)
        XCTAssertTrue(doc.clearEnabled, "bit5 기본 true — 숫자 0 이 못 끈다")
        XCTAssertTrue(doc.cameraFade, "bit2 기본 true")
        XCTAssertFalse(doc.windEnabled)
        XCTAssertFalse(doc.cameraShake)
        XCTAssertFalse(doc.transparentSorting)
    }

    /// `general.clearenabled: null` — 설치본 45씬 · 동봉 44씬의 실제 형태. 태그 0 이라 기본 true.
    func testNullClearEnabledKeepsDefaultTrue() throws {
        let scene = #"{"general":{"orthogonalprojection":{"width":100,"height":100},"clearenabled":null},"objects":[]}"#
        XCTAssertTrue(try SceneDocument.parse(package: ScenePackage.assemble([("scene.json", d(scene))])).clearEnabled)
    }

    /// 텍스트 전용 플래그 — `+0x594` bit1/2/3/4/5(`opaquebackground`/`limitwidth`/`limitrows`/
    /// `limituseellipsis`/`blockalign`) · `+0x518` bit1(`outline`). 전부 기본 false.
    func testTextBoolFlagsUseTag5Gate() throws {
        let t = try XCTUnwrap(textScene("""
        ,"opaquebackground":1,"outline":1,"limituseellipsis":1,"blockalign":1,
        "limitwidth":1,"maxwidth":123,"limitrows":1,"maxrows":7
        """).texts.first)
        XCTAssertFalse(t.opaqueBackground)
        XCTAssertFalse(t.outline)
        XCTAssertFalse(t.overflowEllipsis)
        XCTAssertFalse(t.justify)
        XCTAssertNil(t.maxWidth, "limitwidth 가 태그 5 가 아니면 maxwidth 도 안 걸린다")
        XCTAssertNil(t.maxRows)
    }

    /// `config.*` 는 디스크립터가 아니라 모델 `.json` 파서(`0x1401fac50`–`0x1401fb498`)가
    /// `operator[]` → `cmp byte [rax+8],5` → `asBool` → **참일 때만 `or`** 로 읽는다
    /// (`passthrough` `0x1401faea6` · `autosize` `0x1401fae75` · `solidlayer` `0x1401faed7` ·
    /// `projectlayer` `0x1401faf07` · `instanced` `0x1401faf42`).
    func testConfigSubnodeBoolsUseTag5Gate() throws {
        let layer = try XCTUnwrap(imageScene("""
        ,"config":{"passthrough":1,"autosize":"true","solidlayer":1,"projectlayer":1,"instanced":1}
        """).layers.first)
        XCTAssertFalse(layer.configPassthrough)
        XCTAssertFalse(layer.configAutosize)
        XCTAssertFalse(layer.configIsSolidLayer)
        XCTAssertFalse(layer.configIsProjectLayer)
        XCTAssertFalse(layer.configIsInstanced)
    }

    /// 이펙트 `visible` 은 `+0x118` bit0 기본 **true**(등록 `0x1401efd60`).
    /// 숫자 0 은 못 끈다 — 종전 `as? Bool` 은 껐고, 그러면 이펙트가 파스에서 통째로 드롭됐다.
    func testEffectVisibleNumericZeroDoesNotDropEffect() throws {
        let kept = try imageScene(#","effects":[{"file":"effects/blur/effect.json","visible":0}]"#)
        XCTAssertEqual(try XCTUnwrap(kept.layers.first).effects.count, 1)
        let dropped = try imageScene(#","effects":[{"file":"effects/blur/effect.json","visible":false}]"#)
        XCTAssertEqual(try XCTUnwrap(dropped.layers.first).effects.count, 0, "평문 false 는 그대로 드롭")
    }

    /// 라이트 `castshadow` = `+0x2c4` bit0(등록 `0x14025e64e`), `castvolumetrics` = bit2
    /// (`0x14025e7cc`). 둘 다 기본 false.
    func testLightBoolFlagsUseTag5Gate() throws {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0},
         "objects":[{"id":1,"light":"lpoint","origin":"0 0 0","color":"1 1 1","radius":5,
                     "castshadow":1,"castvolumetrics":1}]}
        """
        let l = try XCTUnwrap(
            SceneDocument.parse(package: ScenePackage.assemble([("scene.json", d(scene))])).lights3D.first)
        XCTAssertFalse(l.castShadow)
        XCTAssertFalse(l.castVolumetrics)
    }

    /// 사운드 `startsilent` = `+0x310` bit1(등록 `0x1401f76b5`), `spatialization` = bit2
    /// (`0x1401f7792`). 둘 다 기본 false.
    func testSoundBoolFlagsUseTag5Gate() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"sound":["sounds/a.mp3"],"startsilent":1,"spatialization":1}]}
        """
        let s = try XCTUnwrap(
            SceneDocument.parse(package: ScenePackage.assemble([("scene.json", d(scene))])).sounds.first)
        XCTAssertFalse(s.startSilent)
        XCTAssertFalse(s.spatialization)
    }

    // MARK: - ③ controlpointangle0..7

    private func particleDoc(_ io: String, particle: String) throws -> SceneDocument {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"particle":"particles/p.json","instanceoverride":\(io)}]}
        """
        return try SceneDocument.parse(package: ScenePackage.assemble([
            ("scene.json", d(scene)), ("particles/p.json", d(particle)),
        ]))
    }

    private let plainParticle = """
    {"emitter":[{"name":"sphererandom","rate":1}],"renderer":[{"name":"sprite"}],
     "controlpoint":[{"offset":"0 0 0"},{"offset":"22 0 0"},{"offset":"-22 0 0"}],"maxcount":4}
    """

    /// `presets/water/previewdrippingwater` 의 실제 저작값 — ±22px 떨어진 두 CP 를 Z 축으로
    /// ∓30°(∓π/6 rad) 벌린 수도꼭지. 단위는 **라디안**(주입기 `0x1401a4230` 에 상수 곱이 없다).
    func testInstanceOverrideParsesControlPointAngles() throws {
        let io = """
        {"controlpoint1":"22 0 0","controlpointangle1":"0.00000 0.00000 -0.52360",
         "controlpoint2":"-22 0 0","controlpointangle2":"0.00000 0.00000 0.52360"}
        """
        let doc = try particleDoc(io, particle: plainParticle)
        let def = try XCTUnwrap(doc.particles.first).def
        XCTAssertEqual(def.controlPointAngles[1], Vec3(x: 0, y: 0, z: -0.5236))
        XCTAssertEqual(def.controlPointAngles[2], Vec3(x: 0, y: 0, z: 0.5236))
        XCTAssertEqual(def.controlPoints[1], Vec3(x: 22, y: 0, z: 0))
    }

    /// 위치와 각도는 **개별 센티널**이다(생성자 `0x14024d760` 이 두 슬롯의 `.x` 를 따로 FLT_MAX 로 깐다).
    /// 각도만 지정한 오버라이드도 유효해야 하고, 그때 위치는 프리셋 값 그대로여야 한다.
    func testControlPointAngleOnlyOverrideKeepsPresetPosition() throws {
        let doc = try particleDoc(#"{"controlpointangle1":"0 0 1.5708"}"#, particle: plainParticle)
        let def = try XCTUnwrap(doc.particles.first).def
        XCTAssertEqual(def.controlPointAngles[1].z, 1.5708, accuracy: 1e-5)
        XCTAssertEqual(def.controlPoints[1], Vec3(x: 22, y: 0, z: 0), "프리셋 offset 유지")
    }

    /// 각도만 있는 `instanceoverride` 도 **비어 있지 않다** — `isEmpty` 가 각도를 안 세면
    /// 오버라이드 전체가 nil 로 접혀 조용히 사라진다.
    func testControlPointAngleAloneMakesOverrideNonEmpty() {
        var ov = ParticleInstanceOverride()
        XCTAssertTrue(ov.isEmpty)
        ov.controlPointAngles[3] = Vec3(x: 0, y: 0, z: 1)
        XCTAssertFalse(ov.isEmpty)
    }

    /// 파티클 **정의** 쪽 짝 — `controlpoint[].angles`(판독 `0x1401d06ce`, 스토어 `+0xb8+32i`
    /// @`0x1401d07c9`). 동봉 도달 0 이지만 스키마의 정본이다.
    func testParticleDefParsesControlPointAngles() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"sphererandom","rate":1}],"renderer":[{"name":"sprite"}],
         "controlpoint":[{"offset":"1 2 3","angles":"0.1 0.2 0.3"}],"maxcount":4}
        """), material: nil)
        XCTAssertEqual(def.controlPoints[0], Vec3(x: 1, y: 2, z: 3))
        XCTAssertEqual(def.controlPointAngles[0].x, 0.1, accuracy: 1e-6)
        XCTAssertEqual(def.controlPointAngles[0].y, 0.2, accuracy: 1e-6)
        XCTAssertEqual(def.controlPointAngles[0].z, 0.3, accuracy: 1e-6)
    }

    // MARK: - ③-b 적용 게이트 `test [cp+0xC0], 0x10005` @0x14022bf26

    private func gateParticle(flags: String) -> String {
        """
        {"emitter":[{"name":"sphererandom","rate":1}],"renderer":[{"name":"sprite"}],
         "controlpoint":[{"offset":"0 0 0"},{"offset":"7 7 7"\(flags)}],"maxcount":4}
        """
    }

    /// bit0(마우스 포인터 구동) — 오버라이드가 **적용되지 않는다**.
    func testControlPointOverrideBlockedByMouseDrivenFlag() throws {
        let doc = try particleDoc(#"{"controlpoint1":"100 200 0","controlpointangle1":"0 0 1"}"#,
                                  particle: gateParticle(flags: #","flags":1"#))
        let def = try XCTUnwrap(doc.particles.first).def
        XCTAssertEqual(def.controlPoints[1], Vec3(x: 7, y: 7, z: 7), "bit0 이면 위치 오버라이드 무시")
        XCTAssertEqual(def.controlPointAngles[1], Vec3(x: 0, y: 0, z: 0), "각도도 같이 무시")
    }

    /// bit2(부모 시스템 CP 에 부착) — 마찬가지로 무시.
    func testControlPointOverrideBlockedByParentAttachFlag() throws {
        let doc = try particleDoc(#"{"controlpoint1":"100 200 0"}"#,
                                  particle: gateParticle(flags: #","flags":4"#))
        XCTAssertEqual(try XCTUnwrap(doc.particles.first).def.controlPoints[1], Vec3(x: 7, y: 7, z: 7))
    }

    /// **값 16 은 bit4 지 bit16 이 아니다**(마스크는 `0x10005`). 동봉 CP 10건이 이 값이라
    /// 여기를 잘못 읽으면 실제 저작 자산이 조용히 오버라이드를 잃는다.
    func testFlagsValue16IsBit4AndDoesNotBlockOverride() throws {
        let doc = try particleDoc(#"{"controlpoint1":"100 200 0"}"#,
                                  particle: gateParticle(flags: #","flags":16"#))
        XCTAssertEqual(try XCTUnwrap(doc.particles.first).def.controlPoints[1], Vec3(x: 100, y: 200, z: 0))
    }

    /// bit1(값 2)도 게이트 대상이 아니다 — 동봉 10건.
    func testFlagsValue2DoesNotBlockOverride() throws {
        let doc = try particleDoc(#"{"controlpoint1":"100 200 0"}"#,
                                  particle: gateParticle(flags: #","flags":2"#))
        XCTAssertEqual(try XCTUnwrap(doc.particles.first).def.controlPoints[1], Vec3(x: 100, y: 200, z: 0))
    }

    /// 게이트에 걸린 CP 는 attract 재베이크도 프리셋 값을 봐야 한다(오버라이드가 없었던 것과 같다).
    func testGatedControlPointKeepsPresetAttractTarget() throws {
        let particle = """
        {"emitter":[{"name":"sphererandom","rate":1}],"renderer":[{"name":"sprite"}],
         "operator":[{"name":"controlpointattract","controlpoint":1,"scale":2,"threshold":10}],
         "controlpoint":[{"offset":"0 0 0"},{"offset":"7 7 7","flags":1}],"maxcount":4}
        """
        let doc = try particleDoc(#"{"controlpoint1":"100 200 0"}"#, particle: particle)
        let def = try XCTUnwrap(doc.particles.first).def
        XCTAssertTrue(def.operators.contains(
            .controlPointAttract(scale: 2, threshold: 10, target: Vec3(x: 7, y: 7, z: 7))),
            "게이트된 CP 는 프리셋 좌표로 베이크돼야 한다 — got \(def.operators)")
    }

    // MARK: - ④ instanceoverride 의 {animation} 바인딩 (클러스터 K 이관)

    /// **동봉 실물 그대로.** `scenes/particleelementpreviews/maintaindistancebetweencontrolpoints/scene.json`
    /// 의 `/objects/1/instanceoverride/controlpoint1` 은 `{"animation":{c0,c1,c2,options}, "value":"…"}` 인데,
    /// 종전 `particleInstanceOverride` 는 `vec3()` 의 정적 `value` 언랩만 해서 트랙을 통째로 버렸다.
    ///
    /// **범위 라벨**: 동봉 `WEAssets`(json 1,698) 전수에서 `"animation"` 딕셔너리는 7건이고 그중
    /// **5건**이 `instanceoverride` 밑이다(`controlpointangle1` 4 · `controlpoint1` 1).
    /// 설치본 `wallpaper_engine`(json 2,143)도 같은 6파일로 동수 — 즉 **이 경로가 애니 블록의 다수파**다.
    ///
    /// 소비처는 아직 없어 **그림은 바뀌지 않는다**(파스·보존 전용).
    func testInstanceOverrideAnimationBindingIsCaptured() throws {
        let io = """
        {"controlpoint1":{
           "animation":{
             "c0":[{"frame":0,"value":0,
                    "front":{"enabled":true,"magic":true,"x":1,"y":0},
                    "back":{"enabled":true,"magic":true,"x":-1,"y":-0.0},
                    "lockangle":true,"locklength":true},
                   {"frame":30,"value":0,
                    "front":{"enabled":true,"magic":true,"x":1,"y":0},
                    "back":{"enabled":true,"magic":true,"x":-1,"y":-0.0},
                    "lockangle":true,"locklength":true}],
             "c1":[{"frame":0,"value":436.42032,
                    "front":{"enabled":true,"magic":true,"x":1,"y":0},
                    "back":{"enabled":true,"magic":true,"x":-1,"y":-0.0},
                    "lockangle":true,"locklength":true},
                   {"frame":30,"value":145.37645,
                    "front":{"enabled":true,"magic":true,"x":1,"y":0},
                    "back":{"enabled":true,"magic":true,"x":-1,"y":-0.0},
                    "lockangle":true,"locklength":true}],
             "c2":[{"frame":0,"value":0,
                    "front":{"enabled":true,"magic":true,"x":1,"y":0},
                    "back":{"enabled":true,"magic":true,"x":-1,"y":-0.0},
                    "lockangle":true,"locklength":true},
                   {"frame":30,"value":0,
                    "front":{"enabled":true,"magic":true,"x":1,"y":0},
                    "back":{"enabled":true,"magic":true,"x":-1,"y":-0.0},
                    "lockangle":true,"locklength":true}],
             "options":{"fps":30,"length":60,"mode":"loop","wraploop":true}},
           "value":"0.00000 436.42032 0.00000"}}
        """
        let doc = try particleDoc(io, particle: plainParticle)
        let sp = try XCTUnwrap(doc.particles.first)

        // ① 정적 `value` 는 종전 그대로 def 에 착지한다(무회귀).
        XCTAssertEqual(sp.def.controlPoints[1], Vec3(x: 0, y: 436.42032, z: 0))

        // ② 트랙이 살아난다 — 종전엔 이 사전이 통째로 비어 있었다.
        let anim = try XCTUnwrap(sp.instanceOverrideAnimations["controlpoint1"],
                                 "instanceoverride 의 {animation} 바인딩이 드롭되면 안 된다")
        XCTAssertEqual(anim.fps, 30)
        XCTAssertEqual(anim.length, 60)
        XCTAssertEqual(anim.mode, "loop")
        XCTAssertTrue(anim.wrapLoop)
        XCTAssertEqual(anim.tracks.count, 3, "c0/c1/c2 세 채널")

        // ③ **실제로 움직인다** — c1(= y 성분)이 frame 0 의 436.42032 에서 frame 30 의 145.37645 로 간다.
        //    정적 언랩만 하던 종전에는 y 가 436.42032 에 고정이었다.
        XCTAssertEqual(anim.value(component: 1, atTime: 0, base: 0), 436.42032, accuracy: 1e-3)
        XCTAssertEqual(anim.value(component: 1, atTime: 1.0, base: 0), 145.37645, accuracy: 1e-3,
                       "frame 30 @ 30fps = 1.0s")
        let mid = anim.value(component: 1, atTime: 0.5, base: 0)
        XCTAssertGreaterThan(mid, 145.37645)
        XCTAssertLessThan(mid, 436.42032)
        // 다른 두 채널은 상수 0.
        XCTAssertEqual(anim.value(component: 0, atTime: 0.5, base: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(anim.value(component: 2, atTime: 0.5, base: 0), 0, accuracy: 1e-6)
    }

    /// 애니가 **아닌** 바인딩/평문은 이 사전에 담기지 않는다 — `PropertyAnimation.parse` 는
    /// `"animation"` 키가 없으면 nil 이라 `{user,value}`·평문 문자열·숫자는 전부 통과한다(무회귀 가드).
    func testInstanceOverrideWithoutAnimationCapturesNothing() throws {
        let io = """
        {"id":126,"count":2.0,"controlpoint1":"22 0 0",
         "size":{"user":"psize","value":2.0}}
        """
        let doc = try particleDoc(io, particle: plainParticle)
        let sp = try XCTUnwrap(doc.particles.first)
        XCTAssertTrue(sp.instanceOverrideAnimations.isEmpty)
        XCTAssertEqual(sp.def.controlPoints[1], Vec3(x: 22, y: 0, z: 0))
    }

    /// 동봉 다수파인 `controlpointangle1` 쪽(4/5건)도 같은 규약으로 잡힌다.
    func testInstanceOverrideControlPointAngleAnimationIsCaptured() throws {
        let io = """
        {"controlpointangle1":{
           "animation":{"c2":[{"frame":0,"value":0},{"frame":15,"value":1.5708}],
                        "options":{"fps":15,"length":30,"mode":"loop"}},
           "value":"0 0 0"}}
        """
        let doc = try particleDoc(io, particle: plainParticle)
        let sp = try XCTUnwrap(doc.particles.first)
        let anim = try XCTUnwrap(sp.instanceOverrideAnimations["controlpointangle1"])
        XCTAssertEqual(anim.fps, 15)
        XCTAssertEqual(anim.value(component: 2, atTime: 1.0, base: 0), 1.5708, accuracy: 1e-4)
        XCTAssertEqual(sp.def.controlPointAngles[1], Vec3(x: 0, y: 0, z: 0), "정적 value 는 그대로")
    }

    /// `solid` 기본값 **true** 를 **네 파스 지점 전부**에서 잠근다(image · text · camera · particle).
    ///
    /// 근거는 하나다 — 기저 오브젝트 생성자 `sub_1401ddbb0` 의
    /// `mov word [r14+0x120], 0x2001`(`0x1401ddc72`, 바이트 `66 41 c7 86 20 01 00 00 01 20`).
    /// `0x2001` = bit0(`visible`) | **bit13(`solid`)** 이고 bit14(`disablepropagation`)는 서지 않는다.
    /// `solid`/`disablepropagation` 은 **같은 기저 디스크립터 표**의 이웃 항목이라 둘 다
    /// 멤버 오프셋 `+0x120` · 타입 6(bool)이고, 비트만 13/14 로 다르다
    /// (썽크로 재확인: `solid` 역직렬화 `0x14019c3f0` `btr edx,0xd`/`bts ecx,0xd` ·
    ///  직렬화 `0x14019c4ca` `test dword [rcx],0x2000` · 게터 `0x14019c600` `shr edx,0xd` ↔
    ///  `disablepropagation` 역직렬화 `0x14019bb40` `btr edx,0xe` · 직렬화 `0x14019bc1a` `…,0x4000` ·
    ///  게터 `0x14019bd50` `shr edx,0xe`).
    /// 파생 ctor 중 bit13 을 끄는 곳은 없다.
    ///
    /// 종전 Waple 은 네 곳 모두 `= false` + `weBool(obj["solid"])` 라, **키 부재**와 **비-bool 태그**에서
    /// 실물과 반대로 접혔다. `isSolid` 소비처가 0건이라 그림은 안 바뀐다(무회귀).
    func testSolidDefaultsTrueAcrossAllFourParseSites() throws {
        // 키 부재 → ctor 기본 true.
        XCTAssertTrue(try XCTUnwrap(imageScene("").layers.first).isSolid)
        XCTAssertTrue(try XCTUnwrap(textScene("").texts.first).isSolid)
        XCTAssertTrue(try XCTUnwrap(cameraScene("").cameraObjects.first).isSolid)
        XCTAssertTrue(try XCTUnwrap(particleDoc(#"{"count":1}"#, particle: plainParticle).particles.first).isSolid)
        // 비-bool 태그 → 스토어를 건너뛰어 ctor 기본 true 유지.
        XCTAssertTrue(try XCTUnwrap(imageScene(#","solid":0"#).layers.first).isSolid)
        XCTAssertTrue(try XCTUnwrap(textScene(#","solid":0"#).texts.first).isSolid)
        XCTAssertTrue(try XCTUnwrap(cameraScene(#","solid":0"#).cameraObjects.first).isSolid)
        // 평문 false 만 실제로 끈다.
        XCTAssertFalse(try XCTUnwrap(imageScene(#","solid":false"#).layers.first).isSolid)
        XCTAssertFalse(try XCTUnwrap(textScene(#","solid":false"#).texts.first).isSolid)
        XCTAssertFalse(try XCTUnwrap(cameraScene(#","solid":false"#).cameraObjects.first).isSolid)
    }
}
