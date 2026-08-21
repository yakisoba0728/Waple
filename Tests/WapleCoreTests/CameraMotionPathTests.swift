import XCTest
@testable import WapleCore

/// `CameraMotion` 경로 재생(= WE 의 **유일한 자동 카메라 모션**)과 프레임 합성의 자물쇠.
///
/// 픽스처는 설치본 `wallpaper_engine/projects/defaultprojects/**/scripts/camera_00.json` 실측값이다
/// (설치본 6씬 · 21경로 · 41transform. **동봉 코퍼스에는 경로 씬이 0건**이라 동봉만 도는
/// 스위트로는 이 축이 한 줄도 안 돈다 — 그래서 여기 값으로 박아 둔다).
final class CameraMotionPathTests: XCTestCase {

    // MARK: - 픽스처 (설치본 실측)

    /// `arsenal/scripts/camera_00.json` 경로 0 — `duration == timestamp[last]` 인 전형(21경로 중 16건).
    private static let arsenal = CameraPath(duration: 30, transforms: [
        CameraPathTransform(timestamp: 0,
                            eye: Vec3(x: -3.544, y: 2.168, z: 2.274),
                            center: Vec3(x: -2.968, y: 1.777, z: 1.556),
                            up: Vec3(x: 0, y: 1, z: 0)),
        CameraPathTransform(timestamp: 30,
                            eye: Vec3(x: -2.618, y: 1.308, z: 2.399),
                            center: Vec3(x: -2.275, y: 1.020, z: 1.505),
                            up: Vec3(x: 0, y: 1, z: 0)),
    ])

    /// `demon_core/scripts/camera_00.json` 경로 0 — `duration(300) > timestamp[last](40)` 인
    /// 유일한 형태(설치본 21경로 중 4건, 전부 demon_core).
    private static let demonCore = CameraPath(duration: 300, transforms: [
        CameraPathTransform(timestamp: 0,
                            eye: Vec3(x: 3.297, y: 1.928, z: 5.252),
                            center: Vec3(x: 2.802, y: 1.628, z: 4.437),
                            up: Vec3(x: 0.432, y: 0.875, z: -0.217)),
        CameraPathTransform(timestamp: 40,
                            eye: Vec3(x: 2.868, y: 1.668, z: 4.546),
                            center: Vec3(x: 2.373, y: 1.368, z: 3.731),
                            up: Vec3(x: 0.975, y: 0.000, z: -0.224)),
    ])

    /// `neon_sunset/scripts/camera_00.json` — transform 이 **하나**뿐인 유일한 경로.
    private static let neonSunset = CameraPath(duration: 5, transforms: [
        CameraPathTransform(timestamp: 0,
                            eye: Vec3(x: 0, y: 0, z: 0),
                            center: Vec3(x: 0, y: 0, z: -0.1),
                            up: Vec3(x: 0, y: 1, z: 0)),
    ])

    // MARK: - 샘플링 팔

    /// 정상 구간은 보간 팔이고 구간 끝은 **다음 timestamp** 다.
    func testInterpolatingArm() throws {
        let st = CameraPathState(pathIndex: 0, transformIndex: 0, elapsed: 7.5)
        let s = try XCTUnwrap(CameraMotion.sample(paths: [Self.arsenal], state: st))
        XCTAssertEqual(s.arm, .interpolating)
        XCTAssertEqual(s.segmentEnd, 30)
        XCTAssertEqual(s.u, 0.25, accuracy: 1e-7)
    }

    /// 마지막 transform 을 붙들고 있을 때의 구간 끝은 **`duration − timestamp[last]`** 다.
    /// 여기가 `duration` 이면(직관적인 값이면) demon_core 경로가 40초 더 오래 돈다.
    func testHoldingLastArmSegmentEnd() throws {
        let st = CameraPathState(pathIndex: 0, transformIndex: 1, elapsed: 100)
        let s = try XCTUnwrap(CameraMotion.sample(paths: [Self.demonCore], state: st))
        XCTAssertEqual(s.arm, .holdingLast)
        XCTAssertEqual(s.segmentEnd, 260, "duration 300 − timestamp 40")
        XCTAssertEqual(s.pose.eye, Vec3(x: 2.868, y: 1.668, z: 4.546), "스냅이라 보간하지 않는다")
    }

