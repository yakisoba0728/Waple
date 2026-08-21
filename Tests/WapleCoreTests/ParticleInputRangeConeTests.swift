import XCTest
@testable import WapleCore

/// `operator[].inputrangemin` / `inputrangemax` **소비** 와 `emitter[].cone` **파스** 를 못박는다.
///
/// 두 키 모두 파스는 이미 있었지만(커밋 87abb1f) `inputrange*` 는 시뮬이 안 읽었고 `cone` 은
/// 파스조차 없었다. 여기서 재확인한 원본 근거는 다음과 같다(전부 이 라운드에 직접 다시 떴다).
///
/// **입력 범위 정규화** — 오퍼레이터 파스 분기 `0x1401ce660`–`0x1401cf145`:
///   `0x1401ce836` `lea rdx,"inputrangemin"` · `0x1401ce98c` `lea rdx,"inputrangemax"`
///   (둘 다 **다음** 키의 이름 `lea` 가 아니라 자기 자리다 — 직전 `mov [rsi+0x1c], eax` 는
///    `flags` 의 저장이라 한 칸 밀려 보이는 그 배치다)
///   `0x1401ceaf0` `call 0x14005f0a0`  = `Vector3::sub` → `span = max − min`
///   `0x1401cedd1`–`0x1401cedfe`       = 성분이 정확히 0 이면 `0x34000000`(`Float.ulpOfOne`)
///   `0x1401cee1a/2a/3a`               = `min.x/y/z` 브로드캐스트 → `[op+0x20/0x30/0x40]`
///   `0x1401cee47/57/67`               = `rcpps(span.x/y/z)`     → `[op+0x50/0x60/0x70]`
/// VM opid 19(`0x140244874`–) 의 정규화 두 자리:
///   3성분 `subps xmm0,xmm1`@`0x140245096` + `mulps xmm0,xmm2`@`0x140245099`
///   스칼라 `subps xmm7,xmm1`@`0x1402450fa` + `mulps xmm7,xmm2`@`0x1402450fd`
/// 부재 기본은 `0` / `1`(주입 `0x1401bfc8c` · `0x1401bfd76`)이라 정규화가 **항등**이다.
///
/// **cone** — `sphererandom` 바인더 `0x1401b9100`–`0x1401b992c`:
///   `0x1401b94ab` `xorps xmm2,xmm2`(기본 0) → `0x1401b94ae` `lea rdx,"cone"` →
///   `0x1401b94b8` `call H_FLOAT`. 팩토리 소비 `0x1401c61b5` `asFloat` →
///   `0x1401c61ba` `mulss xmm0, π` → `0x1401c61bf` `call cosf` → `0x1401c61c4` 부호반전 →
///   `0x1401c61ce` `movss [emit+0xe4]`.
final class ParticleInputRangeConeTests: XCTestCase {

    // MARK: - 1. 정규화 순수 함수

    /// 부재 기본 `(0,0,0)`/`(1,1,1)` 에서 **비트동일 항등**이어야 한다 — 무회귀의 근거다.
    func testDefaultInputRangeIsBitIdentity() {
        let spec = Self.sizeSpec(inMin: 0, inMax: 1)
        let samples: [Float] = [0, 0.25, 1, 3.75, -2, 1e6, 1.0 / 3.0]
        for raw in samples {
            XCTAssertEqual(ParticleSimulator.remapNormalizeInput(raw, spec).bitPattern,
                           raw.bitPattern,
                           "기본 범위에서는 raw 가 비트까지 그대로여야 한다 (raw=\(raw))")
        }
    }

    /// 실물 프리뷰 씬의 값 그대로 — `remapvalue` 150→200.
    /// (`scenes/particleelementpreviews/remapvalue/particles/new_particle_system.json`)
    func testInputRangeMapsPreviewSceneValues() {
        let spec = Self.sizeSpec(inMin: 150, inMax: 200)
        XCTAssertEqual(ParticleSimulator.remapNormalizeInput(150, spec), 0, accuracy: 1e-6)
        XCTAssertEqual(ParticleSimulator.remapNormalizeInput(175, spec), 0.5, accuracy: 1e-6)
        XCTAssertEqual(ParticleSimulator.remapNormalizeInput(200, spec), 1, accuracy: 1e-6)
        // 범위 밖은 여기서 자르지 않는다 — 클램프는 transform 단계(`.none`)의 몫이다.
        XCTAssertEqual(ParticleSimulator.remapNormalizeInput(100, spec), -1, accuracy: 1e-6)
    }

