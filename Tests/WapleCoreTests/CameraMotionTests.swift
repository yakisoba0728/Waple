import XCTest
@testable import WapleCore

/// `CameraMotion` — 경로 재생 이즈 곡선 · camerafade · 실효 fov/zoom · 2D eye 재중심화의 자물쇠.
///
/// 기대값은 전부 `wallpaper64.exe`(imagebase `0x140000000`)의 명령을 float32 로 그대로 밟아
/// 얻은 것이다. 근거 VA 는 `Sources/WapleCore/CameraMotion.swift` 와 `docs/re/camera-motion.md` §8.
final class CameraMotionTests: XCTestCase {

    // MARK: - 3차 에르미트 기저

    /// 끝점에서 기저가 정확히 `(1,0,0,0)` / `(0,0,1,0)` 이어야 한다 — 아니면 보간이 제어점을
    /// 지나지 않는다.
    func testHermiteBasisEndpoints() {
        let a = CameraMotion.hermiteBasis(0)
        XCTAssertEqual(a.h00, 1); XCTAssertEqual(a.h10, 0)
        XCTAssertEqual(a.h01, 0); XCTAssertEqual(a.h11, 0)
        let b = CameraMotion.hermiteBasis(1)
        XCTAssertEqual(b.h00, 0); XCTAssertEqual(b.h10, 0)
        XCTAssertEqual(b.h01, 1); XCTAssertEqual(b.h11, 0)
    }

    /// `u = 0.5` 의 네 계수는 유리수라 **비트동일**로 잠글 수 있다
    /// (`0x140189593`–`0x1401895c5` 의 조립 순서 그대로).
    func testHermiteBasisAtHalf() {
        let b = CameraMotion.hermiteBasis(0.5)
        XCTAssertEqual(b.h00, 0.5)
        XCTAssertEqual(b.h10, 0.125)
        XCTAssertEqual(b.h01, 0.5)
        XCTAssertEqual(b.h11, -0.125)
    }

    /// 기저의 항등식: 임의의 `u` 에서 `h00 + h01 == 1`(상수 보존)이고 `h10 + h11 == 2u³−3u²+u`.
    func testHermiteBasisIdentities() {
        for u in [Float(0), 0.1, 0.25, 0.5, 0.75, 0.9, 1.0] {
            let b = CameraMotion.hermiteBasis(u)
            XCTAssertEqual(b.h00 + b.h01, 1, accuracy: 1e-6, "u=\(u)")
            XCTAssertEqual(b.h10 + b.h11, 2 * u * u * u - 3 * u * u + u, accuracy: 1e-6, "u=\(u)")
        }
    }

    // MARK: - 접선 · 이즈 곡선

    /// 접선은 **양 끝이 같고** `0.5·(p1 − p0)` 다. 구간 안에서 두 제어점 말고는 아무것도
    /// 읽지 않기 때문이다(`imul` 이 `idx`·`idx+1` 둘뿐).
    func testSegmentTangentIsHalfDelta() {
        XCTAssertEqual(CameraMotion.segmentTangent(-3.544, -2.618), 0.5 * (-2.618 - -3.544),
                       accuracy: 1e-7)
        XCTAssertEqual(CameraMotion.segmentTangent(7, 7), 0)
    }

    /// **이 이즈는 스무스스텝이 아니다.** 두 곡선은 `u = 0.5` 에서만 만나고 사분점에서 갈린다.
    /// 여기가 갈리면 경로 재생 궤적이 통째로 달라진다.
    ///
    /// | u | 이 곡선 | 스무스스텝 | 선형 |
    /// |---|---|---|---|
    /// | 0.25 | **0.203125** | 0.15625 | 0.25 |
    /// | 0.75 | **0.796875** | 0.84375 | 0.75 |
    func testEaseIsNeitherSmoothstepNorLinear() {
        XCTAssertEqual(CameraMotion.hermiteFraction(0.25), 0.203125, accuracy: 1e-7)
        XCTAssertEqual(CameraMotion.hermiteFraction(0.75), 0.796875, accuracy: 1e-7)
        for u in [Float(0.25), 0.75] {
            let smoothstep = 3 * u * u - 2 * u * u * u
            XCTAssertNotEqual(CameraMotion.hermiteFraction(u), smoothstep, accuracy: 1e-3,
                              "u=\(u) 스무스스텝과 구별돼야 한다")
            XCTAssertNotEqual(CameraMotion.hermiteFraction(u), u, accuracy: 1e-3,
                              "u=\(u) 선형과 구별돼야 한다")
        }
        XCTAssertEqual(CameraMotion.hermiteFraction(0.5), 0.5, accuracy: 1e-7, "중점은 셋 다 같다")
    }

