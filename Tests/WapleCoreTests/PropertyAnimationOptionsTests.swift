import Foundation
import XCTest
@testable import WapleCore

/// `animation.options` 블록 **전수** — 파서 VA 0x1401a96b0–0x1401a98a8,
/// 초기화 VA 0x1401a8c10–0x1401a8cd1, wraploop 후처리 VA 0x1401a98b0–0x1401a9bb3.
///
/// 옵션 파서가 `find` 하는 키는 정확히 **여섯**(`length`·`fps`·`mode`·`random`·`startpaused`·
/// `wraploop`)이고, `events` 는 **호출부**가 따로 읽는다(0x1401a57a3, 태그 6 배열). 그래서
/// "옵션 블록에서 읽히는 것" 은 일곱이고 그 밖의 이름은 런타임에 자리가 없다(⑨ 가 못박는다).
///
/// 형제 `PropertyAnimationTests` 는 곡선·보간·wraploop 의 **모양**을 본다. 여기는 옵션 블록의
/// **읽기 규약**을 본다: 어느 키가 필수인가 · 부재 시 기본값은 무엇인가 · 타입 게이트가 무엇을
/// 통과시키는가(그리고 **폴라리티가 어디서 갈리는가** — ③-2) · 키끼리 어떻게(안) 얽히는가.
/// 그리고 무엇보다 **무회귀** — 동봉 코퍼스의 `wraploop: null` 5블록이 wraploop 도입 전과
/// **비트 동일**하게 샘플링되는지를 못박는다.
///
/// 동봉·설치본 실측(2026-08-21, 두 트리 바이트 동일 · `projects/` 는 애니 0건):
/// 애니 블록 **7개 / 파일 6개**(preview 4블록·4파일 / non-preview 3블록·2파일 —
/// 저장소 규약 `is_preview` = 경로 세그먼트 중 `preview` 로 **시작**하는 것이 있는가).
/// ```
/// options.length      7/7  {60:6, 30:1}          options.random       0/7
/// options.fps         7/7  {20:4, 30:2, 15:1}    options.startpaused  0/7
/// options.mode        7/7  {"loop":6, "mirror":1} options.events      0/7
/// options.wraploop    7/7  {null:5, true:2}
/// ```
/// 키프레임 38개 · 핸들 `enabled` 는 양면 합쳐 76개(전부 진짜 bool) · `step` 0건.
///
/// `wraploop: true` 2블록은 **둘 다 non-preview** 이고 같은 파일이다
/// (`scenes/particleelementpreviews/maintaindistancebetweencontrolpoints/scene.json`).
/// 다만 그중 하나(`/objects/1/instanceoverride/controlpoint1`)는 `SceneDocument` 가
/// `instanceoverride` 애니를 드롭해 **씬 마운트에는 닿지 않는다** — 지금 실제로 랩되는 것은
/// `/objects/0/origin` 하나다(⑧).
final class PropertyAnimationOptionsTests: XCTestCase {

    // MARK: - 헬퍼

    /// **JSON 문자열을 거쳐** 파스한다. 타입 게이트 테스트는 반드시 이 경로여야 한다 —
    /// Swift 리터럴 딕셔너리(`["wraploop": 1]`)는 `1` 이 `NSNumber` 로 브리지되지 않아
    /// `as? Bool` 이 `nil` 을 돌리므로 **버그를 재현하지 못한다**. `JSONSerialization` 을 거쳐야
    /// `1` 이 `NSNumber` 가 되고 그제야 `as? Bool` 이 `true` 로 새는 실물 경로가 된다
    /// (리눅스 Swift 5.9 실측: `{"b":1}` → `as? Bool` == true, `{"b":1.0}` → true).
    private func parseJSON(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws
        -> PropertyAnimation {
        let data = try XCTUnwrap(json.data(using: .utf8), file: file, line: line)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                file: file, line: line)
        return try XCTUnwrap(PropertyAnimation.parse(obj), file: file, line: line)
    }

    /// 동봉 `maintaindistancebetweencontrolpoints/scene.json`
    /// `/objects/1/instanceoverride/controlpoint1` 의 **c1 트랙 실물 값**을 단일 채널로 옮겨 담은 것이다
    /// (여기서는 `c0` 슬롯에 넣는다 — 이 파일의 헬퍼는 성분 0 만 샘플링한다).
    /// `length 60` 인데 키프레임은 frame 0/30 뿐 — wraploop 이 후반 절반을 되살리는 자리이고,
    /// 값 범위(291.04387)가 코퍼스에서 가장 커서 랩 여부가 가장 크게 드러난다.
    /// (그 블록 자체는 `SceneDocument` 가 `instanceoverride` 애니를 드롭해 씬 마운트에는 닿지 않는다.
    ///  이 테스트는 `PropertyAnimation.parse` 를 직접 부르므로 무관하다 — 실제로 마운트에 닿는
    ///  `/objects/0/origin` 블록은 아래 ⑧ 에서 원본 형태 그대로 본다.)
    private func corpusBlock(wraploopLiteral: String?, mode: String = "loop") -> String {
        let wrap = wraploopLiteral.map { ", \"wraploop\": \($0)" } ?? ""
        return """
        {"animation": {
          "c0": [
            {"frame": 0,  "value": 436.42032,
             "front": {"enabled": true, "magic": true, "x": 1,  "y": 0},
             "back":  {"enabled": true, "magic": true, "x": -1, "y": -0.0},
             "lockangle": true, "locklength": true},
            {"frame": 30, "value": 145.37645,
             "front": {"enabled": true, "magic": true, "x": 1,  "y": 0},
             "back":  {"enabled": true, "magic": true, "x": -1, "y": -0.0},
             "lockangle": true, "locklength": true}],
          "options": {"fps": 30, "length": 60, "mode": "\(mode)"\(wrap)}}}
        """
    }

