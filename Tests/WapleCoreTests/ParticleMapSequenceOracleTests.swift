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
/// **여기서 단언하는 것은 산술과 파스뿐이다** — `MapSequenceBetweenSolver` 는 시뮬에 배선돼
/// 있지 않다(배선하면 파티클 위치가 바뀌고, 이 컨테이너에는 Metal 이 없어 A/B 를 못 뜬다).
/// 근거·수치는 `docs/re/particle-control-points.md` §9.
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
}
