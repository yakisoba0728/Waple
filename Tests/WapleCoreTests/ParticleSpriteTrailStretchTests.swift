import XCTest
@testable import WapleCore

/// F790 회귀: spritetrail WE 공식 의미(속도 방향 신장 쿼드) — minlength 파스 + 신장 공식.
/// 수치 근거: WE 공식 문서(Length=speed 곱, Min/Max Length=클램프, 1/1/1=무신장 회전)와
/// 실물 코퍼스 123건 키 조합(ember/rainrefractive/Cherry_Blossoms_2/rainfall 실측 JSON).
final class ParticleSpriteTrailStretchTests: XCTestCase {
    private func json(_ s: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: s.data(using: .utf8)!) as! [String: Any]
    }

    // MARK: - 파스 (실물 스키마)

    func testParseMinLength() {
        // rainrefractive.json 실측: minlength 가 JSON null 로 직렬화 → 부재 취급(0).
        let rr = ParticleSystemDef.parse(json(#"{"renderer":[{"name":"spritetrail","length":1,"maxlength":20,"minlength":null}],"maxcount":10}"#), material: nil)
        XCTAssertEqual(rr.renderer, .spriteTrail(maxLength: 20, length: 1, minLength: 0))

        // rainfall.json 실측: minlength 명시.
        let rf = ParticleSystemDef.parse(json(#"{"renderer":[{"name":"spritetrail","minlength":5,"maxlength":20}],"maxcount":10}"#), material: nil)
        XCTAssertEqual(rf.renderer, .spriteTrail(maxLength: 20, length: 0, minLength: 5))

        // Cherry_Blossoms_2.json 실측: maxlength 만 → 나머지 부재(0).
        let cb = ParticleSystemDef.parse(json(#"{"renderer":[{"name":"spritetrail","maxlength":1}],"maxcount":10}"#), material: nil)
        XCTAssertEqual(cb.renderer, .spriteTrail(maxLength: 1, length: 0, minLength: 0))
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

    /// H3(핫픽스, 웨이브 W0b): length 가 speed 의 유일한 승수라 length 부재 시엔 신장이 정의되지
    /// 않는다 — minlength/maxlength 만 저작돼도(예: rainfall maxlength=20/minlength=5) speed 승수
    /// 없이는 값을 산정할 근거가 없어, 이 경우 신장을 항등(1)으로 고정한다. 구법(F790 최초 재해석)은
    /// length 부재 시 "곱 항등 1"(mul=1→s=speed) 로 폴백해 씬의 전형적 속도가 그대로 [min,max] 에
    /// 밀려 들어가 사실상 항상 maxlength 로 포화됐다(3489263099 rain_on_the_glass 등 회귀 — speed
    /// 의존성이 관측 불가: spriteTrailStretch(10)==spriteTrailStretch(1000)). rainfall 도 동일 모집단
    /// (length 부재, maxlength=20)이라 이 케이스에 포함.
    func testStretchLengthAbsentIsIdentityRegardlessOfMinMax() {
        // rainfall 실측 키 구성: length 부재, minlength=5, maxlength=20 — speed 무관 항상 1.
        let fall = RendererKind.spriteTrail(maxLength: 20, length: 0, minLength: 5)
        XCTAssertEqual(fall.spriteTrailStretch(speed: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(fall.spriteTrailStretch(speed: 10), 1, accuracy: 1e-6)
        XCTAssertEqual(fall.spriteTrailStretch(speed: 100), 1, accuracy: 1e-6)

        // rain_on_the_glass 실측 키 구성: length 부재, maxlength=6 — speed 무관 항상 1(구법은 6 으로 포화).
        let glass = RendererKind.spriteTrail(maxLength: 6, length: 0, minLength: 0)
        XCTAssertEqual(glass.spriteTrailStretch(speed: 10), 1, accuracy: 1e-6)
        XCTAssertEqual(glass.spriteTrailStretch(speed: 1000), 1, accuracy: 1e-6)
    }

    func testStretchAbsentFieldDefaults() {
        // length 부재 → 신장 항등 1 (Cherry_Blossoms_2: maxlength=1 뿐이라도 회전만).
        let petal = RendererKind.spriteTrail(maxLength: 1, length: 0, minLength: 0)
        XCTAssertEqual(petal.spriteTrailStretch(speed: 40), 1, accuracy: 1e-6)

        // maxlength 부재 → 1 (ember 실측 length=0.007: 신장 0.7–1.05 → ≤1 클램프, 1 미만 축소 허용).
        let ember = RendererKind.spriteTrail(maxLength: 0, length: 0.007, minLength: 0)
        XCTAssertEqual(ember.spriteTrailStretch(speed: 100), 0.7, accuracy: 1e-6)
        XCTAssertEqual(ember.spriteTrailStretch(speed: 150), 1, accuracy: 1e-6)

        // 전부재 → 신장 항등 1(length 부재 폴백 — 속도 무관).
        let bare = RendererKind.spriteTrail(maxLength: 0, length: 0, minLength: 0)
        XCTAssertEqual(bare.spriteTrailStretch(speed: 300), 1, accuracy: 1e-6)
        XCTAssertEqual(bare.spriteTrailStretch(speed: 0.4), 1, accuracy: 1e-6)
    }

    func testStretchNonSpriteTrailIsIdentity() {
        XCTAssertEqual(RendererKind.sprite.spriteTrailStretch(speed: 100), 1)
        XCTAssertEqual(RendererKind.rope(subdivision: 4).spriteTrailStretch(speed: 100), 1)
        XCTAssertEqual(RendererKind.ropeTrail(length: 2, subdivision: 4).spriteTrailStretch(speed: 100), 1)
    }
}
