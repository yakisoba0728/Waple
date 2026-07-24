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

        // rainfall 실측값: 하한 5 — 느린 파티클은 5배 하한.
        let fall = RendererKind.spriteTrail(maxLength: 20, length: 0, minLength: 5)
        XCTAssertEqual(fall.spriteTrailStretch(speed: 1), 5, accuracy: 1e-6)
        XCTAssertEqual(fall.spriteTrailStretch(speed: 10), 10, accuracy: 1e-6)
        XCTAssertEqual(fall.spriteTrailStretch(speed: 100), 20, accuracy: 1e-6)
    }

    func testStretchAbsentFieldDefaults() {
        // length 부재 → 곱 항등 1 (Cherry_Blossoms_2: 속도≥1 이면 상한 1 에 고정 — 회전만).
        let petal = RendererKind.spriteTrail(maxLength: 1, length: 0, minLength: 0)
        XCTAssertEqual(petal.spriteTrailStretch(speed: 40), 1, accuracy: 1e-6)

        // maxlength 부재 → 1 (ember 실측 length=0.007: 신장 0.7–1.05 → ≤1 클램프, 1 미만 축소 허용).
        let ember = RendererKind.spriteTrail(maxLength: 0, length: 0.007, minLength: 0)
        XCTAssertEqual(ember.spriteTrailStretch(speed: 100), 0.7, accuracy: 1e-6)
        XCTAssertEqual(ember.spriteTrailStretch(speed: 150), 1, accuracy: 1e-6)

        // 전부재 → 상한 1 중립(상한 개방이면 신장=속도 그대로 수백 배 붕괴 — 실측 6씬 방어).
        let bare = RendererKind.spriteTrail(maxLength: 0, length: 0, minLength: 0)
        XCTAssertEqual(bare.spriteTrailStretch(speed: 300), 1, accuracy: 1e-6)
        XCTAssertEqual(bare.spriteTrailStretch(speed: 0.4), 0.4, accuracy: 1e-6)
    }

    func testStretchNonSpriteTrailIsIdentity() {
        XCTAssertEqual(RendererKind.sprite.spriteTrailStretch(speed: 100), 1)
        XCTAssertEqual(RendererKind.rope(subdivision: 4).spriteTrailStretch(speed: 100), 1)
        XCTAssertEqual(RendererKind.ropeTrail(length: 2, subdivision: 4).spriteTrailStretch(speed: 100), 1)
    }
}