    /// 0 초부터 length 프레임까지 촘촘히 훑어 **비트 패턴**으로 모은다. 무회귀 판정은
    /// `accuracy:` 가 아니라 비트 동일이어야 한다 — 허용오차를 두면 곡선이 미세하게 달라져도 통과한다.
    private func sampleBits(_ anim: PropertyAnimation, component: Int = 0,
                            frames: Int = 240, base: Float = 0) -> [UInt32] {
        (0...frames).map { i in
            anim.value(component: component, atTime: Float(i) / 4 / anim.fps, base: base).bitPattern
        }
    }

    // MARK: - ① 무회귀: 부재/null 은 wraploop 도입 전과 비트 동일해야 한다

    /// 동봉 5블록의 형태(`"wraploop": null`)와 키 자체 부재가 **서로도, 도입 전 기준선과도** 비트 동일.
    ///
    /// 기준선은 파서를 거치지 않고 같은 트랙을 손으로 세운 애니다 — wraploop 경로가 조용히
    /// 켜지면(예: `wrapLooped` 를 무조건 호출하도록 바뀌면) 이 비교가 즉시 깨진다.
    /// `null` 이 false 로 접혀야 하는 근거: 옵션 파서가 태그 5 만 통과시킨다(VA 0x1401a985d).
    func testWrapLoopAbsentAndNullSampleBitIdenticalToNoWrapLoopBaseline() throws {
        let fromNull = try parseJSON(corpusBlock(wraploopLiteral: "null"))
        let fromAbsent = try parseJSON(corpusBlock(wraploopLiteral: nil))

        XCTAssertFalse(fromNull.wrapLoop, "`\"wraploop\": null` 은 태그 0 이라 서지 않는다")
        XCTAssertFalse(fromAbsent.wrapLoop, "키 부재의 바인더 기본값은 false")
        XCTAssertEqual(fromNull.tracks[0].count, 2, "끝점을 붙이지 않는다")
        XCTAssertEqual(fromAbsent.tracks[0].count, 2)

        // 도입 전 기준선: 같은 두 키프레임을 그대로 든 애니.
        let baseline = PropertyAnimation(
            tracks: [[PropertyKeyframe(frame: 0, value: 436.42032,
                                       frontEnabled: true, frontX: 1, frontY: 0,
                                       backEnabled: true, backX: -1, backY: -0.0),
                      PropertyKeyframe(frame: 30, value: 145.37645,
                                       frontEnabled: true, frontX: 1, frontY: 0,
                                       backEnabled: true, backX: -1, backY: -0.0)]],
            fps: 30, length: 60, mode: "loop", relative: false)

        let want = sampleBits(baseline)
        XCTAssertEqual(sampleBits(fromNull), want, "null 블록이 기준선과 비트 동일이어야 한다")
        XCTAssertEqual(sampleBits(fromAbsent), want, "부재 블록이 기준선과 비트 동일이어야 한다")

        // 그리고 이 비교가 **실제로 무언가를 잡는지** 확인한다: wraploop 을 켜면 반드시 달라진다.
        let wrapped = try parseJSON(corpusBlock(wraploopLiteral: "true"))
        XCTAssertNotEqual(sampleBits(wrapped), want,
                          "wraploop 을 켜면 달라져야 한다 — 같다면 위 비교가 아무것도 못 잡고 있는 것")
    }

    /// 동봉 5블록 중 하나는 `mode: "mirror"`(blendgradient) 다. 그쪽 형태도 null → 무변경.
    func testMirrorBlockWithNullWrapLoopIsUnchanged() throws {
        let anim = try parseJSON(corpusBlock(wraploopLiteral: "null", mode: "mirror"))
        XCTAssertFalse(anim.wrapLoop)
        XCTAssertEqual(anim.tracks[0].count, 2)
        XCTAssertEqual(anim.mode, "mirror")
    }

    // MARK: - ② mode × wraploop — 직교(어느 쪽도 이기지 않는다)

    /// **런타임에는 모드 게이트가 없다.** 옵션 파서가 flags bit4 를 mode 와 무관하게 세우고
    /// (VA 0x1401a9881 `or dword ptr [r12+0xc], 0x10`), 호출부는 `test byte ptr [r13+0x44], 0x10`
    /// **하나만** 보고 트랙 후처리를 돈다(VA 0x1401a5762). mirror(bit0)·single(bit1)은 시간 진행
    /// (VA 0x1401a9f60)에서만 읽힌다. `"loop"` 강제는 에디터 저작 측 제약일 뿐이다
    /// (체크박스 `ng-if="settings.mode === 'loop'"` scripts.js char@810392, 저장 시
    /// `"loop"!==e.mode&&delete e.wraploop` char@575499 — 둘 다 **문자** 오프셋이다).
    ///
    /// 동봉 도달 0(true 2블록은 둘 다 `mode: "loop"`) — 그래서 이 테스트는 회귀 방지용 규약 못박기다.
    func testWrapLoopAppliesRegardlessOfMode() throws {
        for mode in ["loop", "mirror", "single", "LOOP", "nonsense"] {
            let anim = try parseJSON(corpusBlock(wraploopLiteral: "true", mode: mode))
            XCTAssertTrue(anim.wrapLoop, "mode=\(mode) 에서도 wraploop 플래그는 선다")
            XCTAssertEqual(anim.tracks[0].count, 3,
                           "mode=\(mode): 모드와 무관하게 frame 60 끝점이 붙는다(VA 0x1401a5762 에 모드 검사 없음)")
            // 인덱싱 전에 개수를 확인한다 — 구현을 죽였을 때 이 테스트가 **크래시가 아니라 실패**로
            // 떨어져야 변이 계수가 의미를 갖는다(트랩은 프로세스를 죽여 나머지 집계를 삼킨다).
            guard anim.tracks[0].count > 2 else { continue }
            XCTAssertEqual(anim.tracks[0][2].frame, 60)
            XCTAssertEqual(anim.tracks[0][2].value, 436.42032, accuracy: 1e-4,
                           "mode=\(mode): 끝점 값 = 첫 키프레임 값")
        }
    }

