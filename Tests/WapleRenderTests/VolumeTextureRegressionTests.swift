import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

final class VolumeTextureRegressionTests: XCTestCase {
    private func volumeData(encodedHeight: Int = 4) -> Data {
        var pixels: [UInt8] = []
        for z in 0..<2 { for y in 0..<2 { for x in 0..<2 {
            pixels += [UInt8(x * 255), UInt8(y * 255), UInt8(z * 255), 255]
        } } }
        let png = OffscreenCapture.png(rgba: Array(pixels.prefix(2 * encodedHeight * 4)),
                                       width: 2, height: encodedHeight)!
        var data = Data("TEXV0005\0TEXI0001\0".utf8)
        for value in [0, 0x40, 2, 2, 4, 2, 2, 0] { data.append(i32(value)) }
        data.append(Data("TEXB0003\0".utf8))
        for value in [1, 13, 1, 2, 2, 2, 0, png.count, png.count] { data.append(i32(value)) }
        data.append(png)
        return data
    }

    func testVolumeParserAndDecoderPreserveVerticalSliceOrder() throws {
        let data = volumeData()
        let parsed = try XCTUnwrap(TexImage.parse(data))
        XCTAssertEqual(parsed.depth, 2)
        let volume = try XCTUnwrap(TexDecoder.volumeRGBA(from: parsed, data: data))
        XCTAssertEqual(volume.width, 2); XCTAssertEqual(volume.height, 2); XCTAssertEqual(volume.depth, 2)
        let pixels = [UInt8](volume.pixels)
        XCTAssertEqual(Array(pixels[0..<4]), [0, 0, 0, 255])
        XCTAssertEqual(Array(pixels[16..<20]), [0, 0, 255, 255])
        let malformed = volumeData(encodedHeight: 2)
        XCTAssertNil(TexDecoder.volumeRGBA(from: try XCTUnwrap(TexImage.parse(malformed)), data: malformed))
    }

    func testVolumeUploadsAs3DAndGPUReadsEverySlice() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let data = volumeData()
        let tex = try XCTUnwrap(TexImage.parse(data))
        let renderer = SceneRenderer()
        let uploaded = try XCTUnwrap(renderer.makeImageTexture(tex: tex, data: data, device: device))
        XCTAssertEqual(uploaded.texture.textureType, .type3D)
        XCTAssertEqual(uploaded.texture.depth, 2)
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void readVolume(texture3d<float, access::read> input [[texture(0)]],
            device float4* output [[buffer(0)]], uint index [[thread_position_in_grid]]) {
            output[index] = input.read(uint3(index % 2, (index / 2) % 2, index / 4));
        }
        """, options: nil)
        let pipeline = try device.makeComputePipelineState(function: try XCTUnwrap(library.makeFunction(name: "readVolume")))
        let result = try XCTUnwrap(device.makeBuffer(length: 8 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(uploaded.texture, index: 0)
        encoder.setBuffer(result, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 8, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        let values = result.contents().bindMemory(to: SIMD4<Float>.self, capacity: 8)
        for index in 0..<8 {
            XCTAssertEqual(values[index], SIMD4(Float(index % 2), Float((index / 2) % 2), Float(index / 4), 1))
        }
    }
}
