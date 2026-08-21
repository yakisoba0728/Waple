import XCTest
import simd
@testable import WapleCore

/// `PointerHit` — WE 커서 히트테스트 기하(`sub_14019dbb0` + `sub_14019d5a0`)의 순수 재현 검증.
final class PointerHitTests: XCTestCase {

    private func layerQuad(center: SIMD2<Float>, size: SIMD2<Float>,
                           scale: SIMD2<Float> = SIMD2(1, 1), angleZ: Float = 0) -> PointerHit.Quad {
        PointerHit.Quad.layer(center: center, size: size, scale: scale, angleZ: angleZ)
    }

    // MARK: - 회전 없는 기본형(종전 AABB 와 동치여야 한다 — 무회귀 가드)

    func testAxisAlignedMatchesRect() {
        let q = layerQuad(center: SIMD2(480, 270), size: SIMD2(200, 200))
        XCTAssertTrue(PointerHit.contains(q, SIMD2(480, 270)))
        XCTAssertTrue(PointerHit.contains(q, SIMD2(381, 171)))
        XCTAssertTrue(PointerHit.contains(q, SIMD2(579, 369)))
        XCTAssertFalse(PointerHit.contains(q, SIMD2(379, 270)))
        XCTAssertFalse(PointerHit.contains(q, SIMD2(480, 371)))
        XCTAssertFalse(PointerHit.contains(q, SIMD2(1400, 900)))
    }

    /// 경계는 **포함**이다 — 실물이 `jbe`/`jae` 로 등호를 살린다(`0x14019d704`·`0x14019d770`).
    func testBoundaryIsInclusive() {
        let q = layerQuad(center: .zero, size: SIMD2(100, 40))
        for p in [SIMD2<Float>(-50, -20), SIMD2<Float>(50, -20),
                  SIMD2<Float>(-50, 20), SIMD2<Float>(50, 20)] {
            XCTAssertTrue(PointerHit.contains(q, p), "코너 \(p) 가 히트여야 한다")
        }
        XCTAssertFalse(PointerHit.contains(q, SIMD2(50.001, 0)))
    }

    // MARK: - 회전(격차 4 의 본체)

    /// 45° 회전한 정사각형: 축정렬 AABB 라면 코너 근처가 히트로 잡히지만, 회전 쿼드는 안 잡는다.
    /// 반대로 회전 방향의 뾰족한 끝은 AABB 밖인데 쿼드는 잡는다.
    func testRotatedSquareRejectsAABBCornerAndAcceptsRotatedTip() {
        let q = layerQuad(center: .zero, size: SIMD2(100, 100), angleZ: .pi / 4)
        // AABB(±50) 의 코너 — 회전 쿼드 밖(로컬 반경 √2·50 ≈ 70.7 > 50)
        XCTAssertFalse(PointerHit.contains(q, SIMD2(48, 48)))
        // 회전으로 뻗은 끝(로컬 (+50,0) 이 (35.36, 35.36) 로 감) — 안쪽
        XCTAssertTrue(PointerHit.contains(q, SIMD2(35, 35)))
        // 45° 회전이면 대각선 끝이 (±70.7, 0)/(0, ±70.7) — AABB 밖이지만 쿼드 안
        XCTAssertTrue(PointerHit.contains(q, SIMD2(70, 0)))
        XCTAssertFalse(PointerHit.contains(q, SIMD2(71, 0)))
    }

    /// 90° 회전은 폭/높이를 맞바꾼다.
    func testQuarterTurnSwapsExtents() {
        let q = layerQuad(center: .zero, size: SIMD2(200, 40), angleZ: .pi / 2)
        XCTAssertTrue(PointerHit.contains(q, SIMD2(0, 95)))     // 회전 후 세로로 길다
        XCTAssertFalse(PointerHit.contains(q, SIMD2(95, 0)))
        XCTAssertTrue(PointerHit.contains(q, SIMD2(19, 0)))
    }

    // MARK: - 스케일 부호(실물은 det<0 분기를 그대로 받는다)

    func testNegativeScaleStillHits() throws {
        let q = layerQuad(center: SIMD2(100, 100), size: SIMD2(80, 60), scale: SIMD2(-1, 1))
        XCTAssertTrue(PointerHit.contains(q, SIMD2(100, 100)))
        XCTAssertTrue(PointerHit.contains(q, SIMD2(139, 129)))
        XCTAssertFalse(PointerHit.contains(q, SIMD2(141, 100)))
        // u 축이 뒤집혔으므로 로컬 UV 도 뒤집힌다(축 부호를 abs 로 지우면 이 단언이 깨진다).
        let uvRight = try XCTUnwrap(PointerHit.localUV(q, SIMD2(139, 100)))
        XCTAssertLessThan(uvRight.x, 0.05)
    }

    /// 축이 퇴화(scale 0)면 실물은 `|det| ≤ FLT_EPSILON` 으로 미스 처리한다(`0x14019d891`).
    func testDegenerateQuadMisses() {
        let q = layerQuad(center: .zero, size: SIMD2(100, 100), scale: SIMD2(0, 1))
        XCTAssertNil(PointerHit.localUV(q, .zero))
        XCTAssertFalse(PointerHit.contains(q, .zero))
        let zeroSize = layerQuad(center: .zero, size: .zero)
        XCTAssertFalse(PointerHit.contains(zeroSize, .zero))
    }

