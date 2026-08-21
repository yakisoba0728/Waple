import XCTest
import Foundation
@testable import WapleCore

/// `RemapValueMath` — `remapvalue` 값 산출 산술의 오라클 대조.
///
/// 이 클래스가 존재하는 이유: 이 산술은 `ParticleSimulator.remapEval` 안에 파티클 상태와
/// 얽혀 있어서 종전에는 **입력 범위·클램프·파형을 따로 잠글 방법이 없었다.** 실제로 그 자리에
/// 세 가지 이탈이 살아 있었고(문서 §10.8 의 D1·D2·D3), 어느 테스트도 안 잡았다.
///
/// 근거는 전부 `docs/re/remap-operation.md` §10 이고, 아래 주석의 VA 는 기계로 명령 경계를
/// 대조한 것이다.
final class RemapOperationMathTests: XCTestCase {

    // MARK: - 입력 범위 정규화

    /// 정방향 — 폭 50 의 실물 자산 값(프리뷰 씬 `inputrangemin:150` / `inputrangemax:200`).
    func testNormalizeForwardRange() {
        XCTAssertEqual(RemapValueMath.normalize(150, min: 150, max: 200), 0, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.normalize(175, min: 150, max: 200), 0.5, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.normalize(200, min: 150, max: 200), 1, accuracy: 1e-6)
        // 범위 밖은 잘리지 않는다 — 자르는 것은 flags bit0 뿐이다.
        XCTAssertEqual(RemapValueMath.normalize(250, min: 150, max: 200), 2, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.normalize(100, min: 150, max: 200), -1, accuracy: 1e-6)
    }

    /// **역방향(min > max)에 특수 처리가 없다.** `span < 0` → 감소 함수가 될 뿐이다.
    /// 실물 코드에 `abs` 도 min/max 스왑도 없다(파스 `0x1401ceaf0` 은 순수 vec3 뺄셈).
    func testNormalizeReverseRangeJustFlipsSlope() {
        XCTAssertEqual(RemapValueMath.normalize(200, min: 200, max: 150), 0, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.normalize(175, min: 200, max: 150), 0.5, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.normalize(150, min: 200, max: 150), 1, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.normalize(160, min: 200, max: 150), 0.8, accuracy: 1e-6)
    }

    /// 퇴화 범위(min == max)는 **정확히 0 일 때만** `2^-23`(`0x34000000` @`0x1401cedf3`)로 치환된다.
    func testDegenerateInputSpanUsesTheEngineSentinel() {
        XCTAssertEqual(RemapValueMath.degenerateInputSpan,
                       Float(bitPattern: 0x3400_0000))
        XCTAssertEqual(RemapValueMath.degenerateInputSpan, 0x1p-23)
        XCTAssertEqual(RemapValueMath.inputSpan(min: 10, max: 10),
                       RemapValueMath.degenerateInputSpan)
        // 1/2^-23 = 2^23 = 8388608 — 사실상 min 에서의 계단이 된다.
        XCTAssertEqual(RemapValueMath.normalize(11, min: 10, max: 10), 8_388_608, accuracy: 1)
        XCTAssertEqual(RemapValueMath.normalize(9, min: 10, max: 10), -8_388_608, accuracy: 1)
        XCTAssertEqual(RemapValueMath.normalize(10, min: 10, max: 10), 0, accuracy: 1e-6)
        // 폭이 0 이 아니면 치환하지 않는다.
        XCTAssertEqual(RemapValueMath.inputSpan(min: 0, max: 1), 1)
        XCTAssertEqual(RemapValueMath.inputSpan(min: 1, max: 0), -1)
    }

    // MARK: - 클램프 (minps 1.0 → maxps 0)

    func testClamp01FollowsMinThenMaxOrder() {
        XCTAssertEqual(RemapValueMath.clamp01(-3), 0)
        XCTAssertEqual(RemapValueMath.clamp01(0.25), 0.25)
        XCTAssertEqual(RemapValueMath.clamp01(7), 1)
        // `minps dst, src` 는 어느 쪽이 NaN 이든 **src** 를 낸다 — 여기서 src 는 1.0 이다
        // (`0x14024510a` / `0x140245799`). 그래서 NaN 은 0 이 아니라 1 로 접힌다.
        XCTAssertEqual(RemapValueMath.clamp01(Float.nan), 1)
    }

    // MARK: - 파형 넷 (§10.4)

