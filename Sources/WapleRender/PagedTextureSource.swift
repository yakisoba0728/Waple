import Foundation
import Metal
import WapleCore

/// Keeps source bytes and at most two decoded GPU pages, rather than a full-height mega-atlas.
final class PagedTextureSource {
    let image: TexImage
    private let data: Data
    private var pages: [Int: MTLTexture]
    private var recency: [Int] = [0]
    init(image: TexImage, data: Data, first: MTLTexture) {
        self.image = image; self.data = data; self.pages = [0: first]
    }
    var residentPageCount: Int { pages.count }
    func texture(page: Int, renderer: SceneRenderer, device: MTLDevice) -> MTLTexture? {
        guard page >= 0, page < image.imageCount else { return nil }
        if let texture = pages[page] {
            recency.removeAll { $0 == page }; recency.append(page)
            return texture
        }
        guard let decoded = TexDecoder.rgba(from: image, data: data, imageIndex: page, keepFullAtlas: true),
              let texture = renderer.makeTexture(decoded.pixels, decoded.width, decoded.height, device) else { return nil }
        // Encoders retain each resource until execution; eviction cannot invalidate an earlier draw.
        while pages.count >= 2, let oldest = recency.first {
            recency.removeFirst(); pages.removeValue(forKey: oldest)
        }
        pages[page] = texture; recency.append(page)
        return texture
    }
}
