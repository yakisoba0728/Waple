import XCTest
import Metal
@testable import WapleRender

/// render-color 그룹 씬 구현 갭 수정 회귀(2026-07 심층 감사 S-48/49/50 + low S-95/97/98/99).
/// 근거 = WE base-assets 실물 셰이더 직접 대조:
/// - S-48: `downsample_quarter_bloom.vert` — 추출 탭 `a_TexCoord ± g_TexelSize`(±1텍셀, bilinear 4×4 박스).
/// - S-49: `downsample_eighth_blur_v.vert`/`blur_h_bloom.vert` — `localTexel = g_TexelSize*8.0`
///   (g_TexelSize=풀해상도 텍셀 확정, dig-effects-a.md §1.1) → 첫 블러 스트라이드 2 quarter-texel.
/// - S-50: `effects/tint/shaders/tint.frag` — `[COMBO]{"combo":"BLENDMODE","default":30}` +
///   `#if BLENDMODE == 0 → albedo.a = 1.0`.
/// - S-95: HDR 추출도 동일 4탭 다운샘플 — quarter 단일 단계는 ±1텍셀이 풋프린트 전체 커버.
/// - S-97: `effects/pulse/shaders/pulse.frag` — `sin(g_Time*speed + (g_PulsePhase - 1.57079632679))`
///   (phase 는 radian [0,6.282] 직접, 2π 스케일 아님).
/// - S-98: HDR 최종 알파 = 1.0 강제(LDR 경로와 동일 — 캡처 PNG 투명 픽셀 방지, 위생).
/// - S-99: `common_blending.h` RGBToHSL — `#ifdef HDR color = saturate(color)`.
final class RenderColorFixRegressionTests: XCTestCase {

    // MARK: 헬퍼

