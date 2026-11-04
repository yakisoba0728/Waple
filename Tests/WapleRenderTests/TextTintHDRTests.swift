import XCTest
import Metal
@testable import WapleRender

final class TextTintHDRTests: XCTestCase {
    private func renderPair(_ pair: TextRasterizer.TintRaster, tint: SIMD4<Float>, blendMode: Int? = nil) throws -> [Float16] {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let pipeline = try TextShaderPipelines(device: device, pixelFormat: .rgba16Float)
        func texture(_ raster: TextRasterizer.Raster) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                      width: raster.width, height: raster.height, mipmapped: false)
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            raster.rgba.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(0, 0, raster.width, raster.height), mipmapLevel: 0,
                                withBytes: bytes.baseAddress!, bytesPerRow: raster.width * 4)
            }
            return texture
        }
        let white = try texture(pair.white), black = try texture(pair.black)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                  width: white.width, height: white.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let destination = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var destinationPixels = [Float16](repeating: 0.25, count: white.width * white.height * 4)
        for index in stride(from: 3, to: destinationPixels.count, by: 4) { destinationPixels[index] = 1 }
        destinationPixels.withUnsafeBytes { bytes in
            destination.replace(region: MTLRegionMake2D(0, 0, white.width, white.height), mipmapLevel: 0,
                                withBytes: bytes.baseAddress!, bytesPerRow: white.width * 8)
        }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        let vertices: [SIMD4<Float>] = [SIMD4(-1, 1, 0, 0), SIMD4(1, 1, 1, 0), SIMD4(-1, -1, 0, 1),
                                        SIMD4(1, 1, 1, 0), SIMD4(1, -1, 1, 1), SIMD4(-1, -1, 0, 1)]
        vertices.withUnsafeBufferPointer { pointer in
            encoder.setVertexBytes(pointer.baseAddress!, length: pointer.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
        }
        var zero = SIMD2<Float>.zero, one = SIMD2<Float>(repeating: 1)
        var depth = SIMD4<Float>(0, 0, 1, 0), tint = tint
        encoder.setVertexBytes(&zero, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        encoder.setVertexBytes(&one, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        encoder.setVertexBytes(&one, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
        encoder.setVertexBytes(&zero, length: MemoryLayout<SIMD2<Float>>.stride, index: 4)
        encoder.setVertexBytes(&depth, length: MemoryLayout<SIMD4<Float>>.stride, index: 5)
        encoder.setRenderPipelineState(blendMode == nil ? pipeline.normal : pipeline.blend)
        if let blendMode {
            var mode = Int32(blendMode)
            encoder.setFragmentTexture(destination, index: 1)
            encoder.setFragmentBytes(&mode, length: MemoryLayout<Int32>.stride, index: 1)
        }
        encoder.setFragmentTexture(white, index: 0)
        encoder.setFragmentTexture(black, index: 2)
        encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        var pixels = [Float16](repeating: 0, count: white.width * white.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            output.getBytes(bytes.baseAddress!, bytesPerRow: white.width * 8,
                            from: MTLRegionMake2D(0, 0, white.width, white.height), mipmapLevel: 0)
        }
        return pixels
    }

    func testActualTextShaderPreservesHDRMonochromeAndOriginalEmojiRGBTogether() throws {
        let pair = try XCTUnwrap(TextRasterizer.renderTintLayers(text: "M😀", fontData: nil,
                                                                systemFontName: "systemfont_arial", pointSize: 12))
        let output = try renderPair(pair, tint: SIMD4(3, 0.25, 0.5, 1))
        let white = [UInt8](pair.white.rgba), black = [UInt8](pair.black.rgba)
        var mono = 0, color = 0
        for i in stride(from: 0, to: white.count, by: 4) where white[i + 3] == 255 {
            if white[i] == 255 && white[i + 1] == 255 && black[i] == 0 && black[i + 1] == 0 {
                XCTAssertEqual(Float(output[i]), 3, accuracy: 0.02)
                XCTAssertEqual(Float(output[i + 1]), 0.25, accuracy: 0.02)
                mono += 1
            }
            if white[i] == black[i], white[i + 1] == black[i + 1], white[i + 2] == black[i + 2],
               white[i + 1] > 80, Int(white[i]) > Int(white[i + 2]) + 20 {
                XCTAssertEqual(Float(output[i]), Float(white[i]) / 255, accuracy: 0.02)
                XCTAssertEqual(Float(output[i + 1]), Float(white[i + 1]) / 255, accuracy: 0.02)
                color += 1
            }
        }
        XCTAssertGreaterThan(mono, 0)
        XCTAssertGreaterThan(color, 0)
    }

    func testActualTextShaderKeepsFixedBackgroundIndependentOfHDRGlyphTint() throws {
        var style = TextRasterizer.Style()
        style.opaqueBackground = true
        style.padding = SIMD2(8, 8)
        style.backgroundColor = SIMD3(0, 0.5, 0)
        let pair = try XCTUnwrap(TextRasterizer.renderTintLayers(text: "M", fontData: nil, systemFontName: nil,
                                                                pointSize: 12, style: style))
        let output = try renderPair(pair, tint: SIMD4(3, 0, 0, 1))
        XCTAssertEqual(Float(output[0]), 0, accuracy: 0.01)
        XCTAssertEqual(Float(output[1]), 0.5, accuracy: 0.01)
        XCTAssertEqual(Float(output[3]), 1, accuracy: 0.01)
    }
    func testActualTextBlendShaderPreservesHDRAdditiveContribution() throws {
        let pair = try XCTUnwrap(TextRasterizer.renderTintLayers(text: "M", fontData: nil,
                                                                systemFontName: "systemfont_arial", pointSize: 12))
        let output = try renderPair(pair, tint: SIMD4(3, 0.25, 0.5, 1), blendMode: 31)
        let white = [UInt8](pair.white.rgba), black = [UInt8](pair.black.rgba)
        let pixel = try XCTUnwrap(stride(from: 0, to: white.count, by: 4).first {
            white[$0 + 3] == 255 && white[$0] == 255 && black[$0] == 0
        })
        XCTAssertEqual(Float(output[pixel]), 3.25, accuracy: 0.02)
        XCTAssertEqual(Float(output[pixel + 1]), 0.5, accuracy: 0.02)
        XCTAssertEqual(Float(output[pixel + 3]), 1, accuracy: 0.02)
    }

}
