import XCTest
import simd
@testable import WapleCore

/// `mapsequencebetweencontrolpoints`(opid 14) / `mapsequencearoundcontrolpoint`(opid 13) 의
/// **페이로드 파스**와 **between 산술**을 실물 대조로 잠근다.
///
/// 근거는 이 저장소에서 직접 다시 뜬 것이다(함정 16 — 남의 주석을 베끼지 않았다):
///   · 이니셜라이저 점프테이블 `0x14023fa78` 13번 = `0x14023c4cf`, 14번 = `0x14023ca93`
///   · between 핸들러 `0x14023ca93`–`0x14023ce53`, 파스 `0x1401ca1cf`–`0x1401ca628`,
///     주입기 `0x1401bc080`–`0x1401bc419`
///   · around 파스 `0x1401c9930`–`0x1401ca1c2`, 주입기 `0x1401bbc90`–`0x1401bc074`
///
/// 산술·파스와 실제 스폰 경로 배선을 함께 단언한다. `MapSequenceBetweenSolver`의 선언별 상태가
/// burst와 다중 선언 사이에서 보존되는지까지 통합 테스트로 잠근다. 근거·수치는
/// `docs/re/particle-control-points.md` §9.
final class ParticleMapSequenceOracleTests: XCTestCase {

    private let eps: Float = 1e-5

    private func spec(count: Float = 32, mirror: Bool = false,
                      boundsMin: Float = 0, boundsSpan: Float = 1,
                      cpStart: Int = 0, cpEnd: Int = 1, flags: Int = 0,
                      arcAmount: Float = 0.3,
                      arcDirection: Vec3 = Vec3(x: 0, y: 1, z: 0),
                      sizeReduction: Float = 0.9) -> MapSequenceBetweenSpec {
        MapSequenceBetweenSpec(count: count, mirror: mirror,
                               boundsMin: boundsMin, boundsSpan: boundsSpan,
                               cpStart: cpStart, cpEnd: cpEnd, flags: flags,
                               arcAmount: arcAmount, arcDirection: arcDirection,
                               sizeReduction: sizeReduction)
    }

    // MARK: - 1. 스텝 — between 은 count−1, around 는 count

    /// `0x1401ca249 subss xmm0, xmm10(1.0)` → `0x1401ca24e comiss xmm14(1e-4)` →
    /// `0x1401ca29d divss` → `0x1401ca2af movss [rdi]`.
    func testStep_between_isOneOverCountMinusOne() {
        XCTAssertEqual(spec(count: 33).step, 1.0 / 32, accuracy: 1e-7)
        XCTAssertEqual(spec(count: 2).step, 1.0, accuracy: 1e-7)
        // 주입 기본 32 → 1/31.
        XCTAssertEqual(spec().step, 1.0 / 31, accuracy: 1e-7)
    }

    /// 분모 하한 1e-4(`0x1404925fc`). `count == 1` 이면 `count−1 == 0` 이라 여기가 걸린다.
    func testStep_between_denominatorFloorIs1e4() {
        XCTAssertEqual(spec(count: 1).step, 1.0 / 1e-4, accuracy: 1.0)
        // 음수 count 도 하한으로 접힌다(`comiss`/`jbe` 는 `<=` 다).
        XCTAssertEqual(spec(count: -5).step, 1.0 / 1e-4, accuracy: 1.0)
    }

    /// **around 는 `−1` 이 없다** — `0x1401c99a5` 가 `subss` 없이 곧장 `comiss xmm14` 다.
    /// 이 차이는 종전 문서에 없었다.
    func testStep_around_hasNoMinusOne() {
        let a = MapSequenceAroundSpec(count: 32, mirror: false, boundsMin: 0, boundsSpan: 1,
                                      speedMin: Vec3(x: 0, y: 0, z: 0),
                                      speedMax: Vec3(x: 0, y: 0, z: 0),
                                      axis: Vec3(x: 0, y: 0, z: 1), controlPoint: 0)
        XCTAssertEqual(a.step, 1.0 / 32, accuracy: 1e-7)
        XCTAssertNotEqual(a.step, spec(count: 32).step)
    }

    // MARK: - 2. 시퀀스 누산기 t 의 경계 동작

    /// `repeat`(기본): `t > 1` 이면 **0 으로 되감는다**(`0x14023cdcc`). 스텝 부호는 그대로.
    func testAdvance_repeatRewindsToZero() {
        var s = MapSequenceBetweenSolver(t: 0, step: 0.5)
        s.advance(mirror: false); XCTAssertEqual(s.t, 0.5, accuracy: eps)
        s.advance(mirror: false); XCTAssertEqual(s.t, 1.0, accuracy: eps)   // 1.0 은 `> 1` 이 아니다
        s.advance(mirror: false); XCTAssertEqual(s.t, 0.0, accuracy: eps)   // 1.5 > 1 → 0
        XCTAssertEqual(s.step, 0.5, accuracy: eps)
    }

    /// `mirror`: 스텝 부호를 뒤집고 `t = 1 − (t − 1)` 로 접는다(`0x14023cddb`–`0x14023cdef`).
    func testAdvance_mirrorReflectsAtUpperBound() {
        var s = MapSequenceBetweenSolver(t: 0.8, step: 0.5)
        s.advance(mirror: true)
        XCTAssertEqual(s.t, 1 - (1.3 - 1), accuracy: 1e-5)   // = 0.7
        XCTAssertEqual(s.step, -0.5, accuracy: eps)
    }

