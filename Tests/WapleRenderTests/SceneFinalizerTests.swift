import XCTest
import Metal
@testable import WapleRender

final class SceneFinalizerTests: XCTestCase {
    private final class FailingBloomEncoder: LDRBloomEncoding {
        func encode(
            commandBuffer: MTLCommandBuffer,
            source: MTLTexture,
            quarter: MTLTexture,
            eighth: MTLTexture,
            bloom: MTLTexture,
            destination: MTLTexture,
            parameters: LDRBloomParameters
        ) -> Bool {
            false
        }
    }

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

    private func opaquePattern(width: Int, height: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                bytes.append(contentsOf: [
                    UInt8((x * 13 + y) % 256),
                    UInt8((x + y * 17) % 256),
                    UInt8((x * 7 + y * 5) % 256),
                    255
                ])
            }
        }
        return bytes
    }

    private func assertRawFallback(
        device: MTLDevice,
        bloomPass: LDRBloomEncoding?,
        allocator: ((Int, Int) -> MTLTexture?)? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let width = 17, height = 9
        let expected = opaquePattern(width: width, height: height)
        let source = try makeTexture(
            device: device,
            width: width,
            height: height,
            bytes: expected)
        let destination = try makeTexture(device: device, width: width, height: height)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let renderer = SceneRenderer()
        renderer.sceneWantsLDRBloom = true
        renderer.ldrBloomParameters = .init(
            strength: 8,
            threshold: 0,
            tint: SIMD3(1, 1, 1))
        renderer.ldrBloomPass = bloomPass

        XCTAssertTrue(
            renderer.finalizeScene(
                source: source,
                destination: destination,
                commandBuffer: commandBuffer,
                device: device,
                allocateBloomTexture: allocator),
            file: file,
            line: line)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(read(destination), expected, file: file, line: line)
    }

    func testPipelineResourceAndEncoderFailuresRawFallbackByteEquivalent() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        try assertRawFallback(device: device, bloomPass: nil)
        try assertRawFallback(
            device: device,
            bloomPass: try XCTUnwrap(LDRBloomPass(device: device)),
            allocator: { _, _ in nil })
        try assertRawFallback(device: device, bloomPass: FailingBloomEncoder())
    }

    func testFinalizerRequestsExactOddSizedBGRAIntermediatesBeforeEncoding() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let width = 17, height = 9
        let sourceBytes = opaquePattern(width: width, height: height)
        let source = try makeTexture(
            device: device,
            width: width,
            height: height,
            bytes: sourceBytes)
        let destination = try makeTexture(device: device, width: width, height: height)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let renderer = SceneRenderer()
        renderer.sceneWantsLDRBloom = true
        renderer.ldrBloomParameters = .init(
            strength: 0,
            threshold: 0.65,
            tint: SIMD3(1, 1, 1))
        renderer.ldrBloomPass = try XCTUnwrap(LDRBloomPass(device: device))
        var requests: [(width: Int, height: Int, format: MTLPixelFormat)] = []

        XCTAssertTrue(renderer.finalizeScene(
            source: source,
            destination: destination,
            commandBuffer: commandBuffer,
            device: device,
            allocateBloomTexture: { [self] width, height in
                let texture = try? makeTexture(device: device, width: width, height: height)
                if let texture {
                    requests.append((width, height, texture.pixelFormat))
                }
                return texture
            }))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        XCTAssertEqual(requests.map { $0.width }, [4, 2, 2])
        XCTAssertEqual(requests.map { $0.height }, [2, 1, 1])
        XCTAssertTrue(requests.allSatisfy { $0.format == .bgra8Unorm })
        XCTAssertEqual(read(destination), sourceBytes)
    }
}
