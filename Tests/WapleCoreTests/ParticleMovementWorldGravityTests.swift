import XCTest
@testable import WapleCore

/// `movement` 오퍼레이터의 `flags` bit0 — 중력이 **월드 공간 벡터**임을 뜻한다.
///
/// 실물 경로(오퍼레이터 VM op 0x01 핸들러 0x14023fdc9):
///   0x14023fdc9  movsd xmm8, [r14+0x10] / mov eax,[r14+0x18]   중력 vec3 를 스택으로
///   0x14023fde2  test byte [r14+0x1c], 1                        오퍼레이터 flags bit0
///   0x14023fde7  je   0x14023fe37                               꺼져 있으면 회전 없음
///   0x14023fde9  test byte [rsi+0x20], 1                        시스템 worldspace 비트
///   0x14023fded  jne  0x14023fe37                               이미 월드 시뮬이면 변환 불필요
///   0x14023fdfd  call 0x1400dd7d0                               오브젝트 4×4 → 촘촘한 3×3
///   0x14023fe13  call 0x1401f87e0                               out.c = dot(row_c, gravity)
///
/// 파스 쪽은 0x1401cb39d 가 `"flags"` 문자열을 만들고 0x1401cb3ce 정수 게터를 거쳐
/// 0x1401cb3d3 `mov [r14+0xc], eax` 로 페이로드 +0x0c 에 적는다(런타임 +0x1c).
final class ParticleMovementWorldGravityTests: XCTestCase {

    // MARK: 파스

    func testMovementFlagsParsed() {
        let d = ParticleSystemDef.parse(["operator": [
            ["name": "movement", "gravity": "0 -200 0", "flags": 1],
        ]], material: nil)
        XCTAssertEqual(d.operators, [.movement(gravity: Vec3(x: 0, y: -200, z: 0), drag: 0, flags: 1)])
    }

    func testMovementFlagsDefaultsToZeroWhenAbsent() {
        let d = ParticleSystemDef.parse(["operator": [
            ["name": "movement", "gravity": "0 -9.8 0"],
        ]], material: nil)
        // 기본 0 — 인자 생략형 리터럴과 같아야 한다(기존 저작 무회귀).
        XCTAssertEqual(d.operators, [.movement(gravity: Vec3(x: 0, y: -9.8, z: 0), drag: 0)])
    }

    // MARK: 기저 행렬

    func testWorldBasisIdentityIsNoOp() {
        let v = SIMD3<Float>(3, -4, 5)
        XCTAssertEqual(ParticleWorldBasis.identity.apply(v), v)
    }

    /// 0x1401f87e0 의 산술을 그대로: `out.c = dot(row_c, v)`.
    func testWorldBasisAppliesRowDot() {
        let b = ParticleWorldBasis(row0: SIMD3(1, 2, 3), row1: SIMD3(4, 5, 6), row2: SIMD3(7, 8, 9))
        XCTAssertEqual(b.apply(SIMD3(1, 0, 0)), SIMD3(1, 4, 7))   // 열을 뽑는다(행과의 내적이므로)
        XCTAssertEqual(b.apply(SIMD3(0, 1, 0)), SIMD3(2, 5, 8))
        XCTAssertEqual(b.apply(SIMD3(1, 1, 1)), SIMD3(6, 15, 24))
    }

    /// 열우선 월드행렬의 좌상단 3×3 열 3개를 그대로 행에 꽂는다 —
    /// 열우선 저장의 열 c 와 실물 행우선 행 c 가 같은 것(로컬 기저의 월드 이미지)을 가리키기 때문이다.
    func testWorldBasisFromWorldColumns() {
        let b = ParticleWorldBasis(worldColumns: SIMD3(1, 2, 3), SIMD3(4, 5, 6), SIMD3(7, 8, 9))
        XCTAssertEqual(b, ParticleWorldBasis(row0: SIMD3(1, 2, 3), row1: SIMD3(4, 5, 6), row2: SIMD3(7, 8, 9)))
    }

    // MARK: 시뮬레이터 게이트

