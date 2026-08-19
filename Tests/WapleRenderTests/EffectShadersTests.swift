import XCTest
import Metal
@testable import WapleCore
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
        XCTAssertEqual(EffectShaders.params(for: "shake", constants: ["amplitude": [0.02], "speed": [8]]), [0.02, 8, 0, 1])
        let d = EffectShaders.params(for: "shake", constants: [:])
        XCTAssertEqual(d?.count, 4)  // amp, speed, bounds.x, bounds.y
        // F-X8: WE shake.frag g_Speed 실 기본값 1(구코드 5 는 실물과 5배 어긋남 — 코퍼스 실측 상례).
        XCTAssertEqual(d?[1], 1, "speed 기본값은 WE 실물(shake.frag default:1) 과 일치해야 함")
        XCTAssertEqual(d?[2], 0); XCTAssertEqual(d?[3], 1)  // bounds 기본 "0 1"
    }
    /// F-X8: bounds 키(WE shake.vert g_Bounds, 기본 "0 1")가 파라미터 슬롯으로 실제 전달돼야 한다.
    func testShakeBoundsParam() {
        let p = EffectShaders.params(for: "shake", constants: ["bounds": [0.994, 0.997]])
        XCTAssertEqual(p?.count, 4)
        XCTAssertEqual(p?[2], 0.994); XCTAssertEqual(p?[3], 0.997)
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
        // order: r,g,b,blendAlpha,blendMode — blendMode default 30(F672: WE tint.frag [COMBO] default)
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: ["color": [1, 0, 0], "alpha": [0.5]]), [1, 0, 0, 0.5, 30])
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: [:]), [1, 0, 0, 1, 30])  // default red, alpha 1, tint
    }
    func testTintBlendModeMapping() {
        // BLENDMODE 은 콤보(WE 전체 enum). last 슬롯 = 모드.
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: [:], combos: ["BLENDMODE": 2])?.last, 2)   // multiply
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: [:], combos: ["BLENDMODE": 11])?.last, 11) // overlay (구버전엔 불가)
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: ["blendmode": [7]])?.last, 7)  // 폴백: constants
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: [:])?.last, 30)  // 미지정 → WE 기본 Tint(F672)
    }

    func testPulseParams() {
        // audio mode + PULSEALPHA + bounds.
        let p = EffectShaders.params(for: "pulse", constants: ["amount": [1.5], "bounds": [0, 1]],
                                     combos: ["AUDIOPROCESSING": 3, "PULSEALPHA": 1, "BLENDMODE": 9])
        XCTAssertEqual(p?.count, 19)  // F830/F831: +noiseSpeed, noiseAmount, MASK콤보
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
        // F-X8: 실코퍼스 material 키(스톡 waterripple.frag/.vert 주석 확정) = ripplestrength/scale/
        // animationspeed. order: strength, scale, scrollSpeed(=animationspeed 구동, time 은 bind 시 별도 선두).
        let p = EffectShaders.params(for: "waterripple", constants: ["ripplestrength": [0.3], "scale": [2], "animationspeed": [0.2]])
        XCTAssertEqual(p?.count, 3)
        XCTAssertEqual(p?[0], 0.3); XCTAssertEqual(p?[1], 2); XCTAssertEqual(p?[2], 0.2)
        // 구 키(ripple_strength/ripple_scale)도 폴백으로 여전히 인식(무회귀).
        let legacy = EffectShaders.params(for: "waterripple", constants: ["ripple_strength": [0.3], "ripple_scale": [2]])
        XCTAssertEqual(legacy?[0], 0.3); XCTAssertEqual(legacy?[1], 2)
        // defaults — animationspeed 실 기본 0.15(WE waterripple.frag/.vert 주석), 구코드는 scrollspeed 0.05 오기본값.
        let d = EffectShaders.params(for: "waterripple", constants: [:])
        XCTAssertEqual(d?.count, 3)
        XCTAssertEqual(d?[0], 0.1)   // default strength(ripplestrength)
        XCTAssertEqual(d?[1], 1)     // default scale
        XCTAssertEqual(d?[2] ?? -1, 0.15, accuracy: 1e-6)  // default animationspeed
    }
    /// F-X8: WE waterripple.frag `texCoord += normal.xy * g_Strength * g_Strength * mask` — 강도 제곱.
    /// 선형 적용이면 기본값(0.1)에서 실제(0.01)보다 10배 과대 왜곡.
    func testWaterrippleUsesSquaredStrength() throws {
        let src = try XCTUnwrap(EffectShaders.source(for: "waterripple"))
        XCTAssertTrue(src.contains("P[1] * P[1]"), "강도는 제곱(g_Strength*g_Strength)이어야 함: \(src)")
    }
    func testWaterrippleSourceExists() {
        let src = EffectShaders.source(for: "waterripple")
        XCTAssertNotNil(src)
        XCTAssertTrue(src!.contains("ef_main"))
    }
    /// F412: waterripple aux[0](slot1=노멀맵) 미바인드 폴터는 중립 노멀 (128,128,255) — 흰색이면
    /// 셰이더 언팩(rgb*2-1) 후 n=(1,1,1) 이라 마스크 유효 영역 전체가 상시 대각 변위(정적 왜곡).
    /// shake flow map 폴터의 F265 와 동형. 마스크(slot2) 폴터는 흰색(=효과 전체 적용) 유지가 정상.
    func testWaterrippleNormalFallbackIsNeutral() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let r = SceneRenderer()
        let pkg = ScenePackage.assemble([])
        // (a) 명시 nil 슬롯 경로(textureNames 루프 인터셉트) + (b) 슬롯 아예 없음(패딩 경로).
        for eff in [SceneEffect(name: "waterripple", constants: [:], textureNames: [nil, nil, nil]),
                    SceneEffect(name: "waterripple", constants: [:], textureNames: [])] {
            let gpu = try XCTUnwrap(r.buildHandPortEffect(eff, package: pkg, device: device))
            guard case .handPort(_, let aux, _) = gpu.bind else { return XCTFail("handPort 바인드 expected") }
            XCTAssertGreaterThanOrEqual(aux.count, 2)
            var px = [UInt8](repeating: 0, count: 4)
            aux[0].getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            XCTAssertEqual(px, [128, 128, 255, 255], "노멀맵 폴터는 중립 (128,128,255) — 언팩 시 (0,0,1)=무왜곡")
            aux[1].getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
            XCTAssertEqual(px, [255, 255, 255, 255], "마스크 폴터는 흰색(전체 적용) 유지")
        }
    }
    func testScrollParams() {
        // order: scaleX, scaleY, speedX, speedY(부호보존 제곱, F267). 실키는 repeat(scale)·speedx/speedy —
        // WE scroll.vert:19 sign(v)*v^2 커브를 상수 단계에 반영.
        let p = EffectShaders.params(for: "scroll", constants: ["repeat": [2, 3], "speedx": [0.1], "speedy": [-0.2]])
        XCTAssertEqual(p?.count, 4)
        XCTAssertEqual(p?[0], 2); XCTAssertEqual(p?[1], 3)
        XCTAssertEqual(p?[2] ?? -999, 0.01, accuracy: 1e-6)    // sign(0.1)*0.1^2
        XCTAssertEqual(p?[3] ?? -999, -0.04, accuracy: 1e-6)   // sign(-0.2)*0.2^2(부호 보존)
        // 폴백: 구 키(scale/speed 배열)도 여전히 인식(무회귀 — 실배포 케이싱 불확실 대비).
        let legacy = EffectShaders.params(for: "scroll", constants: ["scale": [2, 3], "speed": [0.1, 0.2]])
        XCTAssertEqual(legacy?[0], 2); XCTAssertEqual(legacy?[1], 3)
        XCTAssertEqual(legacy?[2] ?? -999, 0.01, accuracy: 1e-6)
        XCTAssertEqual(legacy?[3] ?? -999, 0.04, accuracy: 1e-6)
        // 기본값: WE 실 기본 speedx/speedy=0.2(구코드는 [0.05,0] 오기본값).
        let d = EffectShaders.params(for: "scroll", constants: [:])
        XCTAssertEqual(d?.count, 4)
        XCTAssertEqual(d?[2] ?? -999, 0.04, accuracy: 1e-6)    // sign(0.2)*0.2^2
        XCTAssertEqual(d?[3] ?? -999, 0.04, accuracy: 1e-6)
    }
    func testWaterwavesParamsCount() {
        // order: dir.x, dir.y, speed, scale, strength, perspective
        let p = EffectShaders.params(for: "waterwaves", constants: ["speed": [4], "scale": [34]])
        XCTAssertEqual(p?.count, 6)
        XCTAssertEqual(p?[2], 4); XCTAssertEqual(p?[3], 34)
    }

    /// F268/F269: WE waterwaves.vert:48 rotateVec2((0,1), direction) — 기준벡터 (0,1). direction=0(기본)
    /// 이면 dir=(0,1)(세로). 구 코드는 기준벡터 (1,0) 이라 상시 90° 어긋났었다.
    ///
    /// G-B4-02: 저장 단위는 **라디안**이다(`rotateVec2` 가 인자를 cos/sin 에 그대로 넣고,
    /// 어노테이션이 `"range":[0,6.28]` + `"default":3.14159265358` + `"conversion":"rad2deg"`).
    /// 아래 두 번째 단언이 도(度) 변환 재유입을 막는 음성 가드다 — 90 을 넣었을 때 90**도**가
    /// 아니라 90**라디안**으로 읽혀야 한다.
    func testWaterwavesDirectionVectorMatchesWERotateVec2Basis() {
        let p0 = EffectShaders.params(for: "waterwaves", constants: [:])
        XCTAssertEqual(p0?[0] ?? .nan, 0, accuracy: 1e-6, "dir.x = -sin(0)")
        XCTAssertEqual(p0?[1] ?? .nan, 1, accuracy: 1e-6, "dir.y = cos(0)")
        // UI 의 90° 는 씬에 π/2 로 저장된다 → dir = (-1, 0)(가로).
        let pHalfPi = EffectShaders.params(for: "waterwaves", constants: ["direction": [.pi / 2]])
        XCTAssertEqual(pHalfPi?[0] ?? .nan, -1, accuracy: 1e-4, "dir.x = -sin(π/2)")
        XCTAssertEqual(pHalfPi?[1] ?? .nan, 0, accuracy: 1e-4, "dir.y = cos(π/2)")
        // 음성 가드: 90 은 90도가 아니라 90 라디안이다.
        let p90 = EffectShaders.params(for: "waterwaves", constants: ["direction": [90]])
        XCTAssertEqual(p90?[0] ?? .nan, -sin(Float(90)), accuracy: 1e-4, "90 은 라디안으로 읽힌다")
        XCTAssertEqual(p90?[1] ?? .nan, cos(Float(90)), accuracy: 1e-4, "90 은 라디안으로 읽힌다")
    }
    func testSourcesExist() {
        for n in ["waterwaves", "scroll", "opacity", "tint", "waterripple", "shake", "pulse"] {
            XCTAssertNotNil(EffectShaders.source(for: n))
            XCTAssertTrue(EffectShaders.source(for: n)!.contains("ef_main"))
        }
    }
}
