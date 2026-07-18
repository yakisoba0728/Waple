import XCTest
import Metal
@testable import WapleRender

final class EffectShadersTests: XCTestCase {
    /// 모든 효과 MSL 이 ev_main/ef_main 함수로 실제 컴파일되는지(런타임) 확인.
    /// Metal 디바이스가 없는 CI 에선 스킵.
    func testAllEffectSourcesCompileMSL() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        for n in ["waterwaves", "scroll", "opacity", "tint", "waterripple", "shake", "pulse"] {
            let src = try XCTUnwrap(EffectShaders.source(for: n), "source missing for \(n)")
            let lib = try device.makeLibrary(source: src, options: nil)
            XCTAssertNotNil(lib.makeFunction(name: "ev_main"), "\(n): no ev_main")
            XCTAssertNotNil(lib.makeFunction(name: "ef_main"), "\(n): no ef_main")
        }
    }
    func testShakeParams() {
        XCTAssertEqual(EffectShaders.params(for: "shake", constants: ["amplitude": [0.02], "speed": [8]]), [0.02, 8])
        XCTAssertEqual(EffectShaders.params(for: "shake", constants: [:])?.count, 2)  // defaults
    }
    /// F265: WE shake.frag:82 `texCoordOffset = offset*g_Amp*g_Amp*flowMask` 대조 — 진폭 제곱 +
    /// flow map(texture1) 방향 구동. 구코드는 진폭 선형 + 합성 원형궤적(sin,cos*1.37)으로 flow 텍스처 미사용.
    func testShakeUsesSquaredAmplitudeAndFlowMap() throws {
        let src = try XCTUnwrap(EffectShaders.source(for: "shake"))
        XCTAssertTrue(src.contains("P[1] * P[1]"), "진폭은 제곱(g_Amp*g_Amp)이어야 함: \(src)")
        XCTAssertTrue(src.contains("flow.sample"), "flow map(texture1) 을 방향 구동에 실제로 샘플해야 함: \(src)")
        XCTAssertFalse(src.contains("cos(t * 1.37)"), "합성 원형궤적(WE 미근거)이 제거되어야 함: \(src)")
    }
    func testUnknownEffect() {
        XCTAssertNil(EffectShaders.source(for: "nope"))
        XCTAssertNil(EffectShaders.params(for: "nope", constants: [:]))
    }
    func testOpacityParams() {
        XCTAssertEqual(EffectShaders.params(for: "opacity", constants: ["alpha": [0.5]]), [0.5])
        XCTAssertEqual(EffectShaders.params(for: "opacity", constants: [:]), [1])  // default
    }
    func testTintParams() {
        // order: r,g,b,blendAlpha,blendMode — blendMode default 0 (normal)
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: ["color": [1, 0, 0], "alpha": [0.5]]), [1, 0, 0, 0.5, 0])
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: [:]), [1, 0, 0, 1, 0])  // default red, alpha 1, normal
    }
    func testTintBlendModeMapping() {
        // BLENDMODE 은 콤보(WE 전체 enum). last 슬롯 = 모드.
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: [:], combos: ["BLENDMODE": 2])?.last, 2)   // multiply
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: [:], combos: ["BLENDMODE": 11])?.last, 11) // overlay (구버전엔 불가)
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: ["blendmode": [7]])?.last, 7)  // 폴백: constants
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: [:])?.last, 0)  // 미지정 → Normal
    }

    func testPulseParams() {
        // audio mode + PULSEALPHA + bounds.
        let p = EffectShaders.params(for: "pulse", constants: ["amount": [1.5], "bounds": [0, 1]],
                                     combos: ["AUDIOPROCESSING": 3, "PULSEALPHA": 1, "BLENDMODE": 9])
        XCTAssertEqual(p?.count, 16)
        XCTAssertEqual(p?[2], 1.5)   // amount
        XCTAssertEqual(p?[6], 9)     // blendmode
        XCTAssertEqual(p?[8], 1)     // pulseAlpha
        XCTAssertEqual(p?[9], 3)     // audioMode
        // defaults: pulseColor 1, speed 3
        let d = EffectShaders.params(for: "pulse", constants: [:])
        XCTAssertEqual(d?[0], 3)     // speed default
        XCTAssertEqual(d?[7], 1)     // pulseColor default
        XCTAssertEqual(d?[9], 0)     // audioMode default off
    }
    func testWaterrippleParams() {
        // order: strength, scale, scrollSpeed (time prepended at bind time)
        let p = EffectShaders.params(for: "waterripple", constants: ["ui_editor_properties_ripple_strength": [0.3], "ui_editor_properties_ripple_scale": [2]])
        XCTAssertEqual(p?.count, 3)
        XCTAssertEqual(p?[0], 0.3); XCTAssertEqual(p?[1], 2)
        // 실제 씬 키(설계 문서 §2 정찰: ripple_strength / ripple_scale).
        let actual = EffectShaders.params(for: "waterripple", constants: ["ripple_strength": [0.3], "ripple_scale": [2]])
        XCTAssertEqual(actual?[0], 0.3); XCTAssertEqual(actual?[1], 2)
        // defaults
        let d = EffectShaders.params(for: "waterripple", constants: [:])
        XCTAssertEqual(d?.count, 3)
        XCTAssertEqual(d?[0], 0.1)  // default strength
        XCTAssertEqual(d?[1], 1)    // default scale
    }
    func testWaterrippleSourceExists() {
        let src = EffectShaders.source(for: "waterripple")
        XCTAssertNotNil(src)
        XCTAssertTrue(src!.contains("ef_main"))
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
        for n in ["waterwaves", "scroll", "opacity", "tint", "waterripple", "shake", "pulse"] {
            XCTAssertNotNil(EffectShaders.source(for: n))
            XCTAssertTrue(EffectShaders.source(for: n)!.contains("ef_main"))
        }
    }
}
