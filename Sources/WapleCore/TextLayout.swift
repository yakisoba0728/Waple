import Foundation

/// WE text anchors are offsets in the layer basis, applied to the whole model matrix.
public enum TextLayout {
    public static func anchorOffset(anchor: String, screenLeft: Float, screenTop: Float,
                                    screenRight: Float, screenBottom: Float) -> SIMD2<Float> {
        guard [screenLeft, screenTop, screenRight, screenBottom].allSatisfy(\.isFinite) else { return .zero }
        let centerX = (screenLeft - screenRight) * 0.5
        let centerY = (screenBottom - screenTop) * 0.5
        switch anchor.lowercased() {
        case "center": return SIMD2(centerX, centerY)
        case "top": return SIMD2(centerX, -screenTop)
        case "bottom": return SIMD2(centerX, screenBottom)
        case "left": return SIMD2(screenLeft, centerY)
        case "right": return SIMD2(-screenRight, centerY)
        case "topleft": return SIMD2(screenLeft, -screenTop)
        case "topright": return SIMD2(-screenRight, -screenTop)
        case "bottomleft": return SIMD2(screenLeft, screenBottom)
        case "bottomright": return SIMD2(-screenRight, screenBottom)
        default: return .zero
        }
    }
}