    /// 아래쪽 경계는 `mirror` 와 무관하게 항상 반사다(`0x14023ce3a`–`0x14023ce48`).
    func testAdvance_negativeAlwaysReflects() {
        var s = MapSequenceBetweenSolver(t: 0.2, step: -0.5)
        s.advance(mirror: false)
        XCTAssertEqual(s.t, 0.3, accuracy: eps)              // −0.3 → +0.3
        XCTAssertEqual(s.step, 0.5, accuracy: eps)
    }

    /// `mirror` 왕복이 실제로 왕복인지 — 여러 스텝을 돌려 궤적 전체를 고정한다.
    func testAdvance_mirrorRoundTrip() {
        var s = MapSequenceBetweenSolver(t: 0, step: 0.5)
        var seen: [Float] = []
        for _ in 0..<6 { s.advance(mirror: true); seen.append(s.t) }
        // 0 → .5 → 1 → .5(반사, step=−.5) → 0 → .5(반사, step=+.5) → 1
        let want: [Float] = [0.5, 1.0, 0.5, 0.0, 0.5, 1.0]
        XCTAssertEqual(seen.count, want.count)
        for (g, w) in zip(seen, want) { XCTAssertEqual(g, w, accuracy: 1e-5) }
    }

    /// 실물은 NaN 에서 두 `jbe` 가 **둘 다 잡혀** 아무것도 안 한다(비순서 비교).
    /// 그래서 `nt < 0` 이지 `!(0 <= nt)` 가 아니다.
    func testAdvance_nanLeavesStepUntouched() {
        var s = MapSequenceBetweenSolver(t: .nan, step: 0.5)
        s.advance(mirror: false)
        XCTAssertTrue(s.t.isNaN)
        XCTAssertEqual(s.step, 0.5, accuracy: eps)
    }

    // MARK: - 3. s(축 위 매개변수) · arc

    /// `s = boundsMin + t·boundsSpan`(`0x14023cc25` + `0x14023cc34`).
    /// `boundsSpan` 은 파스가 굽는 **차**다 — `bounds "0.25 0.75"` → (0.25, 0.5).
    func testS_isBoundsMinPlusTTimesSpan() {
        var s = MapSequenceBetweenSolver(t: 0.5, step: 0)
        let out = s.apply(position: .zero, velocity: .zero, baseSize: 1,
                          a: SIMD3(0, 0, 0), b: SIMD3(10, 0, 0),
                          spec: spec(boundsMin: 0.25, boundsSpan: 0.5),
                          systemWorldSpace: true)
        XCTAssertEqual(out.s, 0.5, accuracy: eps)             // 0.25 + 0.5·0.5
        XCTAssertEqual(out.position.x, 5.0, accuracy: 1e-4)   // s·|B−A| = 0.5·10
    }

    /// `arc = 1 − |2t − 1|²` — 중앙 최대 1, 양 끝 0(`0x14023cc46` powf / `0x14023cc53`).
    func testArc_isParabolaPeakingAtHalf() {
        for (t, want) in [(Float(0), Float(0)), (0.25, 0.75), (0.5, 1.0), (0.75, 0.75), (1.0, 0.0)] {
            var s = MapSequenceBetweenSolver(t: t, step: 0)
            let out = s.apply(position: .zero, velocity: .zero, baseSize: 1,
                              a: SIMD3(0, 0, 0), b: SIMD3(1, 0, 0),
                              spec: spec(), systemWorldSpace: true)
            XCTAssertEqual(out.arc, want, accuracy: 1e-5, "t=\(t)")
        }
    }

    // MARK: - 4. 위치 — 선분 위로 옮기고 수직 성분은 보존한다

    /// `flags = 0` 이면 수직 성분이 **그대로 살아남는다**(arc 곱이 bit0 게이트 뒤에 있다).
    func testPosition_preservesPerpendicularComponent() {
        var s = MapSequenceBetweenSolver(t: 0.5, step: 0)
        let out = s.apply(position: SIMD3(999, 7, -3), velocity: .zero, baseSize: 1,
                          a: SIMD3(0, 0, 0), b: SIMD3(10, 0, 0),
                          spec: spec(), systemWorldSpace: true)
        // 축은 +x. 축 성분(999)은 s·L = 5 로 **대체**되고, y/z 수직 성분은 그대로.
        XCTAssertEqual(out.position.x, 5, accuracy: 1e-3)
        XCTAssertEqual(out.position.y, 7, accuracy: 1e-4)
        XCTAssertEqual(out.position.z, -3, accuracy: 1e-4)
    }

    /// `flags & 1` 이면 수직 성분이 `arc` 로 줄어든다 — 끝(t=0)에서 0 이라 **정확히 축 위**로 온다.
    func testPosition_flagBit0CollapsesPerpendicularAtEnds() {
        var s = MapSequenceBetweenSolver(t: 0, step: 0)
        let out = s.apply(position: SIMD3(999, 7, -3), velocity: .zero, baseSize: 1,
                          a: SIMD3(1, 2, 3), b: SIMD3(11, 2, 3),
                          spec: spec(flags: 1), systemWorldSpace: true)
        XCTAssertEqual(out.arc, 0, accuracy: 1e-6)
        XCTAssertEqual(out.position.x, 1, accuracy: 1e-4)   // A + 0·L·d
        XCTAssertEqual(out.position.y, 2, accuracy: 1e-4)
        XCTAssertEqual(out.position.z, 3, accuracy: 1e-4)
    }