    /// `elapsed < timestamp[i]` 팔(첫 transform 의 timestamp 가 0 이 아닐 때만 도달).
    /// 구간 끝이 `timestamp[i] + timestamp[i+1]` 이라는 **엔진 그대로의 기이한 합**이다.
    func testBeforeSegmentArm() throws {
        let path = CameraPath(duration: 20, transforms: [
            CameraPathTransform(timestamp: 3, eye: Vec3(x: 1, y: 0, z: 0),
                                center: Vec3(x: 0, y: 0, z: 0), up: Vec3(x: 0, y: 1, z: 0)),
            CameraPathTransform(timestamp: 12, eye: Vec3(x: 9, y: 0, z: 0),
                                center: Vec3(x: 0, y: 0, z: 0), up: Vec3(x: 0, y: 1, z: 0)),
        ])
        let st = CameraPathState(pathIndex: 0, transformIndex: 0, elapsed: 1)
        let s = try XCTUnwrap(CameraMotion.sample(paths: [path], state: st))
        XCTAssertEqual(s.arm, .beforeSegment)
        XCTAssertEqual(s.segmentEnd, 15, "3 + 12 — 실물이 더한다(0x1401899f3 addss)")
        XCTAssertEqual(s.pose.eye.x, 1)
    }

    /// `u` 는 **구간 시작 timestamp 를 뺀 뒤** 나눈다(`0x14018950d subss` → `0x140189567 divss`).
    /// 설치본 21경로가 전부 `timestamp[0] == 0` 이라 코퍼스 픽스처로는 이 뺄셈이 검증되지
    /// 않는다 — 그래서 첫 timestamp 가 0 이 아닌 합성 경로로 따로 잠근다.
    /// (`u = elapsed / (ts1 − ts0)` 로 잘못 쓰면 여기서만 갈린다: 0.5 vs 0.8333)
    func testUSubtractsSegmentStart() throws {
        let path = CameraPath(duration: 20, transforms: [
            CameraPathTransform(timestamp: 3, eye: Vec3(x: 0, y: 0, z: 0),
                                center: Vec3(x: 0, y: 0, z: 0), up: Vec3(x: 0, y: 1, z: 0)),
            CameraPathTransform(timestamp: 12, eye: Vec3(x: 100, y: 0, z: 0),
                                center: Vec3(x: 0, y: 0, z: 0), up: Vec3(x: 0, y: 1, z: 0)),
        ])
        let st = CameraPathState(pathIndex: 0, transformIndex: 0, elapsed: 7.5)
        let s = try XCTUnwrap(CameraMotion.sample(paths: [path], state: st))
        XCTAssertEqual(s.arm, .interpolating)
        XCTAssertEqual(s.u, 0.5, accuracy: 1e-7, "(7.5 − 3) / (12 − 3)")
        XCTAssertEqual(s.pose.eye.x, 50, accuracy: 1e-4, "u=0.5 는 중점")
    }

    /// transform 이 하나면 첫 프레임부터 `holdingLast` 이고, `timestamp = 0` 이라 구간 끝이
    /// 저작 duration 과 같다.
    func testSingleTransformPath() throws {
        let st = CameraPathState()
        let s = try XCTUnwrap(CameraMotion.sample(paths: [Self.neonSunset], state: st))
        XCTAssertEqual(s.arm, .holdingLast)
        XCTAssertEqual(s.segmentEnd, 5)
    }

    // MARK: - 보간 값 (설치본 실측 제어점)