    /// 양 끝 기울기가 **0 이 아니라 0.5** 다(`f′(u) = −3u² + 3u + 0.5`). 스무스스텝처럼 끝에서
    /// 멈추지 않고 일정 속도로 들어왔다 나간다 — 경로 사이 이음매가 튀는 이유가 이것이다.
    func testEaseEndpointSlopeIsHalf() {
        let h: Float = 1e-3
        let atZero = (CameraMotion.hermiteFraction(h) - CameraMotion.hermiteFraction(0)) / h
        let atOne = (CameraMotion.hermiteFraction(1) - CameraMotion.hermiteFraction(1 - h)) / h
        XCTAssertEqual(atZero, 0.5, accuracy: 5e-3)
        XCTAssertEqual(atOne, 0.5, accuracy: 5e-3)
    }

    /// 에르미트 누산과 닫힌 식이 같은 값을 준다(부동소수 순서만 다르다).
    func testHermiteMatchesClosedForm() {
        for u in [Float(0), 0.125, 0.25, 0.5, 0.75, 0.875, 1.0] {
            let p0: Float = -3.544, p1: Float = -2.618
            XCTAssertEqual(CameraMotion.hermite(p0: p0, p1: p1, u: u),
                           p0 + (p1 - p0) * CameraMotion.hermiteFraction(u),
                           accuracy: 1e-6, "u=\(u)")
        }
    }

    /// 제어점을 정확히 지난다.
    func testHermitePassesThroughControlPoints() {
        XCTAssertEqual(CameraMotion.hermite(p0: 2, p1: 9, u: 0), 2)
        XCTAssertEqual(CameraMotion.hermite(p0: 2, p1: 9, u: 1), 9)
    }

    // MARK: - camerafade  (0x140180c0b – 0x140180cc0)

    /// 처음/끝 **0.5초씩** 선형. 한가운데는 정확히 0 이라 오버레이가 아예 그려지지 않는다.
    func testFadeAlphaCurve() {
        let d: Float = 30
        XCTAssertEqual(CameraMotion.fadeAlpha(elapsed: 0, duration: d), 1, accuracy: 1e-6)
        XCTAssertEqual(CameraMotion.fadeAlpha(elapsed: 0.25, duration: d), 0.5, accuracy: 1e-6)
        XCTAssertEqual(CameraMotion.fadeAlpha(elapsed: 0.5, duration: d), 0, accuracy: 1e-6)
        XCTAssertEqual(CameraMotion.fadeAlpha(elapsed: 15, duration: d), 0, accuracy: 1e-6)
        XCTAssertEqual(CameraMotion.fadeAlpha(elapsed: 29.5, duration: d), 0, accuracy: 1e-6)
        XCTAssertEqual(CameraMotion.fadeAlpha(elapsed: 29.75, duration: d), 0.5, accuracy: 1e-6)
        XCTAssertEqual(CameraMotion.fadeAlpha(elapsed: 30, duration: d), 1, accuracy: 1e-6)
    }

    /// **경로가 없으면 camerafade 는 아무 일도 하지 않는다** — 머티리얼 로드부터 건너뛴다
    /// (`0x140181bb7`). 동봉 코퍼스 94씬이 `camerafade:true` 인데 경로가 0건이라 전부 무효라는
    /// 결론이 여기에 걸린다.
    func testFadeNeedsPaths() {
        let st = CameraPathState(pathIndex: 0, transformIndex: 0, elapsed: 0)
        XCTAssertNil(CameraMotion.fadeOverlayAlpha(cameraFade: true, paths: [], state: st))
        let p = CameraPath(duration: 30, transforms: [Self.arsenalT0, Self.arsenalT1])
        XCTAssertEqual(CameraMotion.fadeOverlayAlpha(cameraFade: true, paths: [p], state: st), 1)
        XCTAssertNil(CameraMotion.fadeOverlayAlpha(cameraFade: false, paths: [p], state: st))
    }

