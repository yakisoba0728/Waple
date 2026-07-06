import Foundation
import AppKit
import CoreText
import CoreGraphics

/// 텍스트 → 흰색 글리프 + straight 알파 RGBA 비트맵(CoreText).
/// 색/알파는 레이어 tint 경로가 적용하므로 여기선 항상 흰색(규약 일관 — QuadShaders f_main).
public enum TextRasterizer {
    public struct Raster { public let rgba: Data; public let width: Int; public let height: Int }
    private static let maxPointSize: Float = 8192
    private static let maxRasterBytes = 256 << 20

    /// - fontData: pkg/base-assets 의 .otf/.ttf 바이트(전역 등록 없이 디스크립터로 생성).
    /// - systemFontName: "systemfont_arial" 류의 이름 매핑(없거나 실패 시 시스템 폰트).
    public static func render(text: String, fontData: Data?, systemFontName: String?, pointSize: Float) -> Raster? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pointSize.isFinite, pointSize > 0, pointSize <= maxPointSize else { return nil }
        let font = makeFont(fontData: fontData, systemFontName: systemFontName, pointSize: CGFloat(pointSize))
        let attr = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        guard advance.isFinite, ascent.isFinite, descent.isFinite else { return nil }
        let rawW = ceil(advance)
        let rawH = ceil(ascent + descent)
        guard rawW.isFinite, rawH.isFinite, rawW >= 0, rawH >= 0,
              rawW <= CGFloat(Int.max - 2), rawH <= CGFloat(Int.max - 2) else { return nil }
        let w = max(1, Int(rawW) + 2)
        let h = max(1, Int(rawH) + 2)
        guard w <= 8192, h <= 8192, w <= maxRasterBytes / max(1, h * 4) else { return nil }
        var pixels = Data(count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.textPosition = CGPoint(x: 1, y: descent + 1)
            CTLineDraw(line, ctx)
            // premultiplied → straight (흰색 글리프라 rgb=alpha; 255 로 통일해 tint 가 온전히 색을 결정)
            let px = base.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: w * h * 4, by: 4) where px[i + 3] > 0 {
                px[i] = 255; px[i + 1] = 255; px[i + 2] = 255
            }
            return true
        }
        // CoreText 는 하단 원점(row0=bottom) — 우리 텍스처 규약(row0=top)으로 상하 반전.
        guard ok else { return nil }
        var flipped = Data(capacity: w * h * 4)
        pixels.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for row in stride(from: h - 1, through: 0, by: -1) {
                flipped.append(contentsOf: p[(row * w * 4)..<((row + 1) * w * 4)])
            }
        }
        return Raster(rgba: flipped, width: w, height: h)
    }

    private static func makeFont(fontData: Data?, systemFontName: String?, pointSize: CGFloat) -> CTFont {
        if let data = fontData,
           let desc = CTFontManagerCreateFontDescriptorFromData(data as CFData) {
            return CTFontCreateWithFontDescriptor(desc, pointSize, nil)
        }
        if let name = systemFontName {
            // "systemfont_arial" → "Arial" 류 관례 매핑; 실패 시 아래 시스템 폴백.
            let candidate = name.hasPrefix("systemfont_") ? String(name.dropFirst("systemfont_".count)) : name
            let ct = CTFontCreateWithName(candidate.capitalized as CFString, pointSize, nil)
            return ct
        }
        return CTFontCreateUIFontForLanguage(.system, pointSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
    }
}
