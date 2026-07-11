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
        if let name = systemFontName { return resolveSystemFont(name, pointSize: pointSize) }
        return fallbackFont(pointSize)
    }

    /// 코퍼스 실측(~211인스턴스) 별칭: 소문자 키 → 실제 폰트명. macOS 미번들(MS 계열)은 동계열 번들 폰트로 대체.
    static let systemFontAliases: [String: String] = [
        "arial": "Arial",
        "verdana": "Verdana",
        "comicsans": "Comic Sans MS",
        "consolas": "Menlo",     // 미번들 모노스페이스 → 대체
        "cambria": "Georgia",    // 미번들 세리프 → 대체
        "calibri": "Helvetica",  // 미번들 산세리프 → 대체
    ]
    /// 시스템 폰트로 직행하는 이름(시스템 산세리프 요청 취지).
    static let systemFontDirectNames: Set<String> = ["sansserif", "segoe"]

    /// "systemfont_arial" 류 이름 → CTFont. 별칭 히트는 신뢰, 미지 이름은 기존 관례(.capitalized) 시도 후
    /// 실명(패밀리/PostScript)이 요청과 무관하면 미설치로 보고 시스템 폰트로 명시 강등
    /// (CTFontCreateWithName 은 미설치 폰트에서 nil 대신 조용히 엉뚱한 폴백 페이스를 반환하므로).
    static func resolveSystemFont(_ name: String, pointSize: CGFloat) -> CTFont {
        let key = (name.hasPrefix("systemfont_") ? String(name.dropFirst("systemfont_".count)) : name).lowercased()
        guard !key.isEmpty, !systemFontDirectNames.contains(key) else { return fallbackFont(pointSize) }
        if let real = systemFontAliases[key] { return CTFontCreateWithName(real as CFString, pointSize, nil) }
        let ct = CTFontCreateWithName(key.capitalized as CFString, pointSize, nil)
        // ponytail: 공백 제거 소문자 부분일치 — ps명 "ArialMT"·패밀리 "Comic Sans MS" 류 변형 흡수엔 충분.
        let want = key.replacingOccurrences(of: " ", with: "")
        let matched = [CTFontCopyFamilyName(ct) as String, CTFontCopyPostScriptName(ct) as String].contains { actual in
            let got = actual.lowercased().replacingOccurrences(of: " ", with: "")
            return got.contains(want) || want.contains(got)
        }
        return matched ? ct : fallbackFont(pointSize)
    }

    private static func fallbackFont(_ pointSize: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(.system, pointSize, nil) ?? CTFontCreateWithName("Helvetica" as CFString, pointSize, nil)
    }
}
