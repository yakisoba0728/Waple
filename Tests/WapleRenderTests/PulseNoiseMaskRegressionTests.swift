import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

/// F830/F831 회귀: pulse noise 항(g_Texture1) + MASK 콤보(g_Texture2) — WE pulse.frag 실물 계약.
///   noise = tex(g_Texture1, (t·1/12, t·1/36)·noiseSpeed).r · noiseAmount; pulse += noise; 후 pow
///   (AUDIOPROCESSING==0 분기 안, WE :39-42).
///   MASK: albedo = mix(sample, albedo, mask.r) — 알파 포함, rgb max(0) 클램프는 믹스 후(WE :53-58).
final class PulseNoiseMaskRegressionTests: XCTestCase {

    // MARK: 파라미터 슬롯 매핑

    func testPulseNoiseMaskParamSlots() {
        let p = EffectShaders.params(
            for: "pulse",
            constants: ["noisespeed": [0.8], "noiseamount": [1.2]],
            combos: ["MASK": 1])
        XCTAssertEqual(p?.count, 19)
        XCTAssertEqual(p?[16], 0.8)   // noiseSpeed (→ P[17])
        XCTAssertEqual(p?[17], 1.2)   // noiseAmount (→ P[18])
        XCTAssertEqual(p?[18], 1)     // MASK 콤보 (→ P[19])
        // 기본값: WE pulse.frag 주석 — noisespeed 0.5, noiseamount 0, MASK off
        let d = EffectShaders.params(for: "pulse", constants: [:])
        XCTAssertEqual(d?[16], 0.5)
        XCTAssertEqual(d?[17], 0)
        XCTAssertEqual(d?[18], 0)
    }

    // MARK: MSL 소스 계약

    func testPulseNoiseTermMatchesWE() {
        let src = EffectShaders.source(for: "pulse") ?? ""
        // 시간 스크롤 UV 상수 (t/12, t/36) × noiseSpeed — WE pulse.frag:39
        XCTAssertTrue(src.contains("0.08333333"), "noise UV x 상수(1/12) 누락")
        XCTAssertTrue(src.contains("0.02777777"), "noise UV y 상수(1/36) 누락")
        XCTAssertTrue(src.contains("* P[17]"), "noiseSpeed 승수 누락")
        XCTAssertTrue(src.contains("* P[18]"), "noiseAmount 승수 누락")
        // noise 샘플러는 repeat(util/noise.tex-json clampuvs:false — 시간 UV 는 1 초과)
        XCTAssertTrue(src.contains("address::repeat"), "noise repeat 샘플러 누락")
        // 합산 → pow 순서(WE :41-42): noise 가 pow 입력에 포함되어야 함
        guard let add = src.range(of: "pulse += noiseTex"),
              let powR = src.range(of: "pow(max(pulse, 0.0), P[4])") else {
            return XCTFail("noise 합산/pow 구문 누락")
        }
        XCTAssertTrue(add.lowerBound < powR.lowerBound, "WE 순서: noise 합산 후 pow")
    }

    func testPulseMaskBranchMatchesWE() {
        let src = EffectShaders.source(for: "pulse") ?? ""
        // mix(sample, albedo, mask.r) — 원본 프레임버퍼 샘플과 효과 결과의 믹스, P[19] 게이트
        XCTAssertTrue(src.contains("P[19] > 0.5"), "MASK 콤보 게이트 누락")
        XCTAssertTrue(src.contains("mix(c, outC, m)"), "WE mix(sample, albedo, mask) 형태 누락")
        // rgb max(0) 클램프는 믹스 후(WE :58) — 믹스가 클램프보다 먼저
        guard let mixR = src.range(of: "mix(c, outC, m)"),
              let clampR = src.range(of: "max(float3(0.0), outC.rgb)") else {
            return XCTFail("mix/clamp 구문 누락")
        }
        XCTAssertTrue(mixR.lowerBound < clampR.lowerBound, "WE 순서: mask 믹스 후 rgb 클램프")
    }

    // MARK: GPU 렌더(Metal 있을 때만)

