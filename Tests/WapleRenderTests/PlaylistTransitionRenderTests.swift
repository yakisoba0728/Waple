import XCTest
import AppKit
import Metal
import simd
import WapleCore
@testable import WapleRender

final class PlaylistTransitionRenderTests: XCTestCase {
    @MainActor private func fixture() throws -> (MTLDevice, NSImage) {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let w = 96, h = 64
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let i = (y * w + x) * 4
            rgba[i] = UInt8(30 + x * 2)
            rgba[i + 1] = UInt8(20 + y * 3)
            rgba[i + 2] = ((x / 8 + y / 8) % 2 == 0) ? 240 : 40
        } }
        let data = try XCTUnwrap(OffscreenCapture.png(rgba: rgba, width: w, height: h))
        return (device, try XCTUnwrap(NSImage(data: data)))
    }

    @MainActor private func renderer(_ kind: PlaylistTransitionKind, device: MTLDevice, image: NSImage) throws -> PlaylistTransitionRenderer {
        try PlaylistTransitionRenderer(device: device, oldImage: image, kind: kind, hash: 0.31, hash2: 0.73, meshSeed: 42)
    }

    @MainActor private func frame(_ renderer: PlaylistTransitionRenderer, progress: Float) throws -> [UInt8] {
        let device = renderer.device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 96, height: 64, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        try renderer.encode(to: texture, progress: progress, commandBuffer: buffer)
        buffer.commit(); buffer.waitUntilCompleted()
        XCTAssertEqual(buffer.status, .completed, String(describing: buffer.error))
        var bytes = [UInt8](repeating: 0, count: 96 * 64 * 4)
        bytes.withUnsafeMutableBytes { pointer in
            texture.getBytes(pointer.baseAddress!, bytesPerRow: 96 * 4,
                from: MTLRegionMake2D(0, 0, 96, 64), mipmapLevel: 0)
        }
        return bytes
    }

    @MainActor func testAll27ShippedVariantsRenderOutgoingStartAndTransparentEnd() throws {
        let (device, image) = try fixture()
        for kind in PlaylistTransitionKind.allEffects {
            let renderer = try renderer(kind, device: device, image: image)
            let start = try frame(renderer, progress: 0)
            let end = try frame(renderer, progress: 1)
            let opaque = stride(from: 3, to: start.count, by: 4).filter { start[$0] == 255 }.count
            XCTAssertGreaterThan(Double(opaque) / (96 * 64), 0.99, "\(kind): start must cover the outgoing frame")
            XCTAssertTrue(stride(from: 3, to: end.count, by: 4).allSatisfy { end[$0] == 0 }, "\(kind): finish must reveal incoming renderer")
        }
    }

    @MainActor func testIntermediateEffectsAreNotFadeAliases() throws {
        let (device, image) = try fixture()
        let kinds: [PlaylistTransitionKind] = [.fade, .mosaic, .horizontalSlide, .clouds, .bricks, .fadeToBlack, .glassShatter, .boilover]
        var frames = Set<Data>()
        for kind in kinds {
            frames.insert(Data(try frame(renderer(kind, device: device, image: image), progress: 0.55)))
        }
        XCTAssertEqual(frames.count, kinds.count, "all sampled effects must have their own spatial/color behavior")
    }

    @MainActor func testFadeUsesPremultipliedOutgoingPixelsAndSlideMovesInOriginalDirection() throws {
        let (device, image) = try fixture()
        let fade = try renderer(.fade, device: device, image: image)
        let initial = try frame(fade, progress: 0), faded = try frame(fade, progress: 0.25)
        let pixel = (32 * 96 + 24) * 4
        for channel in 0..<4 {
            XCTAssertEqual(Float(faded[pixel + channel]), Float(initial[pixel + channel]) * 0.75, accuracy: 1.1)
        }
        let slide = try frame(renderer(.horizontalSlide, device: device, image: image), progress: 0.5)
        XCTAssertEqual(slide[(32 * 96 + 24) * 4 + 3], 0)
        XCTAssertEqual(slide[(32 * 96 + 72) * 4 + 3], 255)
        for channel in 0..<3 {
            XCTAssertEqual(Float(slide[(32 * 96 + 72) * 4 + channel]), Float(initial[pixel + channel]), accuracy: 1.1)
        }
    }

    @MainActor func testBlackMidpointAndReduceFlickerHoldOutgoingRatherThanCrossfading() throws {
        let (device, image) = try fixture()
        let black = try frame(renderer(.fadeToBlack, device: device, image: image), progress: 0.5)
        let pixel = (32 * 96 + 48) * 4
        XCTAssertEqual(Array(black[pixel..<pixel + 4]), [0, 0, 0, 255])
        let hold = try renderer(.noTransitionReduceFlicker, device: device, image: image)
        XCTAssertEqual(try frame(hold, progress: 0), try frame(hold, progress: 0.99))
    }

    @MainActor func testShatterMeshIsThickVoronoiPartitionAndProjectionRoundTrips() {
        let aspect: Float = 1.5
        let vertices = PlaylistTransitionRenderer.shatterVertices(aspect: aspect, seed: 42)
        XCTAssertEqual(vertices, PlaylistTransitionRenderer.shatterVertices(aspect: aspect, seed: 42))
        XCTAssertTrue(vertices.allSatisfy(\.isFinite))
        XCTAssertEqual(vertices.count % 33, 0)
        var centers = Set<String>()
        var frontArea: Float = 0
        var backCount = 0, sideCount = 0
        for offset in stride(from: 0, to: vertices.count, by: 33) {
            let normal = SIMD3(vertices[offset + 8], vertices[offset + 9], vertices[offset + 10])
            XCTAssertEqual(simd_length(normal), 1, accuracy: 0.0001)
            centers.insert("\(vertices[offset + 5]),\(vertices[offset + 6])")
            XCTAssertEqual(vertices[offset + 7], -0.003, accuracy: 0.000001)
            if normal.z == 1 {
                let a = SIMD2(vertices[offset], vertices[offset + 1])
                let b = SIMD2(vertices[offset + 11], vertices[offset + 12])
                let c = SIMD2(vertices[offset + 22], vertices[offset + 23])
                let ab = b - a, ac = c - a
                frontArea += abs(ab.x * ac.y - ab.y * ac.x) * 0.5
            } else if normal.z == -1 { backCount += 1 }
            else { sideCount += 1 }
        }
        XCTAssertTrue((35...45).contains(centers.count))
        XCTAssertEqual(frontArea, 4 * aspect, accuracy: 0.001)
        XCTAssertGreaterThan(backCount, 0); XCTAssertGreaterThan(sideCount, 0)
        let matrix = PlaylistTransitionRenderer.projection(aspect: aspect)
        let corners: [Float] = [-1, 1]
        for x in corners { for y in corners {
            let world = SIMD4(x * aspect, y, 0, 1)
            let clip = matrix * world
            XCTAssertEqual(clip.x / clip.w, x, accuracy: 0.00001)
            XCTAssertEqual(clip.y / clip.w, y, accuracy: 0.00001)
            XCTAssertTrue((0...1).contains(clip.z / clip.w))
            let restored = matrix.inverse * clip
            XCTAssertEqual(restored.x / restored.w, world.x, accuracy: 0.00001)
            XCTAssertEqual(restored.y / restored.w, world.y, accuracy: 0.00001)
        } }
    }

    @MainActor func testOverlayCancellationIsIdempotentAndNaturalCompletionFiresOnce() throws {
        let (_, image) = try fixture()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 96, height: 64))
        var completions = 0
        let cancelled = try XCTUnwrap(PlaylistTransitionView(oldImage: image, kind: .fade, durationMillis: 1000) { completions += 1 })
        container.addSubview(cancelled)
        cancelled.cancel(); cancelled.cancel()
        XCTAssertTrue(cancelled.isFinished); XCTAssertNil(cancelled.superview)
        cancelled.advance(elapsed: 2)
        XCTAssertEqual(completions, 0)
        let completed = try XCTUnwrap(PlaylistTransitionView(oldImage: image, kind: .fade, durationMillis: 1000) { completions += 1 })
        container.addSubview(completed)
        XCTAssertEqual(completed.advance(elapsed: 0.05), 0)
        completed.advance(elapsed: 1.2); completed.advance(elapsed: 2); completed.cancel()
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(completed.isFinished); XCTAssertNil(completed.superview)
        XCTAssertNil(PlaylistTransitionView(oldImage: image, kind: .random, durationMillis: 1000) {})
    }
}