    /// mode 는 여전히 제 일을 한다 — wraploop 이 켜져 있어도 클록 정책은 mode 가 정한다.
    /// single 은 끝에서 정지(VA 0x1401aa177), loop 은 랩(VA 0x1401aa0cf).
    /// 랩된 트랙의 끝점 값이 첫 값과 같으므로 **single 의 종료값도 첫 값**이 된다.
    func testModeStillGovernsClockWhenWrapLoopIsOn() throws {
        let single = try parseJSON(corpusBlock(wraploopLiteral: "true", mode: "single"))
        let loop = try parseJSON(corpusBlock(wraploopLiteral: "true", mode: "loop"))
        // 두 애니의 **트랙은 같다**(둘 다 랩돼 [0:436.42, 30:145.38, 60:436.42]) — 다른 건 클록뿐이다.
        XCTAssertEqual(single.tracks[0].count, 3)
        XCTAssertEqual(loop.tracks[0].count, 3)

        // t = 3초 = frame 90 — length 60 을 넘긴 자리에서 두 모드가 갈린다.
        //   single: frame 60 에 클램프 → 랩된 끝점 값 = 첫 키프레임 값.
        //   loop  : 90 % 60 = 30 → 가운데 키프레임 값.
        XCTAssertEqual(single.value(component: 0, atTime: 3, base: 0), 436.42032, accuracy: 1e-3,
                       "single: length 에서 정지 — 랩된 끝점 값(=첫 값)에 머문다")
        XCTAssertEqual(loop.value(component: 0, atTime: 3, base: 0), 145.37645, accuracy: 1e-3,
                       "loop: frame 90 → 30 으로 랩")
    }

    // MARK: - ③ 타입 게이트 — jsoncpp 태그 5 만 통과한다

    /// WE 는 bool 여섯 자리 전부에서 `cmp byte ptr [..+8], 5` 로 태그를 먼저 본다. 다만 **검사가
    /// 실패했을 때의 결과는 두 부류로 갈린다** — `options.wraploop`(0x1401a985d) ·
    /// `options.startpaused`(0x1401a97df) · `options.random`(0x1401a97f9) · 키프레임
    /// `step`(0x1401a8f77) 넷은 **false** 로 떨어지지만, 핸들 `back.enabled`(0x1401a8ebb) ·
    /// `front.enabled`(0x1401a8f1c) 둘은 실패 분기가 `mov bpl,1` / `mov r14b,1` 이라 **true** 다.
    /// 아래 ③-2 가 그쪽을 따로 본다. 이 테스트는 **false 부류**만 본다.
    /// jsoncpp 는 `1` 을 태그 1, `"true"` 를 태그 4 로 들고 있으므로 여기서는 **둘 다 false** 다.
    ///
    /// 이 테스트가 **JSON 문자열을 거치는 이유**: Swift 리터럴 `["wraploop": 1]` 은 `NSNumber` 로
    /// 브리지되지 않아 `as? Bool` 이 nil 이다 — 버그가 재현되지 않는다. `JSONSerialization` 을
    /// 거쳐야 `1` 이 `NSNumber` 가 되고 맨 `as? Bool` 이 **true** 로 샌다.
    func testWrapLoopRequiresRealJSONBooleanNotNumberOrString() throws {
        for literal in ["1", "1.0", "2", "\"true\"", "\"1\"", "0", "0.0", "null", "[]", "{}"] {
            let anim = try parseJSON(corpusBlock(wraploopLiteral: literal))
            XCTAssertFalse(anim.wrapLoop, "`\"wraploop\": \(literal)` 은 태그 5 가 아니라 false 여야 한다")
            XCTAssertEqual(anim.tracks[0].count, 2, "`\(literal)`: 끝점이 붙으면 안 된다")
        }
        for literal in ["true", "false"] {
            let anim = try parseJSON(corpusBlock(wraploopLiteral: literal))
            XCTAssertEqual(anim.wrapLoop, literal == "true", "`\(literal)` 은 진짜 bool 이라 그대로 읽는다")
        }
    }

    /// `startpaused` 도 같은 게이트다(VA 0x1401a97df → flags 0x20000000 @0x1401a8cb0).
    /// 이 비트가 서면 시간 진행이 통째로 막혀(VA 0x1401a9f73) 값이 frame 0 에 고정된다.
    func testStartPausedRequiresRealJSONBooleanNotNumber() throws {
        func block(_ literal: String) -> String {
            """
            {"animation": {
              "c0": [{"frame": 0, "value": 10.0}, {"frame": 30, "value": 40.0}],
              "options": {"fps": 30, "length": 30, "mode": "loop", "startpaused": \(literal)}}}
            """
        }
        for literal in ["1", "1.0", "\"true\"", "null", "0"] {
            let anim = try parseJSON(block(literal))
            XCTAssertFalse(anim.startPaused, "`\"startpaused\": \(literal)` → false")
            XCTAssertEqual(anim.value(component: 0, atTime: 0.5, base: 0), 25, accuracy: 1e-3,
                           "`\(literal)`: 정지하지 않고 계속 재생")
        }
        let paused = try parseJSON(block("true"))
        XCTAssertTrue(paused.startPaused)
        XCTAssertEqual(paused.value(component: 0, atTime: 0.5, base: 0), 10, accuracy: 1e-6,
                       "startpaused: frame 0 에 고정")
    }

    /// 키프레임 `step` 은 **false 부류**다(0x1401a8f77 → `jne 0x1401a8faf` = `xor sil,sil`).
    /// `step: 1` 이 계단을 켜면 구간 전체 값이 달라지므로 이 게이트는 값에 직접 물린다.
    func testKeyframeStepRequiresRealJSONBoolean() throws {
        let stepAsNumber = try parseJSON("""
        {"animation": {
          "c0": [{"frame": 0, "value": 10.0}, {"frame": 30, "value": 40.0, "step": 1}],
          "options": {"fps": 30, "length": 30, "mode": "loop"}}}
        """)
        XCTAssertFalse(stepAsNumber.tracks[0][1].step, "`\"step\": 1` 은 태그 1 이라 false")
        XCTAssertEqual(stepAsNumber.value(component: 0, atTime: 15.0 / 30, base: 0), 25,
                       accuracy: 1e-3, "계단이 아니라 보간")
    }

