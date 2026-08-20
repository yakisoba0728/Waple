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

    // MARK: - vortex / vortex_v2 (2026-08-20: 주입기 전수 재독)

    /// `vortex` 의 세 조건부 상수. 종전 `?? 0` 은 소용돌이를 **아예 안 돌게** 만들었다:
    /// dOut(0) > dIn(0) 이 거짓 → 보간 t = 0 → speed = sIn = 0 → 접선 가속 0.
    /// 주입기 0x1401bef00..0x1401bf2c6(3조각). `speedinner` 상수를 싣는 `movss` 가
    /// **3번째 조각의 첫 명령**(0x1401bf22e)이라 조각 하나만 읽으면 통째로 안 보인다.
    func testVortexDistanceAndSpeedDefaults() {
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"name":"vortex"}],"maxcount":10}"#), material: nil)
        guard case let .vortex(axis, dIn, dOut, sIn, sOut, offset, cf, _, _, _, ring) = d.operators[0] else {
            return XCTFail("no vortex")
        }
        XCTAssertEqual(dIn, 500, "0x1401bf0e3 (원근 1.0)")
        XCTAssertEqual(dOut, 650, "0x1401bf1ad (원근 2.0)")
        XCTAssertEqual(sIn, 2500, "0x1401bf22e (원근 1.0)")
        XCTAssertEqual(sOut, 0, "0x1401bf24f `xorps xmm2,xmm2` — 플래그 무관 0.0")
        XCTAssertEqual(axis, Vec3(x: 0, y: 0, z: 1), "\"0 0 1\", 플래그 무관")
        XCTAssertEqual(offset, Vec3(x: 0, y: 0, z: 0), "\"0 0 0\", 플래그 무관")
        XCTAssertEqual(cf, 0, "`centerforce` 문자열은 이 주입기에 **없다** — 참조 2곳이 전부 v2 쪽")
        XCTAssertNil(ring, "ring 은 vortex_v2 전용이다")
    }

    /// **명시된 키는 주입되지 않는다** — `injected` 의 계약. 0 을 적었으면 0 이어야 한다.
    func testVortexExplicitZeroIsNotOverwritten() {
        let d = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"vortex","distanceinner":0,"speedinner":0}],"maxcount":10}"#), material: nil)
        guard case let .vortex(_, dIn, _, sIn, _, _, _, _, _, _, _) = d.operators[0] else { return XCTFail("no vortex") }
        XCTAssertEqual(dIn, 0, "키가 있으면 `find` 가 비-null → 주입 없음")
        XCTAssertEqual(sIn, 0)
    }

    /// vortex_v2 의 `speedouter` 는 `speedinner` 를 **승계하지 않는다**(종전 주석이 틀렸다).
    /// 주입기가 0x1401bf5e0 에서 `xorps xmm2,xmm2` 로 0.0 을 심는다.
    func testVortexV2SpeedOuterDoesNotInheritSpeedInner() {
        let d = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"vortex_v2","speedinner":700}],"maxcount":10}"#), material: nil)
        guard case let .vortex(_, _, _, sIn, sOut, _, _, _, _, _, _) = d.operators[0] else { return XCTFail("no v2") }
        XCTAssertEqual(sIn, 700)
        XCTAssertEqual(sOut, 0, "승계면 700 이었을 것 — WE 에 승계 규칙은 없다")
    }

    /// vortex_v2 는 `offset` 을 **읽지 않는다**. "offset" 문자열의 lea 참조 10곳 중
    /// v2 주입기(0x1401bf2d0..0x1401bf6f8)·v2 핸들러(0x1401cde7e..0x1401ce3f0) 안에는 없다.
    func testVortexV2IgnoresOffsetKey() {
        let d = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"vortex_v2","offset":"100 200 300"}],"maxcount":10}"#), material: nil)
        guard case let .vortex(_, _, _, _, _, offset, _, _, _, _, _) = d.operators[0] else { return XCTFail("no v2") }
        XCTAssertEqual(offset, Vec3(x: 0, y: 0, z: 0), "WE 가 무시하는 키다 — 자매 vortex 에만 있다")
        // 반대로 자매 `vortex` 는 읽어야 한다(주입기 0x1401bef1a, 핸들러 0x1401cd8e6).
        let v1 = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"vortex","offset":"100 200 300"}],"maxcount":10}"#), material: nil)
        guard case let .vortex(_, _, _, _, _, o1, _, _, _, _, _) = v1.operators[0] else { return XCTFail("no vortex") }
        XCTAssertEqual(o1, Vec3(x: 100, y: 200, z: 300), "이쪽은 실제 키다")
    }

    /// ring 4키는 **무조건 주입된다** — 0x1401bf632 의 `test sil,sil` 은 "주입 여부"가 아니라
    /// "어떤 값이냐"만 가른다(ortho 300/50/10/50 · 원근 1.0/0.25/0.05/0.2).
    /// 종전의 "키가 하나도 없으면 ring = nil" 은 WE 에 대응물이 없는 상태였다.
    func testVortexV2RingIsAlwaysInjected() {
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"name":"vortex_v2"}],"maxcount":10}"#), material: nil)
        guard case let .vortex(_, _, _, _, _, _, _, _, _, _, ring) = d.operators[0] else { return XCTFail("no v2") }
        XCTAssertEqual(ring, VortexRing(radius: 300, pullDistance: 50, pullForce: 10, width: 50),
                       "0x1401bf637 / 0x1401bf644 / 0x1401bf65e / xmm6@0x1401bf6b5 (ortho 분기)")
    }

    /// 부분 지정도 나머지가 주입된다 — 실코퍼스의 vortex_v2 3건이 정확히 이 형태다
    /// (radius/pulldistance/width 는 적고 `ringpullforce` 만 생략).
    func testVortexV2RingPartialKeysStillInjectTheRest() {
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"vortex_v2","ringradius":120,"ringwidth":8}],"maxcount":10}
        """), material: nil)
        guard case let .vortex(_, _, _, _, _, _, _, _, _, _, ring) = d.operators[0] else { return XCTFail("no v2") }
        XCTAssertEqual(ring?.radius, 120)
        XCTAssertEqual(ring?.width, 8)
        XCTAssertEqual(ring?.pullDistance, 50, "부재 → 주입")
        XCTAssertEqual(ring?.pullForce, 10, "부재 → 주입. 종전엔 0 이라 링이 통째로 불활성이었다")
    }

    // MARK: - controlpointattract (키 이름 정정)

    /// 대상 좌표의 실물 키는 `origin` 이 아니라 **`offset`** 이다. "origin" 의 lea 참조 14곳 중
    /// 이 원소의 주입기(0x1401bdee0..0x1401be293)·핸들러(0x1401cc9e7..0x1401ccdba)에는 없고,
    /// "offset" 은 양쪽(0x1401bdefa·0x1401cca18)에 있다.
    func testControlPointAttractReadsOffsetNotOrigin() {
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"controlpointattract","offset":"10 20 30","origin":"99 99 99"}],"maxcount":10}
        """), material: nil)
        guard case let .controlPointAttract(_, _, target, _) = d.operators[0] else { return XCTFail("no cpa") }
        XCTAssertEqual(target, Vec3(x: 10, y: 20, z: 30), "`origin` 을 읽으면 (99,99,99) 가 나온다")
    }

    /// `scale`/`threshold` 부재 기본은 0 이 아니라 512 다(0x140492934, 원근 20.0/5.0).
    /// 동봉 `presets/bubbles/…/bubbles1.json` 이 `threshold` 를 생략하는 실사례다.
    func testControlPointAttractScaleAndThresholdDefaults() {
        let d = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"controlpointattract"}],"maxcount":10}"#), material: nil)
        guard case let .controlPointAttract(scale, threshold, _, _) = d.operators[0] else { return XCTFail("no cpa") }
        XCTAssertEqual(scale, 512, "0x140492934")
        XCTAssertEqual(threshold, 512, "0x140492934")
        // 명시된 0 은 유지된다 — 동봉 magic_focus.json 이 `scale: 0` 을 쓴다.
        let z = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"controlpointattract","scale":0}],"maxcount":10}"#), material: nil)
        guard case let .controlPointAttract(s0, _, _, _) = z.operators[0] else { return XCTFail("no cpa") }
        XCTAssertEqual(s0, 0, "키가 있으면 주입되지 않는다")
    }
}