    /// 알파가 0 이면 그리지 않는다(`0x140180c90 comiss/jbe`).
    func testFadeNotDrawnMidSegment() {
        let p = CameraPath(duration: 30, transforms: [Self.arsenalT0, Self.arsenalT1])
        let st = CameraPathState(pathIndex: 0, transformIndex: 0, elapsed: 15)
        XCTAssertNil(CameraMotion.fadeOverlayAlpha(cameraFade: true, paths: [p], state: st))
    }

    // MARK: - 실효 fov / zoom / 2D eye

    /// **2D 는 `perspectiveoverridefov`, 3D 는 `fov`**(`0x1401892a0 cmove`).
    func testEffectiveFovSelection() {
        XCTAssertEqual(CameraMotion.effectiveFovDegrees(orthographic: true, fov: 50,
                                                        perspectiveOverrideFov: 95), 95)
        XCTAssertEqual(CameraMotion.effectiveFovDegrees(orthographic: false, fov: 50,
                                                        perspectiveOverrideFov: 95), 50)
    }

    /// 클램프 `[0.1, 179.9]`. NaN 은 `minss` 의 피연산자 규칙 때문에 **179.9** 로 착지한다 —
    /// Swift 의 `min(_:_:)` 을 그대로 쓰면 NaN 이 새어 나가므로 이 케이스가 그 회귀를 잡는다.
    func testFovClamp() {
        XCTAssertEqual(CameraMotion.clampedFovDegrees(50), 50)
        XCTAssertEqual(CameraMotion.clampedFovDegrees(0.05), 0.10000000149011612)
        XCTAssertEqual(CameraMotion.clampedFovDegrees(-10), 0.10000000149011612)
        XCTAssertEqual(CameraMotion.clampedFovDegrees(200), 179.89999389648438)
        XCTAssertEqual(CameraMotion.clampedFovDegrees(.nan), 179.89999389648438)
        XCTAssertEqual(CameraMotion.clampedFovDegrees(.infinity), 179.89999389648438)
    }

    /// zoom 은 **정사영 전용**이고 두 채널의 곱이다(`0x14017fd45` 게이트 · `0x14017fd5d`).
    /// 3D 씬에서는 블록 자체를 건너뛰므로 1 이어야 한다.
    func testZoomIsOrthographicOnly() {
        XCTAssertEqual(CameraMotion.effectiveZoom(orthographic: true, generalZoom: 2,
                                                  cameraZoom: 1.5), 3)
        XCTAssertEqual(CameraMotion.effectiveZoom(orthographic: false, generalZoom: 2,
                                                  cameraZoom: 1.5), 1)
    }

    /// 2D eye 재중심화 — 캔버스 중앙과 `z = 2000`(정사영 far 평면과 같은 값).
    func test2DEyeRecentering() {
        let e = CameraMotion.recentered2DEye(eye: Vec3(x: 0, y: 0, z: 0),
                                             orthoWidth: 256, orthoHeight: 256)
        XCTAssertEqual(e, Vec3(x: 128, y: 128, z: 2000))
        let e2 = CameraMotion.recentered2DEye(eye: Vec3(x: 5, y: -7, z: 999),
                                              orthoWidth: 1920, orthoHeight: 1080)
        XCTAssertEqual(e2, Vec3(x: 965, y: 533, z: 2000))
    }

    // MARK: - 코퍼스 픽스처

    /// `projects/defaultprojects/arsenal/scripts/camera_00.json` 경로 0 (설치본).
    static let arsenalT0 = CameraPathTransform(
        timestamp: 0,
        eye: Vec3(x: -3.544, y: 2.168, z: 2.274),
        center: Vec3(x: -2.968, y: 1.777, z: 1.556),
        up: Vec3(x: 0, y: 1, z: 0))
    static let arsenalT1 = CameraPathTransform(
        timestamp: 30,
        eye: Vec3(x: -2.618, y: 1.308, z: 2.399),
        center: Vec3(x: -2.275, y: 1.020, z: 1.505),
        up: Vec3(x: 0, y: 1, z: 0))
}
