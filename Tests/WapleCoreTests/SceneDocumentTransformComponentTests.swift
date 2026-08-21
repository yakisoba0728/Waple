import XCTest
@testable import WapleCore

/// 3차 웨이브 클러스터 V — 씬 파스에서 값이 사라지던 자리 4건의 고정 테스트.
///
/// | # | 자리 | 실물 근거(직접 재확인한 VA) | 동봉/설치본 도달 |
/// | ---: | --- | --- | ---: |
/// | 1 | `general.orthogonalprojection.width`/`height` 는 **둘 다** 태그 1..3 일 때만 읽는다 | `0x140187572`–`0x14018758a` 인라인 `isNumeric` 2연 + 실패 시 `0x140187602` 로 두 스토어 스킵 | 0 / 0 |
/// | 2 | `SceneLayer.scaleZ` — `scale` 은 vec3 디스크립터 | 등록 `0x1401e06a6`("scale") → `+0x134`(`0x1401e06c6`) → 태그 **2**(`0x1401e06ea`) | 이미지 4 / 21 · 텍스트 3 / 5 |
/// | 3 | `angleX`/`angleY` — `angles` 도 vec3 | 등록 `0x1401e075c` → `+0x140`(`0x1401e0795`) → 태그 **2**(`0x1401e07ae`) | 레이어·텍스트 **0 / 0** |
/// | 4 | `SceneTextLayer.parallaxDepth` — 공통 오브젝트 표의 vec2 키 | 등록 `0x1401e082f` → `+0x170`(`0x1401e0848`) → 태그 **1**(`0x1401e085a`) | 3 / 3(전건 기본값) |
///
/// 2·3·4 는 **파스·보존 전용**이다 — 소비처가 없으므로 2D 렌더는 비트동일이고,
/// 이 파일은 "값이 실려 있다" 와 "기본값이 종전과 같다" 두 축을 함께 건다.
final class SceneDocumentTransformComponentTests: XCTestCase {

    private func doc(_ scene: String) throws -> SceneDocument {
        try SceneDocument.parse(package: pkg([("scene.json", scene)]))
    }

    /// `general` 만 갈아 끼우는 최소 씬(오브젝트 0).
    private func general(_ proj: String) -> String {
        #"{"general":{"orthogonalprojection":\#(proj)},"objects":[]}"#
    }

    // MARK: - #1 orthogonalprojection.width/height 태그 게이트

