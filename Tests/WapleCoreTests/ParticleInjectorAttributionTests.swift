import XCTest
@testable import WapleCore

/// 원소별 기본값 주입기 역검증 2차 — 귀속을 **원소 이름 strcmp 까지** 사슬로 잇고 읽은 상수들.
/// 사슬: 주입 호출부 → 감싸는 주입기 함수(= xref 가 있는 `.pdata` 조각 시작) → 그 함수의 호출부 →
/// 그 앞을 지배하는 `stricmp`(0x1402c10d0) 의 문자열 리터럴.
final class ParticleInjectorAttributionTests: XCTestCase {
    private func json(_ s: String) -> [String: Any] {
        (try! JSONSerialization.jsonObject(with: Data(s.utf8))) as! [String: Any]
    }

    // MARK: - turbulence vs turbulentvelocityrandom (귀속 혼동 방지)

    /// **두 원소는 다른 주입기다.** `timescale`/`scale` 1.0/1.0 은 0x1401bb030
    /// (= turbulentvelocityrandom, 게이트 `stricmp`@0x1401c874f)의 것이고,
    /// `turbulence` 의 주입기는 0x1401beb80(게이트 `stricmp`@0x1401cd423)이다.
    /// 인접 주소로 귀속하면 이 두 줄이 서로 바뀐다 — 그 회귀를 막는 테스트다.
    func testTurbulenceAndTurbulentVelocityRandomDoNotShareDefaults() {
        let d = ParticleSystemDef.parse(json("""
        {"initializer":[{"name":"turbulentvelocityrandom"}],
         "operator":[{"name":"turbulence"}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        guard case let .turbulentVelocityRandom(tvSpeedMin, tvSpeedMax, tvScale, tvOffset) = d.initializers[0] else {
            return XCTFail("turbulentvelocityrandom 파스 실패")
        }
        XCTAssertEqual(tvScale, 1, "0x1401bb338 — 1.0 은 **이쪽** 원소의 상수다")
        XCTAssertEqual(tvOffset, 0, "0x1401bb34a")
        XCTAssertEqual(tvSpeedMin, 100, "0x1401bb07b (ortho 분기)")
        XCTAssertEqual(tvSpeedMax, 250, "0x1401bb14d (ortho 분기)")

        guard case let .turbulence(tSpeedMin, tSpeedMax, tScale, tTimeScale, tMask, _, _) = d.operators[0] else {
            return XCTFail("turbulence 파스 실패")
        }
        XCTAssertEqual(tScale, 0.01, "0x1401becc5 (ortho) — turbulentvelocityrandom 의 1.0 이 아니다")
        XCTAssertEqual(tTimeScale, 20, "0x1401bebd4 (ortho). 0 은 양쪽 분기 어디에도 없다")
        XCTAssertEqual(tSpeedMin, 500, "0x1401bed85 (ortho)")
        XCTAssertEqual(tSpeedMax, 1000, "0x1401bee64 (ortho)")
        XCTAssertEqual(tMask, Vec3(x: 1, y: 1, z: 0), "0x1401bec98 — ortho 는 z 를 잠근다")
    }

    /// `timescale` 기본이 0 이 아님을 단독으로 못 박는다(정적장 ↔ 흐르는 장의 차이).
    func testTurbulenceTimeScaleDefaultIsNotZero() {
        let d = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"turbulence","speedmin":10,"speedmax":20}],"maxcount":10}"#), material: nil)
        guard case let .turbulence(_, _, _, timeScale, _, _, _) = d.operators[0] else { return XCTFail("no turbulence") }
        XCTAssertNotEqual(timeScale, 0, "ortho 20.0(0x1401bebb1) / 원근 1.0(xmm7@0x1401beba5) — 0 분기는 없다")
    }

    // MARK: - hsvcolorrandom (6필드 중 4필드 정정)

    /// 전 필드 부재 시 채도·명도는 **[0.5, 1] 무작위**다(종전 [1,1] 고정).
    /// 주입기 0x1401ba3e0, 게이트 `stricmp`@0x1401c783a → 호출부 0x1401c786d.
    func testHSVColorRandomAllFieldsMissingUsesInjectorConstants() {
        let d = ParticleSystemDef.parse(json(#"{"initializer":[{"name":"hsvcolorrandom"}]}"#), material: nil)
        XCTAssertTrue(d.initializers.contains(.hsvColorRandom(
            hueMin: 0, hueMax: 1, satMin: 0.5, satMax: 1, valMin: 0.5, valMax: 1,
            hueSteps: 6, hueNoise: 0, satNoise: 0, valNoise: 0)),
            "0x1401ba669(sat 0.5) · 0x1401ba6f0(val 0.5) · 0x1401ba56d(huesteps 6)")
    }

    /// **max 는 min 을 승계하지 않는다** — 둘 다 독립 상수다.
    /// saturationmin 만 준 자산은 [min, 1] 이지 [min, min] 이 아니다.
    func testHSVColorRandomMaxDoesNotInheritMin() {
        let d = ParticleSystemDef.parse(json(
            #"{"initializer":[{"name":"hsvcolorrandom","saturationmin":0.2,"valuemin":0.3}]}"#), material: nil)
        guard case let .hsvColorRandom(_, _, satMin, satMax, valMin, valMax, _, _, _, _) = d.initializers[0] else {
            return XCTFail("no hsvcolorrandom")
        }
        XCTAssertEqual(satMin, 0.2); XCTAssertEqual(satMax, 1, "0x1401ba6d9 — 승계면 0.2 였을 것")
        XCTAssertEqual(valMin, 0.3); XCTAssertEqual(valMax, 1, "0x1401ba716 — 승계면 0.3 였을 것")
    }

    // MARK: - 직교투영 분기

    /// `oscillateposition.scalemax` 는 직교투영 씬에서 10.0 이다(0x1401bd8b5).
    /// 그 조건은 JSON `flags` 가 아니라 `scene.general.orthogonalprojection` 이다 —
    /// 접근자 0x14010daa0(`[rcx+0x118]>>10&1`), 세터 0x14018768a.
    func testOscillatePositionScaleMaxUsesOrthogonalBranch() {
        let d = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"oscillateposition"}],"maxcount":10}"#), material: nil)
        guard case let .oscillatePosition(_, _, _, scaleMax, _, _, _) = d.operators[0] else {
            return XCTFail("no oscillateposition")
        }
        XCTAssertEqual(scaleMax, 10, "동봉 scene.json 355개 중 347개가 ortho — 원근 분기는 0.5")
    }

    // MARK: - 단일 원소 귀속 (자매 원소로 번지지 않아야)

    /// `centerforce` 를 심는 것은 **vortex_v2 뿐**이다(0x1401bf5ff). 자매 `vortex` 의 주입기
    /// 0x1401bef00 에는 그 문자열조차 없다 — 둘을 같이 고치면 vortex 가 회귀한다.
    func testCenterForceDefaultAppliesToVortexV2Only() {
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"vortex"},{"name":"vortex_v2"}],"maxcount":10}
        """), material: nil)
        guard case let .vortex(_, _, _, _, _, _, cfV1, _, _, _, _) = d.operators[0] else { return XCTFail("no vortex") }
        guard case let .vortex(_, _, _, _, _, _, cfV2, _, _, _, _) = d.operators[1] else { return XCTFail("no vortex_v2") }
        XCTAssertEqual(cfV1, 0, "vortex 주입기 0x1401bef00 은 centerforce 를 안 심는다")
        XCTAssertEqual(cfV2, 1, "vortex_v2 주입기 0x1401bf5ff 이 1.0 을 심는다")
    }