    /// 중력만 실리는 최소 def — box 이미터(distanceMax 0)로 원점에 1개, 초기속도 0.
    private func gravityDef(operatorFlags: Int, systemFlags: Int) -> ParticleSystemDef {
        var d = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                            rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100),
                           .sizeRandom(min: 5, max: 5),
                           .velocityRandom(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 0, y: 0, z: 0)),
                           .alphaRandom(min: 1, max: 1, exponent: 1)],
            operators: [.movement(gravity: Vec3(x: 0, y: -200, z: 0), drag: 0, flags: operatorFlags)],
            renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
        d.flags = systemFlags
        return d
    }

    /// z축 +90° 회전의 월드행렬(열우선 열 = 로컬 기저의 월드 이미지).
    /// x_local → +y_world, y_local → −x_world.
    private var rotZ90: ParticleWorldBasis {
        ParticleWorldBasis(worldColumns: SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1))
    }

    private func velocityAfterOneStep(_ def: ParticleSystemDef, basis: ParticleWorldBasis?) -> SIMD3<Float> {
        var sim = ParticleSimulator(def: def, seed: 7)
        if let basis { sim.worldBasis = basis }
        let out = sim.step(0.1)
        XCTAssertEqual(out.count, 1)
        return out.first?.vel ?? SIMD3(.nan, .nan, .nan)
    }

    /// 게이트 통과: 오퍼레이터 flags bit0 · 시스템 worldspace 꺼짐 → 중력이 월드→로컬로 돈다.
    /// (0,−200,0) 을 rotZ90 의 행과 내적하면 (0·0 + (−200)·1 + 0·0, 0·(−1)+…, 0) = (−200, 0, 0).
    func testWorldGravityIsRotatedIntoLocalSpace() {
        let v = velocityAfterOneStep(gravityDef(operatorFlags: 1, systemFlags: 0), basis: rotZ90)
        XCTAssertEqual(v.x, -20, accuracy: 1e-3)   // −200 × dt(0.1)
        XCTAssertEqual(v.y, 0, accuracy: 1e-3)
        XCTAssertEqual(v.z, 0, accuracy: 1e-3)
    }

    /// 오퍼레이터 flags bit0 이 꺼져 있으면 기저와 무관하게 원본 중력(0x14023fde7 `je`).
    func testOperatorFlagBitClearSkipsRotation() {
        let v = velocityAfterOneStep(gravityDef(operatorFlags: 0, systemFlags: 0), basis: rotZ90)
        XCTAssertEqual(v.x, 0, accuracy: 1e-3)
        XCTAssertEqual(v.y, -20, accuracy: 1e-3)
    }

    /// 시스템 최상위 `flags & 1`(worldspace) 이면 이미 월드 시뮬이라 변환을 건너뛴다
    /// (0x14023fded `jne`). 동봉 rain_splashes_droplets 2건이 정확히 이 조합이다.
    func testSystemWorldspaceBitSkipsRotation() {
        let v = velocityAfterOneStep(gravityDef(operatorFlags: 1, systemFlags: 1), basis: rotZ90)
        XCTAssertEqual(v.x, 0, accuracy: 1e-3)
        XCTAssertEqual(v.y, -20, accuracy: 1e-3)
    }

    /// 기저를 아무도 안 넣으면(2D 정사영 경로처럼 회전 개념이 없는 곳) 종전과 완전히 같다.
    func testUntouchedBasisIsBitIdenticalToLegacy() {
        let withFlag = velocityAfterOneStep(gravityDef(operatorFlags: 1, systemFlags: 0), basis: nil)
        let without = velocityAfterOneStep(gravityDef(operatorFlags: 0, systemFlags: 0), basis: nil)
        XCTAssertEqual(withFlag, without)
    }

    /// 기저를 나중에 바꿔도 구움이 따라온다(렌더러가 매 프레임 넣는 경로).
    func testBasisAssignmentRebakesGravity() {
        var sim = ParticleSimulator(def: gravityDef(operatorFlags: 1, systemFlags: 0), seed: 7)
        let a = sim.step(0.1)
        XCTAssertEqual(a.first?.vel.y ?? 0, -20, accuracy: 1e-3)
        sim.worldBasis = rotZ90
        let b = sim.step(0.1)
        // 두 번째 스텝은 회전된 중력 → x 로 −20 이 더 실린다(y 는 그대로 −20).
        XCTAssertEqual(b.first?.vel.x ?? 0, -20, accuracy: 1e-3)
        XCTAssertEqual(b.first?.vel.y ?? 0, -20, accuracy: 1e-3)
    }
}