    /// 폭이 정확히 0 이면 실물은 `0x34000000`(= `Float.ulpOfOne`)으로 갈아 끼운다(0x1401cedf3).
    /// 즉 **0 나눗셈이 아니라 아주 큰 기울기**다.
    func testZeroSpanUsesEpsilonNotDivideByZero() {
        let spec = Self.sizeSpec(inMin: 5, inMax: 5)
        let t = ParticleSimulator.remapNormalizeInput(6, spec)
        XCTAssertTrue(t.isFinite, "0 폭이 무한대를 내면 실물과 다르다")
        XCTAssertEqual(t, 1 / Float.ulpOfOne, accuracy: 1 / Float.ulpOfOne * 1e-5)
        // 정확히 하한이면 0 — 부호가 뒤집히지 않는다.
        XCTAssertEqual(ParticleSimulator.remapNormalizeInput(5, spec), 0)
    }

    /// 스칼라가 아닌 vec3 를 줘도 x 레인만 본다(동봉 도달 5건이 전건 스칼라라는 근거로 고른 규약).
    func testVec3InputRangeUsesXLane() {
        let spec = Self.sizeSpec(inMin: Vec3(x: 10, y: 999, z: -999),
                                 inMax: Vec3(x: 20, y: 0, z: 0))
        XCTAssertEqual(ParticleSimulator.remapNormalizeInput(15, spec), 0.5, accuracy: 1e-6)
    }

    // MARK: - 2. 시뮬 배선(end-to-end)

    /// CP0 로부터 거리 175 인 파티클 하나. `inputrangemin/max` = 150/200 이면 t=0.5 →
    /// `outputrangemin/max` 0/10 의 한가운데 5 가 나와야 한다.
    /// **정규화가 없으면** 입력 175 가 `.none` transform 의 클램프에 걸려 1 → 10 이 된다.
    func testDistanceRemapUsesInputRange() {
        XCTAssertEqual(Self.firstSize(inMin: 150, inMax: 200), 5, accuracy: 1e-4)
    }

    /// 같은 def 에서 범위만 기본값으로 되돌리면 종전(클램프) 동작 — 무회귀 대조군.
    func testDefaultRangeKeepsLegacyClampBehaviour() {
        XCTAssertEqual(Self.firstSize(inMin: 0, inMax: 1), 10, accuracy: 1e-4)
    }

    /// 하한 아래는 음수 t 가 되고 `.none` transform 이 0 으로 자른다(실물 `maxps 0`@0x140245117).
    func testBelowInputRangeClampsToOutputMin() {
        XCTAssertEqual(Self.firstSize(inMin: 300, inMax: 400), 0, accuracy: 1e-4)
    }

    // MARK: - 3. cone 파스

    /// 실물 변환식 `-cos(cone·π)` — 반회전 단위다.
    func testConeThresholdTransform() {
        XCTAssertEqual(ParticleSystemDef.emitterConeThreshold(0), -1, accuracy: 1e-6)
        XCTAssertEqual(ParticleSystemDef.emitterConeThreshold(0.5), 0, accuracy: 1e-6)
        XCTAssertEqual(ParticleSystemDef.emitterConeThreshold(1), 1, accuracy: 1e-6)
        XCTAssertEqual(ParticleSystemDef.emitterConeThreshold(1.0 / 3.0), -0.5, accuracy: 1e-6)
    }

    /// 동봉 전건이 `cone: 0` 이라 **실효 도달 0** 이다 — 배열이 비어 종전 def 와 같은 모양이어야 한다.
    /// (동봉 `WEAssets` 2건 · 설치본 2건, 전부 `sphererandom` 의 `magic_vortex_orb`.)
    func testBundledConeZeroLeavesTableEmpty() {
        let def = ParticleSystemDef.parse(Self.emitterJSON(cone: 0), material: nil)
        XCTAssertEqual(def.emitters.count, 1)
        XCTAssertTrue(def.emitterCone.isEmpty, "전건 0 이면 병렬 테이블을 만들지 않는다")
    }

    /// 키 자체가 없을 때도 마찬가지다(부재 기본 0).
    func testMissingConeLeavesTableEmpty() {
        let def = ParticleSystemDef.parse(Self.emitterJSON(cone: nil), material: nil)
        XCTAssertTrue(def.emitterCone.isEmpty)
    }

