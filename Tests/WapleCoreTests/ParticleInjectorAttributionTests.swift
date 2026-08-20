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
        XCTAssertEqual(scaleMax, 10, "동봉 트리 171개 중 169개가 ortho — 원근 분기는 0.5")
    }

    // MARK: - 단일 원소 귀속 (자매 원소로 번지지 않아야)

    /// `centerforce` 를 심는 것은 **vortex_v2 뿐**이다(0x1401bf5ff). 자매 `vortex` 의 주입기
    /// 0x1401bef00 에는 그 문자열조차 없다 — 둘을 같이 고치면 vortex 가 회귀한다.
    func testCenterForceDefaultAppliesToVortexV2Only() {
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"vortex","flags":2},{"name":"vortex_v2","flags":2}],"maxcount":10}
        """), material: nil)
        guard case let .vortex(_, _, _, _, _, _, cfV1, _, _, _, _, _) = d.operators[0] else { return XCTFail("no vortex") }
        guard case let .vortex(_, _, _, _, _, _, cfV2, _, _, _, _, _) = d.operators[1] else { return XCTFail("no vortex_v2") }
        // 두 원소에 **같은 flags 2** 를 준다 — 게이트가 열려 있는데도 v1 이 0 이어야 한다는 게
        // 이 테스트의 요지다(주입기에 문자열조차 없다). 게이트 자체는
        // `testVortexV2CenterForceRequiresFlagsBit1` 이 따로 본다.
        XCTAssertEqual(cfV1, 0, "vortex 주입기 0x1401bef00 은 centerforce 를 안 심는다")
        XCTAssertEqual(cfV2, 1, "vortex_v2 주입기 0x1401bf5ff 이 1.0 을 심는다")
    }

    /// `distancemax` 를 심는 이미터는 sphererandom 과 boxrandom 뿐이고 `layerimage` 주입기
    /// 0x1401b9930 에는 없다 — 셋을 뭉뚱그리면 layerimage 가 회귀한다.
    ///
    /// **둘 다 직교/원근 조건부고, 실측 동작은 직교다** (동봉 트리 169/171 · 두 트리+설치본
    /// 347/355. 원근 판정 씬은 조건부 상수 원소를 아예 쓰지 않는다):
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
                       "0x1401b981d 직교 분기 — 원근 \"1 1 1\" 을 고르면 사실상 전 씬에서 틀린다")
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
        guard case let .vortex(axis, dIn, dOut, sIn, sOut, offset, cf, _, _, _, ring, _) = d.operators[0] else {
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
        guard case let .vortex(_, dIn, _, sIn, _, _, _, _, _, _, _, _) = d.operators[0] else { return XCTFail("no vortex") }
        XCTAssertEqual(dIn, 0, "키가 있으면 `find` 가 비-null → 주입 없음")
        XCTAssertEqual(sIn, 0)
    }

    /// vortex_v2 의 `speedouter` 는 `speedinner` 를 **승계하지 않는다**(종전 주석이 틀렸다).
    /// 주입기가 0x1401bf5e0 에서 `xorps xmm2,xmm2` 로 0.0 을 심는다.
    func testVortexV2SpeedOuterDoesNotInheritSpeedInner() {
        let d = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"vortex_v2","speedinner":700}],"maxcount":10}"#), material: nil)
        guard case let .vortex(_, _, _, sIn, sOut, _, _, _, _, _, _, _) = d.operators[0] else { return XCTFail("no v2") }
        XCTAssertEqual(sIn, 700)
        XCTAssertEqual(sOut, 0, "승계면 700 이었을 것 — WE 에 승계 규칙은 없다")
    }

    /// vortex_v2 는 `offset` 을 **읽지 않는다**. "offset" 문자열의 lea 참조 10곳 중
    /// v2 주입기(0x1401bf2d0..0x1401bf6f8)·v2 핸들러(0x1401cde7e..0x1401ce3f0) 안에는 없다.
    func testVortexV2IgnoresOffsetKey() {
        let d = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"vortex_v2","offset":"100 200 300"}],"maxcount":10}"#), material: nil)
        guard case let .vortex(_, _, _, _, _, offset, _, _, _, _, _, _) = d.operators[0] else { return XCTFail("no v2") }
        XCTAssertEqual(offset, Vec3(x: 0, y: 0, z: 0), "WE 가 무시하는 키다 — 자매 vortex 에만 있다")
        // 반대로 자매 `vortex` 는 읽어야 한다(주입기 0x1401bef1a, 핸들러 0x1401cd8e6).
        let v1 = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"vortex","offset":"100 200 300"}],"maxcount":10}"#), material: nil)
        guard case let .vortex(_, _, _, _, _, o1, _, _, _, _, _, _) = v1.operators[0] else { return XCTFail("no vortex") }
        XCTAssertEqual(o1, Vec3(x: 100, y: 200, z: 300), "이쪽은 실제 키다")
    }

    /// **주입과 소비는 다르다.** 주입기는 ring 4키를 무조건 JSON 에 심지만, 힘으로 쓰이려면
    /// `flags & 4` 를 지나야 한다 — 런타임이 `test byte [r14+0x110], 4`(0x1402434eb)로 보고
    /// 비면 `je 0x1402437f8`(0x14024356f)로 **비-ring 루프**로 간다.
    /// 동봉 vortex_v2 5건의 flags 는 3·2·2·2·부재로 **어느 것도 bit2 를 갖지 않는다** —
    /// 즉 실코퍼스에서 링은 한 번도 켜지지 않는다. `magic_vortex_orb` 는 ring 키를 적어 두고도
    /// flags 가 2라 꺼져 있다.
    func testVortexV2RingRequiresFlagsBit2() {
        let off = ParticleSystemDef.parse(json(#"{"operator":[{"name":"vortex_v2"}],"maxcount":10}"#), material: nil)
        guard case let .vortex(_, _, _, _, _, _, _, _, _, _, ring0, _) = off.operators[0] else { return XCTFail("no v2") }
        XCTAssertNil(ring0, "flags 기본 0 → ring 모드 아님")

        // 키를 다 적어도 flags 가 없으면 여전히 꺼져 있다(magic_vortex_orb 의 실제 형태).
        let keysOnly = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"vortex_v2","ringradius":120,"ringpulldistance":9,"ringwidth":8,"flags":2}],
         "maxcount":10}
        """), material: nil)
        guard case let .vortex(_, _, _, _, _, _, _, _, _, _, ringK, _) = keysOnly.operators[0] else { return XCTFail("no v2") }
        XCTAssertNil(ringK, "flags 2 는 centerforce 게이트지 ring 게이트가 아니다")

        let on = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"vortex_v2","flags":4}],"maxcount":10}"#), material: nil)
        guard case let .vortex(_, _, _, _, _, _, _, _, _, _, ring1, _) = on.operators[0] else { return XCTFail("no v2") }
        XCTAssertEqual(ring1, VortexRing(radius: 300, pullDistance: 50, pullForce: 10, width: 50),
                       "0x1401bf637 / 0x1401bf644 / 0x1401bf65e / xmm6@0x1401bf6b5 (ortho 분기)")
    }

    /// ring 모드에서 부분 지정이면 나머지가 주입된다.
    func testVortexV2RingPartialKeysStillInjectTheRest() {
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"vortex_v2","flags":4,"ringradius":120,"ringwidth":8}],"maxcount":10}
        """), material: nil)
        guard case let .vortex(_, _, _, _, _, _, _, _, _, _, ring, _) = d.operators[0] else { return XCTFail("no v2") }
        XCTAssertEqual(ring?.radius, 120)
        XCTAssertEqual(ring?.width, 8)
        XCTAssertEqual(ring?.pullDistance, 50, "부재 → 주입")
        XCTAssertEqual(ring?.pullForce, 10, "부재 → 주입")
    }

    /// `centerforce` 는 `flags & 2` 게이트를 지나야 파스된다 — 비면 핸들러가 0x1401ce0b0 에서
    /// `xorps xmm9,xmm9` 로 0 을 굽는다(`test r14b,2` / `je` @0x1401ce074).
    /// 동봉 5건 중 `magic_vortex_0` 만 flags 가 없어 이 경로다.
    func testVortexV2CenterForceRequiresFlagsBit1() {
        let off = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"vortex_v2","centerforce":0.7}],"maxcount":10}"#), material: nil)
        guard case let .vortex(_, _, _, _, _, _, cf0, _, _, _, _, _) = off.operators[0] else { return XCTFail("no v2") }
        XCTAssertEqual(cf0, 0, "flags 에 bit1 이 없으면 명시값조차 무시된다")

        let on = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"vortex_v2","flags":2}],"maxcount":10}"#), material: nil)
        guard case let .vortex(_, _, _, _, _, _, cf1, _, _, _, _, _) = on.operators[0] else { return XCTFail("no v2") }
        XCTAssertEqual(cf1, 1, "게이트를 지나면 주입 상수 1.0(0x1401bf5ff)")
    }

    /// `flags` 는 파스·보존만 하는 값이 아니라 시뮬 동작을 가르므로 파스돼야 한다.
    func testVortexFlagsAreParsed() {
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"vortex","flags":1},{"name":"vortex_v2","flags":3}],"maxcount":10}
        """), material: nil)
        guard case let .vortex(_, _, _, _, _, _, _, _, _, _, _, f1) = d.operators[0] else { return XCTFail("no v1") }
        guard case let .vortex(_, _, _, _, _, _, _, _, _, _, _, f2) = d.operators[1] else { return XCTFail("no v2") }
        XCTAssertEqual(f1, 1, "동봉 exampleturbolence3d·dna 가 쓰는 값")
        XCTAssertEqual(f2, 3, "동봉 vortex_v2 프리뷰가 쓰는 값 = bit0|bit1")
    }

    // MARK: - maintaindistancetocontrolpoint (신규 구현)

    /// 종전엔 통째로 드롭되던 원소다. 주입 기본 `distance` 200(ortho, 0x1401be2bc) ·
    /// `variablestrength` 0 · `controlpoint` 0. 유일한 실사용처(Magic "Vortex orb")는
    /// `{"variablestrength": 5}` 만 적어 `distance` 200 이 그대로 발화한다.
    func testMaintainDistanceToControlPointDefaults() {
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"maintaindistancetocontrolpoint","variablestrength":5}],"maxcount":10}
        """), material: nil)
        guard case let .maintainDistanceToControlPoint(distance, vs, _) = d.operators[0] else {
            return XCTFail("maintaindistancetocontrolpoint 가 파스되지 않는다 — 종전엔 드롭됐다")
        }
        XCTAssertEqual(distance, 200, "0x1401be2bc (원근 1.0 @0x1401be2c6)")
        XCTAssertEqual(vs, 5)
    }

    // MARK: - controlpointattract (키 이름 정정)

    /// **대상은 `origin` 도 `offset` 도 아니라 컨트롤포인트다.** 런타임 핸들러에서 `offset`
    /// (레코드 +0x10)의 유일한 참조는 `lea r8, [r14+0x10]`(0x14024194e)이고 그건 삭제 함수에
    /// 넘기는 베이스 포인터다 — 위치로 쓰이는 곳이 없다. 실제 대상은 `CP[controlpoint].worldPos`.
    func testControlPointAttractTargetComesFromControlPointNotOffsetOrOrigin() {
        let d = ParticleSystemDef.parse(json("""
        {"controlpoint":[{"id":0,"offset":"1 2 3"},{"id":3,"offset":"70 80 90"}],
         "operator":[{"name":"controlpointattract","controlpoint":3,
                      "offset":"10 20 30","origin":"99 99 99"}],"maxcount":10}
        """), material: nil)
        guard case let .controlPointAttract(_, _, target, _, _) = d.operators[0] else { return XCTFail("no cpa") }
        XCTAssertEqual(target, Vec3(x: 70, y: 80, z: 90),
                       "offset 이면 (10,20,30), origin 이면 (99,99,99) 가 나온다")
    }

    /// `controlpoint` 부재 → **CP0 바인딩**(주입 기본 0). 동봉 35인스턴스 중 9건이 이 경로인데
    /// 전건 CP0 이 원점이라 관측은 안 바뀐다 — 그래서 CP0 을 옮긴 픽스처로 본다.
    func testControlPointAttractWithoutControlPointBindsCP0() {
        let d = ParticleSystemDef.parse(json("""
        {"controlpoint":[{"id":0,"offset":"5 -5 0"}],
         "operator":[{"name":"controlpointattract"}],"maxcount":10}
        """), material: nil)
        guard case let .controlPointAttract(_, _, target, _, _) = d.operators[0] else { return XCTFail("no cpa") }
        XCTAssertEqual(target, Vec3(x: 5, y: -5, z: 0))
    }

    /// 클램프는 **부호 없는** `cmp eax,7 / jae → mov eax,7`(0x1401ccc65 → 0x1401ccd01)이다.
    /// 종전 `cpid >= 0, cpid < 8` 은 8 이상을 드롭하고 7 을 통과시켰다 — 둘 다 다르다.
    func testControlPointAttractControlPointClampIsUnsignedSeven() {
        func target(cp: Int) -> Vec3 {
            let d = ParticleSystemDef.parse(json("""
            {"controlpoint":[{"id":0,"offset":"1 0 0"},{"id":7,"offset":"7 0 0"}],
             "operator":[{"name":"controlpointattract","controlpoint":\(cp)}],"maxcount":10}
            """), material: nil)
            guard case let .controlPointAttract(_, _, t, _, _) = d.operators[0] else { return Vec3(x: -1, y: 0, z: 0) }
            return t
        }
        XCTAssertEqual(target(cp: 7), Vec3(x: 7, y: 0, z: 0))
        XCTAssertEqual(target(cp: 99), Vec3(x: 7, y: 0, z: 0), "범위 밖은 드롭이 아니라 7 로 클램프")
        XCTAssertEqual(target(cp: -3), Vec3(x: 7, y: 0, z: 0), "부호 없는 비교라 음수도 7 이다")
    }

    /// `scale`/`threshold` 부재 기본은 0 이 아니라 512 다(0x140492934, 원근 20.0/5.0).
    /// 동봉 `presets/bubbles/…/bubbles1.json` 이 `threshold` 를 생략하는 실사례다.
    func testControlPointAttractScaleAndThresholdDefaults() {
        let d = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"controlpointattract"}],"maxcount":10}"#), material: nil)
        guard case let .controlPointAttract(scale, threshold, _, _, _) = d.operators[0] else { return XCTFail("no cpa") }
        XCTAssertEqual(scale, 512, "0x140492934")
        XCTAssertEqual(threshold, 512, "0x140492934")
        // 명시된 0 은 유지된다 — 동봉 magic_focus.json 이 `scale: 0` 을 쓴다.
        let z = ParticleSystemDef.parse(json(
            #"{"operator":[{"name":"controlpointattract","scale":0}],"maxcount":10}"#), material: nil)
        guard case let .controlPointAttract(s0, _, _, _, _) = z.operators[0] else { return XCTFail("no cpa") }
        XCTAssertEqual(s0, 0, "키가 있으면 주입되지 않는다")
    }

    // MARK: - vortex 중심 = 컨트롤포인트

    /// 소용돌이 중심은 `offset` 이 아니라 **CP 위치 + offset** 이다
    /// (0x1402431be `[r14+0xc0]` → stride 0xd0 `[sys+0x400]` → 0x140243222–0x14024322c 의 `addps`).
    /// 동봉 14인스턴스는 전건 CP 가 원점이라 관측이 안 바뀌지만, CP 를 옮긴 씬에서 갈린다.
    func testVortexCenterComesFromControlPointPlusOffset() {
        let d = ParticleSystemDef.parse(json("""
        {"controlpoint":[{"id":0,"offset":"10 0 0"},{"id":2,"offset":"0 40 0"}],
         "operator":[{"name":"vortex","controlpoint":2,"offset":"1 2 3"}],"maxcount":10}
        """), material: nil)
        guard case let .vortex(_, _, _, _, _, offset, _, _, _, _, _, _) = d.operators[0] else {
            return XCTFail("no vortex")
        }
        XCTAssertEqual(offset, Vec3(x: 1, y: 42, z: 3), "CP2(0,40,0) + offset(1,2,3)")
    }

    /// vortex_v2 는 **CP 위치 그대로**다 — offset 키를 읽지 않으므로 CP 만 남는다.
    func testVortexV2CenterIsControlPointOnly() {
        let d = ParticleSystemDef.parse(json("""
        {"controlpoint":[{"id":1,"offset":"0 0 7"}],
         "operator":[{"name":"vortex_v2","controlpoint":1,"offset":"99 99 99"}],"maxcount":10}
        """), material: nil)
        guard case let .vortex(_, _, _, _, _, offset, _, _, _, _, _, _) = d.operators[0] else {
            return XCTFail("no v2")
        }
        XCTAssertEqual(offset, Vec3(x: 0, y: 0, z: 7), "offset 은 무시되고 CP1 만 남아야 한다")
    }

    /// CP 미지정이면 CP0 이다(주입 기본 0). 동봉 실인스턴스 대부분이 이 경로다.
    func testVortexWithoutControlPointBindsCP0() {
        let d = ParticleSystemDef.parse(json("""
        {"controlpoint":[{"id":0,"offset":"5 5 0"}],
         "operator":[{"name":"vortex"}],"maxcount":10}
        """), material: nil)
        guard case let .vortex(_, _, _, _, _, offset, _, _, _, _, _, _) = d.operators[0] else {
            return XCTFail("no vortex")
        }
        XCTAssertEqual(offset, Vec3(x: 5, y: 5, z: 0))
    }

    // MARK: - boids (신규 구현)

    /// 주입 기본 7건. `flags` 는 **1**(속도 상한 ON)이 기본인데 동봉 실사용 2종은 0 으로 끈다.
    func testBoidsInjectedDefaults() {
        let d = ParticleSystemDef.parse(json(#"{"operator":[{"name":"boids"}],"maxcount":10}"#), material: nil)
        guard case let .boids(sepThr, nbrThr, maxSpeed, sepF, aliF, cohF, flags) = d.operators[0] else {
            return XCTFail("boids 가 파스되지 않는다 — 종전엔 드롭됐다")
        }
        XCTAssertEqual(sepThr, 20, "0x1401bf726 (원근 0.02)")
        XCTAssertEqual(nbrThr, 50, "0x1401bf7f5 (원근 0.2)")
        XCTAssertEqual(maxSpeed, 500, "0x1401bf8c4 (원근 1.0)")
        XCTAssertEqual(sepF, 15, "f64 @0x140492818, 플래그 무관")
        XCTAssertEqual(aliF, 1, "0x1401bf9fd")
        XCTAssertEqual(cohF, 2, "0x1401bfa14")
        XCTAssertEqual(flags, 1, "`mov qword [rbp-0x40], 1` @0x1401bfa69")
    }

    /// 동봉 `presets/water/…/dripping_water.json` 의 실제 조합 — 지정한 넷은 그대로,
    /// 생략한 셋(separationthreshold·maxspeed·… )은 주입값이 뜬다.
    func testBoidsRealPresetShape() {
        let d = ParticleSystemDef.parse(json("""
        {"operator":[{"name":"boids","alignmentfactor":5,"cohesionfactor":5,"flags":0,
                      "neighborthreshold":150,"separationfactor":0}],"maxcount":16}
        """), material: nil)
        guard case let .boids(sepThr, nbrThr, maxSpeed, sepF, aliF, cohF, flags) = d.operators[0] else {
            return XCTFail("no boids")
        }
        XCTAssertEqual(nbrThr, 150); XCTAssertEqual(aliF, 5); XCTAssertEqual(cohF, 5)
        XCTAssertEqual(sepF, 0, "명시된 0 은 주입되지 않는다")
        XCTAssertEqual(flags, 0, "속도 상한 OFF")
        XCTAssertEqual(sepThr, 20, "생략 → 주입")
        XCTAssertEqual(maxSpeed, 500, "생략 → 주입")
    }

    /// 응집(cohesion)이 실제로 두 입자를 끌어당기는지 — 분리·정렬을 끄고 응집만 남긴다.
    func testBoidsCohesionPullsTowardNeighbor() {
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 10, y: 0, z: 0),
                            rate: 0, burst: 2)],
            initializers: [.lifetimeRandom(min: 100, max: 100)],
            operators: [.boids(separationThreshold: 0, neighborThreshold: 1000, maxSpeed: 500,
                               separationFactor: 0, alignmentFactor: 0, cohesionFactor: 10, flags: 0)],
            renderer: .sprite, maxCount: 4, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 5)
        let a = sim.step(0.1)
        XCTAssertEqual(a.count, 2)
        // 서로를 향해 가속해야 한다: x 가 큰 쪽은 −x, 작은 쪽은 +x.
        let lo = a.min { $0.pos.x < $1.pos.x }!, hi = a.max { $0.pos.x < $1.pos.x }!
        // 두 입자가 같은 자리에 뽑히면 실물도 `cmpneqps xmm2, 0` 으로 건너뛰어 단언이 무의미해진다.
        // 그 경우 조용히 실패하지 않도록 전제를 먼저 말한다.
        XCTAssertGreaterThan(hi.pos.x - lo.pos.x, 0.01, "두 입자가 겹쳐 뽑혔다 — 시드를 바꿔라")
        XCTAssertGreaterThan(lo.vel.x, 0, "왼쪽 입자는 오른쪽으로")
        XCTAssertLessThan(hi.vel.x, 0, "오른쪽 입자는 왼쪽으로")
    }

    /// 분리(separation)는 `separationthreshold` 안에서만 밀어낸다 — 밖이면 무작용.
    func testBoidsSeparationOnlyInsideThreshold() {
        func velX(sepThr: Float) -> Float {
            let def = ParticleSystemDef(
                emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 10, y: 0, z: 0),
                                rate: 0, burst: 2)],
                initializers: [.lifetimeRandom(min: 100, max: 100)],
                operators: [.boids(separationThreshold: sepThr, neighborThreshold: 0, maxSpeed: 500,
                                   separationFactor: 10, alignmentFactor: 0, cohesionFactor: 0, flags: 0)],
                renderer: .sprite, maxCount: 4, startTime: 0, material: nil)
            var sim = ParticleSimulator(def: def, seed: 5)
            let a = sim.step(0.1)
            return a.max { $0.pos.x < $1.pos.x }!.vel.x
        }
        // 분리는 **바깥쪽**으로 민다 — x 가 큰 입자는 +x 로.
        XCTAssertGreaterThan(velX(sepThr: 1000), 0, "임계 안 — 서로 밀어낸다")
        XCTAssertEqual(velX(sepThr: 0.001), 0, accuracy: 1e-5, "임계 밖 — 무작용")
    }

    /// 실물 boids 는 이웃 후보를 **`lifetime != 0` 마스크로 거른다**(0x1402442cd → 0x1402442f4 →
    /// `[rbp+0x1e0]`, 0x1402443e0·0x140244401 에서 분리·이웃 마스크 양쪽에 AND). 실물의 입자 배열이
    /// **고정 슬랩**이고 lifetime 0 이 곧 빈 슬롯이라, 죽은 슬롯을 이웃으로 세지 않겠다는 뜻이다.
    ///
    /// Waple 에는 그 마스크가 **필요 없다.** 여기서 못박는 두 성질이 각각 독립으로 그것을 보장한다:
    /// (a) `lifetimeRandom` 이 `max(0.0001, ·)` 로 바닥을 깐다 — `min:0,max:0` 이라도 lifetime 은 1e-4.
    /// (b) `particles` 는 매 스텝 `removeAll { age > lifetime }` 으로 압축된다 — 빈 슬롯이 없다.
    ///
    /// 2026-08-20 에 `applyBoids` 의 j 루프에 `guard particles[j].lifetime != 0` 을 넣었다가 되돌렸다.
    /// 근거로 삼은 "`lifetimerandom(min:0,max:0)` 이면 lifetime 0 인 입자가 한 스텝 존재한다" 가
    /// (a) 때문에 **거짓**이었고, 가드는 한 번도 서지 않은 채 핫루프의 (i,j) 쌍마다 도는 비교만 남았다.
    /// 둘 중 하나가 깨지면 이 테스트가 먼저 울고, 그때 마스크를 되살리면 된다.
    func testBoidsNeverSeesZeroLifetimeNeighbor() {
        func def(cohesion: Float) -> ParticleSystemDef {
            ParticleSystemDef(
                emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 10, y: 0, z: 0),
                                rate: 0, burst: 2)],
                initializers: [.lifetimeRandom(min: 0, max: 0)],
                operators: [.boids(separationThreshold: 0, neighborThreshold: 1000, maxSpeed: 500,
                                   separationFactor: 0, alignmentFactor: 0, cohesionFactor: cohesion,
                                   flags: 0)],
                renderer: .sprite, maxCount: 4, startTime: 0, material: nil)
        }
        // (a) 바닥. dt 를 바닥보다 작게 줘 컬 이전 상태를 관측한다 — lifetime 이 0 이면 이 스텝에서
        //     `age(5e-5) > lifetime(0)` 이 되어 전건 죽으므로, 살아 있다는 것 자체가 바닥의 증거다.
        var sim = ParticleSimulator(def: def(cohesion: 0), seed: 5)
        let alive = sim.step(0.00005)
        XCTAssertEqual(alive.count, 2, "lifetimerandom(0,0) 이어도 바닥 덕에 한 스텝은 산다")
        for p in alive {
            XCTAssertEqual(p.lifetime, 0.0001, accuracy: 1e-9,
                           "lifetime 바닥 = max(0.0001, ·) — 0 이 아니다")
        }
        // (b) 압축. 바닥을 넘긴 dt 면 같은 스텝에 전건 사라진다 — 죽은 슬롯이 배열에 남지 않는다.
        var culled = ParticleSimulator(def: def(cohesion: 0), seed: 5)
        XCTAssertTrue(culled.step(0.001).isEmpty, "죽은 입자는 슬롯으로 남지 않고 배열에서 빠진다")
        XCTAssertEqual(culled.liveCount, 0, "압축 후 살아 있는 입자 0")
        // 따라서 boids 는 lifetime 0 인 이웃을 볼 수 없고, 이웃 계산은 정상적으로 발화한다
        // (마스크가 잘못 되살아나 1e-4 를 0 으로 접으면 여기서 응집이 죽어 0 이 된다).
        var pulled = ParticleSimulator(def: def(cohesion: 10), seed: 5)
        let after = pulled.step(0.00005)
        XCTAssertEqual(after.count, 2)
        guard after.count == 2 else { return }
        XCTAssertGreaterThan(abs(after[0].vel.x) + abs(after[1].vel.x), 0,
                             "이웃이 살아 있으므로 응집이 실제로 속도를 만든다")
    }
}