    // MARK: - ③-2 핸들 `enabled` — **폴라리티가 반대다**

    /// `back.enabled`(0x1401a8ebb) · `front.enabled`(0x1401a8f1c)는 태그 검사 실패 분기가
    /// `mov bpl,1` / `mov r14b,1` 이라 **부재·비-bool 이 전부 enabled** 다. 핸들을 끄는 방법은
    /// 진짜 bool `false` **하나뿐**이고, 핸들 자체가 객체(태그 7)가 아니면 그때만 disabled 다
    /// (바깥 검사 0x1401a8e94 back / 0x1401a8ef5 front).
    ///
    /// **이 테스트는 종전 트리의 미커밋 변경을 반증한 자리다.** 그 변경은 여기에도 옵션용
    /// 태그-5 게이트를 걸어 `{"enabled": 1}` 과 `enabled` 부재를 **disabled** 로 만들었는데,
    /// 원본은 둘 다 **enabled** 다. 코퍼스 도달 0(핸들 76개 전부 명시 bool)이라 동봉 자산은
    /// 어느 쪽이든 같지만, 원본과 반대 방향으로 굳힐 이유가 없다.
    func testHandleEnabledDefaultsToTrueWhenAbsentOrNonBool() throws {
        func block(_ frontLiteral: String) -> String {
            """
            {"animation": {
              "c0": [{"frame": 0, "value": 0.0, "front": \(frontLiteral)},
                     {"frame": 30, "value": 30.0}],
              "options": {"fps": 30, "length": 30, "mode": "loop"}}}
            """
        }
        // 핸들이 객체이기만 하면 enabled — 값이 숫자든 문자열이든 null 이든, 아예 없든.
        for literal in ["{\"enabled\": 1, \"x\": 1, \"y\": 50}",
                        "{\"enabled\": \"true\", \"x\": 1, \"y\": 50}",
                        "{\"enabled\": null, \"x\": 1, \"y\": 50}",
                        "{\"enabled\": 0, \"x\": 1, \"y\": 50}",
                        "{\"x\": 1, \"y\": 50}"] {
            let anim = try parseJSON(block(literal))
            XCTAssertTrue(anim.tracks[0][0].frontEnabled,
                          "front=\(literal): 태그 5 가 아니면 **enabled**(0x1401a8f1c `jne` → `mov r14b,1`)")
            XCTAssertEqual(anim.tracks[0][0].frontX, 1, accuracy: 1e-6)
            XCTAssertEqual(anim.tracks[0][0].frontY, 50, accuracy: 1e-6)
            // 핸들이 켜지면 곡선이 선형에서 벗어난다 — 15 가 아니어야 한다.
            XCTAssertNotEqual(anim.value(component: 0, atTime: 15.0 / 30, base: 0), 15,
                              accuracy: 0.5, "front=\(literal): 핸들이 실제로 곡선을 휜다")
        }
        // 끄는 방법은 진짜 bool false 하나뿐이다.
        let off = try parseJSON(block("{\"enabled\": false, \"x\": 1, \"y\": 50}"))
        XCTAssertFalse(off.tracks[0][0].frontEnabled, "진짜 bool false 만 핸들을 끈다")
        XCTAssertEqual(off.value(component: 0, atTime: 15.0 / 30, base: 0), 15, accuracy: 1e-3,
                       "꺼지면 선형")
        // 핸들이 객체가 아니면(또는 없으면) disabled — 바깥 태그 7 검사.
        for literal in ["true", "1", "\"front\"", "null", "[]"] {
            let anim = try parseJSON(block(literal))
            XCTAssertFalse(anim.tracks[0][0].frontEnabled,
                           "front=\(literal): 객체(태그 7)가 아니면 disabled")
            XCTAssertEqual(anim.value(component: 0, atTime: 15.0 / 30, base: 0), 15, accuracy: 1e-3)
        }
        // back 쪽도 같은 규칙이다(0x1401a8ebb).
        let backNoEnabled = try parseJSON("""
        {"animation": {
          "c0": [{"frame": 0, "value": 0.0},
                 {"frame": 30, "value": 30.0, "back": {"x": -1, "y": 50}}],
          "options": {"fps": 30, "length": 30, "mode": "loop"}}}
        """)
        XCTAssertTrue(backNoEnabled.tracks[0][1].backEnabled, "back 도 부재 → enabled")
        XCTAssertEqual(backNoEnabled.tracks[0][1].backX, -1, accuracy: 1e-6)
    }

    // MARK: - ④ 키별 기본값(부재 시) — 바인더 기본값 ≠ 에디터 주입 기본값

    /// 부재 시 바인더 기본값을 전수로 못박는다.
    ///
    /// | 키 | 타입 게이트 | 부재/불일치 |
    /// | --- | --- | --- |
    /// | `options`(블록) | 태그 7 | WE: **애니 드롭**(0x1401a56a6/0x1401a96bb) · Waple: 관용 |
    /// | `length` | 태그 1–3 | WE: **애니 드롭**(0x1401a9714) · Waple: 마지막 키프레임 프레임 |
    /// | `fps` | 태그 1–3 | WE: **애니 드롭**(0x1401a9723) · Waple: 30 |
    /// | `mode` | 태그 4 | NULL 포인터 → stricmp 건너뜀 → flags 0 = **loop**(0x1401a8c67) |
    /// | `random` | 태그 5 | **false** — 그리고 세워도 읽는 곳이 없다 |
    /// | `startpaused` | 태그 5 | **false** |
    /// | `wraploop` | 태그 5 | **false** |
    ///
    /// **주입기 기본값과 다르다.** 에디터가 새 프로퍼티 애니를 만들 때 쓰는 값은
    /// `{fps:30,length:60,mode:"loop",wraploop:!0}`(scripts.js char@238870) — `wraploop` 이
    /// **true** 다. 퍼펫은 `{length:10, fps:10, mode:"loop", wraploop:true, smoothing:0,
    /// stiffness:1}`(char@235782), 카메라 경로는 `{length:10, fps:10, mode:"single",
    /// wraploop:!1}`(char@280948). 자산 JSON 을 읽는 쪽이 따라야 하는 것은 **바인더 기본값(false)**
    /// 이다 — 주입기 기본값을 부재 기본값으로 쓰면 `wraploop` 을 안 적은 애니가 전부 랩된다.
    func testOptionsDefaultsWhenKeysAbsent() throws {
        let anim = try parseJSON("""
        {"animation": {
          "c0": [{"frame": 0, "value": 10.0}, {"frame": 45, "value": 40.0}],
          "options": {"fps": 20, "length": 45}}}
        """)
        XCTAssertEqual(anim.mode, "loop", "mode 부재 → loop(flags 0). single 이 아니다")
        XCTAssertFalse(anim.startPaused, "startpaused 부재 → false")
        XCTAssertFalse(anim.wrapLoop, "wraploop 부재 → **false**. 에디터 주입 기본값 true 가 아니다")
        XCTAssertEqual(anim.tracks[0].count, 2, "부재 기본값이 false 라 끝점이 붙지 않는다")
        XCTAssertTrue(anim.events.isEmpty, "events 부재 → 빈 배열")
        XCTAssertFalse(anim.relative, "relative 부재 → false")
        XCTAssertEqual(anim.fps, 20)
        XCTAssertEqual(anim.length, 45)
    }

