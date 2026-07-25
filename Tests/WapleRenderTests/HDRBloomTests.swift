import XCTest
import Metal
@testable import WapleRender

/// #22 HDR bloom(hdr && bloom) — 추출(PS 29931 soft-knee)→blur13→합성(saturate(base+bloom) =
/// PS 29925 의 화면 순효과). 부정 컨트롤: hdrPost(클램프) 단독 조기 return 은 글로우가 0 —
/// 라우팅 테스트가 그 결함을 red 로 재현.
final class HDRBloomTests: XCTestCase {
    private final class FailingHDRBloomEncoder: HDRBloomEncoding {
        func encode(
            commandBuffer: MTLCommandBuffer,
            source: MTLTexture,
            quarter: MTLTexture,
            eighth: MTLTexture,
            bloom: MTLTexture,
            destination: MTLTexture,
            parameters: HDRBloomParameters
        ) -> Bool {
            false
        }
    }

    private func makeFloatTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        fill: Float = 0,
        spot: (x: Range<Int>, y: Range<Int>, value: Float)? = nil
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var half = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var v = fill
                if let spot, spot.x.contains(x), spot.y.contains(y) { v = spot.value }
                let i = (y * width + x) * 4
                half[i] = Float16(v); half[i + 1] = Float16(v); half[i + 2] = Float16(v)
                half[i + 3] = 1
            }
        }
        half.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: $0.baseAddress!,
                bytesPerRow: width * 8)
        }
        return texture
    }

    private func makeBGRATexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func read(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!,
                bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0)
        }
        return bytes
    }

    private func encodePass(
        device: MTLDevice,
        source: MTLTexture,
        destination: MTLTexture,
        parameters: HDRBloomParameters
    ) throws {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let pass = try XCTUnwrap(HDRBloomPass(device: device))
        let quarter = try makeFloatTexture(
            device: device,
            width: max(1, source.width / 4),
            height: max(1, source.height / 4))
        let eighth = try makeFloatTexture(
            device: device,
            width: max(1, source.width / 8),
            height: max(1, source.height / 8))
        let bloom = try makeFloatTexture(
            device: device,
            width: max(1, source.width / 8),
            height: max(1, source.height / 8))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(pass.encode(
            commandBuffer: commandBuffer,
            source: source,
            quarter: quarter,
            eighth: eighth,
            bloom: bloom,
            destination: destination,
            parameters: parameters))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// 합성 = WE 순효과 saturate(base+bloom) + knee=0(feather=0) 가드: 임계 미달 균일 0.5 입력은
    /// 블룸 0, 미드톤 무변환(0.5 → 128). PS 29925 의 EOTF_sRGB 디코드는 WE sRGB-뷰 스왑체인의
    /// 하드웨어 재인코드와 상쇄되는 쌍 — 비-sRGB(bgra8) 타깃에 디코드만 이식하면 이중 감마
    /// (실측: p50 0.047 vs 골든 0.18, 클램프 역산 ≈0.20 — HDRBloomPass 합성 셰이더 주석 참조).
    func testCombineKeepsMidtonesAndZeroKneeIsSafe() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let width = 32, height = 16
        let source = try makeFloatTexture(device: device, width: width, height: height, fill: 0.5)
        let destination = try makeBGRATexture(device: device, width: width, height: height)
        try encodePass(
            device: device,
            source: source,
            destination: destination,
            parameters: HDRBloomParameters(strength: 1, threshold: 1, feather: 0, tint: SIMD3(1, 1, 1)))
        let bytes = read(destination)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 {
                XCTAssertEqual(Float(bytes[i + channel]), 0.5 * 255, accuracy: 2,
                               "pixel \(i / 4) channel \(channel)")
            }
            XCTAssertEqual(bytes[i + 3], 255)
        }
    }

    /// 임계 초과 스팟은 주변으로 글로우가 번지고(soft-knee 추출→blur13), 스팟 자신은 saturate 로 순백.
    func testBrightSpotBloomsBeyondItsFootprint() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let width = 64, height = 32
        let source = try makeFloatTexture(
            device: device,
            width: width,
            height: height,
            spot: (x: 28..<36, y: 12..<20, value: 8))
        let destination = try makeBGRATexture(device: device, width: width, height: height)
        try encodePass(
            device: device,
            source: source,
            destination: destination,
            parameters: HDRBloomParameters(strength: 1, threshold: 1, feather: 1, tint: SIMD3(1, 1, 1)))
        let bytes = read(destination)
        func maxRGB(_ x: Int, _ y: Int) -> UInt8 {
            let i = (y * width + x) * 4
            return max(bytes[i], max(bytes[i + 1], bytes[i + 2]))
        }
        XCTAssertEqual(maxRGB(32, 16), 255)              // 스팟: EOTF(>1) → saturate
        XCTAssertGreaterThan(maxRGB(16, 16), 0)          // 스팟 밖 16px: 글로우 도달
        XCTAssertGreaterThan(maxRGB(32, 4), 0)           // 세로 방향도 번짐(2-pass 분리형)
    }

    /// 격리 가드: LDR(bgra8) 소스 유입은 인코드 전 거부 — 호출부 hdrPost(클램프) 폴백 안전.
    func testRejectsNonFloatSource() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let pass = try XCTUnwrap(HDRBloomPass(device: device))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let bgra = try makeBGRATexture(device: device, width: 32, height: 16)
        let quarter = try makeFloatTexture(device: device, width: 8, height: 4)
        let eighth = try makeFloatTexture(device: device, width: 4, height: 2)
        let bloom = try makeFloatTexture(device: device, width: 4, height: 2)
        let destination = try makeBGRATexture(device: device, width: 32, height: 16)
        XCTAssertFalse(pass.encode(
            commandBuffer: commandBuffer,
            source: bgra,
            quarter: quarter,
            eighth: eighth,
            bloom: bloom,
            destination: destination,
            parameters: .defaults))
        commandBuffer.commit()
    }

    // MARK: finalizeScene 라우팅

    private func finalize(
        device: MTLDevice,
        configure: (SceneRenderer) -> Void,
        sourceSpot value: Float = 8
    ) throws -> [UInt8] {
        let width = 64, height = 32
        let source = try makeFloatTexture(
            device: device,
            width: width,
            height: height,
            spot: (x: 28..<36, y: 12..<20, value: value))
        let destination = try makeBGRATexture(device: device, width: width, height: height)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let renderer = SceneRenderer()
        renderer.sceneIsHDR = true
        renderer.hdrPost = HDRPostPass(device: device, outputFormat: .bgra8Unorm)
        configure(renderer)
        XCTAssertTrue(renderer.finalizeScene(
            source: source,
            destination: destination,
            commandBuffer: commandBuffer,
            device: device))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return read(destination)
    }

    /// ★부정 컨트롤(보고된 결함 재현): hdr&&bloom 씬이 hdrPost 조기 return 에 삼켜지면
    /// 스팟 밖 전 픽셀이 0(saturate(0)=0) — HDR bloom 라우팅이 있어야 글로우 > 0.
    func testFinalizeRoutesHDRBloomAndSpreadsGlow() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let bytes = try finalize(device: device, configure: { renderer in
            renderer.sceneWantsHDRBloom = true
            renderer.hdrBloomPass = HDRBloomPass(device: device)
            renderer.hdrBloomParameters = HDRBloomParameters(
                strength: 1, threshold: 1, feather: 1, tint: SIMD3(1, 1, 1))
        })
        // 스팟(28..36, 12..20) 밖 픽셀들의 RGB 합 — hdrPost 단독(클램프) 경로면 정확히 0.
        var outsideSum = 0
        for y in 0..<32 {
            for x in 0..<64 where !(28..<36 ~= x && 12..<20 ~= y) {
                let i = (y * 64 + x) * 4
                outsideSum += Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])
            }
        }
        XCTAssertGreaterThan(outsideSum, 0, "hdr&&bloom 씬에 글로우가 전혀 없음(=hdrPost 조기 return)")
    }

    /// hdr && !bloom 무회귀: HDR bloom 미요청이면 hdrPost(클램프) 출력과 바이트 동일.
    func testFinalizeWithoutBloomRequestKeepsHDRPostByteIdentical() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let expected = try hdrPostReference(device: device)
        let bytes = try finalize(device: device, configure: { _ in })
        XCTAssertEqual(bytes, expected)
    }

    /// 패스 생성 실패/인코드 실패 시 hdrPost(클램프) 폴백(무크래시·바이트 동일).
    func testFinalizeFallsBackToHDRPostWhenBloomUnavailableOrFailing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let expected = try hdrPostReference(device: device)
        let missing = try finalize(device: device, configure: { renderer in
            renderer.sceneWantsHDRBloom = true
            renderer.hdrBloomPass = nil
        })
        XCTAssertEqual(missing, expected)
        let failing = try finalize(device: device, configure: { renderer in
            renderer.sceneWantsHDRBloom = true
            renderer.hdrBloomPass = FailingHDRBloomEncoder()
        })
        XCTAssertEqual(failing, expected)
    }

    private func hdrPostReference(device: MTLDevice) throws -> [UInt8] {
        let width = 64, height = 32
        let source = try makeFloatTexture(
            device: device,
            width: width,
            height: height,
            spot: (x: 28..<36, y: 12..<20, value: 8))
        let destination = try makeBGRATexture(device: device, width: width, height: height)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let post = try XCTUnwrap(HDRPostPass(device: device, outputFormat: .bgra8Unorm))
        post.encode(cb: commandBuffer, src: source, dst: destination)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return read(destination)
    }

    /// H6: 3-레벨 피라미드가 단일 레벨보다 넓은 글로우를 생성.
    func testPyramidWiderGlowThanSingleLevel() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let width = 64, height = 32
        let source = try makeFloatTexture(
            device: device, width: width, height: height,
            spot: (x: 28..<36, y: 12..<20, value: 8))
        let destination = try makeBGRATexture(device: device, width: width, height: height)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let pass = try XCTUnwrap(HDRBloomPyramidPass(device: device))
        let quarter = try makeFloatTexture(device: device, width: max(1, width / 4), height: max(1, height / 4))
        let eighth = try makeFloatTexture(device: device, width: max(1, width / 8), height: max(1, height / 8))
        let sixteenth = try makeFloatTexture(device: device, width: max(1, width / 16), height: max(1, height / 16))
        let bloom = try makeFloatTexture(device: device, width: max(1, width / 8), height: max(1, height / 8))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(pass.encode(
            commandBuffer: commandBuffer,
            source: source,
            quarter: quarter,
            eighth: eighth,
            sixteenth: sixteenth,
            bloom: bloom,
            destination: destination,
            parameters: HDRBloomPyramidParameters(
                strength: 2, threshold: 1, feather: 0.1, tint: SIMD3(1, 1, 1), scatter: 1.619)))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let px = read(destination)
        // 중심 스팟 주변에 0이 아닌 픽셀이 존재(글로우 확산).
        var nonZero = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            if px[i] > 0 || px[i + 1] > 0 || px[i + 2] > 0 { nonZero += 1 }
        }
        XCTAssertGreaterThan(nonZero, 64, "3-레벨 피라미드 글로우가 너무 좁음")
    }
}