    /// `arsenal` 경로 0 의 eye 궤적. 사분점 값이 **선형도 스무스스텝도 아니다**.
    func testArsenalEyeTrajectory() throws {
        func eye(at elapsed: Float) throws -> Vec3 {
            let st = CameraPathState(pathIndex: 0, transformIndex: 0, elapsed: elapsed)
            return try XCTUnwrap(CameraMotion.sample(paths: [Self.arsenal], state: st)).pose.eye
        }
        let q = try eye(at: 7.5)
        XCTAssertEqual(q.x, -3.35590601, accuracy: 1e-6)
        XCTAssertEqual(q.y, 1.99331248, accuracy: 1e-6)
        XCTAssertEqual(q.z, 2.29939055, accuracy: 1e-6)
        let h = try eye(at: 15)
        XCTAssertEqual(h.x, -3.08099985, accuracy: 1e-6)
        XCTAssertEqual(h.y, 1.73799992, accuracy: 1e-6)
        XCTAssertEqual(h.z, 2.33649993, accuracy: 1e-6)
        let t = try eye(at: 22.5)
        XCTAssertEqual(t.x, -2.80609393, accuracy: 1e-6)
        XCTAssertEqual(t.y, 1.48268747, accuracy: 1e-6)
        XCTAssertEqual(t.z, 2.3736093, accuracy: 1e-6)
        // 선형이었다면 사분점이 정확히 이 값이다 — 그렇지 않아야 한다.
        let lerpQuarter: Float = -3.544 + 0.25 * (-2.618 - -3.544)
        XCTAssertNotEqual(q.x, lerpQuarter, accuracy: 1e-3)
    }

    /// `up` 도 같은 에르미트를 탄다(`0x140189815`–`0x140189948`). demon_core 는 `up` 이
    /// 제어점마다 크게 달라서 이 축이 보간되는지 아닌지가 값으로 갈린다.
    func testUpIsInterpolatedToo() throws {
        let st = CameraPathState(pathIndex: 0, transformIndex: 0, elapsed: 10)
        let s = try XCTUnwrap(CameraMotion.sample(paths: [Self.demonCore], state: st))
        XCTAssertEqual(s.u, 0.25, accuracy: 1e-7)
        XCTAssertEqual(s.pose.up.x, 0.542296886, accuracy: 1e-6)
        XCTAssertEqual(s.pose.up.y, 0.697265625, accuracy: 1e-6)
        XCTAssertEqual(s.pose.up.z, -0.218421862, accuracy: 1e-6)
    }

    // MARK: - 전진

    /// `duration == timestamp[last]` 면 마지막 transform 으로 **넘어가지 않고** 곧장 다음 경로다
    /// (`0x140189abf comiss/jbe`). 설치본 21경로 중 16건이 이 형태다.
    func testAdvanceSkipsLastTransformWhenDurationEqualsTimestamp() {
        let paths = [Self.arsenal, Self.arsenal]
        let st = CameraPathState(pathIndex: 0, transformIndex: 0, elapsed: 30)
        let next = CameraMotion.advanced(paths: paths, state: st, dt: 1.0 / 60, segmentEnd: 30)
        XCTAssertEqual(next.pathIndex, 1)
        XCTAssertEqual(next.transformIndex, 0)
        XCTAssertEqual(next.elapsed, 0, "경로 전환은 elapsed 도 0 으로 민다(qword 스토어)")
    }

    /// `duration > timestamp[last]` 면 transform 만 넘기고 **elapsed 는 유지**한다
    /// (`0x140189ac5` 는 dword 스토어라 `+0xec` 를 건드리지 않는다).
    func testAdvanceKeepsElapsedWhenSteppingTransform() {
        let st = CameraPathState(pathIndex: 0, transformIndex: 0, elapsed: 40)
        let next = CameraMotion.advanced(paths: [Self.demonCore], state: st,
                                         dt: 0.5, segmentEnd: 40)
        XCTAssertEqual(next.pathIndex, 0)
        XCTAssertEqual(next.transformIndex, 1)
        XCTAssertEqual(next.elapsed, 40.5, accuracy: 1e-5)
    }

    /// 구간 끝과 **정확히 같으면** 전진하지 않는다(`jbe` 는 같음을 포함한다).
    func testAdvanceIsStrictlyGreater() {
        let st = CameraPathState(pathIndex: 0, transformIndex: 0, elapsed: 29)
        let next = CameraMotion.advanced(paths: [Self.arsenal, Self.arsenal], state: st,
                                         dt: 1, segmentEnd: 30)
        XCTAssertEqual(next.pathIndex, 0)
        XCTAssertEqual(next.elapsed, 30)
    }