    /// `mode` 비교는 `stricmp` 다(VA 0x1401a8c78 / 0x1401a8c91) — 대소문자 무시.
    /// 인식 못 한 문자열은 flags 0 = **loop** 이지 클램프가 아니다.
    func testModeIsCaseInsensitiveAndUnknownFallsBackToLoop() throws {
        func block(_ mode: String) -> String {
            """
            {"animation": {
              "c0": [{"frame": 0, "value": 0.0}, {"frame": 30, "value": 30.0}],
              "options": {"fps": 30, "length": 30, "mode": \(mode)}}}
            """
        }
        // frame 40 에서 두 모드가 갈린다(트랙은 length 30 의 선형 0→30):
        //   mirror: 40 % 60 = 40 > 30 → 60 − 40 = 20  ·  loop: 40 % 30 = 10.
        // (frame 45 를 고르면 mirror 15 · loop 15 로 우연히 같아져 아무것도 못 가른다.)
        let upperMirror = try parseJSON(block("\"MIRROR\""))
        XCTAssertEqual(upperMirror.value(component: 0, atTime: 40.0 / 30, base: 0), 20,
                       accuracy: 1e-3, "\"MIRROR\" 는 stricmp 로 mirror(VA 0x1401a8c78)")
        // 미인식 문자열과 비문자열(태그 4 아님 → mode 포인터 NULL)은 전부 loop.
        for mode in ["\"nonsense\"", "42", "null", "\"\""] {
            let anim = try parseJSON(block(mode))
            XCTAssertEqual(anim.value(component: 0, atTime: 40.0 / 30, base: 0), 10,
                           accuracy: 1e-3, "mode=\(mode): loop 랩(frame 40 → 10). 클램프가 아니다")
        }
    }

    // MARK: - ⑤ random — 반증(죽은 비트)

    /// `options.random` 은 파서에는 있지만(VA 0x1401a9777 → flags bit2 @0x1401a8ca5)
    /// `.text` 전체 스윕에서 **읽는 곳이 0건**이다. 에디터도 로케일 키
    /// `ui_editor_animation_modal_random_start_frame` 만 남기고 참조하지 않으며(ui/ 전체 0건),
    /// 동봉·설치본 애니 7블록에도 키가 없다. 그래서 Waple 은 파스하지도 소비하지도 않는다.
    ///
    /// 이 테스트는 "무시한다" 를 못박는다 — `random` 이 있든 없든 샘플링이 **비트 동일**이어야 한다.
    /// 누가 추측으로 시작 프레임 난수화를 넣으면 여기서 깨진다(그리고 비결정성이 들어온다).
    func testRandomKeyIsInertAndDoesNotPerturbSampling() throws {
        let without = try parseJSON("""
        {"animation": {
          "c0": [{"frame": 0, "value": 10.0}, {"frame": 60, "value": 70.0}],
          "options": {"fps": 30, "length": 60, "mode": "loop"}}}
        """)
        for literal in ["true", "false", "1", "null"] {
            let with = try parseJSON("""
            {"animation": {
              "c0": [{"frame": 0, "value": 10.0}, {"frame": 60, "value": 70.0}],
              "options": {"fps": 30, "length": 60, "mode": "loop", "random": \(literal)}}}
            """)
            XCTAssertEqual(sampleBits(with), sampleBits(without),
                           "`\"random\": \(literal)` 은 샘플링을 바꾸면 안 된다(비트 동일)")
        }
        // 두 번 파스해도 같아야 한다 — 난수 시작 프레임이 몰래 들어오면 여기서 깨진다.
        let again = try parseJSON("""
        {"animation": {
          "c0": [{"frame": 0, "value": 10.0}, {"frame": 60, "value": 70.0}],
          "options": {"fps": 30, "length": 60, "mode": "loop", "random": true}}}
        """)
        XCTAssertEqual(sampleBits(again), sampleBits(without), "재파스도 결정적이어야 한다")
    }

    // MARK: - ⑥ wrapLooped 후처리의 남은 모서리

    /// 끝점의 back 핸들은 첫 키프레임의 **`front` 를 부호반전**한 것이지 `back` 이 아니다
    /// (VA 0x1401a9b48 `test r10b, 2` = 첫 키프레임 flags bit1(front enabled) → 0x1401a9b58
    /// `xorps` 부호마스크 0x140492ff0 → 0x1401a9b5f 저장). "마지막→처음 순환 보간" 으로 오독하면
    /// 첫 키프레임의 `back` 을 쓰게 되는데 그건 다른 곡선이다.
    func testWrapLoopEndpointBackMirrorsFirstFrontNotFirstBack() {
        let first = PropertyKeyframe(frame: 0, value: 5,
                                     frontEnabled: true, frontX: 0.25, frontY: 7,
                                     backEnabled: true, backX: -0.9, backY: -3)
        let last = PropertyKeyframe(frame: 20, value: 50,
                                    frontEnabled: true, frontX: 1, frontY: 0,
                                    backEnabled: true, backX: -1, backY: 0)
        let out = PropertyAnimation.wrapLooped([first, last], lengthFrames: 40)
        XCTAssertEqual(out.count, 3)
        guard out.count > 2 else { return }
        let end = out[2]
        XCTAssertEqual(end.backX, -0.25, accuracy: 1e-6, "back.x = −first.front.x (−0.9 = first.back.x 가 아니다)")
        XCTAssertEqual(end.backY, -7, accuracy: 1e-6, "back.y = −first.front.y (−3 이 아니다)")
        XCTAssertTrue(end.backEnabled)
        XCTAssertEqual(end.value, 5, "끝점 값 = 첫 키프레임 값")
    }

