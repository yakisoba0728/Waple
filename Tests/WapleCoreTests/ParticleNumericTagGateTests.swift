import XCTest
@testable import WapleCore

/// **파티클 태그 게이트 6자리 잠금 — 그리고 나머지 223자리가 관용인 것도 함께 잠근다.**
///
/// 파티클 디스패처는 `0x1401c5490`–`0x1401d152c` 한 덩어리다(pdata 조각 9개 병합).
/// 그 안에서 `asFloat`(`0x140086220`)이 **170번**, `asInt`(`0x140085f70`)이 **59번** 불리는데
/// `call isNumeric`(`0x140088880`)은 **6번**뿐이다(인라인 전개는 이 구간에 0건).
/// 넷은 함수 진입부의 def 최상위 키다:
///
/// | 키 | 게이트 | 접근자 | 게이트 실패 시 |
/// |---|---|---|---|
/// | `starttime` | `0x1401c56b5` | `asFloat 0x1401c56c5` → `[r13+0x10]` | `xorps xmm0,xmm0` → **0.0** |
/// | `flags` | `0x1401c56d8` | `asInt 0x1401c56e4` → `[r13+8]` | `xor ecx,ecx` → **0** |
/// | `sequencemultiplier` | `0x1401c574d` | `asFloat 0x1401c5759` → `[r13+0x14]` | `movss xmm10,1.0` → **1.0** |
/// | `maxcount` | `0x1401c577f` | `asInt 0x1401c578b` → `[r13]` | `xor r15d,r15d` → **0** |
///
/// (레지스터 귀속은 진입부 `operator[]` 순서로 확정 — `material` `0x1401c5564` → rbx,
/// `starttime` `0x1401c558d` → rdi, `animationmode` `0x1401c55b6` → r14,
/// `sequencemultiplier` `0x1401c55df` → r15, `flags` `0x1401c5608` → rsi,
/// `maxcount` `0x1401c5631` → r12. 키 `lea` 는 **다음** 키를 미리 싣고 있으니 한 칸 밀려 읽으면
/// 안 된다 — 브리프 함정 16 그대로다.)
///
/// 나머지 둘은 `rotationrandom` 의 `min`/`max`(`0x1401c8d67`/`0x1401c8e90`)다 — 숫자면
/// **z 성분 전용** 스칼라, 문자열이면 "x y z" 3성분, 그 외면 미저장(0 벡터). 아래 별도 MARK.
///
/// 전수 근거는 `docs/re/json-number-tags.md`.
final class ParticleNumericTagGateTests: XCTestCase {
    private func def(_ body: String) -> ParticleSystemDef {
        ParticleSystemDef.parse(json("{\"renderer\":[{\"name\":\"sprite\"}]\(body)}"), material: nil)
    }

    // MARK: def 최상위 게이트 4자리 — 불리언은 숫자가 아니다

