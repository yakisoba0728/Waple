import XCTest
@testable import WapleCore

/// X-⑪ (G-A5-07/G-B2-05): `conditions` 평가기. 원본 `0x1401e63b0`(1,478 B) 실측 규약.
///
/// 실물 도달은 `fluidsimulation` 하나이고 그 안에 8건 있다 — fbo `_rt_SmokeNormal`,
/// 패스 16(`fluidsimulation_normal`), 그리고 패스 17 의 bind 2건.
final class EffectConditionsTests: XCTestCase {

    private func parse(_ json: String) -> EffectManifest.Conditions? {
        EffectManifest.parseConditions(try? JSONSerialization.jsonObject(with: Data(json.utf8)))
    }

    // MARK: 맨몸 값은 등호다

    /// **`!=0` 도 `>=` 도 아니고 정확히 `==` 다**(`0x1401e68c3` `cmp` + `cmove`).
    /// 이게 중요한 이유: `RENDERING` 은 0/1/2/3 옵션 콤보라, `>=` 였다면 1·2 에서도 켜졌을 것이다.
    func testBareValueIsEquality() {
        let c = parse(#"[{"RENDERING": 3}]"#)
        XCTAssertTrue(EffectManifest.evaluate(c, combos: ["RENDERING": 3]))
        XCTAssertFalse(EffectManifest.evaluate(c, combos: ["RENDERING": 1]), "!=0 이었다면 통과했을 것")
        XCTAssertFalse(EffectManifest.evaluate(c, combos: ["RENDERING": 2]))
        XCTAssertFalse(EffectManifest.evaluate(c, combos: ["RENDERING": 4]), ">= 였다면 통과했을 것")
        XCTAssertFalse(EffectManifest.evaluate(c, combos: [:]), "부재 콤보는 0")
    }

    /// 실수 값은 **0 방향 절삭 후** 정수 등호(`cvttsd2si`).
    func testRealValueTruncatesTowardZero() {
        XCTAssertTrue(EffectManifest.evaluate(parse(#"[{"A": 1.9}]"#), combos: ["A": 1]))
        XCTAssertFalse(EffectManifest.evaluate(parse(#"[{"A": 1.9}]"#), combos: ["A": 2]))
        XCTAssertTrue(EffectManifest.evaluate(parse(#"[{"A": -1.9}]"#), combos: ["A": -1]), "0 방향 절삭")
    }

    // MARK: 명명 연산자

    /// 4종뿐이고 형태는 `{COMBO: {op, value}}` 다. 실물 자산의 `"op"` 값은 14회 전건 `"ge"` 다.
    func testNamedOperators() {
        for (op, pass, fail) in [("ge", 3, 2), ("gt", 4, 3), ("le", 3, 4), ("lt", 2, 3)] {
            let c = parse("[{\"A\": {\"op\": \"\(op)\", \"value\": 3}}]")
            XCTAssertTrue(EffectManifest.evaluate(c, combos: ["A": pass]), "\(op): \(pass) 는 통과")
            XCTAssertFalse(EffectManifest.evaluate(c, combos: ["A": fail]), "\(op): \(fail) 는 탈락")
        }
    }

    /// **미지·부재 op 는 false 고정이 아니라 등호 폴백**이다(`0x1401e67b7`).
    /// 문자열 길이가 정확히 2 가 아니면 비교 시도조차 하지 않는다.
    func testUnknownOrMissingOperatorFallsBackToEquality() {
        for spec in [#"{"value": 3}"#, #"{"op": "eq", "value": 3}"#, #"{"op": "gte", "value": 3}"#,
                     #"{"op": "xx", "value": 3}"#, #"{"op": 7, "value": 3}"#] {
            let c = parse("[{\"A\": \(spec)}]")
            XCTAssertTrue(EffectManifest.evaluate(c, combos: ["A": 3]), "등호 폴백: \(spec)")
            XCTAssertFalse(EffectManifest.evaluate(c, combos: ["A": 4]), "false 고정이 아니다: \(spec)")
        }
    }

    /// `value` 가 숫자가 아니면 0 이다(원본 `asInt()` 가 타입 태그 1/2/3 이 아니면 0).
    func testNonNumericValueBecomesZero() {
        let c = parse(#"[{"A": {"op": "ge", "value": "3"}}]"#)
        XCTAssertTrue(EffectManifest.evaluate(c, combos: ["A": 0]), "value=0 이므로 0 >= 0")
        XCTAssertTrue(EffectManifest.evaluate(c, combos: ["A": 5]))
        XCTAssertFalse(EffectManifest.evaluate(c, combos: ["A": -1]))
    }

    // MARK: fail-open

    /// **애매하면 항상 true.** 배열이 아니거나 비었거나 키가 없으면 통과한다.
    func testFailsOpen() {
        XCTAssertTrue(EffectManifest.evaluate(nil, combos: [:]), "키 부재")
        XCTAssertTrue(EffectManifest.evaluate(parse("[]"), combos: [:]), "빈 배열")
        XCTAssertTrue(EffectManifest.evaluate(parse(#"{"A": 1}"#), combos: [:]), "배열이 아님 → nil → true")
        XCTAssertTrue(EffectManifest.evaluate(parse("3"), combos: [:]), "숫자 → nil → true")
        XCTAssertTrue(EffectManifest.evaluate(parse(#"[null, 3, "x"]"#), combos: [:]),
                      "객체가 아닌 원소는 무시 — 결과에 영향 없음")
    }

    /// 객체가 아닌 원소가 **다른 원소의 판정을 뒤집지 않는다.**
    func testNonObjectElementsDoNotAffectOtherGroups() {
        let c = parse(#"[null, {"A": 1}, "x"]"#)
        XCTAssertTrue(EffectManifest.evaluate(c, combos: ["A": 1]))
        XCTAssertFalse(EffectManifest.evaluate(c, combos: ["A": 2]))
    }

    // MARK: AND 누산

    /// 객체 안의 키끼리도, 배열 원소끼리도 전부 AND 다. OR 는 어디에도 없다.
    func testAccumulationIsAndBothWays() {
        let withinObject = parse(#"[{"A": 1, "B": 2}]"#)
        XCTAssertTrue(EffectManifest.evaluate(withinObject, combos: ["A": 1, "B": 2]))
        XCTAssertFalse(EffectManifest.evaluate(withinObject, combos: ["A": 1, "B": 3]))

        let acrossElements = parse(#"[{"A": 1}, {"B": 2}]"#)
        XCTAssertTrue(EffectManifest.evaluate(acrossElements, combos: ["A": 1, "B": 2]))
        XCTAssertFalse(EffectManifest.evaluate(acrossElements, combos: ["A": 1, "B": 3]))
        XCTAssertFalse(EffectManifest.evaluate(acrossElements, combos: ["A": 9, "B": 2]))
    }

    // MARK: 매니페스트 통합 — 실물 fluidsimulation 배치

    /// 실물 `effects/fluidsimulation/effect.json` 의 세 자리를 그대로 옮긴 픽스처.
    /// 좌변(이펙트 인스턴스 레벨 combos)이 비어 있으면 셋 다 꺼진다 — 동봉 씬이 실제로 그렇다.
    func testFluidSimulationConditionsParseOnAllThreeSites() throws {
        let json = """
        {"passes":[
           {"material":"materials/effects/fluidsimulation_normal.json","target":"_rt_SmokeNormal",
            "bind":[{"name":"_rt_SmokeDye2","index":0}],
            "conditions":[{"LIGHTING":1}]},
           {"material":"materials/effects/fluidsimulation_combine.json",
            "bind":[{"name":"_rt_SmokeDye1","index":0},
                    {"name":"_rt_SmokeNormal","index":2,"conditions":[{"LIGHTING":1}]},
                    {"name":"_rt_SmokeVelocity2","index":4,"conditions":[{"RENDERING":3}]}]}],
         "fbos":[{"name":"_rt_SmokeDye1","scale":2,"format":"rgba8888"},
                 {"name":"_rt_SmokeDye2","scale":2,"format":"rgba8888"},
                 {"name":"_rt_SmokeVelocity2","fit":256,"format":"rg1616f"},
                 {"name":"_rt_SmokeNormal","scale":2,"format":"rgba8888","conditions":[{"LIGHTING":1}]}]}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertNotNil(m.passes[0].conditions, "패스 조건")
        XCTAssertNil(m.passes[1].conditions, "조건 없는 패스는 nil")
        XCTAssertNotNil(m.fbos[3].conditions, "fbo 조건")
        XCTAssertNil(m.fbos[0].conditions)
        XCTAssertNil(m.passes[1].binds[0].conditions, "조건 없는 bind")
        XCTAssertNotNil(m.passes[1].binds[1].conditions, "bind 조건")
        XCTAssertNotNil(m.passes[1].binds[2].conditions)

        // 동봉 씬 상태: 인스턴스 combos 가 비어 있다 → LIGHTING·RENDERING 은 0 → 전부 꺼진다.
        let empty: [String: Int] = [:]
        XCTAssertFalse(EffectManifest.evaluate(m.passes[0].conditions, combos: empty))
        XCTAssertFalse(EffectManifest.evaluate(m.fbos[3].conditions, combos: empty))
        XCTAssertFalse(EffectManifest.evaluate(m.passes[1].binds[1].conditions, combos: empty))
        XCTAssertFalse(EffectManifest.evaluate(m.passes[1].binds[2].conditions, combos: empty))
        XCTAssertTrue(EffectManifest.evaluate(m.passes[1].binds[0].conditions, combos: empty),
                      "조건 없는 bind 는 항상 켜진다")

        // 조명을 켜면 fbo·패스·bind 가 **함께** 살아난다(같은 조건이라 짝이 맞는다).
        let lit = ["LIGHTING": 1]
        XCTAssertTrue(EffectManifest.evaluate(m.passes[0].conditions, combos: lit))
        XCTAssertTrue(EffectManifest.evaluate(m.fbos[3].conditions, combos: lit))
        XCTAssertTrue(EffectManifest.evaluate(m.passes[1].binds[1].conditions, combos: lit))
        XCTAssertFalse(EffectManifest.evaluate(m.passes[1].binds[2].conditions, combos: lit),
                       "RENDERING 은 별개 조건 — 조명만으로는 안 켜진다")
    }

    /// bool 은 조건 값이 될 수 없다 — 원본은 타입 태그로 갈라 무시한다.
    /// (Swift 의 NSNumber 브리징은 `true as? Int` 를 1 로 성공시키므로 명시 방어가 필요하다.)
    func testBooleanValueIsIgnoredNotTreatedAsOne() {
        let c = parse(#"[{"A": true}]"#)
        XCTAssertTrue(EffectManifest.evaluate(c, combos: [:]), "무시 → 빈 그룹 → true")
        XCTAssertTrue(EffectManifest.evaluate(c, combos: ["A": 1]))
        XCTAssertTrue(EffectManifest.evaluate(c, combos: ["A": 99]), "1 로 읽혔다면 여기서 false 였을 것")
    }
}