    /// `frame == length` 를 덮는 경로는 **value 와 back 만** 갈고 front·step 은 보존한다
    /// (VA 0x1401a9b45 는 flags 의 bit0 만 만지고 0x1401a9b8b 가 value 만 덮는다 — front(bit1)와
    /// step(bit2)은 그대로다).
    func testWrapLoopOverwritePreservesFrontHandleAndStepFlag() {
        let first = PropertyKeyframe(frame: 0, value: 5,
                                     frontEnabled: true, frontX: 0.5, frontY: 2,
                                     backEnabled: false, backX: 0, backY: 0)
        let endpoint = PropertyKeyframe(frame: 40, value: 99,
                                        frontEnabled: true, frontX: 0.75, frontY: -4,
                                        backEnabled: true, backX: -1, backY: 6, step: true)
        let out = PropertyAnimation.wrapLooped([first, endpoint], lengthFrames: 40)
        XCTAssertEqual(out.count, 2, "덮기 경로 — 개수 불변")
        guard out.count == 2 else { return }
        XCTAssertEqual(out[1].value, 5, "value 는 첫 키프레임 값으로 갈린다")
        XCTAssertEqual(out[1].backX, -0.5, accuracy: 1e-6, "back 은 −first.front 로 갈린다")
        XCTAssertEqual(out[1].backY, -2, accuracy: 1e-6)
        XCTAssertTrue(out[1].frontEnabled, "front 는 보존")
        XCTAssertEqual(out[1].frontX, 0.75, accuracy: 1e-6)
        XCTAssertEqual(out[1].frontY, -4, accuracy: 1e-6)
        XCTAssertTrue(out[1].step, "step 비트도 보존(VA 0x1401a9b45 는 bit0 만 만진다)")
    }

    /// 꼬리를 버리다 키프레임이 1개가 되면 **버린 상태 그대로** 반환한다.
    /// WE 는 vector 의 end 포인터를 실제로 줄여 놓고 개수 검사에서 빠져나간다
    /// (0x1401a9920 pop 루프 → 0x1401a9935 `jbe 0x1401a9960` → 0x1401a996e `jbe 0x1401a9b90` = 반환).
    /// 즉 "아무 일도 없었던 것처럼" 되돌리지 않는다.
    func testWrapLoopTrimLeavingOneKeyframeReturnsTrimmedTrack() {
        let track = [PropertyKeyframe(frame: 0, value: 5,
                                      frontEnabled: false, frontX: 0, frontY: 0,
                                      backEnabled: false, backX: 0, backY: 0),
                     PropertyKeyframe(frame: 80, value: 9,
                                      frontEnabled: false, frontX: 0, frontY: 0,
                                      backEnabled: false, backX: 0, backY: 0)]
        let out = PropertyAnimation.wrapLooped(track, lengthFrames: 40)
        XCTAssertEqual(out.count, 1, "frame 80 은 버려지고 1개가 남는다")
        guard let head = out.first else { return XCTFail("빈 트랙이 나오면 안 된다") }
        XCTAssertEqual(head.frame, 0)
        XCTAssertEqual(head.value, 5, "끝점을 붙이지 않고 그대로 반환")
    }

    /// 빈 트랙은 만지지 않는다(WE 도 `count <= 1` 에서 즉시 반환 — VA 0x1401a98dd).
    func testWrapLoopLeavesEmptyTrackAlone() {
        XCTAssertEqual(PropertyAnimation.wrapLooped([], lengthFrames: 60).count, 0)
    }

    /// `length` 는 엔진에서 i32 다(`asInt` VA 0x1401a9815) — 소수 길이는 0 방향 절단이고
    /// 끝점 프레임도 그 정수다.
    func testWrapLoopEndpointUsesTruncatedIntegerLength() throws {
        let anim = try parseJSON("""
        {"animation": {
          "c0": [{"frame": 0, "value": 1.0}, {"frame": 10, "value": 2.0}],
          "options": {"fps": 30, "length": 45.9, "mode": "loop", "wraploop": true}}}
        """)
        XCTAssertEqual(anim.tracks[0].count, 3)
        guard anim.tracks[0].count > 2 else { return }
        XCTAssertEqual(anim.tracks[0][2].frame, 45, "45.9 → 45(0 방향 절단)")
    }

    // MARK: - ⑦ 동봉 코퍼스 실물 형태 회귀

