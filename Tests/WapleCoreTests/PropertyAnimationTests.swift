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
        XCTAssertTrue(anim.events.isEmpty, "events 미기재 → 빈 배열")
    }

    // MARK: - 이벤트 마커(options.events) 파스 + 크로싱 검출

    func testParseEventsFromOptions() throws {
        // 실물 3737268876 objects/93 스키마 그대로(surprise 타임라인).
        let dict: [String: Any] = [
            "animation": [
                "c0": [["frame": 0, "value": 0.0], ["frame": 30, "value": 1.0]] as [[String: Any]],
                "options": ["fps": 30, "length": 30, "mode": "single", "name": "surprise",
                            "startpaused": true,
                            "events": [["frame": 0, "name": "surprise"],
                                       ["frame": 21, "name": "regular"],
                                       ["frame": 30, "name": "surprise_end"],
                                       ["name": "malformed-no-frame"]] as [[String: Any]]] as [String: Any],
            ] as [String: Any],
        ]
        let anim = try XCTUnwrap(PropertyAnimation.parse(dict))
        XCTAssertEqual(anim.events, [AnimationMarker(name: "surprise", frame: 0),
                                     AnimationMarker(name: "regular", frame: 21),
                                     AnimationMarker(name: "surprise_end", frame: 30)],
                       "frame 누락 항목은 드롭, 나머지는 순서 보존")
    }

    private let zeldaSurprise = [AnimationMarker(name: "surprise", frame: 0),
                                 AnimationMarker(name: "regular", frame: 21),
                                 AnimationMarker(name: "surprise_end", frame: 30)]

    func testSingleModeFiresFrameZeroOnFirstTickAndEachMarkerOnce() {
        // 최초 틱(prevF=-1 규약): frame 0 마커 발화.
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: zeldaSurprise, length: 30, mode: "single",
                                                      prevF: -1, curF: 0.5), ["surprise"])
        // 이후 진행: 경계 포함(prev < m ≤ cur), 시각순.
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: zeldaSurprise, length: 30, mode: "single",
                                                      prevF: 0.5, curF: 30), ["regular", "surprise_end"])
        // 길이 지난 뒤(클램프 구간): 재발화 없음.
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: zeldaSurprise, length: 30, mode: "single",
                                                      prevF: 30, curF: 90), [])
        // 정지(같은 프레임): 무발화.
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: zeldaSurprise, length: 30, mode: "single",
                                                      prevF: 5, curF: 5), [])
    }

    func testSingleModeMarkerAtTimelineEndFiresExactlyAtCrossing() {
        // 실물 walk_end: frame 750 == length 750, single — 도달 순간 1회.
        let ev = [AnimationMarker(name: "walk_end", frame: 750)]
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: ev, length: 750, mode: "single",
                                                      prevF: 749.7, curF: 750.3), ["walk_end"])
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: ev, length: 750, mode: "single",
                                                      prevF: 750.3, curF: 751), [])
    }

    func testLoopModeFiresOncePerLap() {
        let ev = [AnimationMarker(name: "tick", frame: 7)]
        // 랩 1: 7 통과.
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: ev, length: 300, mode: "loop",
                                                      prevF: 6, curF: 8), ["tick"])
        // 같은 랩 내 재통과 없음.
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: ev, length: 300, mode: "loop",
                                                      prevF: 8, curF: 299), [])
        // 랩 경계(300+7=307) 넘김: 다음 랩 1회.
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: ev, length: 300, mode: "loop",
                                                      prevF: 299, curF: 308), ["tick"])
    }

    func testLoopBigGapFiresAtMostOncePerMarker() {
        // 가림 복귀: 한 틱이 10랩을 건너뛰어도 마커당 1회(마지막 주기만).
        let ev = [AnimationMarker(name: "a", frame: 10), AnimationMarker(name: "b", frame: 20)]
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: ev, length: 30, mode: "loop",
                                                      prevF: 0, curF: 315), ["b", "a"],
                       "(285,315]: b 히트 290(=260+30…20+9·30), a 히트 310 — 시각순 b→a, 각 1회")
    }

    func testMirrorModeFiresBothDirectionsAndEndpointsOncePerCycle() {
        // 실물 젤다 sky change: pause_off@0, storm@45, pause_on@90, length 90, mirror(주기 180).
        let ev = [AnimationMarker(name: "pause_off", frame: 0),
                  AnimationMarker(name: "storm", frame: 45),
                  AnimationMarker(name: "pause_on", frame: 90)]
        // 상행: storm(45) → pause_on(90).
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: ev, length: 90, mode: "mirror",
                                                      prevF: 1, curF: 91), ["storm", "pause_on"])
        // 하행(미러 위상 2L−45=135): storm 재발화, 끝점 pause_on 은 랩당 1회뿐.
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: ev, length: 90, mode: "mirror",
                                                      prevF: 91, curF: 136), ["storm"])
        // 원점 복귀(180): pause_off 1회.
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: ev, length: 90, mode: "mirror",
                                                      prevF: 136, curF: 181), ["pause_off"])
    }

    func testFiredMarkersSameFrameKeepDefinitionOrder() {
        // 실물 deku 186: emerge@0 + surprise_start@0 — 같은 프레임은 정의 순서 유지.
        let ev = [AnimationMarker(name: "emerge", frame: 0), AnimationMarker(name: "surprise_start", frame: 0)]
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: ev, length: 96, mode: "single",
                                                      prevF: -1, curF: 1), ["emerge", "surprise_start"])
    }
}
