import XCTest
@testable import WapleCore

/// `remapvalue` 의 `output` 은 **채널 이름**이고, `input` 과 같은 20항 테이블(0x140484e80)을 쓴다.
/// 매퍼 0x140260f50 이 `stricmp` 선형 탐색으로 인덱스를 내고(`cmp ebx, 0x14` = 20항),
/// 못 찾으면 0x15(=21) 센티넬을 돌려준다. 저장은 `[op+0x04]`=input(0x1401ce71e) ·
/// `[op+0x08]`=output(0x1401ce759).
///
/// **[2026-08-21] `RemapVerb` 는 더 이상 파스의 결과가 아니다.** 실물은 채널·산술·축을 각각
/// 다른 필드에 담으므로(`RemapSpec.outputChannel` / `.operation` / `.outputComponent`),
/// `verb` 는 그 조합의 **읽기 뷰**로만 남는다. 이 파일은 두 층을 다 못박는다 — 축이 맞는지와,
/// 융합 뷰가 종전 철자를 그대로 되푸는지.
final class RemapOutputChannelTests: XCTestCase {

    private func remapOp(_ extra: [String: Any]) -> RemapSpec? {
        var o: [String: Any] = ["name": "remapvalue", "outputrangemin": 0, "outputrangemax": 1]
        for (k, v) in extra { o[k] = v }
        let d = ParticleSystemDef.parse(["operator": [o]], material: nil)
        for op in d.operators { if case let .remapValueEx(spec) = op { return spec } }
        return nil
    }

    /// 동봉 `remapvalue/new_particle_system.json` 의 실제 모양 — 종전엔 통째로 드롭됐다.
    func testColorChannelIsNoLongerDropped() {
        let spec = remapOp(["output": "color", "operation": "remap"])
        XCTAssertEqual(spec?.outputChannel, .color, "output:\"color\" 가 드롭되고 있었다")
        XCTAssertEqual(spec?.operation, .remap)
        XCTAssertEqual(spec?.verb, .setColor, "융합 뷰")
    }

    /// **부재 기본은 `remap`(=Assign)이 아니라 `multiply` 다.**
    /// 주입기 0x1401bfbba 가 `mov r8,[0x140484f28]`(= "multiply") 로 심는다.
    /// 동봉 도달은 `remapvalue` 12건 중 5건(unique 4)이고, 그중 그림이 바뀌는 것은
    /// `thunderbolt.json` 계열의 `output:"opacity"` 2건이다(`RemapOperationAxesTests` 가 실측).
    func testOpacityChannelWithoutOperationDefaultsToMultiply() {
        let spec = remapOp(["output": "opacity"])
        XCTAssertEqual(spec?.outputChannel, .opacity)
        XCTAssertEqual(spec?.operation, .multiply, "주입기 0x1401bfbba → [0x140484f28] = \"multiply\"")
        XCTAssertEqual(spec?.verb, .multiplyOpacity)
    }

    /// `output` 부재도 드롭이 아니다 — 주입기 0x1401bfbf5 가 `[0x140484e90]` = "size" 를 심는다.
    func testAbsentOutputIsInjectedAsSize() {
        let spec = remapOp([:])
        XCTAssertEqual(spec?.outputChannel, .size, "주입기 0x1401bfbf5 → \"size\"")
        XCTAssertEqual(spec?.operation, .multiply)
        XCTAssertEqual(spec?.verb, .multiplySize)
    }

    /// 두 축은 **직교**다 — 채널 × 4산술이 전부 성립해야 한다.
    func testChannelAndOperationAreOrthogonal() {
        for name in ["color", "opacity", "size", "rotation", "angularspeed", "velocity",
                     "speed", "position", "maxlifetime", "controlpoint"] {
            for (raw, want) in [("remap", RemapOperation.remap), ("multiply", .multiply),
                                ("add", .add), ("subtract", .subtract)] {
                let spec = remapOp(["output": name, "operation": raw])
                XCTAssertEqual(spec?.outputChannel.rawValue, name, "\(name)/\(raw) 채널")
                XCTAssertEqual(spec?.operation, want, "\(name)/\(raw) 산술")
            }
        }
    }

