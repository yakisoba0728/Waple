import XCTest
import simd
@testable import WapleCore

/// 씬 구현 갭 파티클 수정(F620~F631) 회귀 — 실물 코퍼스 스키마(460프로젝트 전수 추출) 기반.
/// 대상: S-3 이미터 speed(F620) / S-4 burst+rate 병행(F621) / S-22 animationmode(F622) /
/// S-23 flags(F623) / S-24 vortex 오디오(F624) / S-25·S-66 트레일 샘플(F625/F629) /
/// S-26 orientation(F626) / S-28 box distancemin(F627) / S-65 다중 turbulence(F628) /
/// S-67 mapsequence axis(F630) / S-63 vortex_v2(F631).
final class ParticleSceneFixRegressionTests: XCTestCase {

    // MARK: - F620 (S-3): 이미터 speedmin/speedmax → 방출 방향 초기속도

    /// 실물 fireworks1hit(sphererandom speedmax 1500, velocity 이니셜라이저 無) 형태 —
    /// 종전엔 초기속도 0으로 안 터졌다. speed 가 있으면 스폰 즉시 |vel| ∈ [speedmin, speedmax].
    func testF620_EmitterSpeedGivesInitialVelocity() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"sphererandom","rate":0,"distancemin":0,"distancemax":0,"instantaneous":5,
                      "speedmin":100,"speedmax":1500}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(def.emitterSpeed.count, 1)
        XCTAssertEqual(def.emitterSpeed[0], SIMD2<Float>(100, 1500))
        var sim = ParticleSimulator(def: def, seed: 42)
        let parts = sim.step(0.001)
        XCTAssertEqual(parts.count, 5)
        for p in parts {
            let v = SIMD3<Float>(p.vel.x, p.vel.y, p.vel.z)
            let speed = simd_length(v)
            XCTAssertGreaterThanOrEqual(speed, 100 * 0.999)
            XCTAssertLessThanOrEqual(speed, 1500 * 1.001)
        }
    }

    /// speed 키 부재(0,0)는 RNG 드로 0 — 동일 def 를 직접 조립한 기준과 스폰 결과 비트동일(무회귀).
    func testF620_NoSpeedKeyIsBitIdentical() {
        let parsed = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"sphererandom","origin":"10 20 0","distancemin":5,"distancemax":50,"rate":100}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100}],
         "renderer":[{"name":"sprite"}],"maxcount":50}
        """), material: nil)
        XCTAssertEqual(parsed.emitterSpeed, [SIMD2<Float>(0, 0)])
        let plain = ParticleSystemDef(
            // directions (1,1,0): 파스 디폴트가 엔진 정본("1 1 0" @0x48e288)으로 변경됨 — 기준 측도 갱신.
            emitters: [.sphere(origin: Vec3(x: 10, y: 20, z: 0), directions: Vec3(x: 1, y: 1, z: 0),
                               distanceMin: 5, distanceMax: 50, rate: 100, burst: 0,
                               sign: Vec3(x: 0, y: 0, z: 0))],
            initializers: [.lifetimeRandom(min: 100, max: 100)],
            operators: [], renderer: .sprite, maxCount: 50, startTime: 0, material: nil)
        var a = ParticleSimulator(def: parsed, seed: 7)
        var b = ParticleSimulator(def: plain, seed: 7)
        for _ in 0..<5 {
            let pa = a.step(0.05), pb = b.step(0.05)
            XCTAssertEqual(pa.count, pb.count)
            for (x, y) in zip(pa, pb) { XCTAssertEqual(x.pos, y.pos) }
        }
    }

    /// speedmin 만 있는 실물(lightning2glow 류 — speedmax 부재) → 고정속도(speedmin 승계).
    func testF620_SpeedMinOnlyIsFixedSpeed() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"sphererandom","rate":0,"distancemax":0,"instantaneous":3,"speedmin":250,"speedmax":250}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100}],
         "renderer":[{"name":"sprite"}],"maxcount":5}
        """), material: nil)
        var sim = ParticleSimulator(def: def, seed: 1)
        for p in sim.step(0.001) {
            XCTAssertEqual(simd_length(SIMD3<Float>(p.vel.x, p.vel.y, p.vel.z)), 250, accuracy: 0.01)
        }
    }

    // MARK: - F621 (S-4): burst(instantaneous) + rate 병행

    /// 실물 rain_on_the_glass(instantaneous 20 + rate 50) — 종전 else-if 구조는 rate 분기 영구 미진입.
    /// 첫 스텝: 버스트 20 발화. 이후: rate 로 계속 늘어나야 한다.
    func testF621_BurstAndRateEmitInParallel() {
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                            rate: 50, burst: 20)],
            initializers: [.lifetimeRandom(min: 100, max: 100)],
            operators: [], renderer: .sprite, maxCount: 1000, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 3)
        let first = sim.step(0.1)
        XCTAssertEqual(first.count, 20 + 5)   // 버스트 20 + rate 50×0.1
        for i in 1...10 {
            let n = sim.step(0.1).count
            XCTAssertEqual(n, 20 + 5 * (i + 1), "burst>0 이어도 rate 연속 방출이 계속되어야 한다")
        }
    }

    /// burst-only(rate 0)는 종전과 비트동일 — acc 가 0 유지, 전멸 시 재버스트(ponytail) 유지.
    func testF621_BurstOnlyUnchanged() {
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                            rate: 0, burst: 7)],
            initializers: [.lifetimeRandom(min: 0.15, max: 0.15)],
            operators: [], renderer: .sprite, maxCount: 100, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 5)
        XCTAssertEqual(sim.step(0.1).count, 7)
        _ = sim.step(0.1)   // 전멸(0.15 초과) 직전
        XCTAssertEqual(sim.step(0.1).count, 7, "전멸 후 재버스트(ponytail 루프) 유지 — rate 방출은 없어야 한다")
    }

    // MARK: - F622 (S-22): animationmode=randomframe 스폰 확정 프레임

    /// randomframe — 스폰 시 프레임 1개 고정(종전 age/frametime 폴터는 정지 파티클이 매 프레임 깜빡임).
    func testF622_RandomFrameFixedAtSpawn() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","distancemax":"0 0 0","rate":100}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100}],
         "renderer":[{"name":"sprite"}],"maxcount":10,"animationmode":"randomframe"}
        """), material: nil)
        XCTAssertEqual(def.animationMode, .randomframe)
        var sim = ParticleSimulator(def: def, seed: 9)
        let first = sim.step(0.05)
        XCTAssertFalse(first.isEmpty)
        for p in first { XCTAssertGreaterThanOrEqual(p.frame, 0, "randomframe 은 스폰 시 프레임 확정") }
        // 프레임이 수명 동안 불변인지(깜빡임 아님) — 동일 파티클 uid 의 frame 비교
        var frames: [Int: Float] = Dictionary(uniqueKeysWithValues: first.map { ($0.uid, $0.frame) })
        for _ in 0..<3 {
            for p in sim.step(0.05) {
                if let f0 = frames[p.uid] { XCTAssertEqual(p.frame, f0, "randomframe 은 수명 동안 고정") }
                else { frames[p.uid] = p.frame }
            }
        }
    }

    /// animationmode 부재 → nil(기존 frametime 폴터) + frame 은 -1 유지(스폰 미확정).
    func testF622_NoAnimationModeKeepsLegacyFallback() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","distancemax":"0 0 0","rate":100}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        XCTAssertNil(def.animationMode)
        var sim = ParticleSimulator(def: def, seed: 9)
        for p in sim.step(0.05) { XCTAssertEqual(p.frame, -1) }
    }

    /// sequencemultiplier 파스(실측 "3" 등) — 소비는 렌더 경로(프레임 수 필요)라 파스·보존 검증.
    func testF622_SequenceMultiplierParsed() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","distancemax":"0 0 0","rate":1}],
         "renderer":[{"name":"sprite"}],"maxcount":10,
         "animationmode":"sequence","sequencemultiplier":3}
        """), material: nil)
        XCTAssertEqual(def.animationMode, .sequence)
        XCTAssertEqual(def.sequenceMultiplier, 3)
    }

    // MARK: - F623 (S-23): def flags 파스(perspective=4 / worldspace=1)

    func testF623_FlagsParsed() {
        let perspective = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"sprite"}],
         "maxcount":10,"flags":4}
        """), material: nil)
        XCTAssertEqual(perspective.flags, 4)   // snowperspective 프리셋 실측값
        let worldspace = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"sprite"}],
         "maxcount":10,"flags":1}
        """), material: nil)
        XCTAssertEqual(worldspace.flags, 1)
        // 부재 시 0(기본) — 기존 def 동등
        let absent = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(absent.flags, 0)
    }

    // MARK: - F624 (S-24): vortex 오퍼레이터 오디오반응(속도 배수)

    /// 실물 stars_copy(vortex audioprocessingmode 3) — 파스 + 신호 시 회전 속도 변조.
    func testF624_VortexAudioParsedAndModulates() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","distancemax":"100 0 0","rate":100}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100}],
         "operator":[{"name":"vortex","axis":"0 0 1","distanceinner":0,"distanceouter":100,
                      "speedinner":500,"speedouter":500,"audioprocessingmode":3,
                      "audioprocessingbounds":"0 1"}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(def.vortexAudio.count, 1)
        XCTAssertNotNil(def.vortexAudio[0])
        // 무신호: 오디오 무시 경로와 동일(비트동일 가드)
        var silent = ParticleSimulator(def: def, seed: 11)
        silent.currentAudio = .silent
        var plain = ParticleSimulator(def: def, seed: 11)
        let ps = silent.step(0.1), pp = plain.step(0.1)
        XCTAssertEqual(ps.count, pp.count)
        for (x, y) in zip(ps, pp) { XCTAssertEqual(x.pos, y.pos) }
        // 강신호: 응답 1 → 풀 회전 / 약신호: 회전 감쇠 — 같은 시드에서 궤적이 갈라져야 한다
        func run(_ level: Float) -> ParticleSimulator {
            var s = ParticleSimulator(def: def, seed: 11)
            s.currentAudio = AudioSpectrum16(left: Array(repeating: level, count: 16),
                                             right: Array(repeating: level, count: 16))
            return s
        }
        var loud = run(1.0), quiet = run(0.05)
        _ = loud.step(0.1); _ = quiet.step(0.1)
        let pl = loud.step(0.1), pq = quiet.step(0.1)
        XCTAssertEqual(pl.count, pq.count)
        XCTAssertNotEqual(pl.map { $0.pos }, pq.map { $0.pos }, "vortex 속도가 오디오 응답으로 변조되어야 한다")
    }

    // MARK: - F625/F629 (S-25/S-66): 트레일 샘플 수

    func testF625_TrailSampleCounts() {
        // 종전 4..24 클램프 — maxlength 100/ropetrail 수초가 24샘플(0.8초)로 절단됐다. 캡 240.
        XCTAssertEqual(RendererKind.spriteTrail(maxLength: 100, length: 0.005, minLength: 0).trailSampleCount, 100)
        XCTAssertEqual(RendererKind.spriteTrail(maxLength: 1000, length: 0, minLength: 0).trailSampleCount, 240)
        XCTAssertEqual(RendererKind.spriteTrail(maxLength: 0, length: 0.007, minLength: 0).trailSampleCount, 8)  // 기본
        XCTAssertEqual(RendererKind.ropeTrail(length: 4, subdivision: 2).trailSampleCount, 120)     // 4초×30
        XCTAssertEqual(RendererKind.ropeTrail(length: 30, subdivision: 0).trailSampleCount, 240)    // 캡
        XCTAssertEqual(RendererKind.ropeTrail(length: 0, subdivision: 5).trailSampleCount, 5)       // subdivision 폴터
        // F629: rope subdivision 반영(종전 고정 16 — subdivision 100 이 1/6 해상도였다)
        XCTAssertEqual(RendererKind.rope(subdivision: 100).trailSampleCount, 100)
        XCTAssertEqual(RendererKind.rope(subdivision: 3).trailSampleCount, 4)                       // 하한 4
        XCTAssertEqual(RendererKind.rope(subdivision: 0).trailSampleCount, 16)                      // 부재 기본(무회귀)
    }

    // MARK: - F626 (S-26): 렌더러 orientation 파스

    func testF626_OrientationParsed() {
        let fixed = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],
         "renderer":[{"name":"sprite","orientation":"fixed","axis":"0 0 1"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(fixed.orientation, .fixed(axis: Vec3(x: 0, y: 0, z: 1)))
        let upright = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],
         "renderer":[{"name":"spritetrail","orientation":"upright"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(upright.orientation, .upright)
        // 부재/screen = 기본(기존 스크린 빌보드 폴터)
        let screen = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","rate":1}],"renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        XCTAssertEqual(screen.orientation, .screen)
    }

    // MARK: - F627 (S-28): boxrandom distancemin 코너 쌍

    /// 실물 shootingstar(distancemin "700 100 0" / distancemax "3840 360 0") — 종전 ±max 대칭이라
    /// 우측 밴드가 전폭 스폰으로 퍼졌다. 스폰 영역이 코너 AABB 안이어야 한다.
    func testF627_BoxDistanceMinCorners() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","origin":"-256 256 0","distancemin":"700 100 0",
                      "distancemax":"3840 360 0","rate":1000}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100}],
         "renderer":[{"name":"sprite"}],"maxcount":200}
        """), material: nil)
        XCTAssertEqual(def.boxDistanceMin.count, 1)
        XCTAssertEqual(def.boxDistanceMin[0], Vec3(x: 700, y: 100, z: 0))
        var sim = ParticleSimulator(def: def, seed: 13)
        for p in sim.step(0.1) {
            XCTAssertGreaterThanOrEqual(p.pos.x, -256 + 700 - 0.001)
            XCTAssertLessThanOrEqual(p.pos.x, -256 + 3840 + 0.001)
            XCTAssertGreaterThanOrEqual(p.pos.y, 256 + 100 - 0.001)
            XCTAssertLessThanOrEqual(p.pos.y, 256 + 360 + 0.001)
        }
    }

    /// min>max 축(실물 "500 500 0"~"1000 256 0")은 성분별 정규화, distancemin 부재는 ±max 레거시.
    func testF627_InvertedAxisNormalizedAndLegacyDefault() {
        let inverted = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","distancemin":"500 500 0","distancemax":"1000 256 0","rate":1000}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100}],
         "renderer":[{"name":"sprite"}],"maxcount":200}
        """), material: nil)
        var sim = ParticleSimulator(def: inverted, seed: 17)
        for p in sim.step(0.1) {
            XCTAssert((500.0 - 0.001...1000.0 + 0.001).contains(p.pos.x), "x ∈ [500,1000]")
            XCTAssert((256.0 - 0.001...500.0 + 0.001).contains(p.pos.y), "y 는 역순 코너 정규화 [256,500]")
        }
        // 부재 시 ±distanceMax(기존 비트동일 — 직접 조립 def 와 동일 스폰)
        let legacyParsed = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","distancemax":"100 50 0","rate":1000}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100}],
         "renderer":[{"name":"sprite"}],"maxcount":50}
        """), material: nil)
        XCTAssertNil(legacyParsed.boxDistanceMin[0])
        let plain = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 100, y: 50, z: 0),
                            rate: 1000, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100)],
            operators: [], renderer: .sprite, maxCount: 50, startTime: 0, material: nil)
        var a = ParticleSimulator(def: legacyParsed, seed: 19)
        var b = ParticleSimulator(def: plain, seed: 19)
        let pa = a.step(0.05), pb = b.step(0.05)
        XCTAssertEqual(pa.count, pb.count)
        for (x, y) in zip(pa, pb) { XCTAssertEqual(x.pos, y.pos) }
    }

    // MARK: - F628 (S-65): 다중 turbulence 오퍼레이터 누적

    /// 실물 3000562427(turbulence 2개 — 지배 성분이 first-wins 로 드롭됐다). 두 번째 오퍼레이터도
    /// 스폰 샘플·이류에 참여해야 한다.
    func testF628_MultipleTurbulenceOperatorsAccumulate() {
        func turbOp(_ smin: Float, _ smax: Float) -> ParticleOperator {
            .turbulence(speedMin: smin, speedMax: smax, scale: 0.01, timeScale: 0,
                        mask: Vec3(x: 1, y: 1, z: 1), phaseMin: 0, phaseMax: 1)
        }
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                            rate: 100, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100)],
            operators: [turbOp(1, 1), turbOp(200, 200)],
            renderer: .sprite, maxCount: 10, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 23)
        let parts = sim.step(0.1)
        XCTAssertFalse(parts.isEmpty)
        // 두 오퍼레이터 누적이면 첫 오퍼레이터(속도 1)만으로는 설명 불가한 변위가 생긴다
        var onlyFirst = ParticleSimulator(def: ParticleSystemDef(
            emitters: def.emitters, initializers: def.initializers, operators: [turbOp(1, 1)],
            renderer: def.renderer, maxCount: def.maxCount, startTime: 0, material: nil), seed: 23)
        let ref = onlyFirst.step(0.1)
        XCTAssertNotEqual(parts.map { $0.pos }, ref.map { $0.pos }, "두 번째 turbulence 도 이류에 참여해야 한다")
        let moved = zip(parts, ref).contains { simd_distance($0.pos, $1.pos) > 0.5 }
        XCTAssertTrue(moved, "지배 성분(속도 200)의 변위가 복원되어야 한다")
    }

    /// 단일 turbulence 는 종전과 비트동일(스폰 드로 수 불변).
    func testF628_SingleTurbulenceUnchanged() {
        let op: ParticleOperator = .turbulence(speedMin: 5, speedMax: 10, scale: 0.01, timeScale: 1,
                                               mask: Vec3(x: 1, y: 1, z: 1), phaseMin: 0, phaseMax: 1)
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                            rate: 100, burst: 0)],
            initializers: [.lifetimeRandom(min: 100, max: 100)],
            operators: [op], renderer: .sprite, maxCount: 10, startTime: 0, material: nil)
        var sim = ParticleSimulator(def: def, seed: 29)
        let parts = sim.step(0.1)
        XCTAssertFalse(parts.isEmpty)
        // turbExtra 는 비어 있어야 한다(첫 오퍼레이터만 스칼라 경로) — 스칼라 경로의 스폰 샘플이
        // 실제 일어났는지(turbSpeed > 0)도 함께 확인해 단언이 공허해지지 않게 한다.
        XCTAssertTrue(parts.allSatisfy { $0.turbSpeed > 0 }, "첫 turbulence 는 스칼라 경로로 스폰 샘플")
        XCTAssertTrue(parts.allSatisfy { $0.turbExtra.isEmpty }, "단일 오퍼레이터는 turbExtra 신규 드로 0")
        // 동일 시드 재실행은 비트동일(스폰 드로 수 불변 → RNG 스트림 재현).
        var sim2 = ParticleSimulator(def: def, seed: 29)
        let parts2 = sim2.step(0.1)
        XCTAssertEqual(parts2.count, parts.count)
        XCTAssertEqual(parts2.map { $0.pos }, parts.map { $0.pos }, "동일 시드 재실행 비트동일")
    }

    // MARK: - F630 (S-67): mapsequencearoundcontrolpoint axis 회전 평면

    /// axis "0 1 0"(실측 2씬) → XZ 평면 각도. (1,0,0) 위치: Y축=atan2(1,0)=π/2 → t=0.75,
    /// 레거시 Z축=atan2(0,1)=0 → t=0.5.
    func testF630_MapSequenceAxisSelectsPlane() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","origin":"1 0 0","distancemax":"0 0 0","rate":100}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100},
                        {"name":"mapsequencearoundcontrolpoint","count":8,"axis":"0 1 0"}],
         "renderer":[{"name":"sprite"}],"maxcount":5}
        """), material: nil)
        XCTAssertEqual(def.mapSequenceAxis, Vec3(x: 0, y: 1, z: 0))
        var sim = ParticleSimulator(def: def, seed: 31)
        let parts = sim.step(0.05)
        XCTAssertFalse(parts.isEmpty)
        for p in parts { XCTAssertEqual(p.frame, 0.75 * 8, accuracy: 0.001, "Y축 회전(XZ 평면) 각도") }
        // axis 부재는 레거시 XY 평면(비트동일)
        let legacy = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","origin":"1 0 0","distancemax":"0 0 0","rate":100}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100},
                        {"name":"mapsequencearoundcontrolpoint","count":8}],
         "renderer":[{"name":"sprite"}],"maxcount":5}
        """), material: nil)
        XCTAssertNil(legacy.mapSequenceAxis)
        var sim2 = ParticleSimulator(def: legacy, seed: 31)
        for p in sim2.step(0.05) { XCTAssertEqual(p.frame, 0.5 * 8, accuracy: 0.001) }
    }

    // MARK: - F631 (S-63): vortex_v2 → 표준 vortex 근사 매핑

    /// 실물 3585875739(vortex_v2 2개 — 종전 default 드롭). 표준 vortex 파라미터로 복원.
    func testF631_VortexV2MappedToVortex() {
        let def = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"boxrandom","distancemax":"550 0 0","rate":100}],
         "initializer":[{"name":"lifetimerandom","min":100,"max":100}],
         "operator":[{"name":"vortex_v2","distanceinner":487,"distanceouter":625,"speedinner":172,
                      "audioprocessingmode":3,"audioprocessingbounds":"0.6 1"}],
         "renderer":[{"name":"sprite"}],"maxcount":10}
        """), material: nil)
        guard case let .vortex(axis, dIn, dOut, sIn, sOut, _, _, _, _, _, _, _) = def.operators.first else {
            return XCTFail("vortex_v2 가 vortex 로 매핑되어야 한다")
        }
        XCTAssertEqual(axis, Vec3(x: 0, y: 0, z: 1))
        XCTAssertEqual(dIn, 487); XCTAssertEqual(dOut, 625)
        XCTAssertEqual(sIn, 172); XCTAssertEqual(sOut, 172)   // speedouter 부재 = speedinner 승계
        XCTAssertEqual(def.vortexAudio.count, 1)
        XCTAssertNotNil(def.vortexAudio[0])
        // 드롭되지 않고 실제 회전력을 가한다(속도 0 출발 → vortex 가 속도를 부여)
        var sim = ParticleSimulator(def: def, seed: 37)
        _ = sim.step(0.1)
        let parts = sim.step(0.1)
        XCTAssertFalse(parts.isEmpty)
        XCTAssertTrue(parts.contains { simd_length(SIMD3<Float>($0.vel.x, $0.vel.y, $0.vel.z)) > 1 },
                      "vortex_v2 가 묵동작이면 안 된다")
    }

    // MARK: - 무회귀 가드: 신규 필드 전부 부재인 def 는 직접 조립 def 와 동치

    /// 파스된 def(신규 키 전무)와 직접 조립 def 의 시뮬 결과 비트동일 — F620/622/627/628/630 경로 전부
    /// 키 부재 시 드로 0·레거시 분기임을 종합 검증.
    func testNoNewKeysParsedDefMatchesPlainDef() {
        let parsed = ParticleSystemDef.parse(json("""
        {"emitter":[{"name":"sphererandom","distancemin":1,"distancemax":10,"rate":50},
                    {"name":"boxrandom","distancemax":"20 10 0","rate":50}],
         "initializer":[{"name":"lifetimerandom","min":50,"max":50},
                        {"name":"velocityrandom","min":"1 2 0","max":"3 4 0"}],
         "operator":[{"name":"movement","gravity":"0 -9.8 0"}],
         "renderer":[{"name":"sprite"}],"maxcount":100}
        """), material: nil)
        let plain = ParticleSystemDef(
            // directions (1,1,0): 파스 디폴트가 엔진 정본("1 1 0" @0x48e288)으로 변경됨 — 동치 가드의 기준 측도 갱신.
            emitters: [.sphere(origin: Vec3(x: 0, y: 0, z: 0), directions: Vec3(x: 1, y: 1, z: 0),
                               distanceMin: 1, distanceMax: 10, rate: 50, burst: 0,
                               sign: Vec3(x: 0, y: 0, z: 0)),
                       .box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 20, y: 10, z: 0),
                            rate: 50, burst: 0)],
            initializers: [.lifetimeRandom(min: 50, max: 50),
                           .velocityRandom(min: Vec3(x: 1, y: 2, z: 0), max: Vec3(x: 3, y: 4, z: 0))],
            operators: [.movement(gravity: Vec3(x: 0, y: -9.8, z: 0), drag: 0)],
            renderer: .sprite, maxCount: 100, startTime: 0, material: nil)
        var a = ParticleSimulator(def: parsed, seed: 41)
        var b = ParticleSimulator(def: plain, seed: 41)
        for _ in 0..<10 {
            let pa = a.step(0.05), pb = b.step(0.05)
            XCTAssertEqual(pa.count, pb.count)
            for (x, y) in zip(pa, pb) {
                XCTAssertEqual(x.pos, y.pos)
                XCTAssertEqual(x.vel, y.vel)
                XCTAssertEqual(x.frame, y.frame)
            }
        }
    }
}