    /// 임계 자체가 살아 있는지 — `det = 1e-8 < FLT_EPSILON(1.19e-7)` 이라 **UV 는 정상 범위인데도**
    /// 실물은 미스로 친다(`comiss` 두 분기 사이의 회색지대, `0x14019d6ae`/`0x14019d781`).
    /// 가드를 빼면 이 쿼드는 `u = v = 0.5` 로 히트가 되므로 이 단언만이 임계를 잠근다.
    func testNearDegenerateBelowEpsilonMisses() {
        let tiny = layerQuad(center: .zero, size: SIMD2(1e-5, 1e-3))
        XCTAssertNil(PointerHit.localUV(tiny, .zero), "det=1e-8 은 FLT_EPSILON 미만 → 미스")
        // 바로 위(det = 1e-6 > FLT_EPSILON)는 정상 히트여야 한다 — 가드가 과하게 넓지 않다는 증거.
        let ok = layerQuad(center: .zero, size: SIMD2(1e-3, 1e-3))
        XCTAssertNotNil(PointerHit.localUV(ok, .zero))
    }

    // MARK: - 로컬 좌표(CursorEvent.localPosition 규약)

    /// 실물 `out = (u·size.x, (1−v)·size.y)` — y 가 뒤집힌다.
    func testLocalPixelsFlipY() throws {
        let q = layerQuad(center: SIMD2(500, 300), size: SIMD2(200, 100))
        // c0 = (400, 250) = 로컬 (u,v) = (0,0) → 픽셀 (0, size.y)
        let c0 = try XCTUnwrap(PointerHit.localPixels(q, SIMD2(400, 250), size: SIMD2(200, 100)))
        XCTAssertEqual(c0.x, 0, accuracy: 1e-3)
        XCTAssertEqual(c0.y, 100, accuracy: 1e-3)
        let c3 = try XCTUnwrap(PointerHit.localPixels(q, SIMD2(600, 350), size: SIMD2(200, 100)))
        XCTAssertEqual(c3.x, 200, accuracy: 1e-3)
        XCTAssertEqual(c3.y, 0, accuracy: 1e-3)
        let mid = try XCTUnwrap(PointerHit.localPixels(q, SIMD2(500, 300), size: SIMD2(200, 100)))
        XCTAssertEqual(mid.x, 100, accuracy: 1e-3)
        XCTAssertEqual(mid.y, 50, accuracy: 1e-3)
    }

    /// 코너 순서 `c0(−X−Y) c1(+X−Y) c2(−X+Y) c3(+X+Y)` — `sub_14019dbb0` 의 스택 배치 그대로.
    func testCornerOrder() {
        let q = layerQuad(center: .zero, size: SIMD2(2, 4))
        let c = q.corners
        XCTAssertEqual(c[0], SIMD2(-1, -2))
        XCTAssertEqual(c[1], SIMD2(1, -2))
        XCTAssertEqual(c[2], SIMD2(-1, 2))
        XCTAssertEqual(c[3], SIMD2(1, 2))
    }

    // MARK: - 시차(실물은 **쿼드 중심**을 옮긴다, 광선이 아니라 — 0x14019dd79)

    func testParallaxTranslatesQuad() {
        let q = layerQuad(center: SIMD2(100, 100), size: SIMD2(40, 40))
        XCTAssertFalse(PointerHit.contains(q, SIMD2(135, 100)))
        let shifted = q.translated(by: SIMD2(20, 0))
        XCTAssertTrue(PointerHit.contains(shifted, SIMD2(135, 100)))
        XCTAssertFalse(PointerHit.contains(shifted, SIMD2(99, 100)))
        XCTAssertEqual(shifted.axisX, q.axisX)
        XCTAssertEqual(shifted.axisY, q.axisY)
    }
}

/// `g_PointerState` 비트 2개 — `.z` 는 **엣지**(누른 첫 프레임만), `.x/.y` 는 유지.
final class PointerButtonStateTests: XCTestCase {

    func testImpulseFiresOnlyOnFirstFrame() {
        var s = PointerButtonState()
        XCTAssertEqual(s.clickImpulse, 0, "미클릭 기본 0(캡처 결정성 가드)")

        s.setDown(true)
        XCTAssertEqual(s.clickImpulse, 1, "누른 첫 프레임 = 임펄스")
        s.endFrame()                                  // 0x140181623: s |= 2
        XCTAssertEqual(s.clickImpulse, 0, "유지 중에는 0 — 실물은 홀드가 아니다")
        s.endFrame()
        XCTAssertEqual(s.clickImpulse, 0)

        s.setDown(false)
        XCTAssertEqual(s.clickImpulse, 0)
        s.endFrame()                                  // 0x14018164f: s &= ~2
        s.setDown(true)
        XCTAssertEqual(s.clickImpulse, 1, "뗐다가 다시 누르면 임펄스가 되살아난다")
    }

    /// `.x/.y` 는 누르는 동안 계속 1(핸들러 `0x1400d9e36`–`0x1400d9e4e`). 동봉 셰이더 소비는 0건.
    func testHeldValueIsLevelNotEdge() {
        var s = PointerButtonState()
        XCTAssertEqual(s.heldValue, 0)
        s.setDown(true)
        XCTAssertEqual(s.heldValue, 1)
        s.endFrame()
        XCTAssertEqual(s.heldValue, 1, "홀드 값은 프레임 꼬리에 죽지 않는다")
        XCTAssertEqual(s.clickImpulse, 0, "같은 프레임에도 .z 만 죽는다")
        s.setDown(false)
        XCTAssertEqual(s.heldValue, 0)
    }

    /// 프레임 꼬리를 돌리지 않으면(= 한 프레임 안에서 유니폼을 여러 패스가 읽으면) 값이 같아야 한다.
    func testImpulseStableAcrossPassesWithinOneFrame() {
        var s = PointerButtonState()
        s.setDown(true)
        XCTAssertEqual(s.clickImpulse, 1)
        XCTAssertEqual(s.clickImpulse, 1)
        XCTAssertEqual(s.clickImpulse, 1)
        s.endFrame()
        XCTAssertEqual(s.clickImpulse, 0)
    }
}
