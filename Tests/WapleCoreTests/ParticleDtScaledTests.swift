import XCTest
@testable import WapleCore

/// 오퍼레이터 VM 의 **3번째 인자** `dtScaled` 를 고정한다.
///
/// 호출부 0x140237724–0x14023775f 를 그대로 옮긴 것:
///
///     xmm0 = 0.025 / dt                     0x140237734  (상수 0x140492630 = 0.025f = 1/40)
///     xmm2 = (xmm0 > 1.0) ? 1.0 : xmm0      0x14023773c–0x140237741
///     dtScaled = dt · powf(xmm2, 0.7)       0x140237744–0x14023775f  (지수 0x1404926c8 = 0.7f)
///
/// 규칙은 "운동학은 실시간 dt, **힘·감쇠 계수만** 포화 dt" 다. 이 스위트가 지키는 것은 두 가지 —
/// ① fps ≥ 40 에서 생 dt 와 **비트동일**(무회귀 보장), ② 그 아래에서 실물과 같은 배수.
final class ParticleDtScaledTests: XCTestCase {
    /// dt ≤ 0.025 이면 배수가 정확히 1.0 이라 이른 반환으로 **같은 비트**를 돌려줘야 한다.
    /// powf 를 태우면 1.0 곱셈에서 마지막 비트가 흔들릴 수 있으므로 이 경로가 필요하다.
    func testAtFortyFpsOrAboveIsBitIdenticalToRawDt() {
        let dts: [Float] = [1.0 / 240, 1.0 / 120, 1.0 / 60, 1.0 / 48, 0.025]
        for dt in dts {
            XCTAssertEqual(ParticleSimulator.dtScaled(dt).bitPattern, dt.bitPattern,
                           "dt=\(dt) 에서 비트동일이어야 한다")
        }
    }

    /// 40fps 아래에서만 포화한다. 기대 배수는 `min(1, 0.025/dt)^0.7` 를 직접 계산한 값이다.
    func testBelowFortyFpsSaturates() {
        let expected: [(Float, Float)] = [
            (1.0 / 30, 0.8176), (1.0 / 24, 0.6994), (0.05, 0.6156), (0.1, 0.3789),
        ]
        for (dt, ratio) in expected {
            XCTAssertEqual(ParticleSimulator.dtScaled(dt) / dt, ratio, accuracy: 1e-4,
                           "dt=\(dt) 배수")
            XCTAssertLessThan(ParticleSimulator.dtScaled(dt), dt, "포화는 항상 dt 를 줄인다")
        }
    }

    /// 단조성 — dt 가 커져도 dtScaled 는 줄지 않는다(포화지 반전이 아니다).
    func testIsMonotonicInDt() {
        // 0 에서 시작한다 — 종전엔 `dtScaled(1/240)`(=0.004167)으로 초기화해 놓고 루프를
        // dt=0.002 부터 돌려서, 첫 비교가 곧바로 "역전" 으로 잡혔다(내 테스트 버그였다).
        var prev: Float = 0
        for i in 1...200 {
            let dt = Float(i) * 0.002
            let s = ParticleSimulator.dtScaled(dt)
            XCTAssertGreaterThanOrEqual(s, prev, "dt=\(dt) 에서 역전")
            prev = s
        }
    }

    /// 60fps 시뮬은 dtScaled 도입 **전과 같은 결과**여야 한다 — 모든 적용 지점이 `dtScaled == dt`
    /// 를 받으므로 산술이 그대로다. drag 클램프만 형태가 바뀌는데(`max(0, 1−x)` → `1 − min(x, …)`),
    /// `drag·dt < 1` 이면 두 식이 같은 값이라 여기서도 차이가 없다(이 정의는 drag·dt ≈ 0.033).
    func testSixtyFpsSimulationMatchesPreDtScaledBaseline() {
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 5, y: 5, z: 0), distanceMax: Vec3(x: 1, y: 1, z: 0),
                            rate: 200, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100),
                           .velocityRandom(min: Vec3(x: -10, y: -10, z: 0), max: Vec3(x: 10, y: 10, z: 0))],
            operators: [.movement(gravity: Vec3(x: 0, y: -30, z: 0), drag: 2),
                        .turbulence(speedMin: 50, speedMax: 80, scale: 0.02, timeScale: 3,
                                    mask: Vec3(x: 1, y: 1, z: 0), phaseMin: 0, phaseMax: 1),
                        .controlPointAttract(scale: 10, threshold: 500, target: Vec3(x: 0, y: 0, z: 0),
                                             deleteThreshold: false, flags: 0),
                        .boids(separationThreshold: 20, neighborThreshold: 60, maxSpeed: 300,
                               separationFactor: 3, alignmentFactor: 2, cohesionFactor: 1, flags: 1)],
            renderer: .sprite, maxCount: 24, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 17)
        var last: [Particle] = []
        for _ in 0..<120 { last = sim.step(1.0 / 60.0) }
        XCTAssertEqual(last.count, 24)
        // [2026-08-21] 기준값을 다시 뽑았다. 종전 값(Σ|pos| 1046.868774 · Σ|vel| 205.422028)은
        // dtScaled 도입 전 바이너리에서 뽑은 것이었는데, 이 정의가 쓰는 `turbulence` 의 **노이즈
        // 커널이 자작 값노이즈 → 실물 3D 심플렉스 ×32** 로 바뀌면서 그 앵커가 사라졌다.
        // 이 테스트가 지키려던 불변식(60fps 에서 `dtScaled == dt` 라 산술이 그대로)은 여전히
        // 위 `dtScaled` 단위 테스트와 아래 10fps 발산 단언이 지킨다 — 여기 두 숫자는 그 위에서
        // "커널·적분 순서가 조용히 바뀌지 않았는지" 를 보는 회귀 앵커다.
        func len(_ v: SIMD3<Float>) -> Float { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }
        let sumPos = last.reduce(Float(0)) { $0 + len($1.pos) }
        let sumVel = last.reduce(Float(0)) { $0 + len($1.vel) }
        XCTAssertEqual(sumPos, 593.27484, accuracy: 0.01)
        XCTAssertEqual(sumVel, 243.9239, accuracy: 0.01)

        // 반대로 10fps 에서는 **갈려야 한다** — 갈리지 않으면 dtScaled 가 어디에도 안 걸린 것이다.
        // 도입 전 같은 정의·같은 시드의 실측값은 Σ|pos|=984.134216 · Σ|vel|=220.649338 이었다.
        // 감쇠가 약해지므로(drag·dt 0.2 → drag·dtScaled 0.0758) 속도가 **커지는** 방향이 맞다.
        var slow = ParticleSimulator(def: def, seed: 17)
        var slowLast: [Particle] = []
        for _ in 0..<20 { slowLast = slow.step(0.1) }
        let slowVel = slowLast.reduce(Float(0)) { $0 + len($1.vel) }
        XCTAssertGreaterThan(slowVel, 400, "10fps 에서 감쇠가 완화돼 속도가 커져야 한다 (도입 전 220.6)")
    }
}