    private func makeTexture(
        device: MTLDevice, width: Int, height: Int, bytes: [UInt8]? = nil
    ) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let t = try XCTUnwrap(device.makeTexture(descriptor: d))
        if let bytes {
            XCTAssertEqual(bytes.count, width * height * 4)
            bytes.withUnsafeBytes {
                t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                          withBytes: $0.baseAddress!, bytesPerRow: width * 4)
            }
        }
        return t
    }

    private func makeFloatTexture(
        device: MTLDevice, width: Int, height: Int, fill: Float, alpha: Float = 1
    ) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let t = try XCTUnwrap(device.makeTexture(descriptor: d))
        var half = [Float16](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: half.count, by: 4) {
            half[i] = Float16(fill); half[i + 1] = Float16(fill); half[i + 2] = Float16(fill)
            half[i + 3] = Float16(alpha)
        }
        half.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        return t
    }

    private func read(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }

    private func runLDRBloom(
        device: MTLDevice, width: Int, height: Int, pixels: [UInt8],
        parameters: LDRBloomParameters
    ) throws -> [UInt8] {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let pass = try XCTUnwrap(LDRBloomPass(device: device))
        let source = try makeTexture(device: device, width: width, height: height, bytes: pixels)
        let quarter = try makeTexture(device: device, width: max(1, width / 4), height: max(1, height / 4))
        let eighth = try makeTexture(device: device, width: max(1, width / 8), height: max(1, height / 8))
        let bloom = try makeTexture(device: device, width: max(1, width / 8), height: max(1, height / 8))
        let destination = try makeTexture(device: device, width: width, height: height)
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(pass.encode(commandBuffer: cb, source: source, quarter: quarter, eighth: eighth,
                                  bloom: bloom, destination: destination, parameters: parameters))
        cb.commit()
        cb.waitUntilCompleted()
        return read(destination)
    }

    // MARK: S-48 — LDR 추출 탭 ±1텍셀(WE downsample_quarter_bloom)

    /// 계약: 추출 4탭은 ±1텍셀 대각(bilinear 결합 시 4×4 박스 = 풋프린트 16텍셀 전량).
    /// 구 ±1.5 는 코너 4텍셀만 점샘플(4/16 서브샘플) — 내측 2×2 고휘도 피처 누락(에일리어싱).
    func testS48LDRExtractTapsAreWEQuarterBloomBox() {
        let src = LDRBloomPass.metalSource
        for tap in ["float2(-1.0, -1.0)", "float2( 1.0, -1.0)",
                    "float2(-1.0,  1.0)", "float2( 1.0,  1.0)"] {
            XCTAssertTrue(src.contains(tap), "WE ±1텍셀 탭 누락: \(tap)")
        }
        XCTAssertFalse(src.contains("1.5, -1.5"), "구 ±1.5 서브샘플 잔여")
    }

    /// 기능: quarter 풋프린트의 내측 2×2 밝기 블록이 블룸에 기여해야 한다.
    /// 구 ±1.5 탭은 (16,16)/(19,16)/(16,19)/(19,19) 코너만 샘플해 내측 (17..18)² 을 완전 누락
    /// → 블록 밖 글로우 0. WE(±1)는 bilinear 로 내측을 잡아 블록 밖 픽셀에 글로우 > 0.
    func testS48InnerBrightBlockContributesToBloom() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let width = 64, height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        for y in 17...18 {
            for x in 17...18 {
                let o = (y * width + x) * 4
                pixels[o] = 255; pixels[o + 1] = 255; pixels[o + 2] = 255
            }
        }
        let out = try runLDRBloom(
            device: device, width: width, height: height, pixels: pixels,
            parameters: .init(strength: 4, threshold: 0, tint: SIMD3(1, 1, 1)))
        var outsideGlow: UInt8 = 0
        for y in 0..<height {
            for x in 0..<width where !(17...18 ~= x && 17...18 ~= y) {
                let o = (y * width + x) * 4
                outsideGlow = max(outsideGlow, max(out[o], max(out[o + 1], out[o + 2])))
            }
        }
        XCTAssertGreaterThan(outsideGlow, 0,
                             "내측 2×2 고휘도 블록의 글로우가 추출에서 누락(±1.5 코너 서브샘플 결함)")
    }

    // MARK: S-49 — 첫 블러 스트라이드 2 quarter-texel(WE localTexel = g_TexelSize×8)

    /// 기능: 수평 글로우 스커트가 WE σ 까지 퍼져야 한다. 밝은 세로 바(x 60..<68)의 원거리/근거리
    /// 글로우 비로 판별 — 구 스트라이드(1 quarter-texel, σ≈9px)는 원거리가 급감하고,
    /// WE 스트라이드(2 quarter-texel, σ≈18px)는 원거리 잔량이 크다.
    func testS49FirstBlurStrideSpreadsGlowToWERadius() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let width = 128, height = 128
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        for y in 0..<height {
            for x in 60..<68 {
                let o = (y * width + x) * 4
                pixels[o] = 255; pixels[o + 1] = 255; pixels[o + 2] = 255
            }
        }
        let out = try runLDRBloom(
            device: device, width: width, height: height, pixels: pixels,
            parameters: .init(strength: 0.5, threshold: 0, tint: SIMD3(1, 1, 1)))
        func glow(_ x: Int) -> Int {
            let o = (64 * width + x) * 4
            return max(Int(out[o]), max(Int(out[o + 1]), Int(out[o + 2])))
        }
        let near = glow(72)   // 바 가장자리 +4px
        let far = glow(84)    // +16px
        XCTAssertGreaterThan(near, 0, "근거리 글로우 자체가 없으면 테스트 무효")
        XCTAssertGreaterThan(far * 2, near,
                             "원거리 글로우 급감(σ≈9px, 구 스트라이드 1) — WE(σ≈18px, 스트라이드 2)는 더 넓게 퍼짐. near=\(near) far=\(far)")
    }

    // MARK: S-50 — tint BLENDMODE 기본 30(WE [COMBO] default) + mode 0 알파 규칙

    /// WE tint.frag: `[COMBO]{"combo":"BLENDMODE","type":"imageblending","default":30}`.
    /// blendmode 키 부재(코퍼스 다수) 폴터 경로가 0(Normal = 단색 워시)으로 떨어지는 결함.
    /// 명시 콤보/구버전 constants 키는 그대로 우선.
    func testS50TintBlendModeDefaultsToWE30() {
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: [:])?.last, 30,
                       "WE tint [COMBO] 기본 30(Tint, 휘도보존 컬러라이즈)")
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: ["color": [0, 1, 0], "alpha": [0.5]]),
                       [0, 1, 0, 0.5, 30])
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: [:], combos: ["BLENDMODE": 2])?.last, 2)
        XCTAssertEqual(EffectShaders.params(for: "tint", constants: ["blendmode": [7]])?.last, 7)
    }

    /// WE tint.frag: `#if BLENDMODE == 0 → albedo.a = 1.0`(Normal 모드는 출력 불투명 강제).
    func testS50TintNormalModeForcesOpaqueAlpha() {
        let src = EffectShaders.source(for: "tint") ?? ""
        XCTAssertTrue(src.contains("c.a = 1.0"), "WE 의 BLENDMODE==0 알파 강제 규칙 미반영")
    }

    // MARK: S-95 — HDR 추출 탭도 ±1텍셀(4×4 풋프린트 커버)

    /// 계약: HDR 추출 4탭 ±1텍셀. WE HDR 다운샘플(hdr_downsample.frag)은 2× 단계 피라미드라
    /// ±0.5텍셀이 2×2 박스를 덮지만, Waple 의 quarter 단일 단계는 ±1텍셀(bilinear 4×4 박스)이
    /// 풋프린트 전량 커버 — 구 ±1.5 는 LDR 과 같은 4/16 서브샘플 결함.
    func testS95HDRExtractTapsCoverQuarterFootprint() {
        let src = HDRBloomPass.metalSource
        for tap in ["float2(-1.0, -1.0)", "float2( 1.0, -1.0)",
                    "float2(-1.0,  1.0)", "float2( 1.0,  1.0)"] {
            XCTAssertTrue(src.contains(tap), "HDR 추출 ±1텍셀 탭 누락: \(tap)")
        }
        XCTAssertFalse(src.contains("1.5, -1.5"), "HDR 구 ±1.5 서브샘플 잔여")
    }

    // MARK: S-97 — pulse phase 는 WE radian 직접(2π 스케일 아님)

    /// WE pulse.frag: `sin(g_Time * g_PulseSpeed + (g_PulsePhase - 1.57079632679))`,
    /// phase 범위 [0,6.282](radian). 구 (P[2]−0.25)×2π 는 phase=0 에서만 일치.
    func testS97PulsePhaseIsWERadians() {
        let src = EffectShaders.source(for: "pulse") ?? ""
        XCTAssertTrue(src.contains("(P[2] - 1.57079632679)"),
                      "WE pulse 위상 = phase − π/2 (radian 직접)")
        XCTAssertFalse(src.contains("(P[2] - 0.25)"), "구 2π 스케일 위상 잔여")
    }

    // MARK: S-98 — HDR 최종 알파 1.0 강제

    /// HDRBloomPass 합성 출력 알파는 1.0 — 소스 알파(0.25)를 통과시키면 캡처 PNG 가 투명 픽셀.
    func testS98HDRBloomCombineForcesOpaqueAlpha() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let pass = try XCTUnwrap(HDRBloomPass(device: device))
        let source = try makeFloatTexture(device: device, width: 32, height: 16, fill: 0.5, alpha: 0.25)
        let quarter = try makeFloatTexture(device: device, width: 8, height: 4, fill: 0)
        let eighth = try makeFloatTexture(device: device, width: 4, height: 2, fill: 0)
        let bloom = try makeFloatTexture(device: device, width: 4, height: 2, fill: 0)
        let destination = try makeTexture(device: device, width: 32, height: 16)
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        // 임계=1, 기입 0.5 → 블룸 0: 순수 합성(알파 경로)만 검증.
        XCTAssertTrue(pass.encode(
            commandBuffer: cb, source: source, quarter: quarter, eighth: eighth, bloom: bloom,
            destination: destination,
            parameters: HDRBloomParameters(strength: 1, threshold: 1, feather: 0, tint: SIMD3(1, 1, 1))))
        cb.commit()
        cb.waitUntilCompleted()
        let bytes = read(destination)
        for i in stride(from: 3, to: bytes.count, by: 4) {
            XCTAssertEqual(bytes[i], 255, "HDR 합성 출력 알파는 1.0 강제(소스 알파 통과 금지)")
        }
    }

    /// HDRPostPass(hdrPost 클램프)도 최종 알파 1.0 — 동일 위생 규칙.
    func testS98HDRPostForcesOpaqueAlpha() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let post = try XCTUnwrap(HDRPostPass(device: device, outputFormat: .bgra8Unorm))
        let sd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        sd.usage = [.renderTarget, .shaderRead]
        let src = try XCTUnwrap(device.makeTexture(descriptor: sd))
        let dst = try makeTexture(device: device, width: 1, height: 1)
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let clr = MTLRenderPassDescriptor()
        clr.colorAttachments[0].texture = src
        clr.colorAttachments[0].loadAction = .clear
        clr.colorAttachments[0].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.25)
        clr.colorAttachments[0].storeAction = .store
        try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: clr)).endEncoding()
        post.encode(cb: cb, src: src, dst: dst)
        cb.commit()
        cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: 4)
        dst.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(px[3], 255, "hdrPost 출력 알파는 1.0 강제")
    }

    // MARK: S-99 — rgb2hsl HDR 입력 saturate(common_blending.h `#ifdef HDR`)

    /// WE common_blending.h RGBToHSL 은 HDR 시 saturate 클램프. Waple 은 LDR/HDR 단일 소스라
    /// 무조건 saturate 가 양 경로 정합(LDR UNORM ≤1 에선 항등). HDR Hue/Saturation/Color/Luminosity
    /// (mode 26-29)의 >1 입력 HSL 왜곡 봉인(잠복).
    func testS99Rgb2HslClampsHDRInput() {
        // 위와 같은 구멍 — 주석 처리를 못 잡는다(돌연변이 M7, 2026-08-21). 줄 전문 일치.
        let hasSaturateLine = BlendMSL.source.split(whereSeparator: { $0.isNewline })
            .contains { $0.trimmingCharacters(in: .whitespaces) == "c = saturate(c);" }
        XCTAssertTrue(hasSaturateLine, "we_rgb2hsl 에 HDR saturate 클램프 누락(주석 처리 포함)")
    }
}
