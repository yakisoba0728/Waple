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
        XCTAssertTrue(anim.startPaused, "C⑤: options.startpaused=true 가 파싱돼야")
    }

    // MARK: - C⑤ startpaused(정지 상태로 저작된 애니가 마운트 즉시 재생되는 결함)

    /// startpaused=false(기본) → 종전대로 t 그대로 평가(무회귀).
    func testStartPausedDefaultsFalseAndPlaysNormally() throws {
        let dict: [String: Any] = [
            "animation": [
                "c0": [["frame": 0, "value": 0.0], ["frame": 30, "value": 1.0]] as [[String: Any]],
                "options": ["fps": 30, "length": 30, "mode": "single"] as [String: Any],
            ] as [String: Any],
        ]
        let anim = try XCTUnwrap(PropertyAnimation.parse(dict))
        XCTAssertFalse(anim.startPaused)
        XCTAssertEqual(anim.value(component: 0, atTime: 1.0, base: 0), 1.0, accuracy: 0.01,
                       "startpaused 미저작 → t=1.0(끝 프레임 이후) 정상 재생 후 클램프")
    }

    /// startpaused=true → 마운트 즉시(t 무관) frame 0 값에 고정 — 스크립트 play() 전까지 정지.
    /// 수정 전에는 t 를 그대로 써 마운트 순간 애니가 재생되고 single 모드 클램프로 끝값에 고착됐다.
    func testStartPausedFreezesAtFrameZeroRegardlessOfTime() throws {
        let dict: [String: Any] = [
            "animation": [
                "c0": [["frame": 0, "value": 0.0], ["frame": 30, "value": 1.0]] as [[String: Any]],
                "options": ["fps": 30, "length": 30, "mode": "single", "startpaused": true] as [String: Any],
            ] as [String: Any],
        ]
        let anim = try XCTUnwrap(PropertyAnimation.parse(dict))
        XCTAssertTrue(anim.startPaused)
        for t: Float in [0, 0.5, 1.0, 5.0, 999.0] {
            XCTAssertEqual(anim.value(component: 0, atTime: t, base: 0), 0.0, accuracy: 1e-6,
                           "startpaused → t=\(t) 이어도 frame 0 값(0.0)에 고정돼야(끝값 1.0 으로 고착되면 안 됨)")
        }
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

    func testMirrorValueFoldsBackInsteadOfClamping() {
        // 감사 V01: mode="mirror" 가 클램프로 흐르던 회귀 — 2L 주기 왕복 폴드.
        let anim = PropertyAnimation(tracks: [[kf(0, 0, enabled: false), kf(30, 30, enabled: false)]],
                                     fps: 30, length: 30, mode: "mirror", relative: false)
        // t=1.5s → frame 45 = 1.5L → 폴드 2L−45 = 15(하행 중간값). 클램프였다면 30.
        XCTAssertEqual(anim.value(component: 0, atTime: 1.5, base: 0), 15, accuracy: 0.01)
        // t=2s → frame 60 = 2L → 원점 복귀 0.
        XCTAssertEqual(anim.value(component: 0, atTime: 2.0, base: 0), 0, accuracy: 0.01)
    }

    func testFiredMarkersSameFrameKeepDefinitionOrder() {
        // 실물 deku 186: emerge@0 + surprise_start@0 — 같은 프레임은 정의 순서 유지.
        let ev = [AnimationMarker(name: "emerge", frame: 0), AnimationMarker(name: "surprise_start", frame: 0)]
        XCTAssertEqual(PropertyAnimation.firedMarkers(events: ev, length: 96, mode: "single",
                                                      prevF: -1, curF: 1), ["emerge", "surprise_start"])
    }

    // MARK: - 베지어 규약(핸들 x = 0.5×구간 스케일) — VA 0x1401a9d60–0x1401a9e9a

    /// WE 는 `P1x = f0 + 0.5·dx·front.x`, `P2x = f1 + 0.5·dx·back.x` 로 조립한다
    /// (`mulss xmm8, xmm12(0.5)` @0x1401a9d60 → 0x1401a9d6d/0x1401a9d74 에서 핸들 x 와 곱하고
    /// 0x1401a9d82/0x1401a9d87 에서 끝점 프레임을 더한다). y 에는 스케일이 없다(0x1401a9e58/0x1401a9e8f).
    /// 종전 Waple 은 x 도 오프셋 그대로 더해 **완전히 다른 곡선**이었다 — 아래 값이 그 회귀 감시자다.
    func testBezierHandleXScalesByHalfSegment() {
        // 저작 기본 핸들(front +1 / back −1), 구간 0→60프레임 · 값 0→100.
        // WE 규약: P1x = P2x = 30(구간 중점) → 대칭 ease. 종전 규약: P1x=1, P2x=59.
        let anim = PropertyAnimation(tracks: [[kf(0, 0), kf(60, 100)]],
                                     fps: 30, length: 60, mode: "single", relative: false)
        // 참조값은 스크래치패드 `weanim.py`(VA 재현)로 뽑고 이분법 80회로 근을 조인 것이다.
        XCTAssertEqual(anim.value(component: 0, atTime: 15.0 / 30, base: 0), 10.589254, accuracy: 0.01,
                       "frame 15 — 종전 규약이면 24.61 이 나온다")
        XCTAssertEqual(anim.value(component: 0, atTime: 45.0 / 30, base: 0), 89.410746, accuracy: 0.01,
                       "frame 45 — 종전 규약이면 75.39")
        XCTAssertEqual(anim.value(component: 0, atTime: 30.0 / 30, base: 0), 50, accuracy: 0.01,
                       "대칭이라 중점은 두 규약이 같다 — 이 점만으로는 회귀를 못 잡는다")
    }

    /// 양쪽 핸들 disabled 는 x·y 가 같은 u 다항식을 타므로 **정확히 선형**이다(스케일과 무관).
    func testDisabledHandlesStayLinearUnderNewScale() {
        let anim = PropertyAnimation(tracks: [[kf(0, 0, enabled: false), kf(60, 120, enabled: false)]],
                                     fps: 30, length: 60, mode: "single", relative: false)
        for f in stride(from: 0, through: 60, by: 5) {
            XCTAssertEqual(anim.value(component: 0, atTime: Float(f) / 30, base: 0), Float(f) * 2,
                           accuracy: 0.02, "frame \(f) 선형")
        }
    }

    // MARK: - options.wraploop (VA 0x1401a98b0–0x1401a9b90 · 호출부 0x1401a5762)

    /// 실물 `maintaindistancebetweencontrolpoints/scene.json` 형태: length 60 인데 키프레임은 0/30.
    /// wraploop 이면 frame 60 에 "첫 키프레임과 같은 값" 키프레임이 붙어 후반이 되돌아온다.
    func testWrapLoopAppendsEndpointEqualToFirstKeyframe() throws {
        let dict: [String: Any] = [
            "animation": [
                "c0": [
                    ["frame": 0, "value": 436.42032,
                     "front": ["enabled": true, "x": 1, "y": 0], "back": ["enabled": true, "x": -1, "y": -0.0]],
                    ["frame": 30, "value": 145.37645,
                     "front": ["enabled": true, "x": 1, "y": 0], "back": ["enabled": true, "x": -1, "y": -0.0]],
                ] as [[String: Any]],
                "options": ["fps": 30, "length": 60, "mode": "loop", "wraploop": true] as [String: Any],
            ] as [String: Any],
        ]
        let anim = try XCTUnwrap(PropertyAnimation.parse(dict))
        XCTAssertTrue(anim.wrapLoop)
        XCTAssertEqual(anim.tracks[0].count, 3, "frame 60 끝점이 하나 붙는다")
        let end = anim.tracks[0][2]
        XCTAssertEqual(end.frame, 60)
        XCTAssertEqual(end.value, 436.42032, accuracy: 1e-4, "끝점 값 = 첫 키프레임 값")
        XCTAssertTrue(end.backEnabled, "첫 키프레임 front 가 enabled 라 끝점 back 도 enabled")
        XCTAssertEqual(end.backX, -1, accuracy: 1e-6, "back = −front (부호반전 @0x1401a9b58)")
        XCTAssertEqual(end.backY, 0, accuracy: 1e-6)
        XCTAssertFalse(end.frontEnabled, "새로 붙인 끝점의 front 는 0/disabled")
        // 후반(frame 30→60)이 첫 값으로 되돌아온다 — 미적용이면 145.37645 에서 정지했다.
        XCTAssertEqual(anim.value(component: 0, atTime: 45.0 / 30, base: 0), 290.898385, accuracy: 0.02)
        XCTAssertEqual(anim.value(component: 0, atTime: 59.0 / 30, base: 0), 435.976007, accuracy: 0.02)
    }

    /// `"wraploop": null` 은 bool 이 아니라 서지 않는다(VA 0x1401a985d `cmp byte ptr [rbx+8], 5`).
    /// 설치본 애니 7블록 중 5개가 이 형태다.
    func testWrapLoopNullDoesNotApply() throws {
        let dict: [String: Any] = [
            "animation": [
                "c0": [["frame": 0, "value": 1.0], ["frame": 30, "value": 0.0]] as [[String: Any]],
                "options": ["fps": 15, "length": 60, "mode": "loop", "wraploop": NSNull()] as [String: Any],
            ] as [String: Any],
        ]
        let anim = try XCTUnwrap(PropertyAnimation.parse(dict))
        XCTAssertFalse(anim.wrapLoop)
        XCTAssertEqual(anim.tracks[0].count, 2, "끝점을 붙이지 않는다")
        XCTAssertEqual(anim.value(component: 0, atTime: 45.0 / 15, base: 0), 0, accuracy: 1e-4,
                       "마지막 키프레임 값에서 정지")
    }

    /// 1단계: `frame > length` 인 꼬리를 버린다(VA 0x1401a9920–0x1401a9959).
    func testWrapLoopTrimsKeyframesBeyondLength() {
        let track = [kf(0, 10), kf(20, 20), kf(50, 30), kf(80, 40)]
        let out = PropertyAnimation.wrapLooped(track, lengthFrames: 40)
        XCTAssertEqual(out.map { $0.frame }, [0, 20, 40], "50·80 은 버려지고 40 이 붙는다")
        XCTAssertEqual(out[2].value, 10, "끝점 값 = 첫 키프레임 값")
    }

    /// 2단계 분기: 마지막 키프레임이 이미 `frame == length` 면 새로 붙이지 않고 덮는다.
    func testWrapLoopOverwritesExistingEndpointKeyframe() {
        let track = [kf(0, 10), kf(30, 99)]
        let out = PropertyAnimation.wrapLooped(track, lengthFrames: 30)
        XCTAssertEqual(out.count, 2, "덮기 경로 — 개수 불변")
        XCTAssertEqual(out[1].value, 10, "값만 첫 키프레임 값으로 갈린다")
        XCTAssertEqual(out[1].backX, -1, accuracy: 1e-6)
    }

    /// 첫 키프레임 front 가 disabled 면 끝점 back 도 disabled(VA 0x1401a9b66 `and eax, ~1`).
    func testWrapLoopDisabledFrontYieldsDisabledBack() {
        let track = [kf(0, 5, enabled: false), kf(20, 7)]
        let out = PropertyAnimation.wrapLooped(track, lengthFrames: 40)
        XCTAssertFalse(out[2].backEnabled)
        XCTAssertEqual(out[2].value, 5)
    }

    /// 키프레임 1개짜리 트랙은 그대로(VA 0x1401a98dd `cmp rax, 1` / `jbe`).
    func testWrapLoopKeepsSingleKeyframeTrackUnchanged() {
        let track = [kf(0, 5)]
        XCTAssertEqual(PropertyAnimation.wrapLooped(track, lengthFrames: 60), track)
    }

    // MARK: - step 키프레임 (VA 0x1401a8f56 파스 · 0x1401a9d18 평가)

    /// step 은 **오른쪽 키프레임**의 플래그이고 그 구간 전체를 왼쪽 값으로 고정한다.
    /// 경계 `frame == 오른쪽.frame` 은 다음 구간이므로 그 지점부터 새 값이다.
    func testStepKeyframeHoldsLeftValueForWholeSegment() throws {
        let dict: [String: Any] = [
            "animation": [
                "c0": [["frame": 0, "value": 10.0],
                       ["frame": 30, "value": 20.0, "step": true],
                       ["frame": 60, "value": 30.0]] as [[String: Any]],
                "options": ["fps": 30, "length": 60, "mode": "single"] as [String: Any],
            ] as [String: Any],
        ]
        let anim = try XCTUnwrap(PropertyAnimation.parse(dict))
        XCTAssertTrue(anim.tracks[0][1].step)
        XCTAssertFalse(anim.tracks[0][0].step, "step 미기재 → false")
        XCTAssertEqual(anim.value(component: 0, atTime: 15.0 / 30, base: 0), 10, accuracy: 1e-5, "구간 내 고정")
        XCTAssertEqual(anim.value(component: 0, atTime: 29.0 / 30, base: 0), 10, accuracy: 1e-5, "직전까지 고정")
        XCTAssertEqual(anim.value(component: 0, atTime: 30.0 / 30, base: 0), 20, accuracy: 1e-5, "경계에서 전환")
        XCTAssertEqual(anim.value(component: 0, atTime: 45.0 / 30, base: 0), 25, accuracy: 0.02,
                       "다음 구간은 step 이 아니라 정상 보간")
    }

    // MARK: - mode 문자열 규약 (stricmp — VA 0x1401a8c78/0x1401a8c91)

    func testModeIsCaseInsensitiveAndUnknownFallsBackToLoop() {
        let track = [kf(0, 0, enabled: false), kf(30, 30, enabled: false)]
        // "Mirror" 대문자도 미러다.
        let mirror = PropertyAnimation(tracks: [track], fps: 30, length: 30, mode: "Mirror", relative: false)
        XCTAssertEqual(mirror.value(component: 0, atTime: 1.5, base: 0), 15, accuracy: 0.01)
        // "SINGLE" 대문자도 single(끝 클램프).
        let single = PropertyAnimation(tracks: [track], fps: 30, length: 30, mode: "SINGLE", relative: false)
        XCTAssertEqual(single.value(component: 0, atTime: 1.5, base: 0), 30, accuracy: 0.01)
        // 인식 못 하는 문자열은 flags 0 = loop 다(종전 Waple 은 클램프로 흘렸다).
        let unknown = PropertyAnimation(tracks: [track], fps: 30, length: 30, mode: "ease", relative: false)
        XCTAssertEqual(unknown.value(component: 0, atTime: 1.5, base: 0), 15, accuracy: 0.01,
                       "frame 45 → 랩 15 (클램프였다면 30)")
    }
}
