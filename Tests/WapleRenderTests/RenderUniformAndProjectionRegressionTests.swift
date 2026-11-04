import XCTest
import Metal
import AppKit
import simd
@testable import WapleCore
@testable import WapleRender

final class RenderUniformAndProjectionRegressionTests: XCTestCase {
    func testRendererPacksMatricesArraysAndFollowingParametersAtDeclaredOffsets() throws {
        let translated = try XCTUnwrap(GLSLTranslator.translate(vertex: """
        attribute vec3 a_Position;
        void main() { gl_Position = vec4(a_Position, 1.0); }
        """, fragment: """
        uniform mat3 g_Basis; // {"material":"basis"}
        uniform float g_Weights[3]; // {"material":"weights"}
        uniform vec4 g_Tint; // {"material":"tint"}
        void main() { gl_FragColor = g_Tint * g_Weights[2] + vec4(g_Basis[1], 0.0); }
        """, combos: [:]))
        let renderer = SceneRenderer()
        let values: [String: [Float]] = ["basis": Array(1...9).map(Float.init), "weights": [0.1, 0.2, 0.3], "tint": [1, 2, 3, 4]]
        var packed = renderer.packedMaterial(translated.materialParams) { values[$0.sceneKey] ?? $0.defaultValue }
        let basis = try XCTUnwrap(translated.materialParams.first { $0.sceneKey == "basis" })
        let weights = try XCTUnwrap(translated.materialParams.first { $0.sceneKey == "weights" })
        let tint = try XCTUnwrap(translated.materialParams.first { $0.sceneKey == "tint" })
        XCTAssertEqual(renderer.logicalUniform(packed, parameter: basis), values["basis"])
        XCTAssertEqual(renderer.logicalUniform(packed, parameter: weights), values["weights"])
        XCTAssertEqual(renderer.logicalUniform(packed, parameter: tint), values["tint"])
        renderer.replaceUniform(&packed, parameter: weights, values: [0.75])
        XCTAssertEqual(renderer.logicalUniform(packed, parameter: weights), [0.75, 0.2, 0.3])
        XCTAssertEqual(renderer.logicalUniform(packed, parameter: tint), [1, 2, 3, 4])
    }

    func testEngineUTenthTextureMetadataDoesNotOverlapTintTargetOrParallax() {
        let renderer = SceneRenderer()
        renderer.parallaxPosition = SIMD2(0.25, 0.75)
        let dimensions = (0..<10).map { SIMD4<Float>(Float($0 + 1), 2, 3, 4) }
        let uniform = renderer.engineUniform(time: 5, texRes: dimensions,
            texWrap: Array(repeating: 1, count: 10), texFilter: Array(repeating: 1, count: 10),
            layerTint: SIMD4(7, 8, 9, 1), targetRes: SIMD4(64, 32, 64, 32))
        XCTAssertEqual(uniform.count, 100)
        XCTAssertEqual(uniform[60], 10)
        XCTAssertEqual(uniform[73], 1)
        XCTAssertEqual(uniform[85], 1)
        XCTAssertEqual(Array(uniform[88..<92]), [7, 8, 9, 1])
        XCTAssertEqual(Array(uniform[92..<96]), [64, 32, 64, 32])
        XCTAssertEqual(Array(uniform[96..<98]), [0.25, 0.75])
    }

    func testAutomaticProjectionConsumesDrawableAndExplicitProjectionRemainsAuthored() throws {
        func document(_ projection: String) throws -> SceneDocument {
            try SceneDocument.parse(package: ScenePackage.parse(encodePkg([("scene.json", Data("{\"general\":{\"orthogonalprojection\":\(projection)},\"objects\":[]}".utf8))])))
        }
        let automatic = try document(#"{"auto":true}"#)
        XCTAssertTrue(automatic.orthoAuto)
        XCTAssertEqual(SceneRenderer.projectionSize(document: automatic, drawable: CGSize(width: 800, height: 600)), SIMD2(800, 600))
        let authored = try document(#"{"width":1920,"height":1080}"#)
        XCTAssertEqual(SceneRenderer.projectionSize(document: authored, drawable: CGSize(width: 800, height: 600)), SIMD2(1920, 1080))
    }

    @MainActor func testCurrentFrameCaptureReadsActualMetalTextureAndDiscardsRemountedCompletion() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let renderer = SceneRenderer()
        renderer.device = device
        renderer.queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let bytes: [UInt8] = [30, 60, 90, 255]
        bytes.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 4) }
        renderer.lastPresentedTexture = texture
        let captured = expectation(description: "actual Metal image copied")
        var image: NSImage?
        let clock = renderer.startTime
        renderer.captureCurrentImage { image = $0; captured.fulfill() }
        wait(for: [captured], timeout: 3)
        let bitmap = try XCTUnwrap(image?.representations.compactMap { $0 as? NSBitmapImageRep }.first)
        // Inspect copied BGRA→RGBA channel values, without applying the display's ICC transform.
        var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
        pixel.withUnsafeMutableBufferPointer { bitmap.getPixel($0.baseAddress!, atX: 0, y: 0) }
        XCTAssertEqual(Double(pixel[0]) / 255, 90.0 / 255, accuracy: 0.01)
        XCTAssertEqual(Double(pixel[2]) / 255, 30.0 / 255, accuracy: 0.01)
        XCTAssertEqual(renderer.startTime, clock)
        let stale = expectation(description: "old mount image dropped")
        renderer.captureCurrentImage { result in XCTAssertNil(result); stale.fulfill() }
        renderer.teardown()
        wait(for: [stale], timeout: 3)
    }

    func testSpriteRefreshDelayUsesBoundaryRateCapAndRejectsInvalidClock() {
        XCTAssertEqual(SceneRenderer.initialSpriteRefreshDelay(now: 1.05, frameTime: 0.1), 0.05, accuracy: 1e-8)
        XCTAssertEqual(SceneRenderer.initialSpriteRefreshDelay(now: 1.05, frameTime: 0.1, rate: 2), 0, accuracy: 1e-8)
        XCTAssertEqual(SceneRenderer.initialSpriteRefreshDelay(now: 0.1, frameTime: 1), 0.25)
        XCTAssertEqual(SceneRenderer.initialSpriteRefreshDelay(now: .nan, frameTime: 1), 0)
        XCTAssertEqual(SceneRenderer.initialSpriteRefreshDelay(now: 1, frameTime: 0), 0)
    }
}
