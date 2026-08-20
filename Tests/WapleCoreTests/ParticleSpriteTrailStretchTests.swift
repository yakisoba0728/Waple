import XCTest
@testable import WapleCore

/// F790 회귀: spritetrail WE 공식 의미(속도 방향 신장 쿼드) — minlength 파스 + 신장 공식.
/// 수치 근거: WE 공식 문서(Length=speed 곱, Min/Max Length=클램프, 1/1/1=무신장 회전)와
/// 실물 코퍼스 123건 키 조합(ember/rainrefractive/Cherry_Blossoms_2/rainfall 실측 JSON).
final class ParticleSpriteTrailStretchTests: XCTestCase {

    // MARK: - 파스 (실물 스키마)

    func testParseMinLength() {
        // rainrefractive.json 실측: minlength 가 JSON null 로 직렬화 → 부재 취급(0).
        let rr = ParticleSystemDef.parse(json(#"{"renderer":[{"name":"spritetrail","length":1,"maxlength":20,"minlength":null}],"maxcount":10}"#), material: nil)
        XCTAssertEqual(rr.renderer, .spriteTrail(maxLength: 20, length: 1, minLength: 0))

        // rainfall.json 실측: minlength 명시. **length 부재는 0 이 아니라 주입 0.05 다**
        // (주입기 0x1401c0af0 의 `movabs rcx, 0x3fa99999a0000000` @0x1401c0b55).
        let rf = ParticleSystemDef.parse(json(#"{"renderer":[{"name":"spritetrail","minlength":5,"maxlength":20}],"maxcount":10}"#), material: nil)
        XCTAssertEqual(rf.renderer, .spriteTrail(maxLength: 20, length: 0.05, minLength: 5))

        // Cherry_Blossoms_2.json 실측: maxlength 만 → length 는 주입 0.05, minlength 는 미주입(0).
        let cb = ParticleSystemDef.parse(json(#"{"renderer":[{"name":"spritetrail","maxlength":1}],"maxcount":10}"#), material: nil)
        XCTAssertEqual(cb.renderer, .spriteTrail(maxLength: 1, length: 0.05, minLength: 0))
    }

    // MARK: - 신장 공식 (WE 공식 문서)

    func testStretchDocsIdentity() {
        // 공식 문서 예시: Length/Max/Min = 1 → 어떤 속도에서도 무신장(이동 방향 회전만).
        let r = RendererKind.spriteTrail(maxLength: 1, length: 1, minLength: 1)
        XCTAssertEqual(r.spriteTrailStretch(speed: 0), 1)
        XCTAssertEqual(r.spriteTrailStretch(speed: 7.5), 1)
        XCTAssertEqual(r.spriteTrailStretch(speed: 5000), 1)
    }

    func testStretchClamps() {
        // rainrefractive 실측값: speed×1 을 [0, 20] 클램프 — 빠른 빗방울은 20배 상한.
        let rain = RendererKind.spriteTrail(maxLength: 20, length: 1, minLength: 0)
        XCTAssertEqual(rain.spriteTrailStretch(speed: 5), 5, accuracy: 1e-6)
        XCTAssertEqual(rain.spriteTrailStretch(speed: 800), 20, accuracy: 1e-6)
    }

    /// **[2026-08-20] H3 를 되돌린다.** H3 는 "length 가 speed 의 유일한 승수라 length 부재 시엔
    /// 신장이 정의되지 않는다" 며 신장을 항등 1 로 고정했다. 그 전제가 틀렸다 — 주입기
    /// 0x1401c0af0 이 부재에도 `length` 0.05(0x1401c0b55) · `maxlength` 10.0(0x1401c0c13)을
    /// 심으므로 신장은 언제나 정의된다. `minlength` 만 미주입이다.
    ///
    /// 계약은 WE 가 동봉한 셰이더 원문 그대로다(`assets/shaders/common_particles.h`):
    /// `up = normalize(v) * max(minlength, min(speed·length, maxlength))`, 그리고
    /// `ComputeParticlePosition` 이 두 축 모두에 size 를 곱하므로 그 값이 곧 size 배수다.
    ///
    /// 여기선 **파스를 거쳐** 실제 부재 기본값이 흐르게 한다 — 종전 테스트들이 `length: 0` 을
    /// 손으로 넣어 "부재" 를 흉내내는 바람에 기본값이 바뀌어도 안 깨졌다.
    func testStretchLengthAbsentUsesInjectedDefault() {
        func stretch(_ src: String, speed: Float) -> Float {
            ParticleSystemDef.parse(json(src), material: nil).renderer.spriteTrailStretch(speed: speed)
        }
        // rainfall 실측 키: length 부재(→0.05), minlength 5, maxlength 20.
        let fall = #"{"renderer":[{"name":"spritetrail","minlength":5,"maxlength":20}],"maxcount":10}"#
        XCTAssertEqual(stretch(fall, speed: 1), 5, accuracy: 1e-6, "speed·0.05=0.05 → minlength 5 가 이긴다")
        XCTAssertEqual(stretch(fall, speed: 200), 10, accuracy: 1e-6, "speed·0.05=10 — 클램프 밖")
        XCTAssertEqual(stretch(fall, speed: 5000), 20, accuracy: 1e-6, "maxlength 20 포화")

        // rain_on_the_glass 실측 키: length 부재(→0.05), maxlength 6, minlength 미저작(→0).
        let glass = #"{"renderer":[{"name":"spritetrail","maxlength":6}],"maxcount":10}"#
        XCTAssertEqual(stretch(glass, speed: 10), 0.5, accuracy: 1e-6,
                       "저속에선 1 미만 — 속도 방향으로 **납작해진다**. minlength 가 왜 있는지가 이것이다")
        XCTAssertEqual(stretch(glass, speed: 1000), 6, accuracy: 1e-6, "maxlength 6 포화")
    }

    func testStretchAbsentFieldDefaults() {
        func stretch(_ src: String, speed: Float) -> Float {
            ParticleSystemDef.parse(json(src), material: nil).renderer.spriteTrailStretch(speed: speed)
        }
        // Cherry_Blossoms_2 실측: maxlength=1 뿐 → length 0.05 주입, speed 40 이면 2 → 1 포화.
        let petal = #"{"renderer":[{"name":"spritetrail","maxlength":1}],"maxcount":10}"#
        XCTAssertEqual(stretch(petal, speed: 40), 1, accuracy: 1e-6)
        XCTAssertEqual(stretch(petal, speed: 10), 0.5, accuracy: 1e-6, "포화 전 구간은 speed 의존")

        // ember 실측: length=0.007 저작, maxlength 부재 → **10.0** 주입(종전엔 0 → 1 보정).
        let ember = #"{"renderer":[{"name":"spritetrail","length":0.007}],"maxcount":10}"#
        XCTAssertEqual(stretch(ember, speed: 100), 0.7, accuracy: 1e-6)
        XCTAssertEqual(stretch(ember, speed: 150), 1.05, accuracy: 1e-6,
                       "종전엔 maxlength 부재를 1 로 바꿔쳐 1 로 잘렸다 — 실물 상한은 10 이다")

        // 전부재 → length 0.05 · maxlength 10 · minlength 0.
        let bare = #"{"renderer":[{"name":"spritetrail"}],"maxcount":10}"#
        XCTAssertEqual(stretch(bare, speed: 300), 10, accuracy: 1e-6, "300·0.05=15 → maxlength 10 포화")
        XCTAssertEqual(stretch(bare, speed: 0.4), 0.02, accuracy: 1e-6)
    }

    func testStretchNonSpriteTrailIsIdentity() {
        XCTAssertEqual(RendererKind.sprite.spriteTrailStretch(speed: 100), 1)
        XCTAssertEqual(RendererKind.rope(subdivision: 4).spriteTrailStretch(speed: 100), 1)
        XCTAssertEqual(RendererKind.ropeTrail(length: 2, subdivision: 4).spriteTrailStretch(speed: 100), 1)
    }
}
