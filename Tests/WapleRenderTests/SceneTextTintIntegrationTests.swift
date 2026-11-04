import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

final class SceneTextTintIntegrationTests: XCTestCase {
    func testRealTextBuildAndEncodeKeepHDRGlyphAndUntintedEmojiTogether() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":512,"height":256}},
         "objects":[{"id":1,"text":"M😀","font":"systemfont_arial","pointsize":12,
                     "origin":"256 128 0","color":"3 0 0","padding":0,
                     "horizontalalign":"center","verticalalign":"center"}]}
        """
        let package = ScenePackage.assemble([(name: "scene.json", data: Data(scene.utf8))])
        let document = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        renderer.projW = 512; renderer.projH = 256
        renderer.textShaderPipelines = try TextShaderPipelines(device: device, pixelFormat: .rgba16Float)
        let text = try XCTUnwrap(renderer.buildTexts(doc: document, package: package, device: device).first)
        XCTAssertEqual(text.tint.x, 3)
        XCTAssertNotNil(text.rasterBlackTexture)
        XCTAssertFalse(text.rasterTiles.isEmpty)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                  width: 512, height: 256, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        var aspect = SIMD2<Float>(repeating: 1)
        renderer.encodeText(text, into: encoder, aspectScale: &aspect, device: device)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        var pixels = [Float16](repeating: 0, count: 512 * 256 * 4)
        pixels.withUnsafeMutableBytes { bytes in
            output.getBytes(bytes.baseAddress!, bytesPerRow: 512 * 8,
                            from: MTLRegionMake2D(0, 0, 512, 256), mipmapLevel: 0)
        }
        var red: Float = 0, green: Float = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            red = max(red, Float(pixels[index]))
            green = max(green, Float(pixels[index + 1]))
        }
        XCTAssertGreaterThan(red, 2.8, "the actual scene caller must retain float HDR tint")
        XCTAssertGreaterThan(green, 0.5, "emoji RGB must survive the scene's red-only tint")
    }
}