    /// `sine` = `0.5 − 0.5·cos(π·s·t)` — **주기가 `t` 기준 `2/s`** 다.
    /// 종전 Waple 추정(`0.5 − 0.5·cos(2π·s·t)`)은 주기를 절반으로 잡았다. `t = 1/(2s)` 에서
    /// 두 식이 **1.0 대 0.0** 으로 정반대라, 아래 첫 단언이 그 이탈을 직접 무는 자리다.
    func testSineHasHalfTheFrequencyOfTheOldGuess() {
        XCTAssertEqual(RemapValueMath.sine(0, inputScale: 2), 0, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.sine(0.25, inputScale: 2), 0.5, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.sine(0.5, inputScale: 2), 1, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.sine(1, inputScale: 2), 0, accuracy: 1e-6)
        // thunderbolt 실물: transforminputscale 6 → 수명 동안 정확히 3주기.
        XCTAssertEqual(RemapValueMath.sine(1.0 / 6, inputScale: 6), 1, accuracy: 1e-5)
        XCTAssertEqual(RemapValueMath.sine(1.0 / 3, inputScale: 6), 0, accuracy: 1e-5)
        XCTAssertEqual(RemapValueMath.sine(1.0 / 12, inputScale: 6), 0.5, accuracy: 1e-5)
    }

    /// `square` — 최근접짝수 반올림이라 `frac(u)` 가 **정확히 0.5 면 0** 이다(`roundps …, 8` @`0x14024546b`).
    func testSquareTieGoesToZero() {
        XCTAssertEqual(RemapValueMath.square(0, inputScale: 1), 0)
        XCTAssertEqual(RemapValueMath.square(0.25, inputScale: 1), 0)
        XCTAssertEqual(RemapValueMath.square(0.5, inputScale: 1), 0)     // ★ 동점 → 0
        XCTAssertEqual(RemapValueMath.square(0.75, inputScale: 1), 1)
        XCTAssertEqual(RemapValueMath.square(1.0, inputScale: 1), 0)
        XCTAssertEqual(RemapValueMath.square(1.75, inputScale: 1), 1)
        // 음수는 `trunc` + `(u<0 ? 1 : 0)` 보정이 floor 기반 frac 과 같은 값을 낸다.
        XCTAssertEqual(RemapValueMath.square(-0.25, inputScale: 1), 1)
        XCTAssertEqual(RemapValueMath.square(-0.75, inputScale: 1), 0)
    }

    /// `saw` = `frac(u)`. **부호 보정이 `u` 가 아니라 `t` 를 본다**(`0x1402454f9`) —
    /// `s < 0` 이면 square 와 갈리고 결과가 `[0,1]` 밖으로 나간다. 그것이 실물이다.
    func testSawUsesPreScaleSignAndCanLeaveUnitRange() {
        XCTAssertEqual(RemapValueMath.saw(0.25, inputScale: 2), 0.5, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.saw(0.75, inputScale: 2), 0.5, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.saw(1.0, inputScale: 2), 0, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.saw(-0.25, inputScale: 2), 0.5, accuracy: 1e-6)
        // t < 0 이면서 u > 0 인 조합: 보정이 그대로 더해져 1.5 가 된다.
        XCTAssertEqual(RemapValueMath.saw(-0.25, inputScale: -2), 1.5, accuracy: 1e-6)
    }

    /// `triangle` = `1 − |2·frac(|u|) − 1|`. `|u|` 라 음수 입력이 양수와 대칭이다.
    func testTriangleIsSymmetricAroundZero() {
        XCTAssertEqual(RemapValueMath.triangle(0, inputScale: 2), 0, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.triangle(0.125, inputScale: 2), 0.5, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.triangle(0.25, inputScale: 2), 1, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.triangle(0.5, inputScale: 2), 0, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.triangle(-0.25, inputScale: 2), 1, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.triangle(-0.125, inputScale: 2), 0.5, accuracy: 1e-6)
    }

    func testNoiseFoldIsHalfPlusHalf() {
        XCTAssertEqual(RemapValueMath.unitFromSignedNoise(-1), 0, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.unitFromSignedNoise(0), 0.5, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.unitFromSignedNoise(1), 1, accuracy: 1e-6)
    }

    // MARK: - 출력 매핑

    /// `out = (max − min)·v + min`. 역방향 출력범위는 실물 자산에 실재한다
    /// (프리뷰 씬 `outputrangemin:"1 0 0"` → `outputrangemax:"0 0 1"`).
    func testOutputMapHandlesReverseRangeByNegativeSpan() {
        XCTAssertEqual(RemapValueMath.outputMap(0, min: 1, max: 0), 1, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.outputMap(0.5, min: 1, max: 0), 0.5, accuracy: 1e-6)
        XCTAssertEqual(RemapValueMath.outputMap(1, min: 1, max: 0), 0, accuracy: 1e-6)
        // rain_screen 의 fbmnoise 항목: −5..7
        XCTAssertEqual(RemapValueMath.outputMap(0.25, min: -5, max: 7), -2, accuracy: 1e-6)
        // 폭 0(min == max)은 상수를 낸다 — 여기엔 나눗셈이 없으므로 센티넬 치환도 없다.
        XCTAssertEqual(RemapValueMath.outputMap(0.9, min: 3, max: 3), 3, accuracy: 1e-6)
    }