    /// 마지막 경로 다음은 0 번으로 되감는다(`0x140189afc cmovae`).
    func testPathWrapsAround() {
        let st = CameraPathState(pathIndex: 1, transformIndex: 0, elapsed: 30)
        let next = CameraMotion.advanced(paths: [Self.arsenal, Self.arsenal], state: st,
                                         dt: 0.1, segmentEnd: 30)
        XCTAssertEqual(next.pathIndex, 0)
    }

    /// 실효 재생 시간 — demon_core 는 저작 300초가 아니라 **260초**만 돈다.
    func testEffectivePathDuration() {
        XCTAssertEqual(CameraMotion.effectivePathDuration(Self.arsenal), 30)
        XCTAssertEqual(CameraMotion.effectivePathDuration(Self.demonCore), 260)
        XCTAssertEqual(CameraMotion.effectivePathDuration(Self.neonSunset), 5)
    }

    /// 60Hz 로 실제로 굴려서 경로가 30초에 정확히 한 번 넘어가는지 본다(적분 회귀).
    func testArsenalRunsThirtySecondsAtSixtyHertz() throws {
        let paths = [Self.arsenal, Self.arsenal]
        var st = CameraPathState()
        var switches = 0
        let dt: Float = 1.0 / 60
        for _ in 0..<(60 * 31) {
            let r = try XCTUnwrap(CameraMotion.step(paths: paths, state: st, dt: dt))
            if r.next.pathIndex != st.pathIndex { switches += 1 }
            st = r.next
        }
        XCTAssertEqual(switches, 1, "31초 동안 경로 전환 1회")
        XCTAssertEqual(st.pathIndex, 1)
        XCTAssertEqual(st.elapsed, 1, accuracy: 0.05, "전환 뒤 1초쯤 경과")
    }

    // MARK: - 프레임 합성

    /// **shake 는 시차 초점에 새어 들어간다.** 초점 식이 `scene+0xf0`(shake 가 이미 더해진 eye)을
    /// 읽기 때문이다(`0x140189c18`/`0x140189c24`). 이 커플링이 없어지면 값이 갈린다.
    func testShakeLeaksIntoParallaxFocus() throws {
        var input = CameraMotion.FrameInput(
            time: 2, dt: 1.0 / 60, orthographic: true, orthoWidth: 256, orthoHeight: 256,
            pose: CameraPose(eye: Vec3(x: 0, y: 0, z: 0), center: Vec3(x: 0, y: 0, z: -1),
                             up: Vec3(x: 0, y: 1, z: 0), zoom: 1),
            cameraShake: true, shakeSpeed: 3, shakeAmplitude: 0.5, shakeRoughness: 1,
            cameraParallax: true, parallaxAmount: 0.5, parallaxDelay: 0.1,
            parallaxMouseInfluence: 1, pointer: Vec2(x: 0.25, y: 0.75),
            previousFocus: Vec2(x: 128, y: 128), fovDegrees: 95)

        let withShake = CameraMotion.frame(input)
        XCTAssertEqual(withShake.pose.eye.x, 0.845205426, accuracy: 1e-6)
        XCTAssertEqual(withShake.pose.eye.y, -1.16237748, accuracy: 1e-6)
        XCTAssertEqual(withShake.pose.eye.z, 0, "2D 는 z 성분이 죽는다")
        // eye 와 center 에 **같은** 델타 → 시선 방향 보존(평행이동)
        XCTAssertEqual(withShake.pose.center.x - withShake.pose.eye.x, 0, accuracy: 1e-6)
        XCTAssertEqual(withShake.pose.up, Vec3(x: 0, y: 1, z: 0), "up 은 건드리지 않는다 = 롤 없음")
        XCTAssertEqual(withShake.focus.x, 117.825058, accuracy: 1e-4)
        XCTAssertEqual(withShake.focus.y, 117.501617, accuracy: 1e-4)
        let u = try XCTUnwrap(withShake.parallaxUniform)
        XCTAssertEqual(u.x, 0.460254133, accuracy: 1e-6)
        XCTAssertEqual(u.y, 0.458990693, accuracy: 1e-6)

        input.cameraShake = false
        let noShake = CameraMotion.frame(input)
        XCTAssertEqual(noShake.focus.x, 117.688889, accuracy: 1e-4)
        XCTAssertEqual(noShake.focus.y, 117.688889, accuracy: 1e-4)
        XCTAssertNotEqual(withShake.focus.x, noShake.focus.x, accuracy: 1e-3,
                          "shake 가 초점에 새어 들어가야 한다")
    }