    /// 무회귀: 정상 정수 저작은 종전과 같은 값이 실린다(동봉·설치본 전건이 이 형태 — 168/178 씬).
    func testOrthoIntegerSizeUnchanged() throws {
        let d = try doc(general(#"{"width":800,"height":600}"#))
        XCTAssertEqual(d.projectionWidth, 800)
        XCTAssertEqual(d.projectionHeight, 600)
    }

    /// 실물은 태그 3(real)도 받고 `asUInt`(`0x140085ee0`)의 `cvttsd2si`(`0x140085f12`)로
    /// **0 방향 절단**한다. 반올림이 아니다.
    func testOrthoRealSizeTruncatesTowardZero() throws {
        let d = try doc(general(#"{"width":800.9,"height":600.9}"#))
        XCTAssertEqual(d.projectionWidth, 800)
        XCTAssertEqual(d.projectionHeight, 600)
    }

    /// **불리언은 숫자가 아니다.** 종전 `lenientInt` 는 `true` → 1 이라 1×1 정사영을 만들었다.
    /// 실물은 `movzx eax,[rsi+8]; dec; cmp 2; ja`(`0x140187572`)에서 태그 5 를 걸러 스토어를 건너뛴다.
    func testOrthoBooleanWidthRejected() throws {
        let d = try doc(general(#"{"width":true,"height":true}"#))
        XCTAssertEqual(d.projectionWidth, 1920, "태그 5 는 게이트를 못 넘는다 — 1×1 정사영이 되면 안 된다")
        XCTAssertEqual(d.projectionHeight, 1080)
    }

    /// 문자열(태그 4)도 거부 — 실물은 `asUInt` 가 태그 4 에서 abort 하므로 애초에 게이트를 통과 못 한다.
    func testOrthoStringSizeRejected() throws {
        let d = try doc(general(#"{"width":"800","height":"600"}"#))
        XCTAssertEqual(d.projectionWidth, 1920)
        XCTAssertEqual(d.projectionHeight, 1080)
    }

    /// **전부-아니면-전무**: 하나만 숫자여도 `0x140187602` 로 점프해 **두 스토어가 모두** 안 돈다.
    /// 종전 Waple 은 키별 독립 폴백이라 width 만 800 이 됐다.
    /// (동봉·설치본 씬 전수에서 한쪽만 저작한 사례 **0건** — 이 분기는 워크샵 대비 방어다.)
    func testOrthoWidthOnlyFallsBackBoth() throws {
        let d = try doc(general(#"{"width":800}"#))
        XCTAssertEqual(d.projectionWidth, 1920, "height 가 없으면 width 도 안 읽는다")
        XCTAssertEqual(d.projectionHeight, 1080)
    }

    /// 한쪽만 비숫자여도 **둘 다** 안 읽는다 — 게이트가 키별 독립이면 여기서 갈린다
    /// (`0x14018757b` 의 `ja` 가 height 검사 **전에** 공통 탈출로 뛴다).
    func testOrthoBooleanWidthWithNumericHeightRejectsBoth() throws {
        let d = try doc(general(#"{"width":true,"height":600}"#))
        XCTAssertEqual(d.projectionWidth, 1920)
        XCTAssertEqual(d.projectionHeight, 1080, "height 는 숫자지만 width 가 태그 5 라 스토어 자체가 안 돈다")
    }

    /// 대칭 케이스 — height 만 문자열.
    func testOrthoStringHeightWithNumericWidthRejectsBoth() throws {
        let d = try doc(general(#"{"width":800,"height":"600"}"#))
        XCTAssertEqual(d.projectionWidth, 1920, "height 가 태그 4 면 width 스토어도 안 돈다")
        XCTAssertEqual(d.projectionHeight, 1080)
    }

    /// 바인딩 객체(태그 7)도 숫자가 아니다.
    func testOrthoBindingObjectRejected() throws {
        let d = try doc(general(#"{"width":{"value":800},"height":{"value":600}}"#))
        XCTAssertEqual(d.projectionWidth, 1920)
        XCTAssertEqual(d.projectionHeight, 1080)
    }

    /// `auto:true` 는 종전대로 width/height 를 **읽지 않는다**(`0x140187565` → `0x14018756D` 점프).
    func testOrthoAutoStillSkipsSize() throws {
        let d = try doc(general(#"{"auto":true,"width":800,"height":600}"#))
        XCTAssertTrue(d.orthoAuto)
        XCTAssertEqual(d.projectionWidth, 1920)
        XCTAssertEqual(d.projectionHeight, 1080)
    }

    // MARK: - #2/#3 SceneLayer.scaleZ · angleX/angleY

    private let model = #"{"width":1920,"height":1080,"material":"materials/m.json"}"#
    private let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#

    private func layerPkg(_ body: String) throws -> SceneDocument {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"10 20 30","visible":true\(body)}]}
        """
        return try SceneDocument.parse(package: pkg([
            ("scene.json", scene), ("models/x.json", model), ("materials/m.json", material),
        ]))
    }

    /// `"sx sy sz"` 의 3성분째가 `scaleZ` 로 살아남는다(종전엔 통째로 사라졌다).
    func testLayerScaleZPreserved() throws {
        let d = try layerPkg(#","scale":"2 3 4""#)
        XCTAssertEqual(d.layers.count, 1)
        XCTAssertEqual(d.layers[0].scale, Vec2(x: 2, y: 3), "기존 Vec2 는 그대로 — 무회귀")
        XCTAssertEqual(d.layers[0].scaleZ, 4, accuracy: 1e-6)
    }

    /// `angles` 의 x·y 가 살아남는다(라디안 그대로 — 스크립트 경계의 도(度) 변환과 무관).
    func testLayerAnglesXYPreserved() throws {
        let d = try layerPkg(#","angles":"0.25 0.5 0.75""#)
        XCTAssertEqual(d.layers[0].angleX, 0.25, accuracy: 1e-6)
        XCTAssertEqual(d.layers[0].angleY, 0.5, accuracy: 1e-6)
        XCTAssertEqual(d.layers[0].angleZ, 0.75, accuracy: 1e-6, "종전 z 규약은 안 바뀐다")
    }

    /// **무회귀 기본값** — 키 부재 시 `scaleZ` 1 · `angleX/Y` 0. 동봉 씬 대다수가 이 경로다.
    func testLayerTransformComponentDefaults() throws {
        let d = try layerPkg("")
        XCTAssertEqual(d.layers[0].scaleZ, 1)
        XCTAssertEqual(d.layers[0].angleX, 0)
        XCTAssertEqual(d.layers[0].angleY, 0)
    }

    /// 2성분 저작(`"2 3"`)은 z 를 만들지 않는다 — 실물 vec3 주입기도 읽어낸 성분만 덮는다.
    func testLayerTwoComponentScaleKeepsDefaultZ() throws {
        let d = try layerPkg(#","scale":"2 3""#)
        XCTAssertEqual(d.layers[0].scale, Vec2(x: 2, y: 3))
        XCTAssertEqual(d.layers[0].scaleZ, 1)
    }

    /// `shape:"quad"` 이펙트 캐리어(`effectQuadLayer`)도 같은 공통 디스크립터 표를 탄다.
    /// **도달 0 이 아니다** — 동봉·설치본 shape 쿼드는 각 3개뿐인데 전건이 3성분 `scale` 이고
    /// z≠1 이다(lightshafts 프리뷰 1.20791 / 2.03800 / 2.09076).
    func testEffectQuadLayerKeepsScaleZAndAnglesXY() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":3,"shape":"quad","scale":"2.038 2.038 2.038","angles":"0.1 0.2 0.3",
                     "effects":[{"file":"effects/lightshafts/effect.json","passes":[{}]}]}]}
        """
        let d = try SceneDocument.parse(package: pkg([("scene.json", scene)]))
        let q = try XCTUnwrap(d.layers.first)
        XCTAssertEqual(q.scaleZ, 2.038, accuracy: 1e-5)
        XCTAssertEqual(q.angleX, 0.1, accuracy: 1e-6)
        XCTAssertEqual(q.angleY, 0.2, accuracy: 1e-6)
        XCTAssertEqual(q.angleZ, 0.3, accuracy: 1e-6)
    }

    // MARK: - #2/#3/#4 SceneTextLayer

    private func textPkg(_ body: String) throws -> SceneDocument {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":7,"text":"hi","origin":"10 20 30"\(body)}]}
        """
        return try SceneDocument.parse(package: pkg([("scene.json", scene)]))
    }

    /// 텍스트도 같은 공통 디스크립터를 타므로 scale z · angles x/y 를 보존한다.
    func testTextScaleZAndAnglesXY() throws {
        let d = try textPkg(#","scale":"2 3 4","angles":"0.1 0.2 0.3""#)
        XCTAssertEqual(d.texts.count, 1)
        XCTAssertEqual(d.texts[0].scale, Vec2(x: 2, y: 3))
        XCTAssertEqual(d.texts[0].scaleZ, 4, accuracy: 1e-6)
        XCTAssertEqual(d.texts[0].angleX, 0.1, accuracy: 1e-6)
        XCTAssertEqual(d.texts[0].angleY, 0.2, accuracy: 1e-6)
        XCTAssertEqual(d.texts[0].angleZ, 0.3, accuracy: 1e-6)
    }

    /// **`parallaxDepth` 는 텍스트에만 없던 필드였다** — 워크샵 텍스트 1,597 중 956 이 저작한다.
    func testTextParallaxDepthParsed() throws {
        let d = try textPkg(#","parallaxDepth":"0.25 0.5""#)
        XCTAssertEqual(d.texts[0].parallaxDepth, Vec2(x: 0.25, y: 0.5))
    }

    /// 음수 시차(워크샵 실측 184건)도 그대로 실린다 — 클램프하지 않는다.
    func testTextParallaxDepthNegativePreserved() throws {
        let d = try textPkg(#","parallaxDepth":"-1 -2""#)
        XCTAssertEqual(d.texts[0].parallaxDepth, Vec2(x: -1, y: -2))
    }

    /// **무회귀 기본값** — 키 부재 시 (1,1). 동봉·설치본 텍스트 3/3 건이 명시하는 값과 같다.
    func testTextParallaxDepthDefaultsToOne() throws {
        let d = try textPkg("")
        XCTAssertEqual(d.texts[0].parallaxDepth, Vec2(x: 1, y: 1))
        XCTAssertEqual(d.texts[0].scaleZ, 1)
        XCTAssertEqual(d.texts[0].angleX, 0)
        XCTAssertEqual(d.texts[0].angleY, 0)
    }

    /// 1성분만 있는 저작은 vec2 를 못 만든다 — 레이어/파티클/스프라이트와 **같은** 규약(무회귀 대칭).
    func testTextParallaxDepthSingleComponentKeepsDefault() throws {
        let d = try textPkg(#","parallaxDepth":"0.5""#)
        XCTAssertEqual(d.texts[0].parallaxDepth, Vec2(x: 1, y: 1))
    }
}