    // MARK: - flags 게이트

    /// bit0 = `t` 클램프 · bit1 = 최종값 클램프. 그 둘뿐이고, 상위 비트는 죽어 있다.
    func testFlagBitsGateTheTwoClampsIndependently() {
        func run(_ flags: Int) -> Float {
            RemapValueMath.evaluate(raw: 2, inputMin: 0, inputMax: 1,
                                    outputMin: 0, outputMax: 1,
                                    flags: flags, inputScale: 2, wave: nil)
        }
        XCTAssertEqual(run(0), 2, accuracy: 1e-6)   // 아무것도 안 자른다
        XCTAssertEqual(run(1), 1, accuracy: 1e-6)   // t 만 자른다
        XCTAssertEqual(run(2), 1, accuracy: 1e-6)   // 최종만 자른다
        XCTAssertEqual(run(3), 1, accuracy: 1e-6)
        // 상위 비트는 무동작 — bit0/bit1 이 같으면 결과가 같아야 한다.
        XCTAssertEqual(run(0xFFFC), run(0), accuracy: 1e-6)
        XCTAssertEqual(run(0xFFFD), run(1), accuracy: 1e-6)
    }

    /// 두 클램프가 **다른 자리**에 걸린다는 것을 구별하는 실험.
    /// 출력범위를 −5..7 로 두면 bit1 만 켠 쪽은 최종값이 잘리고, bit0 만 켠 쪽은 안 잘린다.
    func testTheTwoClampsAreNotInterchangeable() {
        func run(_ flags: Int, _ raw: Float) -> Float {
            RemapValueMath.evaluate(raw: raw, inputMin: 0, inputMax: 1,
                                    outputMin: -5, outputMax: 7,
                                    flags: flags, inputScale: 2, wave: nil)
        }
        // raw = 0.5 → t = 0.5 → out = 12·0.5 − 5 = 1.0 (둘 다 범위 안)
        XCTAssertEqual(run(0, 0.5), 1, accuracy: 1e-6)
        XCTAssertEqual(run(1, 0.5), 1, accuracy: 1e-6)
        XCTAssertEqual(run(2, 0.5), 1, accuracy: 1e-6)
        // raw = 0.1 → t = 0.1 → out = −3.8
        XCTAssertEqual(run(1, 0.1), -3.8, accuracy: 1e-5)   // bit0 은 t 만 본다 → 안 잘림
        XCTAssertEqual(run(2, 0.1), 0, accuracy: 1e-6)      // bit1 이 최종을 [0,1] 로 가둔다
    }

    // MARK: - `none` 은 transforminputscale 을 곱하지 않는다 (D1)

    /// 실물은 `transformfunction: none`(그리고 어휘 밖 센티넬)에서 변환 디스패치를 통째로
    /// 건너뛴다(`dec`+`cmp 5`+`ja` `0x140245137`–`0x14024513c` → `0x140245928`). 그래서
    /// `v = t` 이고 `transforminputscale` 이 곱해지지 않는다.
    ///
    /// 주입 기본값이 **2.0** 이므로 이 규칙을 틀리면 램프가 두 배 가팔라진다 — 아래 두 번째
    /// 단언이 그 차이를 직접 무는 자리다(0.5 대 1.0).
    func testNoneTransformIgnoresInputScale() {
        let t = RemapValueMath.evaluate(raw: 0.25, inputMin: 0, inputMax: 1,
                                        outputMin: 0, outputMax: 1,
                                        flags: RemapValueMath.InjectedDefault.flags,
                                        inputScale: RemapValueMath.InjectedDefault.transformInputScale,
                                        wave: nil)
        XCTAssertEqual(t, 0.25, accuracy: 1e-6)
        let half = RemapValueMath.evaluate(raw: 0.5, inputMin: 0, inputMax: 1,
                                           outputMin: 0, outputMax: 1,
                                           flags: 1, inputScale: 2, wave: nil)
        XCTAssertEqual(half, 0.5, accuracy: 1e-6)
    }

    // MARK: - 실물 자산 두 건 (§10.7)

