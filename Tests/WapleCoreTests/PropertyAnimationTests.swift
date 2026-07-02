import XCTest
@testable import WapleCore

final class PropertyAnimationTests: XCTestCase {
    /// 양쪽 핸들 disabled = 선형 — 중점에서 평균값.
    private func kf(_ frame: Float, _ value: Float, enabled: Bool = true,
                    fx: Float = 1, fy: Float = 0, bx: Float = -1, by: Float = 0) -> PropertyKeyframe {
        PropertyKeyframe(frame: frame, value: value,
                         frontEnabled: enabled, frontX: fx, frontY: fy,
                         backEnabled: enabled, backX: bx, backY: by)
    }

    func testLinearMidpointAndClamp() {
        let anim = PropertyAnimation(tracks: [[kf(0, 10, enabled: false), kf(60, 20, enabled: false)]],
                                     fps: 30, length: 60, mode: "single", relative: false)
        XCTAssertEqual(anim.value(component: 0, atTime: 1.0, base: 0), 15, accuracy: 0.01, "선형 중점")
        XCTAssertEqual(anim.value(component: 0, atTime: -1, base: 0), 10, "시작 전 클램프")
        XCTAssertEqual(anim.value(component: 0, atTime: 99, base: 0), 20, "종료 후 클램프(single)")
    }

    func testBezierSymmetricMidpointAndMonotonic() {
        // 대칭 플랫 핸들(±1, 0): 중점 = 평균, 전 구간 단조 증가(WE 기본 ease).
        let anim = PropertyAnimation(tracks: [[kf(0, 0), kf(60, 100)]],
                                     fps: 30, length: 60, mode: "single", relative: false)
        XCTAssertEqual(anim.value(component: 0, atTime: 1.0, base: 0), 50, accuracy: 0.5, "대칭 → 중점=평균")
        var prev: Float = -1
        for i in 0...20 {
            let v = anim.value(component: 0, atTime: Float(i) * 0.1, base: 0)
            XCTAssertGreaterThanOrEqual(v + 0.001, prev, "단조성 위반 at \(i)")
            prev = v
        }
        XCTAssertEqual(anim.value(component: 0, atTime: 0, base: 0), 0, accuracy: 0.01)
        XCTAssertEqual(anim.value(component: 0, atTime: 2, base: 0), 100, accuracy: 0.01)
    }

    func testLoopWrapsAndRelativeAddsBase() {
        let anim = PropertyAnimation(tracks: [[kf(0, 0, enabled: false), kf(30, 30, enabled: false)]],
                                     fps: 30, length: 30, mode: "loop", relative: true)
        // t=1.5s → frame 45 → wrap 15 → 값 15; relative → base 100 + 15 = 115
        XCTAssertEqual(anim.value(component: 0, atTime: 1.5, base: 100), 115, accuracy: 0.01)
    }

    func testMissingTrackReturnsBase() {
        let anim = PropertyAnimation(tracks: [[kf(0, 1, enabled: false)]],
                                     fps: 30, length: 30, mode: "single", relative: false)
        XCTAssertEqual(anim.value(component: 2, atTime: 0.5, base: 42), 42, "없는 트랙(c2)은 base 유지")
    }

    func testParseFromSceneObjectDict() throws {
        // 실물 스키마 그대로(3147346398 패턴).
        let dict: [String: Any] = [
            "animation": [
                "c0": [
                    ["frame": 0, "value": -600.0,
                     "front": ["enabled": true, "x": 1, "y": 0], "back": ["enabled": true, "x": -1, "y": 0]],
                    ["frame": 60, "value": 780.0,
                     "front": ["enabled": false, "x": 1, "y": 0], "back": ["enabled": true, "x": -1, "y": -20.2]],
                ] as [[String: Any]],
                "options": ["fps": 30, "length": 60, "mode": "loop"] as [String: Any],
                "relative": true,
            ] as [String: Any],
            "value": "100 200 0",
        ]
        let anim = try XCTUnwrap(PropertyAnimation.parse(dict))
        XCTAssertEqual(anim.fps, 30)
        XCTAssertEqual(anim.length, 60)
        XCTAssertEqual(anim.mode, "loop")
        XCTAssertTrue(anim.relative)
        XCTAssertEqual(anim.tracks.count, 1)
        XCTAssertEqual(anim.tracks[0].count, 2)
        XCTAssertEqual(anim.tracks[0][0].value, -600)
        XCTAssertEqual(anim.tracks[0][1].backY, -20.2, accuracy: 0.01)
        XCTAssertFalse(anim.tracks[0][1].frontEnabled)
    }
}
