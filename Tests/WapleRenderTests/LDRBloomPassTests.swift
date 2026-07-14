import XCTest
import Metal
@testable import WapleRender

final class LDRBloomPassTests: XCTestCase {
    private func makeTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        bytes: [UInt8]? = nil
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        if let bytes {
            XCTAssertEqual(bytes.count, width * height * 4)
            bytes.withUnsafeBytes {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: $0.baseAddress!,
                    bytesPerRow: width * 4)
            }
        }
        return texture
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

    private func execute(
        device: MTLDevice,
        width: Int,
        height: Int,
        pixels: [UInt8],
        parameters: LDRBloomParameters
    ) throws -> [UInt8] {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let pass = try XCTUnwrap(LDRBloomPass(device: device))
        let source = try makeTexture(device: device, width: width, height: height, bytes: pixels)
        let quarter = try makeTexture(
            device: device,
            width: max(1, width / 4),
            height: max(1, height / 4))
        let eighth = try makeTexture(
            device: device,
            width: max(1, width / 8),
            height: max(1, height / 8))
        let bloom = try makeTexture(
            device: device,
            width: max(1, width / 8),
            height: max(1, height / 8))
        let destination = try makeTexture(device: device, width: width, height: height)
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
        XCTAssertEqual(commandBuffer.status, .completed)
        return read(destination)
    }

    private func isolatedWhitePixel(width: Int = 64, height: Int = 64) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        let offset = (32 * width + 32) * 4
        pixels[offset + 0] = 255
        pixels[offset + 1] = 255
        pixels[offset + 2] = 255
        return pixels
    }

    func testShaderContractPinsExactPassMathAndWeights() {
        let source = LDRBloomPass.metalSource
        [
            "float2(-1.5, -1.5)",
            "float2( 1.5, -1.5)",
            "float2(-1.5,  1.5)",
            "float2( 1.5,  1.5)",
            "rgb *= saturate(scale - u.threshold)",
            "float gray = dot(float3(0.2989, 0.5870, 0.1140), rgb)",
            "rgb = 2.0 * rgb - gray",
            "max(float3(0.0), rgb * u.strength * u.tint.rgb)",
            "0.006299", "0.017298", "0.039533", "0.075189",
            "0.119007", "0.156756", "0.171834",
            "return float4(scene + glow, 1.0)"
        ].forEach { XCTAssertTrue(source.contains($0), "missing shader contract: \($0)") }
    }

    func testPipelineCompilesAndEncodesOddSubEightDimensions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let width = 7, height = 5
        let pixels = Array(
            repeating: [UInt8(24), UInt8(48), UInt8(72), UInt8(255)],
            count: width * height).flatMap { $0 }
        let output = try execute(
            device: device,
            width: width,
            height: height,
            pixels: pixels,
            parameters: .init(strength: 0, threshold: 0.65, tint: SIMD3(1, 1, 1)))
        XCTAssertEqual(output, pixels)
    }

    func testBelowThresholdAndZeroStrengthAreRawIdentity() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let width = 17, height = 9
        let below = Array(
            repeating: [UInt8(64), UInt8(80), UInt8(100), UInt8(255)],
            count: width * height).flatMap { $0 }
        XCTAssertEqual(
            try execute(
                device: device,
                width: width,
                height: height,
                pixels: below,
                parameters: .init(strength: 2, threshold: 0.65, tint: SIMD3(1, 1, 1))),
            below)

        var varied: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                varied.append(contentsOf: [
                    UInt8((x * 11 + y * 3) % 256),
                    UInt8((x * 5 + y * 17) % 256),
                    UInt8((x * 19 + y * 7) % 256),
                    255
                ])
            }
        }
        XCTAssertEqual(
            try execute(
                device: device,
                width: width,
                height: height,
                pixels: varied,
                parameters: .init(strength: 0, threshold: -1, tint: SIMD3(1, 1, 1))),
            varied)
    }

    func testIsolatedBrightPixelSpreadsToSurroundingPixelsAndForcesOpaqueAlpha() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let pixels = isolatedWhitePixel()
        let output = try execute(
            device: device,
            width: 64,
            height: 64,
            pixels: pixels,
            parameters: .init(strength: 8, threshold: 0, tint: SIMD3(1, 1, 1)))
        let brightOffset = (32 * 64 + 32) * 4
        var halo: UInt8 = 0
        for offset in stride(from: 0, to: output.count, by: 4) where offset != brightOffset {
            halo = max(
                halo,
                max(output[offset + 0], max(output[offset + 1], output[offset + 2])))
        }
        XCTAssertTrue(stride(from: 3, to: output.count, by: 4).allSatisfy { output[$0] == 255 })
        XCTAssertGreaterThan(halo, 0)
    }

    func testRedTintSuppressesGreenAndBlueBloom() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let output = try execute(
            device: device,
            width: 64,
            height: 64,
            pixels: isolatedWhitePixel(),
            parameters: .init(strength: 8, threshold: 0, tint: SIMD3(1, 0, 0)))
        let brightOffset = (32 * 64 + 32) * 4
        var red: UInt8 = 0, green: UInt8 = 0, blue: UInt8 = 0
        for offset in stride(from: 0, to: output.count, by: 4) where offset != brightOffset {
            blue = max(blue, output[offset + 0])
            green = max(green, output[offset + 1])
            red = max(red, output[offset + 2])
        }
        XCTAssertGreaterThan(red, 0)
        XCTAssertEqual(green, 0)
        XCTAssertEqual(blue, 0)
    }
}