    /// `maintaindistancebetweencontrolpoints/scene.json` 의 두 블록이 실제로 얼마나 달라지는지.
    /// c1 은 `436.42032 → 145.37645` 라 끝점 복귀 폭이 **291.04387 = 값 범위 전체**다.
    /// 미적용이면 frame 30–60 이 145.37645 에 정지한다.
    func testBundledWrapLoopBlockRecoversWholeValueRangeInSecondHalf() throws {
        let wrapped = try parseJSON(corpusBlock(wraploopLiteral: "true"))
        let flat = try parseJSON(corpusBlock(wraploopLiteral: "null"))

        // frame 60(= length)에서: 랩되면 첫 값, 아니면 마지막 키프레임 값에 정지.
        let atEnd = wrapped.value(component: 0, atTime: 59.999 / 30, base: 0)
        let atEndFlat = flat.value(component: 0, atTime: 59.999 / 30, base: 0)
        XCTAssertEqual(atEnd, 436.42032, accuracy: 0.05, "랩: 끝에서 첫 값으로 복귀")
        XCTAssertEqual(atEndFlat, 145.37645, accuracy: 1e-3, "미적용: 마지막 키프레임 값에 정지")
        XCTAssertEqual(abs(atEnd - atEndFlat), 291.04387, accuracy: 0.05,
                       "실측 최대 어긋남 = 값 범위 전체")

        // 후반 절반이 정말 정지하는지: 미적용은 frame 30..<60 이 전부 같은 값.
        // (frame 60 은 loop 클록이 0 으로 접는 자리라 제외한다 — `60 % 60 == 0` → 첫 값.)
        for f in stride(from: 30.0, to: 60.0, by: 5.0) {
            XCTAssertEqual(flat.value(component: 0, atTime: Float(f) / 30, base: 0), 145.37645,
                           accuracy: 1e-3, "미적용 frame \(f): 정지")
        }
        // 랩은 단조 복귀 — frame 30 에서 60 으로 갈수록 첫 값에 가까워진다.
        var prev = wrapped.value(component: 0, atTime: 30.0 / 30, base: 0)
        for f in stride(from: 35.0, through: 60.0, by: 5.0) {
            let cur = wrapped.value(component: 0, atTime: Float(f) / 30, base: 0)
            XCTAssertGreaterThan(cur, prev, "랩 frame \(f): 첫 값(436.42)으로 되돌아오는 중")
            prev = cur
        }
    }

    /// 다른 채널(c1/c2)도 같이 랩된다 — 호출부가 트랙 벡터 전체를 stride 0x30 으로 순회한다
    /// (VA 0x1401a5769–0x1401a5793). 채널 하나만 랩되면 3성분 프로퍼티가 찢어진다.
    func testWrapLoopAppliesToEveryChannelNotJustC0() throws {
        let anim = try parseJSON("""
        {"animation": {
          "c0": [{"frame": 0, "value": 1.0}, {"frame": 30, "value": 2.0}],
          "c1": [{"frame": 0, "value": 10.0}, {"frame": 30, "value": 20.0}],
          "c2": [{"frame": 0, "value": 100.0}, {"frame": 30, "value": 200.0}],
          "options": {"fps": 30, "length": 60, "mode": "loop", "wraploop": true}}}
        """)
        XCTAssertEqual(anim.tracks.count, 3)
        for (i, want) in [(0, Float(1)), (1, Float(10)), (2, Float(100))] {
            XCTAssertEqual(anim.tracks[i].count, 3, "c\(i) 도 끝점이 붙어야 한다")
            guard anim.tracks[i].count > 2 else { continue }
            XCTAssertEqual(anim.tracks[i][2].frame, 60)
            XCTAssertEqual(anim.tracks[i][2].value, want, "c\(i) 끝점 값 = 그 채널 첫 키프레임 값")
        }
    }

    /// 덮기 경로 + **첫 키프레임 front 가 disabled** 인 조합. WE 는 flags bit0 만 지우고
    /// backX/backY 는 **남긴다**(0x1401a9b66 `and eax, 0xfffffffe` — 0x1401a9b5f 저장을 건너뛴다).
    /// 붙이기 경로(형제 `PropertyAnimationTests.testWrapLoopDisabledFrontYieldsDisabledBack`)는
    /// 새 키프레임이 0 으로 초기화돼 back 도 0 이라 이 구분이 안 보인다 — 덮기 경로에서만 갈린다.
    func testWrapLoopOverwriteWithDisabledFirstFrontKeepsStaleBackValues() {
        let first = PropertyKeyframe(frame: 0, value: 5,
                                     frontEnabled: false, frontX: 0, frontY: 0,
                                     backEnabled: true, backX: -0.9, backY: -3)
        let endpoint = PropertyKeyframe(frame: 40, value: 99,
                                        frontEnabled: true, frontX: 0.75, frontY: -4,
                                        backEnabled: true, backX: -0.8, backY: 3)
        let out = PropertyAnimation.wrapLooped([first, endpoint], lengthFrames: 40)
        XCTAssertEqual(out.count, 2, "덮기 경로")
        guard out.count == 2 else { return }
        XCTAssertEqual(out[1].value, 5, "value 는 첫 키프레임 값")
        XCTAssertFalse(out[1].backEnabled, "첫 front 가 disabled 라 끝점 back 도 disabled(bit0 클리어)")
        XCTAssertEqual(out[1].backX, -0.8, accuracy: 1e-6, "backX 는 지우지 않고 그대로 남는다")
        XCTAssertEqual(out[1].backY, 3, accuracy: 1e-6, "backY 도 그대로")
        XCTAssertTrue(out[1].frontEnabled, "front 는 손대지 않는다")
    }

    // MARK: - ⑧ 실제로 마운트에 닿는 코퍼스 블록 원본 형태

