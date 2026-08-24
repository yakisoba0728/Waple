import XCTest
@testable import WapleCore

/// `remapvalue` 의 **직교 3축**을 못박는다 — `output`(채널) × `operation`(4산술) × `outputcomponent`(축).
///
/// 근거 전문은 `docs/re/remap-operation.md`. 이 파일이 못박는 판정 셋:
///  ① `operation` 은 **값 곡선이 아니다.** VM opid 19 핸들러(0x140244874–0x140246ec0)의 값 산출
///     구간(0x140244874–0x1402459a5)은 `[r14+0x10]`(=operation)을 **한 번도 읽지 않는다**.
///     32번의 읽기가 전부 output 디스패치(`jmp rcx` @0x1402459a5) 뒤이고 최소 주소가 0x1402459a7 이다.
///  ② 부재 기본은 `remap` 이 아니라 **`multiply`** 다(주입기 0x1401bfbba → [0x140484f28]).
///  ③ `rotation`/`angularspeed` 는 **z 성분 하나**([rsi+0x290]/[rsi+0x2a8])이고 **dt 곱이 없다**.
///
/// **절대 다이제스트를 굽지 않는다.** 리눅스 시임과 macOS `simd` 는 부동소수 결과가 비트동일하지
/// 않아 플랫폼을 못 넘는다. 대신 같은 자산을 **두 벌** 시뮬해(현 파스 vs 종전 기본 `remap`) 비트동일
/// 여부만 본다 — 그 판정은 플랫폼과 무관하고, remap 밖의 코드가 바뀌어도 흔들리지 않는다.
final class RemapOperationAxesTests: XCTestCase {

    // MARK: - 픽스처

