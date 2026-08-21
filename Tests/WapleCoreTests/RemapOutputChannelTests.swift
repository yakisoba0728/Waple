import XCTest
@testable import WapleCore

/// `remapvalue` 의 `output` 은 **채널 이름**이고, `input` 과 같은 20항 테이블(0x140484e80)을 쓴다.
/// 매퍼 0x140260f50 이 `stricmp` 선형 탐색으로 인덱스를 내고(`cmp ebx, 0x14` = 20항),
/// 못 찾으면 0x15(=21) 센티넬을 돌려준다. 저장은 `[op+0x04]`=input(0x1401ce71e) ·
/// `[op+0x08]`=output(0x1401ce759).
///
/// Waple 의 `RemapVerb` 는 그 채널과 `operation` 을 융합한 표현이라, 종전 파스가 채널 이름을
/// 그대로 `RemapVerb(rawValue:)` 에 먹여 **오퍼레이터를 통째로 드롭**하고 있었다.
/// 동봉 실측 3건이 그렇게 사라졌다 — `output:"color"` 1건 · `output:"opacity"` 2건.
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
        XCTAssertEqual(spec?.verb, .setColor, "output:\"color\" 가 드롭되고 있었다")
    }

    /// 동봉 2건 — `operation` 이 없으면 기본이 `remap`(= set)이다.
    func testOpacityChannelWithoutOperationDefaultsToSet() {
        XCTAssertEqual(remapOp(["output": "opacity"])?.verb, .setOpacity)
    }

    /// `operation` 이 동사를 가른다.
    func testOperationSelectsTheVerb() {
        XCTAssertEqual(remapOp(["output": "color", "operation": "multiply"])?.verb, .multiplyColor)
        XCTAssertEqual(remapOp(["output": "size", "operation": "multiply"])?.verb, .multiplySize)
        XCTAssertEqual(remapOp(["output": "size", "operation": "remap"])?.verb, .setSize)
        XCTAssertEqual(remapOp(["output": "rotation", "operation": "add"])?.verb, .addRotation)
        XCTAssertEqual(remapOp(["output": "rotation"])?.verb, .setRotation)
        XCTAssertEqual(remapOp(["output": "angularspeed", "operation": "add"])?.verb, .addAngularVelocity)
    }

    /// 채널 이름은 **대소문자 무시**다 — 실물 매퍼가 `stricmp` 다(0x140260f77).
    func testChannelLookupIsCaseInsensitive() {
        XCTAssertEqual(remapOp(["output": "COLOR", "operation": "remap"])?.verb, .setColor)
        XCTAssertEqual(remapOp(["output": "Opacity"])?.verb, .setOpacity)
    }

    /// 이미 Waple 융합 어휘로 적힌 것(직접 조립한 def · 기존 테스트)은 그대로 받아야 한다.
    func testFusedVerbSpellingStillAccepted() {
        XCTAssertEqual(remapOp(["output": "multiplycolor"])?.verb, .multiplyColor)
        XCTAssertEqual(remapOp(["output": "setangularvelocity"])?.verb, .setAngularVelocity)
    }

    /// Waple 에 대응 동사가 없는 채널은 **지어내지 않고** 종전대로 드롭한다(동봉 도달 0).
    func testChannelsWithoutAWapleVerbAreStillDropped() {
        for name in ["position", "controlpoint", "layerorigin", "runtime", "timeofday",
                     "distancetocontrolpoint", "lifetimefraction"] {
            XCTAssertNil(remapOp(["output": name])?.verb, "\(name) 은 대응 동사가 없어야 한다")
        }
    }

    /// 인식 못 하는 문자열도 드롭 — 실물 매퍼의 센티넬 0x15 와 같은 뜻이다.
    func testUnknownOutputIsDropped() {
        XCTAssertNil(remapOp(["output": "nosuchchannel"])?.verb)
    }
}