    /// 시스템 flags bit0 이 **안 서면** `p −= A` 를 건너뛴다(`0x14023cb55`) — 수직 성분의 기준이
    /// A 가 아니라 **원점을 지나는 축**이 된다. 두 경로가 실제로 갈리는지 고정한다.
    func testPosition_systemWorldSpaceGateChangesPerpendicularOrigin() {
        let p = SIMD3<Float>(0, 7, 0), a = SIMD3<Float>(0, 5, 0), b = SIMD3<Float>(10, 5, 0)
        var on = MapSequenceBetweenSolver(t: 0.5, step: 0)
        var off = MapSequenceBetweenSolver(t: 0.5, step: 0)
        let outOn = on.apply(position: p, velocity: .zero, baseSize: 1, a: a, b: b,
                             spec: spec(), systemWorldSpace: true)
        let outOff = off.apply(position: p, velocity: .zero, baseSize: 1, a: a, b: b,
                               spec: spec(), systemWorldSpace: false)
        // 켜짐: q = p − A = (0,2,0) → perp = (0,2,0) → p' = (5,7,0)
        XCTAssertEqual(outOn.position.y, 7, accuracy: 1e-4)
        // 꺼짐: q = p = (0,7,0) → perp = (0,7,0) → p' = A + (5,0,0) + (0,7,0) = (5,12,0)
        XCTAssertEqual(outOff.position.y, 12, accuracy: 1e-4)
    }

    /// 퇴화 선분(A == B)이어도 나눗셈이 터지지 않는다 — `Ls = max(L, FLT_MIN)`(`0x14023cb5d`).
    func testPosition_degenerateSegmentDoesNotDivideByZero() {
        var s = MapSequenceBetweenSolver(t: 0.5, step: 0)
        let out = s.apply(position: SIMD3(3, 4, 5), velocity: .zero, baseSize: 1,
                          a: SIMD3(1, 1, 1), b: SIMD3(1, 1, 1),
                          spec: spec(), systemWorldSpace: true)
        XCTAssertTrue(out.position.x.isFinite && out.position.y.isFinite && out.position.z.isFinite)
    }

    // MARK: - 5. flags 게이트 넷

    /// `flags & 8` — `arcamount · |B−A| · arc` 만큼 `arcdirection` 으로 휜다(`0x14023ccbd`).
    /// 기본 `flags` 가 0 이라 **기본은 꺼져 있다**.
    func testFlagBit3_arcDirectionBulge() {
        var off = MapSequenceBetweenSolver(t: 0.5, step: 0)
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(10, 0, 0)
        let noBulge = off.apply(position: .zero, velocity: .zero, baseSize: 1, a: a, b: b,
                                spec: spec(arcAmount: 0.3), systemWorldSpace: true)
        XCTAssertEqual(noBulge.position.y, 0, accuracy: 1e-5)

        var on = MapSequenceBetweenSolver(t: 0.5, step: 0)
        let bulge = on.apply(position: .zero, velocity: .zero, baseSize: 1, a: a, b: b,
                             spec: spec(flags: 8, arcAmount: 0.3), systemWorldSpace: true)
        // arc(=1) · L(=10) · 0.3 = 3, 방향 (0,1,0)
        XCTAssertEqual(bulge.position.y, 3, accuracy: 1e-4)
    }

    /// `flags & 2` — 속도에 `arc` 를 곱한다(`0x14023cd22`).
    func testFlagBit1_velocityDamping() {
        var s = MapSequenceBetweenSolver(t: 0.25, step: 0)
        let out = s.apply(position: .zero, velocity: SIMD3(4, 8, 12), baseSize: 1,
                          a: SIMD3(0, 0, 0), b: SIMD3(1, 0, 0),
                          spec: spec(flags: 2), systemWorldSpace: true)
        XCTAssertEqual(out.arc, 0.75, accuracy: 1e-5)
        XCTAssertEqual(out.velocity.x, 3, accuracy: 1e-4)
        XCTAssertEqual(out.velocity.y, 6, accuracy: 1e-4)
        XCTAssertEqual(out.velocity.z, 9, accuracy: 1e-4)
    }

    /// `flags & 4` — `size *= (1 − sr) + sr·arc`(`0x14023cd6e`–`0x14023cd9c`).
    /// `sr = 0.9` 기본이면 양 끝에서 원래의 **10%**, 중앙에서 100%.
    func testFlagBit2_sizeReduction() {
        for (t, want) in [(Float(0), Float(0.1)), (0.5, 1.0), (1.0, 0.1)] {
            var s = MapSequenceBetweenSolver(t: t, step: 0)
            let out = s.apply(position: .zero, velocity: .zero, baseSize: 4,
                              a: SIMD3(0, 0, 0), b: SIMD3(1, 0, 0),
                              spec: spec(flags: 4), systemWorldSpace: true)
            XCTAssertEqual(out.baseSize, 4 * want, accuracy: 1e-4, "t=\(t)")
        }
        // 게이트가 없으면 손대지 않는다.
        var off = MapSequenceBetweenSolver(t: 0, step: 0)
        XCTAssertEqual(off.apply(position: .zero, velocity: .zero, baseSize: 4,
                                 a: SIMD3(0, 0, 0), b: SIMD3(1, 0, 0),
                                 spec: spec(flags: 0), systemWorldSpace: true).baseSize, 4)
    }

