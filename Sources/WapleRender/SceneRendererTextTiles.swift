import Foundation
import Metal

extension SceneRenderer {
    struct GPUTextTile {
        let texture: MTLTexture
        var blackTexture: MTLTexture? = nil
        let rect: SIMD4<Float>
        let textureRect: SIMD4<Float>
    }

    func uploadTextTintTiles(_ raster: TextRasterizer.TintTiledRaster, device: MTLDevice) -> [GPUTextTile] {
        var result = uploadTextTiles(raster.white, device: device)
        guard result.count == raster.black.tiles.count else { return [] }
        for index in result.indices {
            let tile = raster.black.tiles[index]
            guard let black = makeTexture(tile.rgba, tile.width, tile.height, device) else { return [] }
            result[index].blackTexture = black
        }
        return result
    }

    func uploadTextTiles(_ raster: TextRasterizer.TiledRaster, device: MTLDevice) -> [GPUTextTile] {
        var result: [GPUTextTile] = []
        for tile in raster.tiles {
            guard let texture = makeTexture(tile.rgba, tile.width, tile.height, device) else { return [] }
            let content = tile.contentRect
            let x = Float(tile.x) + Float(content.minX), y = Float(tile.y) + Float(content.minY)
            let rect = SIMD4(x / Float(raster.width), y / Float(raster.height),
                             (x + Float(content.width)) / Float(raster.width),
                             (y + Float(content.height)) / Float(raster.height))
            let textureRect = SIMD4(Float(content.minX) / Float(tile.width), Float(content.minY) / Float(tile.height),
                                    Float(content.maxX) / Float(tile.width), Float(content.maxY) / Float(tile.height))
            result.append(GPUTextTile(texture: texture, rect: rect, textureRect: textureRect))
        }
        return result
    }

    /// Caller binds the same pipeline, tint, camera, blend snapshot and aspect for every tile.
    func drawTextTiles(_ tiles: [GPUTextTile], fallbackTexture: MTLTexture,
                       fallbackBlackTexture: MTLTexture? = nil,
                       vertexBuffer: MTLBuffer, vertexCount: Int,
                       projectiveDepth: SIMD4<Float>, encoder: MTLRenderCommandEncoder) {
        guard !tiles.isEmpty else {
            encoder.setFragmentTexture(fallbackTexture, index: 0)
            encoder.setFragmentTexture(fallbackBlackTexture, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
            return
        }
        guard vertexCount > 0, vertexCount <= vertexBuffer.length / MemoryLayout<SIMD4<Float>>.stride,
              vertexBuffer.storageMode != .private else { return }
        let source = vertexBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: vertexCount)
        let vertices = Array(UnsafeBufferPointer(start: source, count: vertexCount))
        for tile in tiles {
            let cropped = TextTileGeometry.crop(vertices: vertices, projectiveDepth: projectiveDepth,
                                                rect: tile.rect, textureRect: tile.textureRect)
            guard !cropped.vertices.isEmpty else { continue }
            cropped.vertices.withUnsafeBufferPointer { buffer in
                encoder.setVertexBytes(buffer.baseAddress!, length: buffer.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
            }
            var depth = cropped.projectiveDepth
            encoder.setVertexBytes(&depth, length: MemoryLayout<SIMD4<Float>>.stride, index: 5)
            encoder.setFragmentTexture(tile.texture, index: 0)
            encoder.setFragmentTexture(tile.blackTexture, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cropped.vertices.count)
        }
    }
}
