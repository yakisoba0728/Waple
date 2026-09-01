import XCTest
@testable import WapleCore

final class PropertyAnimationTests: XCTestCase {
    /// 양쪽 핸들 disabled = 선형 — 중점에서 평균값.
    ///
    /// **`enabled: false` 는 좌표까지 0 으로 만든다**(2026-08-21 클러스터 AF). 실물 파서가
    /// disabled 핸들의 `x`/`y` 를 아예 읽지 않아 0 으로 남기고(0x1401a8fd1 `xorps` +
    /// 0x1401a8ffb/0x1401a907f 의 건너뛰기), 평가기는 `enabled` 비트를 **안 본다**
    /// (제어점 조립 0x1401a9d6d/0x1401a9d74/0x1401a9e58/0x1401a9e8f 가 무조건 실행).
    /// 종전 헬퍼는 `enabled: false` 인데도 `fx: 1`/`bx: -1` 을 그대로 넘겨, "실물 파서가
    /// 절대 만들지 않는 키프레임" 으로 선형성을 시험하고 있었다.
    private func kf(_ frame: Float, _ value: Float, enabled: Bool = true,
                    fx: Float = 1, fy: Float = 0, bx: Float = -1, by: Float = 0) -> PropertyKeyframe {
        PropertyKeyframe(frame: frame, value: value,
                         frontEnabled: enabled, frontX: enabled ? fx : 0, frontY: enabled ? fy : 0,
                         backEnabled: enabled, backX: enabled ? bx : 0, backY: enabled ? by : 0)
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

    /// r3-O5: `options.events` 는 **항목 단위**로 드롭한다. 종전 배열 전체 캐스트
    /// (`as? [[String: Any]]`)는 원소 하나가 비객체면 마커를 전량 잃었다 — 바로 위 파스 주석의
    /// "형식 이상 항목은 드롭" 과 실제 동작이 갈렸다.
    func testParseEventsDropsOnlyMalformedElements() throws {
        let dict: [String: Any] = [
            "animation": [
                "c0": [["frame": 0, "value": 0.0], ["frame": 30, "value": 1.0]] as [[String: Any]],
                "options": ["fps": 30, "length": 30, "mode": "single",
                            // 두 번째 원소가 **객체가 아니다** — 종전엔 이 하나로 전량 소실됐다.
                            "events": ["ignored-string",
                                       ["frame": 12, "name": "keep"],
                                       42,
                                       ["frame": 21, "name": "keep2"]] as [Any]] as [String: Any],
            ] as [String: Any],
        ]
        let anim = try XCTUnwrap(PropertyAnimation.parse(dict))
        XCTAssertEqual(anim.events, [AnimationMarker(name: "keep", frame: 12),
                                     AnimationMarker(name: "keep2", frame: 21)],
                       "비객체 원소만 드롭되고 나머지는 순서대로 살아야")
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

    // MARK: - options.wraploop (VA 0x1401a98b0–0x1401a9bb3 · 호출부 0x1401a5762)
    //
    // 함수 끝은 `ret` @0x1401a9ba6 이고 그 뒤에 noreturn 스텁 둘(0x1401a9ba7 · 0x1401a9bad)이
    // 붙는다. 종전 주석이 적던 `0x1401a9b90` 은 xmm 복원 라벨이지 함수 끝이 아니다
    // (2026-08-21 `merged()` + 디스어셈으로 재확인).

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
        // 개수를 먼저 못박는다 — 붙이기 경로가 죽으면 아래 `out[2]` 가 인덱스 트랩으로 죽어
        // 변이 계수가 "실패" 대신 "크래시" 로 기록된다(be7a3c0 회고에서 지적된 자리).
        XCTAssertEqual(out.count, 3, "frame 40 끝점이 붙는다")
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

    // MARK: - 트랙 경계 조건 (평가기 VA 0x1401a9bc0)

    /// 실물 평가기의 세 경계를 못박는다.
    /// - 키프레임 0개: WE 는 **0.0**(0x1401a9bfd `cmp [rcx],rax` → `xorps xmm0,xmm0`).
    ///   Waple 은 `value(component:)` 의 앞 가드가 **base 유지**로 흘린다.
    ///   근거는 2026-08-21 클러스터 Q 에서 다시 세웠다 — 실물이 쓰는 규칙은 "빈 트랙 → 0.0" 이
    ///   아니라 **트랙 수 == 프로퍼티 성분 수** 라는 전부-아니면-전무 게이트이고
    ///   (등록기 `sete al` 0x14017679e → `mov byte ptr [r15+0x18], al` 0x1401767a1 → 소비자
    ///   게이트 0x14017241f), `PropertyAnimation` 은 성분 수를 모르므로 그 게이트를 옮길 수 없다.
    ///   게이트 없이 0.0 만 옮기면 누락 채널이 base 대신 0 으로 눌려 **더** 갈린다.
    ///   자세한 대조는 `docs/re/property-animation.md` §3.4 · §5.1.
    ///   코퍼스 도달 0(트랙 **19개**(c0×7 + c1×6 + c2×6) 전수 키프레임 2개, 빈 배열 0건 —
    ///   종전 주석의 "20개" 는 오기다).
    /// - 키프레임 1개: 왼쪽 분기(0x1401a9cb8)와 오른쪽 분기(0x1401a9ec7)가 같은 값을 준다.
    /// - 중복 시각: WE 는 파스에서 `frame <= 직전` 을 버려(0x1401a8fc1 `jle`) 애초에 못 만든다.
    ///   Waple 은 정렬로 관용하므로 평가기까지 살아 들어온다 — 반개구간 탐색이 **마지막 중복**을
    ///   왼쪽 끝점으로 잡는다(앞의 것들은 `frame < k2.frame` 이 거짓이라 전부 건너뛴다).
    func testTrackBoundaryCases() {
        // 0개 트랙 — 자리만 지키는 채널.
        let empty = PropertyAnimation(tracks: [[], [kf(0, 1, enabled: false), kf(10, 2, enabled: false)]],
                                      fps: 30, length: 10, mode: "loop", relative: false)
        XCTAssertEqual(empty.value(component: 0, atTime: 0.1, base: 77), 77, "빈 트랙은 base 유지")
        XCTAssertEqual(empty.value(component: 9, atTime: 0.1, base: 77), 77, "범위 밖 성분도 base 유지")
        XCTAssertEqual(empty.value(component: 1, atTime: 5.0 / 30, base: 0), 1.5, accuracy: 1e-4)
        // 1개 트랙 — 어느 시각이든 그 값.
        let one = PropertyAnimation(tracks: [[kf(10, 42)]], fps: 30, length: 60,
                                    mode: "single", relative: false)
        for t: Float in [0, 10.0 / 30, 1.0, 2.0] {
            XCTAssertEqual(one.value(component: 0, atTime: t, base: 5), 42, accuracy: 1e-6,
                           "키프레임 1개 트랙은 t=\(t) 에서도 그 값")
        }
        // 중복 시각 — 마지막 중복이 왼쪽 끝점이 된다.
        let dup = PropertyAnimation(
            tracks: [[kf(0, 0, enabled: false), kf(10, 5, enabled: false),
                      kf(10, 50, enabled: false), kf(20, 100, enabled: false)]],
            fps: 1, length: 20, mode: "single", relative: false)
        XCTAssertEqual(dup.value(component: 0, atTime: 10, base: 0), 50, accuracy: 1e-4,
                       "frame 10 은 [10,20) 구간의 왼쪽 끝점 — 중복 중 마지막 값")
        XCTAssertEqual(dup.value(component: 0, atTime: 15, base: 0), 75, accuracy: 0.02)
        XCTAssertEqual(dup.value(component: 0, atTime: 5, base: 0), 2.5, accuracy: 0.02,
                       "앞 구간은 첫 중복까지 정상 보간")
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