    /// `apply` 는 꼬리에서 누산기를 **전진시킨다**(실물이 레코드를 갱신하는 자리 `0x14023cda2`).
    func testApply_advancesAccumulator() {
        var s = MapSequenceBetweenSolver(spec: spec(count: 5))   // step = 1/4
        XCTAssertEqual(s.t, 0, accuracy: eps)
        _ = s.apply(position: .zero, velocity: .zero, baseSize: 1,
                    a: SIMD3(0, 0, 0), b: SIMD3(1, 0, 0), spec: spec(count: 5), systemWorldSpace: true)
        XCTAssertEqual(s.t, 0.25, accuracy: eps)
    }

    // MARK: - 6. 파스 — 주입 기본값 전수(0x1401bc080)

    func testParse_between_injectedDefaults() {
        let def = ParticleSystemDef.parse(json("""
        {"initializer":[{"name":"mapsequencebetweencontrolpoints"}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(def.mapSequenceBetween.count, 1)
        let s = def.mapSequenceBetween[0]
        XCTAssertEqual(s.count, 32)                              // 0x1401bc0db
        XCTAssertFalse(s.mirror)                                 // "repeat" 0x1401bc2b0
        XCTAssertEqual(s.boundsMin, 0); XCTAssertEqual(s.boundsSpan, 1)   // "0 1" 0x1401bc1d0
        XCTAssertEqual(s.cpStart, 0)                             // 0x1401bc35e
        XCTAssertEqual(s.cpEnd, 1)                               // mov r8d,1 0x1401bc3a4
        XCTAssertEqual(s.flags, 0)                               // xor r8d,r8d 0x1401bc3b9 (함정 16)
        XCTAssertEqual(s.arcAmount, 0.3, accuracy: 1e-6)         // 0x1401bc3cb
        XCTAssertEqual(s.arcDirection, Vec3(x: 0, y: 1, z: 0))   // "0 1 0" 0x1401bc3e2
        XCTAssertEqual(s.sizeReduction, 0.9, accuracy: 1e-6)     // 0x1401bc3f8
    }

    func testParse_around_injectedDefaults() {
        let def = ParticleSystemDef.parse(json("""
        {"initializer":[{"name":"mapsequencearoundcontrolpoint"}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(def.mapSequenceAround.count, 1)
        let s = def.mapSequenceAround[0]
        XCTAssertEqual(s.count, 32)                                     // 0x1401bbceb
        XCTAssertFalse(s.mirror)
        XCTAssertEqual(s.boundsMin, 0); XCTAssertEqual(s.boundsSpan, 1)
        XCTAssertEqual(s.speedMin, Vec3(x: 0, y: 0, z: 0))              // "0 0 0" 0x1401bbeb3
        XCTAssertEqual(s.speedMax, Vec3(x: 0, y: 0, z: 0))              // "0 0 0" 0x1401bbf7b
        XCTAssertEqual(s.axis, Vec3(x: 0, y: 0, z: 1))                  // "0 0 1" 0x1401bbfc4
        XCTAssertEqual(s.controlPoint, 0)                               // 0x1401bbff0
    }

    /// CP 인덱스 클램프는 **부호 없는** `cmovb`(`0x1401ca435`–`0x1401ca456`) — 음수가 7 이 된다.
    func testParse_between_controlPointClampIsUnsigned() {
        let def = ParticleSystemDef.parse(json("""
        {"initializer":[{"name":"mapsequencebetweencontrolpoints",
                         "controlpointstart":-1,"controlpointend":99}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(def.mapSequenceBetween[0].cpStart, 7)
        XCTAssertEqual(def.mapSequenceBetween[0].cpEnd, 7)
    }

    /// `bounds` 는 파스가 **차를 굽는다** — `"2 5"` → (min 2, span 3).
    func testParse_between_boundsStoresSpanNotMax() {
        let def = ParticleSystemDef.parse(json("""
        {"initializer":[{"name":"mapsequencebetweencontrolpoints","bounds":"2 5"}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(def.mapSequenceBetween[0].boundsMin, 2, accuracy: 1e-6)
        XCTAssertEqual(def.mapSequenceBetween[0].boundsSpan, 3, accuracy: 1e-6)
    }

    /// 선언이 둘이면 **둘 다** 남는다(def 레벨 스칼라였다면 마지막이 이겨 start/end 를 잃는다).
    func testParse_between_multipleDeclarationsAreNotFolded() {
        let def = ParticleSystemDef.parse(json("""
        {"initializer":[{"name":"mapsequencebetweencontrolpoints","controlpointstart":1,"controlpointend":2},
                        {"name":"mapsequencebetweencontrolpoints","controlpointstart":3,"controlpointend":4}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(def.mapSequenceBetween.count, 2)
        XCTAssertEqual(def.mapSequenceBetween[0].cpStart, 1)
        XCTAssertEqual(def.mapSequenceBetween[0].cpEnd, 2)
        XCTAssertEqual(def.mapSequenceBetween[1].cpStart, 3)
        XCTAssertEqual(def.mapSequenceBetween[1].cpEnd, 4)
    }

    /// 동봉·설치 두 코퍼스의 실제 저작값 하나를 그대로 통과시킨다
    /// (`presets/lightning/particles/presets/thunderbolt.json` — `flags: 23`, `arcamount: 0.1`).
    /// `23 = 1|2|4|16` 이므로 **bit4 가 서 있다** — 런타임 핸들러는 bit4 를 안 읽지만
    /// 파스 꼬리 `0x1401ca637` 이 그 비트로 두 번째 스트림 레코드를 찍는다(효과 미확정).
    func testParse_between_corpusThunderbolt() {
        let def = ParticleSystemDef.parse(json("""
        {"initializer":[{"name":"mapsequencebetweencontrolpoints","arcamount":0.1,"flags":23}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        let s = def.mapSequenceBetween[0]
        XCTAssertEqual(s.flags, 23)
        XCTAssertEqual(s.flags & 1, 1)     // 수직 성분 수렴
        XCTAssertEqual(s.flags & 2, 2)     // 속도 감쇠
        XCTAssertEqual(s.flags & 4, 4)     // sizereductionamount
        XCTAssertEqual(s.flags & 8, 0)     // arcamount 는 **꺼져 있다**(0.1 을 적었는데도)
        XCTAssertEqual(s.arcAmount, 0.1, accuracy: 1e-6)
        XCTAssertEqual(s.count, 32)        // 미저작 → 주입 기본
    }

    /// `magic_trinity.json` 의 around 저작값 — `speedmin "0 10 0"` / `speedmax "0 100 0"`.
    /// 이 두 키는 종전 문서에서 "어디로 가는지 미확정" 이었다.
    func testParse_around_corpusMagicTrinity() {
        let def = ParticleSystemDef.parse(json("""
        {"initializer":[{"name":"mapsequencearoundcontrolpoint","bounds":"0 1","count":3.02,
                         "limitbehavior":"repeat","speedmax":"0 100 0","speedmin":"0 10 0"}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        let s = def.mapSequenceAround[0]
        XCTAssertEqual(s.count, 3.02, accuracy: 1e-5)
        XCTAssertEqual(s.speedMin, Vec3(x: 0, y: 10, z: 0))
        XCTAssertEqual(s.speedMax, Vec3(x: 0, y: 100, z: 0))
        XCTAssertFalse(s.mirror)
        XCTAssertEqual(s.step, 1.0 / 3.02, accuracy: 1e-6)   // −1 이 없다
    }

    /// `limitbehavior:"mirror"` 는 파스가 0/1 로 굽는다(`0x1401ca3ca`).
    func testParse_between_mirrorFlag() {
        let def = ParticleSystemDef.parse(json("""
        {"initializer":[{"name":"mapsequencebetweencontrolpoints","limitbehavior":"mirror","count":10}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        XCTAssertTrue(def.mapSequenceBetween[0].mirror)
        XCTAssertEqual(def.mapSequenceBetween[0].count, 10)
    }

    /// 두 이니셜라이저가 없으면 배열도 비어 있다(유령 기본값을 만들지 않는다).
    func testParse_absentLeavesArraysEmpty() {
        let def = ParticleSystemDef.parse(json("""
        {"initializer":[{"name":"sizerandom","min":1,"max":2}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        XCTAssertTrue(def.mapSequenceBetween.isEmpty)
        XCTAssertTrue(def.mapSequenceAround.isEmpty)
    }

    // MARK: - 7. 시뮬레이터 배선

    /// opid 14 레코드의 `t` 는 파티클 상태가 아니라 이니셜라이저 인스턴스 상태다. 따라서 burst 3개는
    /// 같은 solver를 차례로 소비해 CP0→CP1의 0, 1/2, 1 지점에 놓여야 한다. flags bit2의 기준 크기
    /// 쓰기(`+0x278`)도 같은 통합 경로에서 확인한다.
    func testSimulator_betweenConsumesSharedInitializerStateAcrossBurst() {
        let def = ParticleSystemDef.parse(json("""
        {"flags":1,
         "controlpoint":[{"id":0,"offset":"0 0 0"},{"id":1,"offset":"10 0 0"}],
         "emitter":[{"name":"boxrandom","rate":0,"instantaneous":3,"distancemax":"0 0 0"}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10},
                        {"name":"sizerandom","min":4,"max":4},
                        {"name":"mapsequencebetweencontrolpoints","count":3,"flags":7}],
         "renderer":[{"name":"sprite"}],"maxcount":3}
        """), material: nil)

        var sim = ParticleSimulator(def: def, seed: 401)
        let particles = sim.step(0.01)

        XCTAssertEqual(particles.count, 3)
        XCTAssertEqual(particles[0].pos.x, 0, accuracy: eps)
        XCTAssertEqual(particles[1].pos.x, 5, accuracy: eps)
        XCTAssertEqual(particles[2].pos.x, 10, accuracy: eps)
        XCTAssertEqual(particles[0].size, 0.4, accuracy: eps)
        XCTAssertEqual(particles[1].size, 4, accuracy: eps)
        XCTAssertEqual(particles[2].size, 0.4, accuracy: eps)
    }

    /// between 선언마다 독립 레코드/누산기가 있고, around 선언은 between 페이로드 배열의 인덱스를
    /// 소비하지 않는다. 두 번째 between이 마지막으로 위치를 쓰므로 최종 x는 100, 200이어야 한다.
    func testSimulator_betweenDeclarationsKeepIndependentStateAcrossAround() {
        let def = ParticleSystemDef.parse(json("""
        {"flags":1,
         "controlpoint":[{"id":0,"offset":"0 0 0"},{"id":1,"offset":"10 0 0"},
                         {"id":2,"offset":"100 0 0"},{"id":3,"offset":"200 0 0"}],
         "emitter":[{"name":"boxrandom","rate":0,"instantaneous":2,"distancemax":"0 0 0"}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10},
                        {"name":"mapsequencebetweencontrolpoints","count":2,
                         "controlpointstart":0,"controlpointend":1},
                        {"name":"mapsequencearoundcontrolpoint","count":2},
                        {"name":"mapsequencebetweencontrolpoints","count":2,
                         "controlpointstart":2,"controlpointend":3}],
         "renderer":[{"name":"sprite"}],"maxcount":2}
        """), material: nil)

        var sim = ParticleSimulator(def: def, seed: 402)
        let particles = sim.step(0.01)

        XCTAssertEqual(particles.count, 2)
        XCTAssertEqual(particles[0].pos.x, 100, accuracy: eps)
        XCTAssertEqual(particles[1].pos.x, 200, accuracy: eps)
    }

    /// opid 13은 파티클의 축 성분과 반지름을 보존하면서, 선언별 `t`를 원 둘레의 각도로 쓴다.
    /// 기본 z축에서 파서가 만든 기저는 axis=(0,0,1), tangent=(1,0,0), radial=(0,1,0)이므로
    /// `t=0,.25,.5,.75,1`은 각각 +Y,+X,−Y,−X,+Y다. 끝점 1도 실제로 한 번 소비한 뒤
    /// repeat 누산기가 `fmod(1.25, 1)=.25`로 감긴다(0x14023c63f–0x14023ca04).
    func testSimulator_aroundPlacesBurstOnBinaryCircleSequence() {
        let def = ParticleSystemDef.parse(json("""
        {"flags":1,
         "controlpoint":[{"offset":"0 0 0"}],
         "emitter":[{"name":"boxrandom","origin":"10 0 0","rate":0,
                     "instantaneous":5,"distancemax":"0 0 0"}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10},
                        {"name":"mapsequencearoundcontrolpoint","count":4,
                         "bounds":"0 1","axis":"0 0 1"}],
         "renderer":[{"name":"sprite"}],"maxcount":5}
        """), material: nil)

        var sim = ParticleSimulator(def: def, seed: 405)
        let particles = sim.step(0.01)

        XCTAssertEqual(particles.count, 5)
        let expected: [SIMD3<Float>] = [SIMD3(0, 10, 0), SIMD3(10, 0, 0),
                                        SIMD3(0, -10, 0), SIMD3(-10, 0, 0),
                                        SIMD3(0, 10, 0)]
        for (particle, want) in zip(particles, expected) {
            XCTAssertEqual(particle.pos.x, want.x, accuracy: 1e-4)
            XCTAssertEqual(particle.pos.y, want.y, accuracy: 1e-4)
            XCTAssertEqual(particle.pos.z, want.z, accuracy: 1e-4)
        }
    }

    /// opid 13의 속도 세 축은 JSON xyz를 월드 xyz에 곧장 더하지 않는다.
    /// `t=.25`, axis=+Z이면 R=+X, T=−Y이므로 로컬 (x,y,z)=(2,15,250)은
    /// `T·2 + R·15 + D·250 = (15,−2,250)`이 된다. random의 xyz는 원본 호출 순서를
    /// 재배열한 값이다: PE는 z, x, y 순으로 세 번 뽑는다(0x14023c74d/7c7/7ea).
    func testAroundVelocity_usesTangentRadialAxisAndRawMinMaxLerp() {
        let payload = MapSequenceAroundSpec(
            count: 4, mirror: false, boundsMin: 0, boundsSpan: 1,
            speedMin: Vec3(x: 1, y: 10, z: 100),
            speedMax: Vec3(x: 5, y: 20, z: 300),
            axis: Vec3(x: 0, y: 0, z: 1), controlPoint: 0)
        var solver = MapSequenceAroundSolver(t: 0.25, step: 0)
        let out = solver.apply(position: SIMD3(10, 0, 0), velocity: .zero,
                               controlPoint: .zero,
                               randomXYZ: SIMD3(0.25, 0.5, 0.75),
                               spec: payload)

        XCTAssertEqual(out.velocity.x, 15, accuracy: 1e-4)
        XCTAssertEqual(out.velocity.y, -2, accuracy: 1e-4)
        XCTAssertEqual(out.velocity.z, 250, accuracy: 1e-4)
    }

    /// 원본은 속도를 축별 scalar로 먼저 접지 않고, R→T→D 순서의 여섯 벡터 항을
    /// 순차 누적한다. 분배법칙으로 재결합하면 정상 유한 입력에서도 1 ULP가 달라진다.
    func testAroundVelocity_matchesBinaryExpandedAccumulationBits() {
        let payload = MapSequenceAroundSpec(
            count: 8, mirror: false, boundsMin: 0, boundsSpan: 1,
            speedMin: Vec3(x: Float(bitPattern: 0x41f6_5f5a), y: 0, z: 0),
            speedMax: Vec3(x: Float(bitPattern: 0x4278_a49a), y: 0, z: 0),
            axis: Vec3(x: 0, y: 0, z: 1), controlPoint: 0)
        var solver = MapSequenceAroundSolver(t: 0.125, step: 0)
        let out = solver.apply(position: SIMD3(10, 0, 0), velocity: .zero,
                               controlPoint: .zero,
                               randomXYZ: SIMD3(Float(bitPattern: 0x3f3d_9e28), 0, 0),
                               spec: payload)

        XCTAssertEqual(out.velocity.x.bitPattern, 0x4218_d056)
    }

    /// `FUN_1401c19e0`의 수직축 특이분기는 cross를 계산하지 않고 B=+X, C=+Y를
    /// 상수로 쓴다. 따라서 axis가 -Z여도 t=0의 반경 시작 방향은 +Y다.
    func testAroundNegativeVerticalAxis_usesBinaryConstantBasis() {
        let payload = MapSequenceAroundSpec(
            count: 4, mirror: false, boundsMin: 0, boundsSpan: 1,
            speedMin: Vec3(x: 0, y: 0, z: 0),
            speedMax: Vec3(x: 0, y: 0, z: 0),
            axis: Vec3(x: 0, y: 0, z: -1), controlPoint: 0)
        var solver = MapSequenceAroundSolver(t: 0, step: 0)
        let out = solver.apply(position: SIMD3(10, 0, 0), velocity: .zero,
                               controlPoint: .zero, randomXYZ: .zero,
                               spec: payload)

        XCTAssertEqual(out.position.x, 0, accuracy: 1e-4)
        XCTAssertEqual(out.position.y, 10, accuracy: 1e-4)
        XCTAssertEqual(out.position.z, 0, accuracy: 1e-4)
    }

    /// 정상축도 `v / length` 재작성은 비트동일하지 않다. 원본은 reciprocal을 한 번 만든 뒤
    /// mulss/mulps를 하고, C는 정규화 전 raw B와 cross한 뒤 별도로 정규화한다.
    func testAroundGeneralAxis_matchesBinaryBasisNormalizationBits() {
        let payload = MapSequenceAroundSpec(
            count: 1, mirror: false, boundsMin: 0, boundsSpan: 1,
            speedMin: Vec3(x: 0, y: 0, z: 0),
            speedMax: Vec3(x: 0, y: 0, z: 0),
            axis: Vec3(x: 0.1, y: 0.2, z: 0.3), controlPoint: 0)
        var solver = MapSequenceAroundSolver(t: 0, step: 0)
        let out = solver.apply(position: SIMD3(10, 0, 0), velocity: .zero,
                               controlPoint: .zero, randomXYZ: .zero,
                               spec: payload)

        XCTAssertEqual(out.position.z.bitPattern, 0xc067_6ae0)
    }

    /// 파티클 JSON `controlpoint[].angles`는 디스크립터에 저장되지만 CP 생성자가 읽지 않아
    /// identity 프레임으로 남는다. 반대로 씬 `instanceoverride.controlpointangleN`은 현재 CP 3×3을
    /// 실제로 덮고, opid 13은 그 프레임으로 D/B/C를 회전한다. +Z 90°에서 t=0의 +Y 반경은 −X가 된다.
    func testAroundFrame_usesOnlyLiveInstanceOverrideAngle() {
        let source: [String: Any] = json("""
        {"flags":1,
         "controlpoint":[{"offset":"0 0 0","angles":"0 0 1.5707964"}],
         "emitter":[{"name":"boxrandom","origin":"10 0 0","rate":0,
                     "instantaneous":1,"distancemax":"0 0 0"}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10},
                        {"name":"mapsequencearoundcontrolpoint","count":4,
                         "bounds":"0 1","axis":"0 0 1"}],
         "renderer":[{"name":"sprite"}],"maxcount":1}
        """)

        let authoredOnly = ParticleSystemDef.parse(source, material: nil)
        var authoredSim = ParticleSimulator(def: authoredOnly, seed: 406)
        let authoredParticle = authoredSim.step(0.01)[0]
        XCTAssertEqual(authoredParticle.pos.x, 0, accuracy: 1e-4)
        XCTAssertEqual(authoredParticle.pos.y, 10, accuracy: 1e-4)

        var override = ParticleInstanceOverride()
        override.controlPointAngles[0] = Vec3(x: 0, y: 0, z: .pi / 2)
        let liveOverride = ParticleSystemDef.parse(source, material: nil, instanceOverride: override)
        var overrideSim = ParticleSimulator(def: liveOverride, seed: 406)
        let overrideParticle = overrideSim.step(0.01)[0]
        XCTAssertEqual(overrideParticle.pos.x, -10, accuracy: 1e-4)
        XCTAssertEqual(overrideParticle.pos.y, 0, accuracy: 1e-4)
    }

    /// around repeat는 between의 `t=0` 리셋과 다르게 fmod로 overshoot를 보존한다.
    /// exact endpoint 1은 `>`가 아니므로 한 번 유지되고, mirror/하단 반사는 step 부호도 바꾼다.
    func testAroundAdvance_matchesFmodEndpointAndReflections() {
        var endpoint = MapSequenceAroundSolver(t: 0.75, step: 0.25)
        endpoint.advance(mirror: false)
        XCTAssertEqual(endpoint.t, 1, accuracy: eps)
        endpoint.advance(mirror: false)
        XCTAssertEqual(endpoint.t, 0.25, accuracy: eps)

        var repeatOvershoot = MapSequenceAroundSolver(t: 0.9, step: 0.35)
        repeatOvershoot.advance(mirror: false)
        XCTAssertEqual(repeatOvershoot.t, 0.25, accuracy: eps)
        XCTAssertEqual(repeatOvershoot.step, 0.35, accuracy: eps)

        var mirror = MapSequenceAroundSolver(t: 0.9, step: 0.35)
        mirror.advance(mirror: true)
        XCTAssertEqual(mirror.t, 0.75, accuracy: eps)
        XCTAssertEqual(mirror.step, -0.35, accuracy: eps)

        var lower = MapSequenceAroundSolver(t: 0.1, step: -0.35)
        lower.advance(mirror: false)
        XCTAssertEqual(lower.t, 0.25, accuracy: eps)
        XCTAssertEqual(lower.step, 0.35, accuracy: eps)

        var nan = MapSequenceAroundSolver(t: .nan, step: 0.35)
        nan.advance(mirror: false)
        XCTAssertTrue(nan.t.isNaN)
        XCTAssertEqual(nan.step, 0.35, accuracy: eps)
    }

    /// 속도 범위가 모두 0이어도 원본은 z/x/y 난수 호출 세 번을 수행한다. 뒤 이니셜라이저가
    /// 같은 스트림의 정확히 여덟 번째 값을 받는지 통합 경로에서 잠근다.
    func testSimulator_aroundConsumesThreeRandomDrawsWhenSpeedIsZero() {
        let seed: UInt64 = 407
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":0,"instantaneous":1,
                     "origin":"10 0 0","distancemax":"0 0 0"}],
         "initializer":[{"name":"mapsequencearoundcontrolpoint","count":4},
                        {"name":"lifetimerandom","min":10,"max":20}],
         "renderer":[{"name":"sprite"}],"maxcount":1}
        """), material: nil)

        var expectedRNG = SplitMix64(seed: seed)
        for _ in 0..<7 { _ = expectedRNG.nextFloat() } // box xyz + shared + around z/x/y
        let expectedLifetime = 10 + expectedRNG.nextFloat() * 10

        var sim = ParticleSimulator(def: def, seed: seed)
        let particle = sim.step(0.01)[0]
        XCTAssertEqual(particle.lifetime, expectedLifetime, accuracy: 1e-6)
    }

    // MARK: - 8. 두 번째 스트림 opcode 4 — instanceoverride.count

    /// `FUN_1401d15a0` opcode 4(`0x1401d186a`–`0x1401d189c`)는 authored count에
    /// `instanceoverride.count`를 곱한 뒤 −1/floor를 적용해 opid 14의 step을 다시 쓴다.
    /// authored 4 × override 2는 8개 점, 즉 0...7 선분의 정수 좌표 하나씩이어야 한다.
    func testSimulator_betweenBit4UsesStaticInstanceCountOverride() {
        var override = ParticleInstanceOverride()
        override.count = 2
        let def = ParticleSystemDef.parse(json("""
        {"flags":1,
         "controlpoint":[{"offset":"0 0 0"},{"offset":"7 0 0"}],
         "emitter":[{"name":"boxrandom","rate":0,"instantaneous":4,"distancemax":"0 0 0"}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10},
                        {"name":"mapsequencebetweencontrolpoints","count":4,"flags":16}],
         "renderer":[{"name":"sprite"}],"maxcount":4}
        """), material: nil, instanceOverride: override)

        var sim = ParticleSimulator(def: def, seed: 403)
        let particles = sim.step(0.01)

        XCTAssertEqual(particles.count, 8)
        for (particle, expectedX) in zip(particles, [0, 1, 2, 3, 4, 5, 6, 7] as [Float]) {
            XCTAssertEqual(particle.pos.x, expectedX, accuracy: eps)
        }
    }

    /// between flags bit4가 없으면 opcode 4 레코드 자체가 없고 authored step `1/(4−1)`을 보존한다.
    func testOpcode4Step_withoutBetweenBit4KeepsAuthoredStep() {
        let payload = spec(count: 4, flags: 0)
        XCTAssertNil(payload.opcode4Step(instanceCountMultiplier: 2, systemFlags: 0))
        XCTAssertEqual(payload.step, 1.0 / 3.0, accuracy: eps)
    }

    /// 시스템 최상위 flags bit5가 서면 팩토리 `0x1401ca62c`가 opcode 4 레코드를 생략한다.
    func testOpcode4Step_withSystemBit5KeepsAuthoredStep() {
        let payload = spec(count: 4, flags: 0x10)
        XCTAssertNil(payload.opcode4Step(instanceCountMultiplier: 2, systemFlags: 0x20))
        XCTAssertEqual(payload.step, 1.0 / 3.0, accuracy: eps)
    }

    /// opcode 4 VM은 count가 바뀔 때만 도는 알림이 아니라 시스템 업데이트마다 돈다. 따라서 mirror가
    /// 세 번째 스폰에서 step을 음수로 뒤집어도 다음 업데이트 시작에 양수 `1/(3−1)`로 돌아간다.
    func testSimulator_opcode4ResetsMirroredStepAtEveryUpdate() {
        let def = ParticleSystemDef.parse(json("""
        {"flags":1,
         "controlpoint":[{"offset":"0 0 0"},{"offset":"10 0 0"}],
         "emitter":[{"name":"boxrandom","rate":1,"distancemax":"0 0 0"}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10},
                        {"name":"mapsequencebetweencontrolpoints","count":3,"flags":16,
                         "limitbehavior":"mirror"}],
         "renderer":[{"name":"sprite"}],"maxcount":6}
        """), material: nil)

        var sim = ParticleSimulator(def: def, seed: 404)
        var newestX: [Float] = []
        for _ in 0..<5 {
            newestX.append(sim.step(1).last?.pos.x ?? .nan)
        }

        let expected: [Float] = [0, 5, 10, 5, 10]
        for (got, want) in zip(newestX, expected) {
            XCTAssertEqual(got, want, accuracy: eps)
        }
    }
}