    /// 동봉 `scenes/particleelementpreviews/remapvalue/…/new_particle_system.json`:
    /// `inputrangemin:150` · `inputrangemax:200` · `outputrangemin:"1 0 0"` ·
    /// `outputrangemax:"0 0 1"` · `transformfunction` 부재(none) · `transforminputscale` 부재(2.0) ·
    /// `flags` 부재(1). x 성분은 **역방향**(1 → 0), z 성분은 정방향(0 → 1)이다.
    func testBundledRemapValuePreviewSceneRamp() {
        func comp(_ raw: Float, _ lo: Float, _ hi: Float) -> Float {
            RemapValueMath.evaluate(raw: raw, inputMin: 150, inputMax: 200,
                                    outputMin: lo, outputMax: hi,
                                    flags: RemapValueMath.InjectedDefault.flags,
                                    inputScale: RemapValueMath.InjectedDefault.transformInputScale,
                                    wave: nil)
        }
        // x: 1 → 0
        XCTAssertEqual(comp(150, 1, 0), 1, accuracy: 1e-6)
        XCTAssertEqual(comp(175, 1, 0), 0.5, accuracy: 1e-6)   // ★ inputScale 을 곱하면 0 이 된다
        XCTAssertEqual(comp(200, 1, 0), 0, accuracy: 1e-6)
        // z: 0 → 1
        XCTAssertEqual(comp(150, 0, 1), 0, accuracy: 1e-6)
        XCTAssertEqual(comp(175, 0, 1), 0.5, accuracy: 1e-6)
        XCTAssertEqual(comp(200, 0, 1), 1, accuracy: 1e-6)
        // 범위 밖은 flags bit0 이 t 를 잘라 포화한다(bit1 은 꺼져 있다).
        XCTAssertEqual(comp(500, 1, 0), 0, accuracy: 1e-6)
        XCTAssertEqual(comp(0, 1, 0), 1, accuracy: 1e-6)
    }

    /// 동봉 `presets/lightning/particles/presets/thunderbolt.json`:
    /// `transformfunction:"sine"` · `transforminputscale:6` · **`flags:0`**(두 클램프 다 끔).
    /// 입력·출력 범위는 부재라 주입 기본 0..1 이다.
    func testBundledThunderboltSineFlagsZero() {
        func at(_ lifeFraction: Float) -> Float {
            RemapValueMath.evaluate(raw: lifeFraction,
                                    inputMin: RemapValueMath.InjectedDefault.inputRangeMin,
                                    inputMax: RemapValueMath.InjectedDefault.inputRangeMax,
                                    outputMin: RemapValueMath.InjectedDefault.outputRangeMin,
                                    outputMax: RemapValueMath.InjectedDefault.outputRangeMax,
                                    flags: 0, inputScale: 6,
                                    wave: RemapValueMath.sine)
        }
        XCTAssertEqual(at(0), 0, accuracy: 1e-5)
        XCTAssertEqual(at(1.0 / 6), 1, accuracy: 1e-5)
        XCTAssertEqual(at(1.0 / 3), 0, accuracy: 1e-5)
        XCTAssertEqual(at(0.5), 1, accuracy: 1e-5)
        XCTAssertEqual(at(1), 0, accuracy: 1e-5)
        // 수명 [0,1] 에 정확히 **3주기**. 봉우리 셋과 골 넷을 전부 못박는다 —
        // 종전 추정식(2π)이면 6주기라 봉우리 자리가 전부 골이 된다.
        for peak in [1.0 / 6, 0.5, 5.0 / 6] {
            XCTAssertEqual(at(Float(peak)), 1, accuracy: 1e-4)
        }
        for trough in [0.0, 1.0 / 3, 2.0 / 3, 1.0] {
            XCTAssertEqual(at(Float(trough)), 0, accuracy: 1e-4)
        }
    }

    // MARK: - 주입 기본값

    func testInjectedDefaultsMatchTheEngineInjector() {
        XCTAssertEqual(RemapValueMath.InjectedDefault.flags, 1)                  // 0x1401d809d
        XCTAssertEqual(RemapValueMath.InjectedDefault.transformInputScale, 2)    // 0x1401bffe1
        XCTAssertEqual(RemapValueMath.InjectedDefault.transformOctaves, 3)       // 0x1401bfff8
        XCTAssertEqual(RemapValueMath.InjectedDefault.inputRangeMin, 0)          // 0x1401bfc8c
        XCTAssertEqual(RemapValueMath.InjectedDefault.inputRangeMax, 1)          // 0x1401bfd76
        XCTAssertEqual(RemapValueMath.InjectedDefault.outputRangeMin, 0)         // 0x1401bfe64
        XCTAssertEqual(RemapValueMath.InjectedDefault.outputRangeMax, 1)         // 0x1401bff52
    }
}