    /// 값이 실리면 emitters 와 **병렬**로 보존한다(저작값 그대로 — 변환은 파생 함수가 한다).
    func testNonZeroConeIsPreservedInParallel() {
        var json = Self.emitterJSON(cone: 0.25)
        let box: [String: Any] = ["id": 1, "name": "boxrandom", "rate": 1, "distancemax": "0 0 0"]
        var emitters = json["emitter"] as! [Any]
        emitters.append(box)
        json["emitter"] = emitters
        let def = ParticleSystemDef.parse(json, material: nil)
        XCTAssertEqual(def.emitters.count, 2)
        XCTAssertEqual(def.emitterCone.count, def.emitters.count, "emitters 와 병렬이어야 한다")
        guard def.emitterCone.count == 2 else { return }
        XCTAssertEqual(def.emitterCone[0], 0.25, accuracy: 1e-6)
        XCTAssertEqual(def.emitterCone[1], 0, "cone 은 sphererandom 바인더에만 있다")
    }

    /// `cone` 이 있어도 시뮬 결과는 종전과 **완전히 같아야 한다**(미배선 — [미해결] 샘플링 규약).
    func testConeDoesNotChangeSimulation() {
        let a = Self.liveCounts(ParticleSystemDef.parse(Self.emitterJSON(cone: nil), material: nil))
        let b = Self.liveCounts(ParticleSystemDef.parse(Self.emitterJSON(cone: 0.4), material: nil))
        XCTAssertEqual(a, b, "cone 은 아직 시뮬에 배선되지 않았다 — 결과가 갈리면 안 된다")
    }

    // MARK: - 픽스처

    private static func sizeSpec(inMin: Float, inMax: Float) -> RemapSpec {
        sizeSpec(inMin: Vec3(x: inMin, y: inMin, z: inMin),
                 inMax: Vec3(x: inMax, y: inMax, z: inMax))
    }

    private static func sizeSpec(inMin: Vec3, inMax: Vec3) -> RemapSpec {
        RemapSpec(outputChannel: .size, operation: .remap,
                  input: .distanceToControlPoint, transform: nil, octaves: 1, inputScale: 1,
                  outMin: Vec3(x: 0, y: 0, z: 0), outMax: Vec3(x: 10, y: 10, z: 10),
                  blendInStart: 0, blendInEnd: 0, blendOutStart: 1, blendOutEnd: 1,
                  inputCP0: 0, inputCP1: 1, outputCP0: 0, outputCP1: 1,
                  inMin: inMin, inMax: inMax)
    }

    /// CP0 = 원점, 파티클 한 개를 (175,0,0) 에 즉발로 놓는다(거리 175 고정 — RNG 무관).
    private static func firstSize(inMin: Float, inMax: Float) -> Float {
        var d = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 175, y: 0, z: 0),
                            distanceMax: Vec3(x: 0, y: 0, z: 0), rate: 0, burst: 1)],
            initializers: [.lifetimeRandom(min: 1000, max: 1000),
                           .sizeRandom(min: 1, max: 1),
                           .velocityRandom(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 0, y: 0, z: 0)),
                           .alphaRandom(min: 1, max: 1, exponent: 1)],
            operators: [.remapValueEx(spec: sizeSpec(inMin: inMin, inMax: inMax))],
            renderer: .sprite, maxCount: 16, startTime: 0, material: nil)
        d.controlPoints = [Vec3(x: 0, y: 0, z: 0), Vec3(x: 0, y: 0, z: 0)]
        var sim = ParticleSimulator(def: d, seed: 11)
        let shown = sim.step(0.1)
        XCTAssertFalse(shown.isEmpty, "픽스처가 파티클을 하나도 안 내면 이 테스트는 공허하다")
        return shown.first?.size ?? .nan
    }

    private static func emitterJSON(cone: Float?) -> [String: Any] {
        var e: [String: Any] = ["id": 0, "name": "sphererandom", "rate": 4,
                                "distancemin": 0, "distancemax": 0]
        if let cone { e["cone"] = Double(cone) }
        return ["emitter": [e],
                "initializer": [["id": 0, "name": "lifetimerandom", "min": 1000, "max": 1000],
                                ["id": 1, "name": "sizerandom", "min": 1, "max": 1]],
                "operator": [], "maxcount": 64, "renderer": "spritetrail"]
    }

    private static func liveCounts(_ d: ParticleSystemDef, steps: Int = 8) -> [Int] {
        var sim = ParticleSimulator(def: d, seed: 7)
        return (0..<steps).map { _ in _ = sim.step(0.1); return sim.liveCount }
    }
}