    /// pulse ef_main 을 1x1 텍스처들로 직접 실행. time=0 이면 sin(-π/2) 기저=0:
    ///   noise=0 → pulse=0 → PULSEALPHA 면 알파 0. noise=white×1 → pulse=1 → 알파 유지.
    private func renderPulse(mask: UInt8, noiseAmount: Float, maskCombo: Float) throws -> [UInt8]? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let src = try XCTUnwrap(EffectShaders.source(for: "pulse"))
        let lib = try device.makeLibrary(source: src, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "ev_main")
        pd.fragmentFunction = lib.makeFunction(name: "ef_main")
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipe = try device.makeRenderPipelineState(descriptor: pd)

        let quad: [Float] = [-1, -1, 1, -1, -1, 1, 1, 1]  // float2 ×4 (triangleStrip)
        let vbuf = device.makeBuffer(bytes: quad, length: MemoryLayout<Float>.stride * quad.count)!

        func tex(_ px: [UInt8]) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            d.usage = [.shaderRead]
            let t = device.makeTexture(descriptor: d)!
            var v = px
            t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &v, bytesPerRow: 4)
            return t
        }
        let fb = tex([200, 100, 50, 255])          // sample (원본)
        let noise = tex([255, 255, 255, 255])      // noise.r = 1
        let maskT = tex([mask, mask, mask, 255])   // mask.r = 0(블랙)|255(화이트)

        // P = [time] + params — time=0: sin(0·speed + (0−π/2)) = −1 → 기저 smoothstep=0.
        var P: [Float] = [0,  /*time*/
                          3, 0, /*speed,phase*/ 1, 1, /*amount,power*/ 0, 1, /*threshLo,Hi*/
                          9, 1, 1, 0, /*blendmode, pulseColor, pulseAlpha, audioMode*/
                          1, 1, 1, 0, 0, 0, /*tintLo(백), tintHi(흑)*/
                          0.5, noiseAmount, maskCombo]
        var audio: Float = 0

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]; td.storageMode = .shared
        let target = device.makeTexture(descriptor: td)!
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: rpd))
        enc.setRenderPipelineState(pipe)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setFragmentTexture(fb, index: 0)
        enc.setFragmentTexture(noise, index: 1)
        enc.setFragmentTexture(maskT, index: 2)
        enc.setFragmentBytes(&P, length: MemoryLayout<Float>.stride * P.count, index: 0)
        enc.setFragmentBytes(&audio, length: MemoryLayout<Float>.stride, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: 4)
        target.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        return px
    }

    /// F830: noise=1×1 추가 시(time=0 기저 0) pulse=1 → PULSEALPHA 알파 통과. noise=0 이면 알파 0.
    func testPulseNoiseAddsToPulse() throws {
        guard let withNoise = try renderPulse(mask: 0, noiseAmount: 1, maskCombo: 0),
              let noNoise = try renderPulse(mask: 0, noiseAmount: 0, maskCombo: 0) else {
            throw XCTSkip("no Metal device")
        }
        XCTAssertEqual(withNoise[3], 255, "noise>0 → pulse=1 → 알파 유지")
        XCTAssertEqual(noNoise[3], 0, "noise=0, time=0 → pulse=0 → 알파 0")
    }

    /// F831: MASK 블랙 = mix(sample, albedo, 0) → 원본 그대로(알파 포함). 화이트 = 효과 적용.
    /// time=0·noise=0 이면 pulse=0 → PULSEALPHA 알파 0, PULSECOLOR blend 도 pulse=0 이라 rgb=원본.
    /// ⇒ 마스크 블랙/화이트 모두 rgb 동일하지만 **알파** 가 갈린다(블랙=원본 255, 화이트=효과 0).
    func testPulseMaskMixesWithOriginal() throws {
        guard let black = try renderPulse(mask: 0, noiseAmount: 0, maskCombo: 1),
              let white = try renderPulse(mask: 255, noiseAmount: 0, maskCombo: 1) else {
            throw XCTSkip("no Metal device")
        }
        XCTAssertEqual(black, [200, 100, 50, 255], "mask=0 → 원본 통과")
        XCTAssertEqual(white[3], 0, "mask=1 → 효과(pulse=0 → 알파 0) 적용")
        // MASK 콤보 OFF 면 mask=블랙이어도 효과 적용(알파 0) — 게이트 확인
        guard let off = try renderPulse(mask: 0, noiseAmount: 0, maskCombo: 0) else {
            throw XCTSkip("no Metal device")
        }
        XCTAssertEqual(off[3], 0, "MASK off → mask 텍스처 무관하게 효과 적용")
    }
}