    /// 융합 뷰는 대응 이름이 있는 조합에서만 값을 낸다 — 실물엔 융합 이름 자체가 없다.
    func testFusedVerbIsOnlyADerivedView() {
        XCTAssertEqual(remapOp(["output": "color", "operation": "multiply"])?.verb, .multiplyColor)
        XCTAssertEqual(remapOp(["output": "size", "operation": "remap"])?.verb, .setSize)
        XCTAssertEqual(remapOp(["output": "rotation", "operation": "add"])?.verb, .addRotation)
        XCTAssertEqual(remapOp(["output": "angularspeed", "operation": "add"])?.verb, .addAngularVelocity)
        // 융합 이름이 없는 조합 — nil 이 정직하다.
        XCTAssertNil(remapOp(["output": "color", "operation": "add"])?.verb)
        XCTAssertNil(remapOp(["output": "position", "operation": "remap"])?.verb)
        XCTAssertNil(remapOp(["output": "speed", "operation": "add"])?.verb)
    }

    /// 채널 이름은 **대소문자 무시**다 — 실물 매퍼가 `stricmp` 다(0x140260f77).
    func testChannelLookupIsCaseInsensitive() {
        XCTAssertEqual(remapOp(["output": "COLOR", "operation": "remap"])?.outputChannel, .color)
        XCTAssertEqual(remapOp(["output": "Opacity"])?.outputChannel, .opacity)
        XCTAssertEqual(remapOp(["output": "AngularSpeed"])?.outputChannel, .angularSpeed)
    }

    /// 이미 Waple 융합 어휘로 적힌 것(직접 조립한 def · 기존 테스트)은 두 축으로 풀린다.
    func testFusedVerbSpellingIsUnfoldedIntoAxes() {
        let mc = remapOp(["output": "multiplycolor"])
        XCTAssertEqual(mc?.outputChannel, .color)
        XCTAssertEqual(mc?.operation, .multiply)
        XCTAssertEqual(mc?.verb, .multiplyColor)

        let sav = remapOp(["output": "setangularvelocity"])
        XCTAssertEqual(sav?.outputChannel, .angularSpeed)
        XCTAssertEqual(sav?.operation, .remap)
        XCTAssertEqual(sav?.verb, .setAngularVelocity)

        // `operation` 키가 명시돼 있으면 **명시 쪽이 산술 축을 이긴다** — 실물은 두 필드가 따로다.
        let mixed = remapOp(["output": "multiplysize", "operation": "add"])
        XCTAssertEqual(mixed?.outputChannel, .size)
        XCTAssertEqual(mixed?.operation, .add)
        XCTAssertEqual(mixed?.verb, .multiplySize, "자산이 쓴 철자는 뷰에 그대로 남는다")
    }

    /// 종전에 드롭되던 채널 11종이 이제 **파스된다**. 실물은 20종을 다 받는다.
    /// (그중 6종은 실물에서도 출력 무동작이고, CP 계열 5종은 Waple 미구현 — 시뮬 쪽 검증은
    ///  `RemapOperationAxesTests.testUnappliedChannelsDoNotTouchTheSimulation`.)
    func testAllTwentyChannelsParse() {
        for c in RemapChannel.allCases {
            // `input` 은 확장 키다 — 이게 없으면 `velocity`/`speed` 는 레거시 `.remapValue` 경로로
            // 빠져(그쪽이 무회귀 경로다) 여기 `.remapValueEx` 조회에 안 잡힌다.
            XCTAssertEqual(remapOp(["output": c.rawValue, "input": "lifetimefraction"])?.outputChannel, c,
                           "\(c.rawValue)(슬롯 \(c.weIndex)) 이 드롭되고 있다")
        }
    }

    /// 확장 키가 하나도 없는 `velocity`/`speed` 는 **레거시 경로**를 그대로 탄다(시뮬 비트동일 무회귀).
    func testLegacyVelocityAndSpeedPathIsUntouched() {
        let d = ParticleSystemDef.parse(["operator": [
            ["name": "remapvalue", "output": "velocity", "outputrangemin": 0, "outputrangemax": 1],
            ["name": "remapvalue", "output": "speed", "outputrangemin": 0, "outputrangemax": 1],
        ]], material: nil)
        XCTAssertEqual(d.operators.count, 2)
        for op in d.operators {
            guard case .remapValue = op else { return XCTFail("레거시 경로를 벗어났다: \(op)") }
        }
    }

    /// 인식 못 하는 문자열은 드롭 — 실물 매퍼의 센티넬 0x15 가 `dec`+`cmp 0x11`+`ja`(0x140245993)
    /// 에 걸려 **무동작**이 되는 것과 관측이 같다.
    func testUnknownOutputIsDropped() {
        XCTAssertNil(remapOp(["output": "nosuchchannel"]))
    }
}
