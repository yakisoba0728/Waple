import XCTest
@testable import WapleCore

/// `emitter[].duration` / `delay` 방출 창 — 실물 게이트를 그대로 재는 테스트.
///
/// 실물 파티클 tick `0x1402378a0`–`0x14023b33d`(`r15` = 이미터 레코드):
///   · 은퇴 비트 `0x1402379d2`–`0x1402379db` — 서 있으면 방출 블록을 통째로 건너뛴다(**영구**)
///   · ① `0x1402379ea` `comiss xmm8, [r15+0x18]` / `jb` — **delay > 0 이면 이번 프레임 방출 없음**
///   · ② `0x140237af1` — **duration < 0 이면 방출 없음**
///   · ③ `0x140238461` — `delay > 0` 이면 `delay -= dt` 하고 거기서 끝(**delay 가 duration 앞**)
///   · ④ `0x14023ae24` — `delay <= 0` 이면 `duration -= dt`, 0 이하가 된 프레임에 `-1.0` 못 박고 은퇴
///   · ⑤ `0x14023ae48` — `duration <= 0` + `rate > 0` 이면 은퇴 안 함 = **`duration == 0` 은 무한**
final class ParticleEmitterWindowWETests: XCTestCase {

    /// 즉발 없이 rate 로만 방출하는 최소 def. `window` 가 nil 이면 `emitterWindow` 를 아예 안 채운다.
    private func def(window: EmitterWindow?) -> ParticleSystemDef {
        var d = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
                            rate: 20, burst: 0)],
            initializers: [.lifetimeRandom(min: 1000, max: 1000),
                           .sizeRandom(min: 1, max: 1),
                           .velocityRandom(min: Vec3(x: 0, y: 0, z: 0), max: Vec3(x: 0, y: 0, z: 0)),
                           .alphaRandom(min: 1, max: 1, exponent: 1)],
            operators: [], renderer: .sprite, maxCount: 4096, startTime: 0, material: nil)
        if let window { d.emitterWindow = [window] }
        return d
    }

    private func liveCounts(_ d: ParticleSystemDef, steps: Int, dt: Float = 0.1) -> [Int] {
        var sim = ParticleSimulator(def: d, seed: 5)
        return (0..<steps).map { _ in _ = sim.step(dt); return sim.liveCount }
    }

    /// **무회귀가 최우선** — 창이 없을 때와 `.unbounded`(0/0) 일 때가 종전 경로와 완전히 같아야 한다.
    func testUnboundedWindowIsIdenticalToNoWindow() {
        let none = liveCounts(def(window: nil), steps: 12)
        let zero = liveCounts(def(window: .unbounded), steps: 12)
        XCTAssertEqual(none, zero, "duration/delay 가 0/0 이면 창 자체가 없는 것과 같아야 한다")
        XCTAssertGreaterThan(none.last ?? 0, 0, "기준 경로가 애초에 방출을 안 하면 이 테스트가 공허하다")
    }

    /// ① delay 동안은 한 개도 안 나온다. ③ 그 사이 duration 은 깎이지 않는다.
    func testDelayBlocksEmissionAndFreezesDuration() {
        // delay 0.5s → dt 0.1 로 5스텝 동안 0, 그 뒤부터 방출.
        let counts = liveCounts(def(window: EmitterWindow(duration: 0, delay: 0.5)), steps: 12)
        XCTAssertEqual(Array(counts.prefix(5)), Array(repeating: 0, count: 5),
                       "delay 가 남은 동안에는 방출이 없어야 한다(0x1402379ea)")
        XCTAssertGreaterThan(counts.last ?? 0, 0, "delay 가 끝나면 방출이 시작돼야 한다")
    }

    /// ④ duration 이 소진되면 은퇴하고, ⑤ 은퇴는 **영구**다.
    func testDurationRetiresEmitterPermanently() {
        // delay 0 · duration 0.3s → 3스텝 방출 뒤 은퇴. 수명이 1000s 라 기존 파티클은 안 죽는다.
        let counts = liveCounts(def(window: EmitterWindow(duration: 0.3, delay: 0)), steps: 20)
        let atRetire = counts[4]
        XCTAssertGreaterThan(atRetire, 0, "은퇴 전에는 방출돼야 한다")
        XCTAssertEqual(counts.suffix(10), ArraySlice(Array(repeating: atRetire, count: 10)),
                       "은퇴 뒤에는 생존 수가 더 늘면 안 된다 — 은퇴는 영구다(0x14023ae67)")
    }

    /// ⑤ `duration == 0` 은 "0초 방출" 이 아니라 **무한**이다(rate > 0 이면 은퇴하지 않는다).
    func testZeroDurationMeansInfiniteNotInstant() {
        let counts = liveCounts(def(window: EmitterWindow(duration: 0, delay: 0)), steps: 20)
        XCTAssertGreaterThan(counts[19], counts[4],
                             "duration 0 은 무한이라 계속 늘어야 한다(0x14023ae48)")
    }

    /// ② `duration < 0` 은 영구 차단이다(은퇴 프레임에 못 박히는 `-1.0` 이 여기 걸린다).
    func testNegativeDurationBlocksEmissionForever() {
        let counts = liveCounts(def(window: EmitterWindow(duration: -1, delay: 0)), steps: 20)
        XCTAssertEqual(counts, Array(repeating: 0, count: 20),
                       "duration 이 음수면 처음부터 끝까지 방출이 없어야 한다(0x140237af1)")
    }

    /// delay 와 duration 이 **직렬**이다 — 대기가 끝난 뒤에 비로소 duration 이 돌기 시작한다.
    func testDelayThenDurationIsSequential() {
        // thunderbolt_beam_child 실물 모양: 0.2초 대기 → 1초 방출 → 은퇴.
        let counts = liveCounts(def(window: EmitterWindow(duration: 1, delay: 0.2)), steps: 30)
        XCTAssertEqual(Array(counts.prefix(2)), [0, 0], "0.2초 대기 중에는 방출 없음")
        XCTAssertGreaterThan(counts[8], 0, "대기 뒤에는 방출")
        let tail = counts.suffix(8)
        XCTAssertEqual(Set(tail).count, 1, "1초 방출이 끝나면 은퇴해 생존 수가 고정돼야 한다")
    }
}