    func testDefMaxCountRejectsBoolean() {
        XCTAssertEqual(def(#","maxcount":true"#).maxCount, 0, "isNumeric(0x1401c577f) 실패 → 0")
        XCTAssertEqual(def(#","maxcount":false"#).maxCount, 0)
        XCTAssertEqual(def(#","maxcount":250"#).maxCount, 250, "정상 숫자는 그대로")
    }

    func testDefStartTimeRejectsBoolean() {
        XCTAssertEqual(def(#","maxcount":4,"starttime":true"#).startTime, 0,
                       "게이트 실패 분기는 xorps xmm0,xmm0 (0x1401c56cc)")
        XCTAssertEqual(def(#","maxcount":4,"starttime":false"#).startTime, 0)
        XCTAssertEqual(def(#","maxcount":4,"starttime":2.5"#).startTime, 2.5)
    }

    func testDefFlagsRejectsBoolean() {
        XCTAssertEqual(def(#","maxcount":4,"flags":true"#).flags, 0, "xor ecx,ecx (0x1401c56ee)")
        XCTAssertEqual(def(#","maxcount":4,"flags":false"#).flags, 0)
        XCTAssertEqual(def(#","maxcount":4,"flags":5"#).flags, 5)
    }

    /// 함정 15 — 게이트 실패는 **0 이 아니라 생성자/기본 상수**다. 여기서는 1.0 이다.
    func testDefSequenceMultiplierRejectsBooleanAndKeepsOne() {
        XCTAssertEqual(def(#","maxcount":4,"sequencemultiplier":true"#).sequenceMultiplier, 1,
                       "실패 분기 movss xmm10,[0x140492704] = 1.0 (0x1401c5769)")
        XCTAssertEqual(def(#","maxcount":4,"sequencemultiplier":false"#).sequenceMultiplier, 1,
                       "false 라고 0 이 되면 안 된다 — 게이트는 값을 안 쓴다")
        XCTAssertEqual(def(#","maxcount":4,"sequencemultiplier":3"#).sequenceMultiplier, 3)
    }

    // MARK: rotationrandom.min/max — 초기화자 쪽 유일한 게이트(숫자 = z 성분 전용)

    /// 숫자 분기는 `asFloat` 결과를 **z 에만** 쓴다(`movss [rbp+0xe8]` `0x1401c8d78` ·
    /// `movss [rbp+0x3d8]` `0x1401c8ea1`). x·y 는 진입부 0-초기화 그대로다.
    /// 문자열 복사(`0x1401c8e71`–`0x1401c8e87`)가 `[+0x280] → [+0xe8]` 이라 `+0xe8` = z 가 확정된다.
    func testRotationRandomNumericMinMaxLandsOnZOnly() {
        let d = def(#","maxcount":4,"initializer":[{"name":"rotationrandom","min":-0.4,"max":-0.3}]"#)
        XCTAssertTrue(d.initializers.contains(.rotationRandom(min: Vec3(x: 0, y: 0, z: -0.4),
                                                              max: Vec3(x: 0, y: 0, z: -0.3),
                                                              exponent: 1)),
                      "동봉 lightshafts 저작 형태 — 종전엔 통째로 버려져 max 가 2π 였다: \(d.initializers)")
    }

    /// 문자열 저작은 종전대로 3성분 그대로.
    func testRotationRandomStringMinMaxUnchanged() {
        let d = def(#","maxcount":4,"initializer":[{"name":"rotationrandom","min":"1 2 3","max":"4 5 6"}]"#)
        XCTAssertTrue(d.initializers.contains(.rotationRandom(min: Vec3(x: 1, y: 2, z: 3),
                                                              max: Vec3(x: 4, y: 5, z: 6),
                                                              exponent: 1)))
    }

    /// 불리언·배열은 게이트도 `isString` 도 통과 못 한다 → 아무것도 저장 안 함 → **0 벡터**.
    /// 키가 **있으므로** 주입(`0x1401bb390`)이 일어나지 않는다 — `max` 가 2π 로 돌아가면 안 된다.
    func testRotationRandomUnreadableMinMaxIsZeroNotInjectedDefault() {
        for body in [#","maxcount":4,"initializer":[{"name":"rotationrandom","min":true,"max":true}]"#,
                     #","maxcount":4,"initializer":[{"name":"rotationrandom","min":[1,2,3],"max":[4,5,6]}]"#] {
            let d = def(body)
            XCTAssertTrue(d.initializers.contains(.rotationRandom(min: Vec3(x: 0, y: 0, z: 0),
                                                                  max: Vec3(x: 0, y: 0, z: 0),
                                                                  exponent: 1)),
                          "키가 있으면 주입 없음 → 0 벡터: \(body) → \(d.initializers)")
        }
        // 부재는 반대로 주입 상수가 선다(무회귀 대조군).
        let absent = def(#","maxcount":4,"initializer":[{"name":"rotationrandom"}]"#)
        XCTAssertTrue(absent.initializers.contains(.rotationRandom(min: Vec3(x: 0, y: 0, z: 0),
                                                                   max: Vec3(x: 0, y: 0, z: 6.28318530717),
                                                                   exponent: 1)))
    }

    // MARK: 게이트가 **없는** 자리 — 실물과 같이 1/0 으로 읽는다(무회귀 잠금)

    /// `exponent` 일곱 자리는 전부 맨 `asFloat` 다(`0x1401c720f`·`0x1401c73e6`·`0x1401c7798`·
    /// `0x1401c8011`·`0x1401c82df`·`0x1401c901b`·`0x1401c967f`). 태그 5 는 1.0/0.0 이 된다.
    func testInitializerExponentKeepsBooleanLeniency() {
        let t = def(#","maxcount":4,"initializer":[{"name":"sizerandom","min":1,"max":2,"exponent":true}]"#)
        XCTAssertTrue(t.initializers.contains(.sizeRandom(min: 1, max: 2, exponent: 1)),
                      "asFloat 태그 5 → 1.0")
        let f = def(#","maxcount":4,"initializer":[{"name":"sizerandom","min":1,"max":2,"exponent":false}]"#)
        XCTAssertTrue(f.initializers.contains(.sizeRandom(min: 1, max: 2, exponent: 0)),
                      "false 는 **0.0** 이다 — 부재 기본 1 로 접으면 실물과 갈린다")
    }

    /// 같은 이름의 오퍼레이터 `flags` 는 게이트가 없다 — def 최상위와 규약이 다르다.
    /// (`movement` 의 `flags` 리더는 `0x1401cb3d3` 부근, `call isNumeric` 없음.)
    func testOperatorFlagsKeepsBooleanLeniency() {
        let d = def(#","maxcount":4,"operator":[{"name":"movement","gravity":"0 0 0","drag":0,"flags":true}]"#)
        XCTAssertTrue(d.operators.contains(.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0, flags: 1)),
                      "게이트 없는 asInt 는 태그 5 를 1 로 읽는다: \(d.operators)")
        let f = def(#","maxcount":4,"operator":[{"name":"movement","gravity":"0 0 0","drag":0,"flags":false}]"#)
        XCTAssertTrue(f.operators.contains(.movement(gravity: Vec3(x: 0, y: 0, z: 0), drag: 0, flags: 0)))
    }
}