    /// `cameraparallax` 가 꺼져 있으면 초점도 유니폼도 **갱신되지 않는다** —
    /// 실물이 블록 전체를 건너뛴다(`0x140189b54 je`). 유니폼을 (0.5,0.5)로 "친절하게" 채우면
    /// 실물과 갈린다.
    func testParallaxOffLeavesFocusUntouched() {
        let input = CameraMotion.FrameInput(
            time: 1, dt: 1.0 / 60, orthographic: true, orthoWidth: 256, orthoHeight: 256,
            pose: CameraPose(eye: Vec3(x: 0, y: 0, z: 0), center: Vec3(x: 0, y: 0, z: -1),
                             up: Vec3(x: 0, y: 1, z: 0), zoom: 1),
            cameraParallax: false, pointer: Vec2(x: 0.9, y: 0.1),
            previousFocus: Vec2(x: 11, y: 22))
        let out = CameraMotion.frame(input)
        XCTAssertEqual(out.focus, Vec2(x: 11, y: 22))
        XCTAssertNil(out.parallaxUniform)
    }

    /// `mouseinfluence = 0`(코퍼스 저작 173/175)이면 초점이 **캔버스 중앙에 고정**된다.
    /// 마우스를 어디에 두든 유니폼이 (0.5, 0.5) 여야 한다.
    func testMouseInfluenceZeroPinsFocusToCenter() throws {
        for p in [Vec2(x: 0, y: 0), Vec2(x: 1, y: 1), Vec2(x: 0.37, y: 0.82)] {
            let input = CameraMotion.FrameInput(
                time: 0, dt: 1, orthographic: true, orthoWidth: 256, orthoHeight: 256,
                pose: CameraPose(eye: Vec3(x: 0, y: 0, z: 0), center: Vec3(x: 0, y: 0, z: -1),
                                 up: Vec3(x: 0, y: 1, z: 0), zoom: 1),
                cameraParallax: true, parallaxMouseInfluence: 0, pointer: p,
                previousFocus: Vec2(x: 128, y: 128))
            let out = CameraMotion.frame(input)
            let u = try XCTUnwrap(out.parallaxUniform)
            XCTAssertEqual(u.x, 0.5, accuracy: 1e-6, "pointer=\(p)")
            XCTAssertEqual(u.y, 0.5, accuracy: 1e-6, "pointer=\(p)")
        }
    }

    /// `renderState+0x118 & 0x200200` 이 서면 마우스 영향이 **0 으로 강제**된다(`0x140189b67`).
    func testForcePointerCenterOverridesInfluence() throws {
        var input = CameraMotion.FrameInput(
            time: 0, dt: 1, orthographic: true, orthoWidth: 256, orthoHeight: 256,
            pose: CameraPose(eye: Vec3(x: 0, y: 0, z: 0), center: Vec3(x: 0, y: 0, z: -1),
                             up: Vec3(x: 0, y: 1, z: 0), zoom: 1),
            cameraParallax: true, parallaxMouseInfluence: 1, pointer: Vec2(x: 1, y: 0),
            previousFocus: Vec2(x: 128, y: 128), forcePointerCenter: true)
        let pinned = try XCTUnwrap(CameraMotion.frame(input).parallaxUniform)
        XCTAssertEqual(pinned.x, 0.5, accuracy: 1e-6)
        input.forcePointerCenter = false
        let free = try XCTUnwrap(CameraMotion.frame(input).parallaxUniform)
        XCTAssertNotEqual(free.x, 0.5, accuracy: 1e-3)
    }
}
