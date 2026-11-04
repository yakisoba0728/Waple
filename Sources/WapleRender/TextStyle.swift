import Foundation
import CoreGraphics
import CoreText
import Accelerate
import WapleCore

extension TextRasterizer {
    public struct Style {
        public var spacing = SIMD2<Float>(repeating: 0)
        public var outline = false
        public var outlineColor = SIMD3<Float>(repeating: 0)
        public var outlineThickness: Float = 4
        public var padding = SIMD2<Float>(repeating: 0)
        public var needsOffscreen = false
        public var opaqueBackground = false
        public var backgroundColor = SIMD3<Float>(repeating: 0)
        public var backgroundBrightness: Float = 1
        public var blur = false
        public var blurSize: Float = 6
        public var dropShadow = false
        public var dropShadowSize: Float = 6
        public var dropShadowOpacity: Float = 1
        public var dropShadowColor = SIMD3<Float>(repeating: 0)
        public var dropShadowOffset = SIMD2<Float>(repeating: 4)

        public init() {}

        public init(layer: SceneTextLayer) {
            spacing = SIMD2(layer.spacing?.x ?? 0, layer.spacing?.y ?? 0)
            outline = layer.outline
            outlineColor = SIMD3(layer.outlineColor.x, layer.outlineColor.y, layer.outlineColor.z)
            outlineThickness = layer.outlineThickness
            padding = SIMD2(layer.padding.x, layer.padding.y)
            needsOffscreen = !layer.effects.isEmpty || (layer.colorBlendMode != 0 && layer.colorBlendMode != 31)
            opaqueBackground = layer.opaqueBackground
            backgroundColor = SIMD3(layer.backgroundColor.x, layer.backgroundColor.y, layer.backgroundColor.z)
            backgroundBrightness = layer.backgroundBrightness.isFinite ? layer.backgroundBrightness : 1
            blur = layer.blur
            blurSize = layer.blurSize
            dropShadow = layer.dropShadow
            dropShadowSize = layer.dropShadowSize
            dropShadowOpacity = layer.dropShadowOpacity
            dropShadowColor = SIMD3(layer.dropShadowColor.x, layer.dropShadowColor.y, layer.dropShadowColor.z)
            dropShadowOffset = SIMD2(layer.dropShadowOffset.x, layer.dropShadowOffset.y)
        }

        var activePadding: SIMD2<Float> {
            guard needsOffscreen || opaqueBackground else { return .zero }
            return SIMD2(padding.x.isFinite ? min(padding.x, 512) : 0,
                         padding.y.isFinite ? min(padding.y, 512) : 0)
        }
        var activeOutlineWidth: Float { outline ? bounded(outlineThickness, lower: 1) : 0 }
        var activeBlurSize: Float { blur ? bounded(blurSize, lower: 0.01) : 0 }
        var activeShadowSize: Float { dropShadow ? bounded(dropShadowSize, lower: 0.01) : 0 }
        var activeShadowOffset: SIMD2<Float> {
            guard dropShadow else { return .zero }
            return SIMD2(dropShadowOffset.x.isFinite ? min(max(dropShadowOffset.x, -512), 512) : 0,
                         dropShadowOffset.y.isFinite ? min(max(dropShadowOffset.y, -512), 512) : 0)
        }
        var effectMargin: Float {
            let offset = max(abs(activeShadowOffset.x), abs(activeShadowOffset.y))
            return ceil(activeOutlineWidth + activeBlurSize * 2 + activeShadowSize * 2 + (offset.isFinite ? min(offset, 512) : 0))
        }
        private func bounded(_ value: Float, lower: Float) -> Float {
            value.isFinite ? min(max(value, lower), 512) : lower
        }
    }

    static func cgColor(_ rgb: SIMD3<Float>, alpha: Float = 1) -> CGColor {
        func channel(_ value: Float) -> CGFloat { CGFloat(value.isFinite ? min(max(value, 0), 1) : 0) }
        // Match the bitmap's sRGB profile. Generic RGB conversion changes authored bytes
        // (e.g. 0.5 becomes about 0.557) and introduces green/blue into a red glyph.
        return CGColor(srgbRed: channel(rgb.x), green: channel(rgb.y), blue: channel(rgb.z), alpha: channel(alpha))
    }

    /// Use installed WE cascade faces in their documented order, followed by macOS coverage.
    /// No font files are registered or redistributed; unavailable licensed faces stay unavailable.
    static let fallbackFontNames = ["Arial", "Segoe UI Emoji", "Arial Unicode MS", "Segoe UI",
                                    "TwemojiMozilla", "Segoe UI Symbol", "Microsoft YaHei", "Malgun Gothic",
                                    "Apple Color Emoji", "PingFang SC", "Apple SD Gothic Neo"]

    private static let fallbackDescriptors: [CTFontDescriptor] = {
        let available = Set((CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? [])
        return fallbackFontNames.filter { available.contains($0) }.map { name in
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
        }
    }()

    static func withFallbackCascade(_ font: CTFont) -> CTFont {
        guard !fallbackDescriptors.isEmpty else { return font }
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute: fallbackDescriptors] as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), nil, descriptor)
    }
}

enum TextBitmapStyle {
    /// shortcut: bitmap convolution approximates WE's distance-field blur; replace this
    /// branch when the independent MSDF generator and median-sampling pipeline are validated.
    static func blur(_ pixels: Data, width: Int, height: Int, radius: Float) -> Data {
        guard radius.isFinite, radius > 0 else { return pixels }
        var source = pixels
        // Convolution must operate on premultiplied channels to avoid dark translucent edges.
        source.withUnsafeMutableBytes { bytes in
            guard let p = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let a = Int(clamping: p[i + 3])
                for c in 0..<3 { p[i + c] = UInt8(clamping: (Int(clamping: p[i + c]) * a + 127) / 255) }
            }
        }
        var destination = Data(count: source.count)
        let boundedRadius = min(radius, 511)
        guard let diameter = safeInt(ceil(Double(boundedRadius) * 2)) else { return pixels }
        let kernel = UInt32(clamping: max(1, min(1023, diameter | 1)))
        let status = source.withUnsafeMutableBytes { src in
            destination.withUnsafeMutableBytes { dst -> vImage_Error in
                var input = vImage_Buffer(data: src.baseAddress!, height: vImagePixelCount(height),
                                          width: vImagePixelCount(width), rowBytes: width * 4)
                var output = vImage_Buffer(data: dst.baseAddress!, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: width * 4)
                return vImageBoxConvolve_ARGB8888(&input, &output, nil, 0, 0, kernel, kernel, nil,
                                                  vImage_Flags(kvImageEdgeExtend))
            }
        }
        guard status == kvImageNoError else { return pixels }
        destination.withUnsafeMutableBytes { bytes in
            guard let p = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in stride(from: 0, to: bytes.count, by: 4) where p[i + 3] > 0 {
                for c in 0..<3 { p[i + c] = TextRasterizer.unpremultiply(p[i + c], alpha: Int(clamping: p[i + 3])) }
            }
        }
        return destination
    }
}
