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

    /// ITextLayer.pointsize 는 "300 DPI 기준 point"(lib.sceneScript.d.ts:1606). 72DPI 1:1 컨텍스트로
    /// 래스터하므로 실효 폰트크기에 300/72(≈4.17)를 곱해 WE 화면 크기에 맞춘다(미적용 시 4~5배 작음).
    private static let weRenderDPI: CGFloat = 300

    /// - fontData: pkg/base-assets 의 .otf/.ttf 바이트(전역 등록 없이 디스크립터로 생성).
    /// - systemFontName: "systemfont_arial" 류의 이름 매핑(없거나 실패 시 시스템 폰트).
    /// - maxWidth: "Limit width" 워드랩 폭(래스터 px = WE 로컬 px — 실물 maxwidth 스크립트가 화면폭을
    ///   scale 로 나눠 전달). nil = 무제한(기존 경로 그대로 — 무회귀).
    /// - maxRows: "Limit rows" 최대 행수(초과 행 잘림). nil = 무제한.
    /// - ellipsis: "Overflow ellipsis" — 행 잘림 시 마지막 행에 U+2026(maxWidth 초과 시 끝을 잘라 삽입).
    /// - justify: "Justify text"(blockalign) — 문단 중간 워드랩 줄을 maxWidth 로 양쪽 정렬.
    /// - align: 블록 내 행 정렬(horizontalalign) — 멀티라인만 적용(단일 행은 종전 x=1 그대로).
    public static func render(text: String, fontData: Data?, systemFontName: String?, pointSize: Float,
                              maxWidth: Float? = nil, maxRows: Int? = nil,
                              ellipsis: Bool = false, justify: Bool = false,
                              align: String = "left") -> Raster? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pointSize.isFinite, pointSize > 0, pointSize <= maxPointSize else { return nil }
        let font = makeFont(fontData: fontData, systemFontName: systemFontName,
                            pointSize: CGFloat(pointSize) * weRenderDPI / 72)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: white]

        // ── 행 구성: maxWidth(limitwidth) 시 CTTypesetter 워드랩(UAX#14: 공백 단어 경계·CJK 문자 경계,
        //    폭 초과 단어는 내부 강제 분리, `\n` 은 강제 개행). 아니면 기존 `\n` 분리 그대로(무회귀).
        //    (단일 CTLine 은 `\n` 을 제로폭 글리프로 뭉개 한 줄로 붕괴시킨다.)
        var rows: [String]
        var midParagraph: [Bool]   // justify 대상(문단 마지막·잘린 끝 행 제외)
        if let mw = maxWidth, mw.isFinite, mw >= 1 {
            let ns = text as NSString
            let ts = CTTypesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
            rows = []; midParagraph = []
            var start = 0
            while start < ns.length {
                let count = CTTypesetterSuggestLineBreak(ts, start, Double(mw))
                guard count > 0 else { break }   // 방어(규약상 ≥1 클러스터)
                var piece = ns.substring(with: NSRange(location: start, length: count))
                let hard = piece.hasSuffix("\n")
                if hard { piece.removeLast() }
                rows.append(piece)
                start += count
                midParagraph.append(!hard && start < ns.length)
            }
        } else {
            rows = text.components(separatedBy: "\n")
            midParagraph = Array(repeating: false, count: rows.count)
        }

        // ── 행 제한(limitrows): 초과 행 잘림 + (ellipsis) 마지막 행에 U+2026.
        var clipped = false
        if let mr = maxRows, mr > 0, rows.count > mr {
            rows.removeLast(rows.count - mr)
            midParagraph.removeLast(midParagraph.count - mr)
            midParagraph[midParagraph.count - 1] = false   // 잘린 끝 행은 justify 스트레치 제외
            clipped = true
        }

        var lines = rows.map {
            CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attrs))
        }
        if clipped, ellipsis, let lastRow = rows.last {
            let cand = CTLineCreateWithAttributedString(
                NSAttributedString(string: lastRow + "\u{2026}", attributes: attrs))
            if let mw = maxWidth, CTLineGetTypographicBounds(cand, nil, nil, nil) > Double(mw) {
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attrs))
                lines[lines.count - 1] = CTLineCreateTruncatedLine(cand, Double(mw), .end, token) ?? cand
            } else {
                lines[lines.count - 1] = cand
            }
        }
        if justify, let mw = maxWidth, mw >= 1 {
            for i in lines.indices where midParagraph[i] {
                lines[i] = CTLineCreateJustifiedLine(lines[i], 1.0, Double(mw)) ?? lines[i]
            }
        }

        // 줄 높이는 폰트 메트릭(빈 줄도 한 행 차지) — 폭은 줄별 실측 최대치.
        // F476: 기본 폰트 메트릭만 쓰면 CoreText 캐스케이드로 그려지는 폴백 글리프(CJK·이모지 등
        // 기본 폰트보다 ascent/descent 가 큰 폰트)가 캔버스 상하단에서 잘린다 — 줄별 실측(런의 실제
        // 폰트 반영)과 기본 폰트 메트릭의 최대를 캔버스 높이/베이스라인에 사용한다.
        var ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        let widths = lines.map { line -> Double in
            var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
            let w = CTLineGetTypographicBounds(line, &a, &d, &l)
            if a.isFinite { ascent = max(ascent, a) }
            if d.isFinite { descent = max(descent, d) }
            if l.isFinite { leading = max(leading, l) }
            return w
        }
        let lineH = ceil(ascent + descent + leading)
        let maxW = widths.max() ?? 0
        guard ascent.isFinite, descent.isFinite, lineH.isFinite, lineH > 0, maxW.isFinite else { return nil }
        let rawW = ceil(maxW)
        let rawH = lineH * CGFloat(lines.count)
        guard rawW.isFinite, rawH.isFinite, rawW >= 0, rawH >= 0,
              rawW <= CGFloat(Int.max - 2), rawH <= CGFloat(Int.max - 2) else { return nil }
        let w = max(1, Int(rawW) + 2)
        let h = max(1, Int(rawH) + 2)
        // 8192/바이트 상한 초과 시 nil(=드로우 스킵=조용한 텍스트 소실) 대신 pointSize 를 축소해 재시도 —
        // 4.17× DPI 스케일이 이 가드를 조기 격발하므로(장문 단일줄·대형 폰트), 최악이라도 pre-B1 의
        // 작은 크기로 수렴시켜 "작게 보임"을 지킨다(회귀 방지). 워드랩(진짜 해결)은 별건(BACKLOG).
        if w > 8192 || h > 8192 || w > maxRasterBytes / max(1, h * 4) {
            let scale = 8192.0 / Double(max(w, h))
            let reduced = pointSize * Float(min(0.95, scale))
            guard reduced > 0, reduced < pointSize else { return nil }
            return render(text: text, fontData: fontData, systemFontName: systemFontName, pointSize: reduced,
                          maxWidth: maxWidth, maxRows: maxRows, ellipsis: ellipsis, justify: justify, align: align)
        }
        var pixels = Data(count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // F2(flip②): CGBitmapContext 메모리 row0 = 그려진 이미지의 top(1회 실측 확인 — 아래 flip 제거
            // 근거). 첫 줄을 사용자공간 최상단(y=h-1-ascent)에 그리면 이미 row0=첫 줄이라 텍스처 규약
            // (row0=top)과 그대로 정합한다. 형제 4곳(TexDecoder.swift 등)과 동일하게 무반전으로 통일.
            for (i, line) in lines.enumerated() {
                // 멀티라인 블록 내 행 정렬(horizontalalign) — 단일 행은 종전 x=1 그대로(무회귀).
                var x: CGFloat = 1
                if lines.count > 1 {
                    let lw = CGFloat(widths[i])
                    switch align {
                    case "center": x = (CGFloat(w) - lw) / 2
                    case "right": x = CGFloat(w) - 1 - lw
                    default: break
                    }
                }
                ctx.textPosition = CGPoint(x: x, y: CGFloat(h) - 1 - ascent - CGFloat(i) * lineH)
                CTLineDraw(line, ctx)
            }
            // premultiplied → straight (흰색 글리프라 rgb=alpha; 255 로 통일해 tint 가 온전히 색을 결정)
            let px = base.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: w * h * 4, by: 4) where px[i + 3] > 0 {
                px[i] = 255; px[i + 1] = 255; px[i + 2] = 255
            }
            return true
        }
        // F2(flip②): 여기서 반전하지 않는다 — 위 드로우가 이미 row0=top 규약을 만족한다(반전을 넣으면
        // 글리프 상하 미러 + 멀티라인 행 순서 역전). 소비측(SceneRendererResources.rasterize → makeTexture,
        // 텍스트 쿼드 uv(0,0)=TL)도 무반전을 전제한다.
        guard ok else { return nil }
        return Raster(rgba: pixels, width: w, height: h)
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