    private func makeDef(lifetime: Float = 100, maxCount: Int = 8,
                         operators: [ParticleOperator] = []) -> ParticleSystemDef {
        ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                            rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: lifetime, max: lifetime),
                           .sizeRandom(min: 4, max: 4),
                           .alphaRandom(min: 1, max: 1, exponent: 1)],
            operators: operators,
            renderer: .sprite, maxCount: maxCount, startTime: 0, material: nil)
    }

    /// 값이 상수 `v` 로 굳는 스펙(outputrange min==max → transform·입력과 무관).
    private func constSpec(_ channel: RemapChannel, _ op: RemapOperation, _ v: Vec3,
                           outputComponent: RemapComponent = .all) -> RemapSpec {
        RemapSpec(outputChannel: channel, operation: op, outputComponent: outputComponent,
                  input: .lifetimeFraction, transform: nil, octaves: 3, inputScale: 1,
                  outMin: v, outMax: v,
                  blendInStart: 0, blendInEnd: 0, blendOutStart: 1, blendOutEnd: 1,
                  inputCP0: 0, inputCP1: 1, outputCP0: 0, outputCP1: 1)
    }

    private func firstParticle(_ spec: RemapSpec, lifetime: Float = 100, dt: Float = 1) -> Particle {
        var sim = ParticleSimulator(def: makeDef(lifetime: lifetime,
                                                 operators: [.remapValueEx(spec: spec)]), seed: 7)
        return sim.step(dt)[0]
    }

    // MARK: - ① `operation` 은 값 곡선이 아니다 (착지 1)

    /// 종전 `remapEval` 3단계는 `subtract` 에서 `v = 1 − v01` 로 값을 **뒤집었다**.
    /// 실물 값 산출 구간에 `operation` 읽기가 0회이므로 그 셰이핑은 존재할 수 없다.
    ///
    /// 입력 `lifetimefraction`(n=0.5) · 변환 없음 · outputrange 0..1 이면 값은 언제나 0.5 여야 한다 —
    /// **네 산술 전부에서**. 종전 코드는 `subtract` 에서만 0.5 대신 0.5(대칭점이라 우연히 같음)…
    /// 가 아니라 n=0.25 에서 갈린다. 그래서 n=0.25 로 잰다(종전: 0.75, 실물: 0.25).
    func testOperationIsNotAValueCurve() {
        for op in [RemapOperation.remap, .multiply, .add, .subtract] {
            let spec = RemapSpec(outputChannel: .size, operation: .remap,
                                 input: .lifetimeFraction, transform: nil, octaves: 3, inputScale: 1,
                                 outMin: Vec3(x: 0, y: 0, z: 0), outMax: Vec3(x: 1, y: 1, z: 1),
                                 blendInStart: 0, blendInEnd: 0, blendOutStart: 1, blendOutEnd: 1,
                                 inputCP0: 0, inputCP1: 1, outputCP0: 0, outputCP1: 1)
            // 값 산출만 보려고 산술은 항상 `remap`(덮어쓰기)으로 고정하고, 스펙의 `operation`
            // 축만 바꿔 끼운다 — 값 곡선이 `operation` 에 반응하면 여기서 갈린다.
            let probe = RemapSpec(outputChannel: .size, operation: op,
                                  input: spec.input, transform: spec.transform, octaves: spec.octaves,
                                  inputScale: spec.inputScale, outMin: spec.outMin, outMax: spec.outMax,
                                  blendInStart: 0, blendInEnd: 0, blendOutStart: 1, blendOutEnd: 1,
                                  inputCP0: 0, inputCP1: 1, outputCP0: 0, outputCP1: 1)
            var sim = ParticleSimulator(def: makeDef(lifetime: 1,
                                                     operators: [.remapValueEx(spec: probe)]), seed: 7)
            let p = sim.step(0.25)[0]                       // n = 0.25 → v01 = 0.25
            let base: Float = 4                              // sizerandom 4
            let want: Float
            switch op {
            case .remap:    want = 0.25
            case .multiply: want = base * 0.25
            case .add:      want = base + 0.25
            case .subtract: want = base - 0.25
            }
            XCTAssertEqual(p.size, want, accuracy: 1e-5,
                           "operation \(op) 가 값 곡선을 건드리면 안 된다 — 목적지 산술만 골라야 한다")
        }
    }

    // MARK: - ② 4산술 × 채널 (착지 3)

    /// 실물 `output:"size"` 케이스(0x140245a1d–0x140245a8c)의 네 갈래를 그대로 잰다.
    /// `remap`=대입(movups) · `multiply`=v·dst(mulps) · `add`=v+dst(addps) · `subtract`=dst−v(subps).
    func testFourArithmeticsOnScalarChannels() {
        // size: 기본 4
        XCTAssertEqual(firstParticle(constSpec(.size, .remap, Vec3(x: 3, y: 3, z: 3))).size, 3, accuracy: 1e-5)
        XCTAssertEqual(firstParticle(constSpec(.size, .multiply, Vec3(x: 3, y: 3, z: 3))).size, 12, accuracy: 1e-5)
        XCTAssertEqual(firstParticle(constSpec(.size, .add, Vec3(x: 3, y: 3, z: 3))).size, 7, accuracy: 1e-5)
        XCTAssertEqual(firstParticle(constSpec(.size, .subtract, Vec3(x: 3, y: 3, z: 3))).size, 1, accuracy: 1e-5)
        // opacity: 기본 1, [0,1] 클램프(Waple 규약)
        XCTAssertEqual(firstParticle(constSpec(.opacity, .multiply, Vec3(x: 0.25, y: 0, z: 0))).alpha,
                       0.25, accuracy: 1e-5)
        XCTAssertEqual(firstParticle(constSpec(.opacity, .subtract, Vec3(x: 0.25, y: 0, z: 0))).alpha,
                       0.75, accuracy: 1e-5)
        XCTAssertEqual(firstParticle(constSpec(.opacity, .remap, Vec3(x: 0.5, y: 0, z: 0))).alpha,
                       0.5, accuracy: 1e-5)
    }

    /// color 는 벡터 채널이라 **성분마다** 같은 4산술을 건다(0x140246161 = all 분기).
    func testFourArithmeticsOnColor() {
        // colorrandom 없음 → 기본 (1,1,1).
        let mul = firstParticle(constSpec(.color, .multiply, Vec3(x: 0.5, y: 0.25, z: 0)))
        XCTAssertEqual(mul.color.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(mul.color.y, 0.25, accuracy: 1e-5)
        XCTAssertEqual(mul.color.z, 0, accuracy: 1e-5)
        let sub = firstParticle(constSpec(.color, .subtract, Vec3(x: 0.25, y: 0.25, z: 0.25)))
        XCTAssertEqual(sub.color.x, 0.75, accuracy: 1e-5)
        let add = firstParticle(constSpec(.color, .add, Vec3(x: -0.5, y: 0, z: 0)))
        XCTAssertEqual(add.color.x, 0.5, accuracy: 1e-5)
    }

    /// **`rotation`/`angularspeed` 는 z 성분 하나이고 dt 곱이 없다.**
    ///
    /// 실물 rotation 핸들러 0x140245bac 의 목적지는 `[rsi+0x290]` **하나**다. 회전 배열이
    /// 0x280/0x288/0x290 이라는 것은 형제 `angularmovement` 핸들러가 여섯 포인터를
    /// 0x14024000d–0x140240039 에서 한 줄씩 잡아 확정한다(rot xyz = 0x280/0x288/0x290,
    /// angvel xyz = 0x298/0x2a0/0x2a8). 그러므로 그것은 rot.**z** 다.
    ///
    /// dt 는 핸들러 전 구간(0x140244874–0x140246ec0)에 dtScaled 슬롯 `[rbp+0xf0]` 참조가
    /// **0건**이라 들어갈 자리가 없다 — 종전의 `val * (w*dt)` 는 근거 없는 [추정] 이었다.
    func testRotationAndAngularSpeedAreZOnlyAndFrameIndependent() {
        let rot = firstParticle(constSpec(.rotation, .add, Vec3(x: 2, y: 2, z: 2)), dt: 0.5)
        XCTAssertEqual(rot.rotation.z, 2, accuracy: 1e-5, "dt(0.5)가 곱해지면 안 된다")
        XCTAssertEqual(rot.rotation.x, 0, accuracy: 1e-6, "x 는 건드리지 않는다")
        XCTAssertEqual(rot.rotation.y, 0, accuracy: 1e-6, "y 는 건드리지 않는다")

        // 프레임 독립이 아니라 **프레임당 가산**이다 — dt 를 반으로 줄이면 같은 시간에 두 배가 쌓인다.
        var simA = ParticleSimulator(def: makeDef(operators: [
            .remapValueEx(spec: constSpec(.angularSpeed, .add, Vec3(x: 1, y: 1, z: 1)))]), seed: 7)
        _ = simA.step(1.0); let a = simA.step(1.0)[0]
        XCTAssertEqual(a.angularVel.z, 2, accuracy: 1e-5, "스텝마다 +1")
        XCTAssertEqual(a.angularVel.x, 0, accuracy: 1e-6)

        let setRot = firstParticle(constSpec(.rotation, .remap, Vec3(x: 5, y: 5, z: 5)))
        XCTAssertEqual(setRot.rotation.z, 5, accuracy: 1e-5)
        XCTAssertEqual(setRot.rotation.x, 0, accuracy: 1e-6, "set 도 z 전용이다")
    }

    /// `speed` 는 `|v|` 에 4산술을 걸고 방향을 보존한 채 재스케일한다(0x140245b05–0x140245ba7).
    /// `multiply` 는 `s'/s` 에서 s 가 정확히 상쇄돼 **종전 배수 경로와 산술이 같다**.
    func testSpeedAppliesArithmeticToMagnitude() {
        // movement 없이 vel 을 세우려면 setvelocity 를 앞에 둔다(저작 순서대로 적용).
        let setV = constSpec(.velocity, .remap, Vec3(x: 10, y: 0, z: 0))
        func posAfterOneStep(_ op: RemapOperation, _ v: Float) -> Float {
            var sim = ParticleSimulator(def: makeDef(operators: [
                .remapValueEx(spec: setV),
                .remapValueEx(spec: constSpec(.speed, op, Vec3(x: v, y: v, z: v)))]), seed: 7)
            return sim.step(1.0)[0].pos.x
        }
        XCTAssertEqual(posAfterOneStep(.multiply, 2), 20, accuracy: 1e-4, "|v|·2 → 20")
        XCTAssertEqual(posAfterOneStep(.remap, 3), 3, accuracy: 1e-4, "속력 지정 → 3")
        XCTAssertEqual(posAfterOneStep(.add, 5), 15, accuracy: 1e-4, "|v|+5 → 15")
        XCTAssertEqual(posAfterOneStep(.subtract, 4), 6, accuracy: 1e-4, "|v|−4 → 6")
    }

    // MARK: - ③ `outputcomponent` (착지 3·4)

    /// 벡터 채널 6종만 `outputcomponent`(`[r14+0x20]`) 스위치를 갖는다 — 실물 읽기 6곳
    /// (color 0x140245fce · position 0x140246252 · velocity 0x1402464e6 · controlpoint 0x1402467c6 ·
    ///  deltatocontrolpoint 0x140246aaf · directiontocontrolpoint 0x140246c7d).
    func testOnlyVectorChannelsCarryTheOutputComponentSwitch() {
        let withSwitch = RemapChannel.allCases.filter { $0.hasOutputComponentSwitch }
        XCTAssertEqual(Set(withSwitch), Set<RemapChannel>([.color, .position, .velocity, .controlPoint,
                                                           .deltaToControlPoint, .directionToControlPoint]))
        XCTAssertEqual(withSwitch.count, 6, "실물 `[r14+0x20]` 읽기 6곳")
    }

    /// 축은 **목적 성분과 값 레인을 함께** 고른다(x→0x2f8/xmm3 · y→0x300/[rbp-0x80] · z→0x308/[rbp-0x70]).
    func testOutputComponentSelectsAxisAndLane() {
        let v = Vec3(x: 0.1, y: 0.2, z: 0.3)
        let onlyY = firstParticle(constSpec(.color, .remap, v, outputComponent: .y))
        XCTAssertEqual(onlyY.color.x, 1, accuracy: 1e-6, "x 는 그대로")
        XCTAssertEqual(onlyY.color.y, 0.2, accuracy: 1e-5, "y 레인이 y 배열로")
        XCTAssertEqual(onlyY.color.z, 1, accuracy: 1e-6, "z 는 그대로")

        let onlyZ = firstParticle(constSpec(.color, .multiply, v, outputComponent: .z))
        XCTAssertEqual(onlyZ.color.z, 0.3, accuracy: 1e-5)
        XCTAssertEqual(onlyZ.color.x, 1, accuracy: 1e-6)

        // sum/average/max/min 은 **입력 축약 전용**이라 출력에 오면 무동작이다(`jne` @0x140245fef).
        for c in [RemapComponent.sum, .average, .max, .min] {
            let p = firstParticle(constSpec(.color, .remap, v, outputComponent: c))
            XCTAssertEqual(p.color.x, 1, accuracy: 1e-6, "\(c) 는 출력에 오면 무동작")
            XCTAssertEqual(p.color.y, 1, accuracy: 1e-6)
            XCTAssertEqual(p.color.z, 1, accuracy: 1e-6)
        }
    }

    // MARK: - ④ `component` → `inputcomponent` / `outputcomponent` (착지 4)

    /// 실물 키는 `inputcomponent`(0x14048f760) 와 `outputcomponent`(0x14048f810) 둘이고,
    /// `component` 라는 독립 키 문자열은 바이너리에 **없다**(ASCII·UTF-16LE 전수 0건).
    /// Waple 레거시 별칭은 남기되 실물 키가 이긴다.
    func testInputAndOutputComponentKeysAreSeparate() {
        func spec(_ extra: [String: Any]) -> RemapSpec? {
            var o: [String: Any] = ["name": "remapvalue", "output": "color"]
            for (k, v) in extra { o[k] = v }
            let d = ParticleSystemDef.parse(["operator": [o]], material: nil)
            for op in d.operators { if case let .remapValueEx(s) = op { return s } }
            return nil
        }
        // 부재 기본은 둘 다 "all" 이다(주입기 0x1401bfc0b · 0x1401bfc21 → [0x140484e40]).
        XCTAssertEqual(spec([:])?.inputComponent, .all)
        XCTAssertEqual(spec([:])?.outputComponent, .all)
        // 두 키가 서로 새지 않는다.
        XCTAssertEqual(spec(["inputcomponent": "z"])?.inputComponent, .z)
        XCTAssertEqual(spec(["inputcomponent": "z"])?.outputComponent, .all)
        XCTAssertEqual(spec(["outputcomponent": "y"])?.outputComponent, .y)
        XCTAssertEqual(spec(["outputcomponent": "y"])?.inputComponent, .all)
        // 8종 어휘 전부(매퍼 0x140261030, 표 0x140484e40) + 대소문자 무시.
        for c in RemapComponent.allCases {
            XCTAssertEqual(spec(["outputcomponent": c.rawValue.uppercased()])?.outputComponent, c)
        }
        // 레거시 별칭은 `inputcomponent` 쪽으로 가고, 실물 키가 있으면 진다.
        XCTAssertEqual(spec(["component": "y"])?.inputComponent, .y)
        XCTAssertEqual(spec(["component": "y"])?.component, 1, "종전 0/1/2 읽기 뷰")
        XCTAssertEqual(spec(["component": "y", "inputcomponent": "z"])?.inputComponent, .z)
    }

    /// 성분 키 셋 전부 **동봉 도달 0건**이라 이 분리는 관측을 바꿀 수 없다.
    func testComponentKeysHaveZeroReachInBundledAssets() throws {
        let root = try XCTUnwrap(Self.bundledAssetsRoot(), "동봉 WEAssets 를 못 찾았다")
        var hits: [String] = []
        var scanned = 0
        let fm = FileManager.default
        guard let it = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in it where url.pathExtension == "json" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            for key in ["\"component\"", "\"inputcomponent\"", "\"outputcomponent\""]
            where text.contains(key) { hits.append("\(url.lastPathComponent) \(key)") }
        }
        XCTAssertGreaterThan(scanned, 100, "자산 트리가 비었다 — 경로가 틀린 것")
        XCTAssertEqual(hits, [], "성분 키 도달이 0 이 아니다 — 분리의 무회귀 근거가 무너진다")
    }

    // MARK: - ⑤ 적용하지 않는 채널

    /// 실물이 무동작인 6종(`lifetimefraction`·`runtime`·`timeofday`·`particlesystemtime`·
    /// `layertime`·`layerorigin`)과 Waple 미구현 CP 계열 5종은 **시뮬을 건드리지 않는다**.
    /// 파스는 되므로(`RemapOutputChannelTests.testAllTwentyChannelsParse`) 정보는 잃지 않는다.
    func testUnappliedChannelsDoNotTouchTheSimulation() {
        var plain = ParticleSimulator(def: makeDef(), seed: 11)
        let bare = plain.step(1.0)[0]
        for c in RemapChannel.allCases where !ParticleSimulator.remapChannelIsApplied(c) {
            let p = firstParticle(constSpec(c, .remap, Vec3(x: 99, y: 99, z: 99)))
            XCTAssertEqual(p.pos, bare.pos, "\(c.rawValue) 가 위치를 건드렸다")
            XCTAssertEqual(p.vel, bare.vel, "\(c.rawValue) 가 속도를 건드렸다")
            XCTAssertEqual(p.size, bare.size, "\(c.rawValue) 가 크기를 건드렸다")
            XCTAssertEqual(p.alpha, bare.alpha, "\(c.rawValue) 가 알파를 건드렸다")
            XCTAssertEqual(p.color, bare.color, "\(c.rawValue) 가 색을 건드렸다")
            XCTAssertEqual(p.lifetime, bare.lifetime, "\(c.rawValue) 가 수명을 건드렸다")
        }
        // 실물도 무동작인 6종은 열거가 스스로 표시한다(점프테이블 0x14024bcb4 덤프로 확인).
        XCTAssertEqual(Set(RemapChannel.allCases.filter { $0.isNoOpOutput }),
                       Set<RemapChannel>([.lifetimeFraction, .runtime, .timeOfDay,
                                          .particleSystemTime, .layerTime, .layerOrigin]))
    }

    // MARK: - ⑥ 동봉 자산 항목별 무회귀 (착지 2)

    /// 동봉 트리에서 `remapvalue`/`remapinitialvalue` 를 가진 파일 전건.
    /// (`remapvalue` all 12 · unique 10 — `spec/assets/particle-corpus.json` 과 일치.)
    static let remapAssetFiles = [
        "presets/lightning/particles/presets/thunderbolt.json",
        "presets/lightning/previewthunderbolt/particles/presets/thunderbolt.json",
        "presets/rain/particles/presets/rain_screen.json",
        "presets/rain/particles/presets/rain_screen_4k.json",
        "presets/rain/particles/presets/rain_screen_fast.json",
        "presets/rain/particles/presets/rain_screen_fast_4k.json",
        "presets/rain/previewrainscreen/particles/presets/rain_screen.json",
        "presets/rain/previewrainscreen/particles/presets/rain_screen_fast.json",
        "scenes/particleelementpreviews/remapvalue/particles/new_particle_system.json",
        "scenes/particleelementpreviews/remapinitialvalue/particles/new_particle_system.json",
        "presets/lightning/particles/presets/thunderbolt_beam_child.json",
        "presets/lightning/previewthunderbolt/particles/presets/thunderbolt_beam_child.json",
    ]

    /// `operation` 부재 기본을 **종전값 `remap`** 으로 되돌린 def — 착지 2 의 대조군이다.
    private func withLegacyOperationDefault(_ def: ParticleSystemDef) -> ParticleSystemDef {
        var out = def
        out.operators = def.operators.map { op in
            guard case let .remapValueEx(s) = op else { return op }
            return .remapValueEx(spec: RemapSpec(
                outputChannel: s.outputChannel, operation: .remap,
                outputComponent: s.outputComponent, inputComponent: s.inputComponent,
                verb: s.verb, input: s.input, transform: s.transform, octaves: s.octaves,
                inputScale: s.inputScale, outMin: s.outMin, outMax: s.outMax,
                blendInStart: s.blendInStart, blendInEnd: s.blendInEnd,
                blendOutStart: s.blendOutStart, blendOutEnd: s.blendOutEnd,
                inputCP0: s.inputCP0, inputCP1: s.inputCP1,
                outputCP0: s.outputCP0, outputCP1: s.outputCP1,
                inMin: s.inMin, inMax: s.inMax))
        }
        return out
    }

    private func digest(_ def: ParticleSystemDef) -> String {
        var sim = ParticleSimulator(def: def, seed: 0xC0FFEE)
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ f: Float) { h = (h ^ UInt64(f.bitPattern)) &* 0x100000001b3 }
        for _ in 0..<400 {
            for p in sim.step(1.0 / 30.0) {
                mix(p.pos.x); mix(p.pos.y); mix(p.pos.z)
                mix(p.vel.x); mix(p.vel.y); mix(p.vel.z)
                mix(p.color.x); mix(p.color.y); mix(p.color.z)
                mix(p.rotation.z); mix(p.angularVel.z)
                mix(p.size); mix(p.alpha); mix(p.lifetime)
            }
        }
        return String(format: "%016llx", h)
    }

    private func parsedDef(_ file: String, root: URL) -> ParticleSystemDef? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(file)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ParticleSystemDef.parse(obj, material: nil)
    }

    /// **착지 2 의 실측.** `operation` 부재 기본을 `remap`→`multiply` 로 바꿨을 때
    /// **그림이 바뀌는 자산이 정확히 어느 것인지**를 자산별로 못박는다.
    ///
    /// 실측 결과(2026-08-21, 동봉 트리 12파일):
    ///   · `thunderbolt.json` · `previewthunderbolt/thunderbolt.json` — **바뀐다**.
    ///     `output:"opacity"` · `operation` 부재라 `setOpacity`(alphafade 를 밀어냄) →
    ///     `multiplyOpacity`(번개 깜빡임이 페이드 **위에** 얹힌다).
    ///   · 나머지 10파일 — **비트동일**. rain 의 `output:"velocity"` 6건은 `operation:"remap"` 이
    ///     명시돼 있고, `output:"speed"` 3건은 확장 키가 없어 레거시 `.remapValue(.speed)` 경로를
    ///     타며(그쪽은 원래 곱하기였다 — **우연히 맞아 있었다**), 프리뷰 2건도 `remap` 명시거나
    ///     `remapinitialvalue`(Waple 미파스)다.
    func testBundledAssetsOnlyThunderboltOpacityChangesWithTheNewDefault() throws {
        let root = try XCTUnwrap(Self.bundledAssetsRoot(), "동봉 WEAssets 를 못 찾았다")
        let mustChange = Set([
            "presets/lightning/particles/presets/thunderbolt.json",
            "presets/lightning/previewthunderbolt/particles/presets/thunderbolt.json",
        ])
        var changed: Set<String> = []
        for f in Self.remapAssetFiles {
            let def = try XCTUnwrap(parsedDef(f, root: root), "파스 실패: \(f)")
            if digest(def) != digest(withLegacyOperationDefault(def)) { changed.insert(f) }
        }
        XCTAssertEqual(changed, mustChange,
                       "부재 기본 multiply 의 도달이 실측과 다르다(그림이 바뀌는 자산 목록)")
    }

    /// 바뀌는 두 건도 **알파만** 바뀐다 — `opacity` 는 표시 파생이라 물리(위치·속도)를 안 건드린다.
    func testThunderboltChangeIsAlphaOnly() throws {
        let root = try XCTUnwrap(Self.bundledAssetsRoot(), "동봉 WEAssets 를 못 찾았다")
        let f = "presets/lightning/particles/presets/thunderbolt.json"
        let def = try XCTUnwrap(parsedDef(f, root: root))
        let old = withLegacyOperationDefault(def)
        var a = ParticleSimulator(def: def, seed: 0xC0FFEE)
        var b = ParticleSimulator(def: old, seed: 0xC0FFEE)
        var sawAlphaDiff = false
        for _ in 0..<400 {
            let pa = a.step(1.0 / 30.0), pb = b.step(1.0 / 30.0)
            XCTAssertEqual(pa.count, pb.count, "파티클 수가 갈리면 RNG 드로가 갈린 것이다")
            for (x, y) in zip(pa, pb) {
                XCTAssertEqual(x.pos, y.pos, "opacity 채널이 위치를 건드렸다")
                XCTAssertEqual(x.vel, y.vel, "opacity 채널이 속도를 건드렸다")
                XCTAssertEqual(x.size, y.size)
                if x.alpha != y.alpha { sawAlphaDiff = true }
            }
        }
        XCTAssertTrue(sawAlphaDiff, "알파가 한 번도 안 갈리면 이 자산이 도달하지 않는다는 뜻이다")
    }

    /// `output:"speed"` 3건은 **레거시 경로**를 탄다 — 확장 키가 하나도 없기 때문이다.
    /// 그래서 부재 기본을 바꿔도 이 셋은 무회귀다(이미 곱하기였다).
    func testBundledSpeedRemapsStayOnTheLegacyPath() throws {
        let root = try XCTUnwrap(Self.bundledAssetsRoot(), "동봉 WEAssets 를 못 찾았다")
        var legacySpeed = 0
        for f in ["presets/rain/particles/presets/rain_screen.json",
                  "presets/rain/particles/presets/rain_screen_4k.json",
                  "presets/rain/previewrainscreen/particles/presets/rain_screen.json"] {
            let def = try XCTUnwrap(parsedDef(f, root: root))
            for op in def.operators {
                if case let .remapValue(output, _, _) = op, case .speed = output { legacySpeed += 1 }
            }
        }
        XCTAssertEqual(legacySpeed, 3, "동봉 `output:\"speed\"` 3건은 확장 키가 없어 레거시 경로다")
    }

    /// 동봉 `remapvalue` 의 (채널, 산술) 조합 도수 — 문서 §2.1 과 맞는지.
    func testBundledRemapValueAxesCensus() throws {
        let root = try XCTUnwrap(Self.bundledAssetsRoot(), "동봉 WEAssets 를 못 찾았다")
        var census: [String: Int] = [:]
        for f in Self.remapAssetFiles {
            guard let def = parsedDef(f, root: root) else { continue }
            for op in def.operators {
                switch op {
                case let .remapValueEx(s): census["\(s.outputChannel.rawValue)/\(s.operation)", default: 0] += 1
                case let .remapValue(output, _, _):
                    switch output {
                    case .velocity: census["velocity/legacy", default: 0] += 1
                    case .speed: census["speed/legacy", default: 0] += 1
                    }
                default: break
                }
            }
        }
        XCTAssertEqual(census["velocity/remap"], 6, "rain velocity 6건(all)")
        XCTAssertEqual(census["opacity/multiply"], 2, "thunderbolt opacity 2건 — 부재 기본이 도달하는 자리")
        XCTAssertEqual(census["color/remap"], 1, "remapvalue 프리뷰 1건")
        XCTAssertEqual(census["speed/legacy"], 3, "레거시 경로 3건")
        XCTAssertNil(census["velocity/legacy"], "velocity 는 전건 operation 명시라 Ex 경로다")
        XCTAssertEqual(census.values.reduce(0, +), 12, "동봉 remapvalue all 12")
    }

    static func bundledAssetsRoot() -> URL? {
        bundledWEAssetsRoot()
    }
}