    /// `maintaindistancebetweencontrolpoints/scene.json` `/objects/0/origin` — `wraploop: true` 2블록
    /// 중 **`SceneDocument` 가 실제로 파스하는 유일한 블록**이다(오브젝트 애니 키 5개 중 `origin`).
    /// c0/c2 는 상수 0 이고 **c1 만** `0 → -126.1462` 로 움직이며 `relative: true` 다.
    /// 세 채널 전부 랩돼야 3성분 프로퍼티가 찢어지지 않는다.
    func testBundledOriginBlockWrapsEveryChannelAndKeepsRelative() throws {
        let anim = try parseJSON("""
        {"animation": {
          "c0": [{"frame": 0,  "value": 0,
                  "front": {"enabled": true, "magic": true, "x": 1, "y": 0},
                  "back":  {"enabled": true, "magic": true, "x": -1, "y": -0.0},
                  "lockangle": true, "locklength": true},
                 {"frame": 30, "value": 0,
                  "front": {"enabled": true, "magic": true, "x": 1, "y": 0},
                  "back":  {"enabled": true, "magic": true, "x": -1, "y": -0.0},
                  "lockangle": true, "locklength": true}],
          "c1": [{"frame": 0,  "value": 0,
                  "front": {"enabled": true, "magic": true, "x": 1, "y": 0},
                  "back":  {"enabled": true, "magic": true, "x": -1, "y": -0.0},
                  "lockangle": true, "locklength": true},
                 {"frame": 30, "value": -126.1462,
                  "front": {"enabled": true, "magic": true, "x": 1, "y": 0},
                  "back":  {"enabled": true, "magic": true, "x": -1, "y": -0.0},
                  "lockangle": true, "locklength": true}],
          "c2": [{"frame": 0,  "value": 0,
                  "front": {"enabled": true, "magic": true, "x": 1, "y": 0},
                  "back":  {"enabled": true, "magic": true, "x": -1, "y": -0.0},
                  "lockangle": true, "locklength": true},
                 {"frame": 30, "value": 0,
                  "front": {"enabled": true, "magic": true, "x": 1, "y": 0},
                  "back":  {"enabled": true, "magic": true, "x": -1, "y": -0.0},
                  "lockangle": true, "locklength": true}],
          "options": {"fps": 30, "length": 60, "mode": "loop", "wraploop": true},
          "relative": true}}
        """)
        XCTAssertTrue(anim.wrapLoop)
        XCTAssertTrue(anim.relative, "relative 는 bool 값을 읽는다(WE 는 키 존재만 — 이 블록은 true 라 동치)")
        XCTAssertEqual(anim.tracks.count, 3)
        for c in 0..<3 {
            XCTAssertEqual(anim.tracks[c].count, 3, "c\(c) 도 frame 60 끝점이 붙어야 한다")
            guard anim.tracks[c].count > 2 else { continue }
            XCTAssertEqual(anim.tracks[c][2].frame, 60)
            XCTAssertEqual(anim.tracks[c][2].value, 0, accuracy: 1e-6, "세 채널 다 첫 값 0 으로 복귀")
        }
        // `lockangle`/`locklength`/`magic` 은 재생에 없다(바이너리 xref 0건) — 파스가 무시해야 한다.
        XCTAssertTrue(anim.tracks[1][0].frontEnabled)
        XCTAssertEqual(anim.tracks[1][0].frontX, 1, accuracy: 1e-6)

        // relative 는 base 를 더한다. 랩 덕분에 frame 30→60 이 base 로 되돌아온다.
        let base: Float = 7
        XCTAssertEqual(anim.value(component: 1, atTime: 30.0 / 30, base: base), base - 126.1462,
                       accuracy: 1e-3, "frame 30 은 최저점")
        let atEnd = anim.value(component: 1, atTime: 59.999 / 30, base: base)
        XCTAssertEqual(atEnd, base, accuracy: 0.05, "frame 60 에서 base 로 복귀")
        // 미적용이면 후반이 최저점에 정지 — 이 블록의 실측 어긋남 폭은 126.1462 다.
        // (대조군도 `relative: true` 여야 base 합산이 같은 조건이 된다.)
        let flat = try parseJSON("""
        {"animation": {
          "c1": [{"frame": 0, "value": 0}, {"frame": 30, "value": -126.1462}],
          "options": {"fps": 30, "length": 60, "mode": "loop", "wraploop": null},
          "relative": true}}
        """)
        // c0 부재 → c0 자리는 빈 트랙, c1 은 인덱스 1.
        let atEndFlat = flat.value(component: 1, atTime: 59.999 / 30, base: base)
        XCTAssertEqual(atEndFlat, base - 126.1462, accuracy: 1e-3, "미적용: 최저점에 정지")
        XCTAssertEqual(abs(atEnd - atEndFlat), 126.1462, accuracy: 0.05,
                       "Waple 이 실제로 파스하는 블록의 실측 어긋남")
    }

    // MARK: - ⑨ 옵션 블록에서 읽는 키는 정확히 일곱이다

    /// WE 의 옵션 파서(0x1401a96b0)는 `length`·`fps`·`mode`·`random`·`startpaused`·`wraploop`
    /// **여섯 개만** `find` 하고, `events` 는 호출부가 따로 읽는다(0x1401a57a3, 태그 6 배열).
    /// 그 밖의 이름은 런타임에 아무 자리도 없다 — 에디터가 `options` 에 같이 저장하는
    /// `smoothing`/`stiffness`(퍼펫) · `parent`/`name` 은 **저작 메타**이고, `keyframes` 같은
    /// 이름은 아예 직렬화 이름이 아니다.
    ///
    /// 이 테스트는 "더 읽을 게 남았나" 를 못박는다 — 미지의 형제 키를 넣어도 샘플링이 **비트 동일**
    /// 이어야 하고, 누가 근거 없이 하나를 읽기 시작하면 여기서 깨진다.
    func testUnknownSiblingOptionKeysAreInert() throws {
        let bare = try parseJSON("""
        {"animation": {
          "c0": [{"frame": 0, "value": 3.0}, {"frame": 40, "value": 9.0}],
          "options": {"fps": 20, "length": 40, "mode": "loop"}}}
        """)
        let noisy = try parseJSON("""
        {"animation": {
          "c0": [{"frame": 0, "value": 3.0}, {"frame": 40, "value": 9.0}],
          "options": {"fps": 20, "length": 40, "mode": "loop",
                      "smoothing": 0, "stiffness": 1, "parent": {"id": 7, "key": "origin"},
                      "name": "walk", "keyframes": [], "easing": "cubic", "interpolation": 2,
                      "tangent": "auto", "step": true, "curve": "bezier"}}}
        """)
        XCTAssertEqual(sampleBits(noisy), sampleBits(bare),
                       "형제 키를 아무리 넣어도 샘플링은 비트 동일이어야 한다")
        XCTAssertEqual(noisy.mode, bare.mode)
        XCTAssertEqual(noisy.fps, bare.fps)
        XCTAssertEqual(noisy.length, bare.length)
        XCTAssertFalse(noisy.wrapLoop, "options 레벨 `step` 은 키프레임 플래그지 옵션이 아니다")
        XCTAssertFalse(noisy.startPaused)
        XCTAssertTrue(noisy.events.isEmpty)
    }
}
