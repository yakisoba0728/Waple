import XCTest
@testable import WapleCore

final class EffectManifestTests: XCTestCase {

    /// 중복 FBO 이름이 파스를 통과하고, **소비처가 그것으로 죽지 않아야** 한다.
    ///
    /// `EffectManifest` 는 치수만 8192 로 클램프하고 이름 유일성은 보지 않는다(설계상 그대로 둔다 —
    /// 파서는 파일이 말하는 것을 그대로 옮기는 게 맞다). 문제는 소비처였다:
    /// `SceneRendererResources.swift:573` 이 `Dictionary(uniqueKeysWithValues:)` 로 이름→인덱스
    /// 표를 만들면서 중복 키에 트랩했고, 그 줄이 `loadEffectManifest` 바로 다음이라
    /// **셰이더 해석보다 먼저** 터졌다. 매니페스트는 pkg 우선 조회라 워크샵 pkg 가 자체
    /// `effects/<name>/effect.json` 을 실으면 그대로 도달한다.
    ///
    /// 여기서는 파서가 중복을 보존하는지(= 소비처가 중복을 실제로 받게 되는지)를 고정한다.
    /// 소비처의 무트랩 규약은 같은 커밋에서 `uniquingKeysWith:` 로 바뀌었다.
    func testDuplicateFboNamesArePreservedForConsumers() throws {
        let json = """
        {"passes":[{"material":"materials/effects/a.json","target":"_rt_Dup"}],
         "fbos":[{"name":"_rt_Dup","scale":1},{"name":"_rt_Dup","scale":4}]}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.fbos.count, 2, "파서는 중복을 접지 않는다 — 접으면 소비처가 중복을 못 본다")
        XCTAssertEqual(m.fbos.map(\.name), ["_rt_Dup", "_rt_Dup"])
        // 소비처가 쓰는 것과 같은 방식으로 표를 만들어도 트랩하지 않아야 한다(뒤가 이긴다).
        let index = Dictionary(m.fbos.enumerated().map { ($1.name, $0) },
                               uniquingKeysWith: { _, later in later })
        XCTAssertEqual(index["_rt_Dup"], 1, "중복 이름은 뒤 선언이 이겨야 한다")
    }
    /// 실물 localcontrast effect.json 구조 그대로.
    func testParsesPassesTargetsBindsFbos() throws {
        let json = """
        {"passes":[
           {"material":"materials/effects/a.json","target":"_rt_Q1",
            "bind":[{"name":"previous","index":0}]},
           {"material":"materials/effects/b.json","target":"_rt_Q2",
            "bind":[{"name":"_rt_Q1","index":0}]},
           {"material":"materials/effects/c.json",
            "bind":[{"name":"_rt_Q1","index":0},{"name":"previous","index":2}]}],
         "fbos":[
           {"name":"_rt_Q1","scale":4,"format":"rgba8888"},
           {"name":"_rt_Q2","scale":4}]}
        """
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.passes.count, 3)
        XCTAssertEqual(m.fbos.count, 2)
        XCTAssertEqual(m.fbos[0].name, "_rt_Q1")
        XCTAssertEqual(m.fbos[0].scale, 4)
        let p0 = m.passes[0]
        XCTAssertEqual(p0.material, "materials/effects/a.json")
        XCTAssertEqual(p0.target, "_rt_Q1")
        XCTAssertEqual(p0.binds.count, 1)
        XCTAssertEqual(p0.binds[0].name, "previous")
        XCTAssertEqual(p0.binds[0].index, 0)
        XCTAssertNil(m.passes[2].target, "target 부재 = 효과 출력")
        XCTAssertEqual(m.passes[2].binds[1].name, "previous")
        XCTAssertEqual(m.passes[2].binds[1].index, 2)
    }

    /// 단일 패스(shader 직지정 스타일)도 매니페스트로.
    func testSinglePassWithDirectShader() throws {
        let json = #"{"passes":[{"shader":"effects/foo"}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.passes.count, 1)
        XCTAssertEqual(m.passes[0].shader, "effects/foo")
        XCTAssertNil(m.passes[0].material)
        XCTAssertTrue(m.fbos.isEmpty)
    }

    /// 실물 motionblur 의 command=copy 패스(셰이더 없이 source fbo → target fbo 지속).
    func testCopyCommandPass() throws {
        let json = #"{"passes":[{"material":"m.json","target":"_b2"},{"command":"copy","target":"_b1","source":"_b2"},{"material":"c.json"}],"fbos":[{"name":"_b1","scale":1},{"name":"_b2","scale":1}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.passes.count, 3)
        XCTAssertEqual(m.passes[1].command, "copy")
        XCTAssertEqual(m.passes[1].source, "_b2")
        XCTAssertEqual(m.passes[1].target, "_b1")
        XCTAssertNil(m.passes[1].material)
        XCTAssertNil(m.passes[0].command)
    }

    /// X-②: 실물 fluidsimulation `{"command":"swap","source":"_rt_SmokeVelocity1","target":"_rt_SmokeVelocity2"}`.
    func testSwapCommandPass() throws {
        let json = #"{"passes":[{"command":"swap","source":"_rt_V1","target":"_rt_V2"}],"fbos":[{"name":"_rt_V1","scale":1},{"name":"_rt_V2","scale":1}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.passes[0].command, "swap")
        XCTAssertEqual(m.passes[0].source, "_rt_V1")
        XCTAssertEqual(m.passes[0].target, "_rt_V2")
        XCTAssertNil(m.passes[0].material)
    }

    func testRejectsNegativeBindSlots() throws {
        let json = #"{"passes":[{"shader":"effects/foo","bind":[{"name":"previous","index":-1},{"name":"mask","index":0}]}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.passes[0].binds, [EffectManifest.Bind(name: "mask", index: 0)])
    }

    func testHugeFBOScaleDefaultsInsteadOfTrapping() throws {
        let json = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt","scale":1e300}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.fbos, [EffectManifest.FBO(name: "_rt", scale: 1)])
    }

    /// X-①: 실물 cursorripple `_rt_EightBuffer1/2` {fit:512} — 정사각 고정 크기(scale 무관).
    func testFBOFitParsedAsSquareFixedSize() throws {
        let json = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt_EightBuffer1","fit":512,"format":"rgba8888"}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.fbos[0].fixedWidth, 512)
        XCTAssertEqual(m.fbos[0].fixedHeight, 512)
    }

    /// X-①: 실물 glitter `_rt_GlitterTiles` {width:256, height:256, uvs:"repeat"} — 비정사각도 지원 +
    /// 타일 아틀라스 랩 플래그.
    func testFBOWidthHeightAndUvsRepeatParsed() throws {
        let json = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt_GlitterTiles","width":256,"height":128,"format":"r8","uvs":"repeat"}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertEqual(m.fbos[0].fixedWidth, 256)
        XCTAssertEqual(m.fbos[0].fixedHeight, 128)
        XCTAssertTrue(m.fbos[0].uvsRepeat)
    }

    /// scale 만 있으면 fixedWidth/fixedHeight 는 nil(종전 dst 비례 경로 무회귀).
    func testFBOWithoutFitOrSizeStaysScaleBased() throws {
        let json = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt_Q","scale":4}]}"#
        let m = try XCTUnwrap(EffectManifest.parse(Data(json.utf8)))
        XCTAssertNil(m.fbos[0].fixedWidth)
        XCTAssertNil(m.fbos[0].fixedHeight)
        XCTAssertFalse(m.fbos[0].uvsRepeat)
    }

    /// X-① 클램프: fit 의 신뢰불가 초대형 값(safeInt 범위 밖)은 scale 과 동일하게 무시(nil) —
    /// 트랩 없이 scale 기반 폴백으로 안전 낙하. 범위 안이지만 과대(>8192)한 값은 8192 로 클램프.
    func testHugeFBOFitDoesNotTrap() throws {
        let outOfRange = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt","fit":1e300}]}"#
        let m1 = try XCTUnwrap(EffectManifest.parse(Data(outOfRange.utf8)))
        XCTAssertNil(m1.fbos[0].fixedWidth)
        XCTAssertNil(m1.fbos[0].fixedHeight)

        let overCap = #"{"passes":[{"shader":"effects/foo"}],"fbos":[{"name":"_rt","fit":100000}]}"#
        let m2 = try XCTUnwrap(EffectManifest.parse(Data(overCap.utf8)))
        XCTAssertEqual(m2.fbos[0].fixedWidth, 8192)
        XCTAssertEqual(m2.fbos[0].fixedHeight, 8192)
    }
}
