import XCTest
@testable import WapleCore

final class EffectManifestTests: XCTestCase {
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
}
