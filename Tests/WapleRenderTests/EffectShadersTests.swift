import XCTest
@testable import WapleRender

final class EffectShadersTests: XCTestCase {
    func testUnknownEffect() {
        XCTAssertNil(EffectShaders.source(for: "nope"))
        XCTAssertNil(EffectShaders.params(for: "nope", constants: [:]))
    }
    func testOpacityParams() {
        XCTAssertEqual(EffectShaders.params(for: "opacity", constants: ["alpha": [0.5]]), [0.5])
        XCTAssertEqual(EffectShaders.params(for: "opacity", constants: [:]), [1])  // default
    }
    func testTintParams() {
        // order: r,g,b,blendAlpha
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: ["color": [1, 0, 0], "alpha": [0.5]]), [1, 0, 0, 0.5])
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: [:]), [1, 0, 0, 1])  // default red, alpha 1
    }
    func testScrollParams() {
        // order: scaleX, scaleY, speedX, speedY
        let p = EffectShaders.params(for: "scroll", constants: ["scale": [2, 3], "speed": [0.1, 0.2]])
        XCTAssertEqual(p, [2, 3, 0.1, 0.2])
        XCTAssertEqual(EffectShaders.params(for: "scroll", constants: [:])?.count, 4)
    }
    func testWaterwavesParamsCount() {
        // order: cos(dir), sin(dir), speed, scale, strength, perspective
        let p = EffectShaders.params(for: "waterwaves", constants: ["speed": [4], "scale": [34]])
        XCTAssertEqual(p?.count, 6)
        XCTAssertEqual(p?[2], 4); XCTAssertEqual(p?[3], 34)
    }
    func testSourcesExist() {
        for n in ["waterwaves", "scroll", "opacity", "tint"] {
            XCTAssertNotNil(EffectShaders.source(for: n))
            XCTAssertTrue(EffectShaders.source(for: n)!.contains("ef_main"))
        }
    }
}