    /// `distancemax` 를 심는 이미터는 sphererandom 과 boxrandom 뿐이고 `layerimage` 주입기
    /// 0x1401b9930 에는 없다 — 셋을 뭉뚱그리면 layerimage 가 회귀한다.
    ///
    /// **둘 다 직교/원근 조건부고, 실측 동작은 직교(씬의 98.8%)다:**
    ///   · sphererandom: 256(0x1401b9454) / 1.0(0x1401b945e)
    ///   · boxrandom:    "256 256 0"(0x1401b981d) / "1 1 1"(0x1401b971b), `cmovne` @0x1401b9831
    /// boxrandom 의 z=0 은 직교 서사와 맞는다(turbulence 의 mask "1 1 0" 과 같은 이유).
    func testEmitterDistanceMaxDefaultsDifferPerEmitter() {
        let d = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"sphererandom","rate":1},{"name":"boxrandom","rate":1},{"name":"layerimage","rate":1}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        guard case let .sphere(_, _, _, sphereMax, _, _, _) = d.emitters[0] else { return XCTFail("no sphere") }
        XCTAssertEqual(sphereMax, 256, "0x1401b9470 (ortho) — 원근은 1.0, 어느 쪽도 0 이 아니다")
        guard case let .box(_, boxMax, _, _) = d.emitters[1] else { return XCTFail("no box") }
        XCTAssertEqual(boxMax, Vec3(x: 256, y: 256, z: 0),
                       "0x1401b981d 직교 분기 — 원근 \"1 1 1\" 을 고르면 98.8% 의 씬에서 틀린다")
        guard case let .box(_, layerMax, _, _) = d.emitters[2] else { return XCTFail("no layerimage box") }
        XCTAssertEqual(layerMax, Vec3(x: 0, y: 0, z: 0), "layerimage 주입기엔 distancemax 가 **없다**")
        XCTAssertEqual(d.emitterSpeed[2], SIMD2<Float>(0.1, 0.2), "0x1401b9a5d / 0x1401b9b1b — layerimage 만 speed 기본이 0 이 아니다")
    }

    // MARK: - 정수 주입기 (0x1401d7be0)

    /// `mapsequence*` 의 `count` 부재 기본은 0 이 아니라 32 다(인라인 정수 주입
    /// 0x1401bbcaf / 0x1401bc09f). 0 이면 시퀀스 매핑이 통째로 죽는다.
    func testMapSequenceCountDefaultsTo32() {
        let d = ParticleSystemDef.parse(json("""
        {"initializer":[{"name":"mapsequencearoundcontrolpoint"},{"name":"mapsequencebetweencontrolpoints"}]}
        """), material: nil)
        XCTAssertTrue(d.initializers.contains { if case .mapSequence(32, false, false) = $0 { return true }; return false })
        XCTAssertTrue(d.initializers.contains { if case .mapSequence(32, false, true) = $0 { return true }; return false })
    }
}
