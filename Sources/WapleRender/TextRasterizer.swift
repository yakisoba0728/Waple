import Foundation
import AppKit
import CoreText
import CoreGraphics
import WapleCore

/// 텍스트 → straight 알파 RGBA 비트맵(CoreText).
/// 단색 글리프에만 요청한 RGB를 굽는다(기본 흰색). GPU는 레이어 알파만 적용한다.
/// 컬러 폰트(이모지 sbix/CBDT/COLR) 글리프만 CTLineDraw 가 그린 자체 색을 그대로 보존한다
/// (WE 실물 동작 — 근거는 render() 의 un-premultiply 블록 주석에 VA 로 인용).
public enum TextRasterizer {
    /// `width`/`height` 는 **스케일 전 글리프 픽셀 크기**이고, 실물 텍스트 오브젝트의 `size`
    /// 멤버(`+0x2f0`)에 대응한다 — 커서 히트 상자가 바로 그 멤버다.
    ///
    /// 실물 규약(2026-08-21 실측, `docs/re/text-layer.md` §8b):
    /// `0x140258900`(텍스트 vtable `0x140491950` 슬롯 `+0x110`, 레이아웃 직후 `0x1402575db` 이 호출)이
    /// `[obj+0x2f0] = (잉크박스 maxX-minX, maxY-minY) + 2·clamp(padding, 512)` 를 쓰고
    /// (잉크박스는 레이아웃 결과 `+0x90`–`+0x9c`, 패딩 게이트는 `0x14025895d`–`0x14025896d`),
    /// 커서 히트 순회가 그 vec2 를 그대로 상자로 쓴다(`0x14019dd8a` → `mulps -0.5` `0x14019de4b`).
    /// 텍스트 오브젝트의 타입 가상함수는 4(`0x1400fde90`)라 이미지(1)와 **같은 상자 함수**
    /// `0x14019dbb0` 를 탄다.
    ///
    /// 스타일 패딩은 위 게이트에서만 포함한다. 래스터 효과의 투명 여백은 width/height에
    /// 포함하지만 hitSize에서는 빼므로 소비자는 padding을 두 번 더하지 않는다.
    /// (`docs/re/text-layer.md` §11.1).
    public struct Raster {
        public let rgba: Data
        public let width: Int
        public let height: Int
        /// Effects enlarge the bitmap but do not enlarge the pointer target.
        public let effectMargin: Int
        public var hitSize: SIMD2<Float> { SIMD2(Float(max(0, width - effectMargin * 2)), Float(max(0, height - effectMargin * 2))) }
    }

    public struct Tile {
        public let rgba: Data
        public let width: Int
        public let height: Int
        /// Position in the full text bitmap, with x rightward and y downward from top-left.
        public let x: Int
        public let y: Int
        /// Visible interior in texture pixels; a one-pixel texture gutter prevents linear-sampling seams.
        public let contentRect: CGRect
    }
    public struct TiledRaster {
        public let width: Int
        public let height: Int
        public let hitSize: SIMD2<Float>
        public let tiles: [Tile]
    }
    public struct TintRaster {
        public let white: Raster
        public let black: Raster
    }
    public struct TintTiledRaster {
        public let white: TiledRaster
        public let black: TiledRaster
    }

    /// Color-font/fixed-style pixels are equal in both planes. Only monochrome foreground
    /// contributes to their difference, so float shader tint preserves HDR RGB without recoloring emoji.
    public static func renderTintLayers(text: String, fontData: Data?, systemFontName: String?, pointSize: Float,
                                         maxWidth: Float? = nil, maxRows: Int? = nil,
                                         ellipsis: Bool = false, justify: Bool = false,
                                         align: String = "left", style: Style = .init()) -> TintRaster? {
        guard let white = render(text: text, fontData: fontData, systemFontName: systemFontName, pointSize: pointSize,
                                 maxWidth: maxWidth, maxRows: maxRows, ellipsis: ellipsis, justify: justify,
                                 align: align, style: style), white.rgba.count <= maxRasterBytes / 2,
              let black = render(text: text, fontData: fontData, systemFontName: systemFontName, pointSize: pointSize,
                                 maxWidth: maxWidth, maxRows: maxRows, ellipsis: ellipsis, justify: justify,
                                 align: align, style: style, tint: .zero),
              white.width == black.width, white.height == black.height else { return nil }
        return TintRaster(white: white, black: black)
    }

    public static func renderTintTiles(text: String, fontData: Data?, systemFontName: String?, pointSize: Float,
                                        maxWidth: Float? = nil, maxRows: Int? = nil,
                                        ellipsis: Bool = false, justify: Bool = false,
                                        align: String = "left", style: Style = .init(),
                                        tileDimension: Int = 4096) -> TintTiledRaster? {
        guard let white = renderTiles(text: text, fontData: fontData, systemFontName: systemFontName, pointSize: pointSize,
                                      maxWidth: maxWidth, maxRows: maxRows, ellipsis: ellipsis, justify: justify,
                                      align: align, style: style, tileDimension: tileDimension),
              white.tiles.reduce(0, { $0 + $1.rgba.count }) <= maxRasterBytes / 2,
              let black = renderTiles(text: text, fontData: fontData, systemFontName: systemFontName, pointSize: pointSize,
                                      maxWidth: maxWidth, maxRows: maxRows, ellipsis: ellipsis, justify: justify,
                                      align: align, style: style, tint: .zero, tileDimension: tileDimension),
              white.width == black.width, white.height == black.height,
              white.tiles.count == black.tiles.count else { return nil }
        return TintTiledRaster(white: white, black: black)
    }
    // docs/re/text-layer.md §3.4: WE clamps finite authored sizes to 1...256 points.
    private static let maxPointSize: Float = 256
    private static let maxRasterBytes = 256 << 20

    /// ITextLayer.pointsize 는 "300 DPI 기준 point"(lib.sceneScript.d.ts:1606). 72DPI 1:1 컨텍스트로
    /// 래스터하므로 실효 폰트크기에 300/72(≈4.17)를 곱해 WE 화면 크기에 맞춘다(미적용 시 4~5배 작음).
    ///
    /// **바이너리 근거(2026-08-21 실측)**: 텍스트 오브젝트는 `pointsize` 멤버 `+0x4e0` 를 스케일 없이
    /// FontKey`+0x0c` 로 넣고(`0x140257443`→`0x140257461`), 페이스 로드가
    /// `FT_Set_Char_Size(face, 0, (int)(pt*64), 300, 300)` 를 호출한다
    /// (`mulss 64.0` @`0x1401ad1d4` · `r9d=0x12c`/`[rsp+0x20]=0x12c` @`0x1401ad1dc`/`0x1401ad1e5` ·
    /// call @`0x1401ad1f2`). FreeType 규약상 char_height 는 1/64 **포인트**이고 해상도가 DPI 이므로
    /// 실효 픽셀 = pt × 300/72. **배율은 여기서 한 번만 곱해야 한다** — 파스 기본값(32)과 이
    /// 300/72 를 둘 다 "픽셀"로 오해해 이중 적용하면 모든 텍스트가 4.17× 커진다.
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
                              align: String = "left", style: Style = .init(),
                              tint: SIMD3<Float> = .init(repeating: 1)) -> Raster? {
        renderImpl(text: text, fontData: fontData, systemFontName: systemFontName, pointSize: pointSize,
                   maxWidth: maxWidth, maxRows: maxRows, ellipsis: ellipsis, justify: justify,
                   align: align, style: style, tint: tint)
    }

    /// Preserves authored size for long text. Each tile has the same full-layout coordinates;
    /// a tile boundary never creates a new line or changes shaping/kerning.
    public static func renderTiles(text: String, fontData: Data?, systemFontName: String?, pointSize: Float,
                                   maxWidth: Float? = nil, maxRows: Int? = nil,
                                   ellipsis: Bool = false, justify: Bool = false,
                                   align: String = "left", style: Style = .init(),
                                   tint: SIMD3<Float> = .init(repeating: 1), tileDimension: Int = 4096) -> TiledRaster? {
        guard tileDimension > 0, tileDimension <= 8192,
              let layout = renderImpl(text: text, fontData: fontData, systemFontName: systemFontName, pointSize: pointSize,
                                      maxWidth: maxWidth, maxRows: maxRows, ellipsis: ellipsis, justify: justify,
                                      align: align, style: style, tint: tint, measureOnly: true) else { return nil }
        // Tiling removes the texture-dimension limit, not the aggregate raster budget.
        guard layout.height <= maxRasterBytes / 4, layout.width <= maxRasterBytes / max(1, layout.height * 4) else { return nil }
        guard let effectMargin = safeInt(Double(style.effectMargin)) else { return nil }
        let dimension = min(tileDimension, max(1, 8190 - 2 * effectMargin))
        let columns = (layout.width - 1) / dimension + 1
        let rows = (layout.height - 1) / dimension + 1
        let count = columns * rows
        guard count <= 16384 else { return nil }
        let gutterPixels = 2 * columns * layout.height + 2 * rows * layout.width + 4 * count
        let estimatedBytes = (layout.width * layout.height + gutterPixels) * 4 + count * MemoryLayout<Tile>.stride
        guard estimatedBytes <= maxRasterBytes else { return nil }
        var tiles: [Tile] = []
        tiles.reserveCapacity(count)
        for y in stride(from: 0, to: layout.height, by: dimension) {
            for x in stride(from: 0, to: layout.width, by: dimension) {
                let rect = CGRect(x: x, y: y, width: min(dimension, layout.width - x), height: min(dimension, layout.height - y))
                // Render neighboring pixels as a gutter before bitmap blur/shadow, then crop
                // them away. Sampling a tile edge must not change the authored glyph/effect.
                let textureRect = rect.insetBy(dx: -1, dy: -1)
                    .intersection(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
                let gutter = CGFloat(style.effectMargin)
                let expanded = textureRect.insetBy(dx: -gutter, dy: -gutter)
                    .intersection(CGRect(x: 0, y: 0, width: layout.width, height: layout.height))
                guard let tile = renderImpl(text: text, fontData: fontData, systemFontName: systemFontName, pointSize: pointSize,
                                            maxWidth: maxWidth, maxRows: maxRows, ellipsis: ellipsis, justify: justify,
                                            align: align, style: style, tint: tint, crop: expanded) else { return nil }
                guard let tileW = Int(exactly: textureRect.width), let tileH = Int(exactly: textureRect.height),
                      let localX = Int(exactly: textureRect.minX - expanded.minX),
                      let localY = Int(exactly: textureRect.minY - expanded.minY),
                      let tileX = Int(exactly: textureRect.minX), let tileY = Int(exactly: textureRect.minY) else { return nil }
                var rgba = Data(count: tileW * tileH * 4)
                for row in 0..<tileH {
                    let src = ((row + localY) * tile.width + localX) * 4
                    let dst = row * tileW * 4
                    rgba.replaceSubrange(dst..<(dst + tileW * 4), with: tile.rgba[src..<(src + tileW * 4)])
                }
                let contentRect = CGRect(x: rect.minX - textureRect.minX, y: rect.minY - textureRect.minY,
                                         width: rect.width, height: rect.height)
                tiles.append(Tile(rgba: rgba, width: tileW, height: tileH,
                                  x: tileX, y: tileY, contentRect: contentRect))
            }
        }
        return TiledRaster(width: layout.width, height: layout.height, hitSize: layout.hitSize, tiles: tiles)
    }

    private static func renderImpl(text: String, fontData: Data?, systemFontName: String?, pointSize: Float,
                                   maxWidth: Float?, maxRows: Int?, ellipsis: Bool, justify: Bool,
                                   align: String, style: Style, tint: SIMD3<Float>,
                                   measureOnly: Bool = false, crop: CGRect? = nil) -> Raster? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, pointSize.isFinite else { return nil }
        let pointSize = min(max(pointSize, 1), maxPointSize)
        let font = makeFont(fontData: fontData, systemFontName: systemFontName,
                            pointSize: CGFloat(pointSize) * weRenderDPI / 72)
        // CoreText ignores foregroundColor for color-font runs, preserving emoji RGB while
        // tinting only monochrome glyphs. The GPU applies layer alpha, never RGB a second time.
        let foreground = Self.cgColor(tint)
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        if style.spacing.x.isFinite, style.spacing.x != 0 { attrs[.kern] = CGFloat(style.spacing.x) }
        let fillAttributes = attrs
        if style.outline {
            attrs[.strokeColor] = Self.cgColor(style.outlineColor)
            attrs[.strokeWidth] = -CGFloat(style.activeOutlineWidth) * 100 / CTFontGetSize(font)
        }

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

        func makeLines(_ attrs: [NSAttributedString.Key: Any]) -> [CTLine] {
            var lines = rows.map {
                CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attrs))
            }
            if clipped, ellipsis, let lastRow = rows.last {
                let cand = CTLineCreateWithAttributedString(
                    NSAttributedString(string: lastRow + "\u{2026}", attributes: attrs))
                if let mw = maxWidth, mw.isFinite, CTLineGetTypographicBounds(cand, nil, nil, nil) > Double(mw) {
                    let token = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attrs))
                    lines[lines.count - 1] = CTLineCreateTruncatedLine(cand, Double(mw), .end, token) ?? cand
                } else {
                    lines[lines.count - 1] = cand
                }
            }
            if justify, let mw = maxWidth, mw.isFinite, mw >= 1 {
                for i in lines.indices where midParagraph[i] {
                    lines[i] = CTLineCreateJustifiedLine(lines[i], 1.0, Double(mw)) ?? lines[i]
                }
            }
            return lines
        }
        let lines = makeLines(attrs)
        let fillLines = style.outline ? makeLines(fillAttributes) : []

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
        let baseLineH = ceil(ascent + descent + leading)
        let lineH = max(1, baseLineH + CGFloat(style.spacing.y.isFinite ? style.spacing.y : 0))
        let maxW = widths.max() ?? 0
        guard ascent.isFinite, descent.isFinite, lineH.isFinite, lineH > 0, maxW.isFinite else { return nil }
        let padding = style.activePadding
        let edge = CGFloat(style.effectMargin)
        let insetX = CGFloat(padding.x) + edge
        let insetY = CGFloat(padding.y) + edge
        let rawW = ceil(maxW) + 2 * insetX
        let rawH = baseLineH + lineH * CGFloat(max(0, lines.count - 1)) + 2 * insetY
        guard rawW.isFinite, rawH.isFinite, rawW >= 0, rawH >= 0,
              let integerW = safeInt(Double(rawW)), let integerH = safeInt(Double(rawH)),
              integerW <= Int.max - 2, integerH <= Int.max - 2,
              let margin = safeInt(Double(style.effectMargin)) else { return nil }
        let canvasW = max(1, integerW + 2)
        let canvasH = max(1, integerH + 2)
        if measureOnly { return Raster(rgba: Data(), width: canvasW, height: canvasH, effectMargin: margin) }
        let w: Int, h: Int
        if let crop {
            guard let cropW = Int(exactly: crop.width), let cropH = Int(exactly: crop.height),
                  cropW > 0, cropH > 0 else { return nil }
            w = cropW; h = cropH
        } else { w = canvasW; h = canvasH }
        // Legacy single-bitmap callers retain their bounded fallback. renderTiles keeps
        // authored size and crops the same layout instead; neither path allocates without a cap.
        if w > 8192 || h > 8192 || h > maxRasterBytes / 4 || w > maxRasterBytes / max(1, h * 4) {
            guard crop == nil else { return nil }
            let scale = 8192.0 / Double(max(w, h))
            let reduced = max(1, pointSize * Float(min(0.95, scale)))
            guard reduced > 0, reduced < pointSize else { return nil }
            return render(text: text, fontData: fontData, systemFontName: systemFontName, pointSize: reduced,
                          maxWidth: maxWidth, maxRows: maxRows, ellipsis: ellipsis, justify: justify, align: align,
                          style: style, tint: tint)
        }
        var pixels = Data(count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            if let crop {
                ctx.translateBy(x: -crop.minX, y: -(CGFloat(canvasH) - crop.maxY))
            }
            // 그레이스케일 AA 고정: 서브픽셀(LCD) 스무딩이 켜지면 채널별 커버리지가 달라져 아래
            // un-premultiply 뒤 단색 글리프가 순백을 벗어난다(종전엔 rgb=255 강제가 이를 덮었다).
            // WE 도 단색 글리프는 FT_PIXEL_MODE_GRAY 단일 커버리지 경로다(0x1401afa25 `cmp al, 2`).
            ctx.setAllowsFontSmoothing(false)
            ctx.setShouldSmoothFonts(false)
            if style.opaqueBackground {
                ctx.setFillColor(Self.cgColor(style.backgroundColor * style.backgroundBrightness))
                ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
            }
            if style.dropShadow {
                let offset = style.activeShadowOffset
                ctx.setShadow(offset: CGSize(width: CGFloat(offset.x.isFinite ? offset.x : 0),
                                             height: CGFloat(offset.y.isFinite ? offset.y : 0)),
                              blur: CGFloat(style.activeShadowSize),
                              color: Self.cgColor(style.dropShadowColor, alpha: style.dropShadowOpacity))
            }
            // F2(flip②): CGBitmapContext 메모리 row0 = 그려진 이미지의 top(1회 실측 확인 — 아래 flip 제거
            // 근거). 첫 줄을 사용자공간 최상단(y=h-1-ascent)에 그리면 이미 row0=첫 줄이라 텍스처 규약
            // (row0=top)과 그대로 정합한다. 형제 4곳(TexDecoder.swift 등)과 동일하게 무반전으로 통일.
            for (i, line) in lines.enumerated() {
                // 멀티라인 블록 내 행 정렬(horizontalalign) — 단일 행은 종전 x=1 그대로(무회귀).
                var x: CGFloat = 1 + insetX
                if lines.count > 1 {
                    let lw = CGFloat(widths[i])
                    switch align {
                    case "center": x = (CGFloat(canvasW) - lw) / 2
                    case "right": x = CGFloat(canvasW) - 1 - insetX - lw
                    default: break
                    }
                }
                ctx.textPosition = CGPoint(x: x, y: CGFloat(canvasH) - 1 - insetY - ascent - CGFloat(i) * lineH)
                CTLineDraw(line, ctx)
                if style.outline {
                    // Draw fill last so a wide stroke cannot cover thin glyph interiors.
                    ctx.textPosition = CGPoint(x: x, y: CGFloat(canvasH) - 1 - insetY - ascent - CGFloat(i) * lineH)
                    CTLineDraw(fillLines[i], ctx)
                }
            }
            // ── premultiplied → straight ─────────────────────────────────────────────────
            // 종전엔 알파>0 픽셀의 rgb 를 무조건 255 로 밀었다. 흰색 글리프(rgb=alpha)에는 맞지만,
            // CoreText 캐스케이드가 컬러 폰트(Apple Color Emoji=sbix, Noto Color Emoji=CBDT,
            // COLR/CPAL)로 폴백하면 CTLineDraw 는 foregroundColor 를 무시하고 **글리프 자체 색**을
            // 그린다 — 255 강제는 그 색을 흰 실루엣으로 파괴한다(이모지가 흰 덩어리가 됨).
            //
            // WE 실물은 컬러 글리프의 RGB 를 살린다(wallpaper64.exe, imagebase 0x140000000;
            // FreeType+HarfBuzz 정적 링크. 글리프 래스터 함수 0x1401ae080):
            //   · 0x1401ae282  test dword [rbx+8], 0x4000  ← FT_HAS_COLOR(face)
            //                  (FT_FACE_FLAG_COLOR = 1<<14, LLP64 FT_FaceRec.face_flags = +8)
            //   · 0x1401ae28b  mov r8d, 0x100004           ← FT_LOAD_COLOR|FT_LOAD_RENDER 로
            //                  FT_Load_Glyph(0x1402f12d0) 호출. MSDF 를 끈 경로(0x1401ae2e3)도 동일 플래그.
            //                  컬러 폰트가 아니면 0x1401ae2b7 이 FT_LOAD_NO_BITMAP(8) 로 윤곽만 읽는다.
            //   · 0x1401ae2a2  cmp byte [rax+0x82], 7      ← slot->bitmap.pixel_mode == FT_PIXEL_MODE_BGRA
            //                  (LLP64 FT_GlyphSlotRec: format=+0x60, bitmap=+0x68, pixel_mode=+0x82)
            //   · 0x1401ae392  cmp byte [r9+0x42], 7       ← FT_BitmapGlyph 쪽 동일 검사 → 글리프별 "컬러" 플래그
            //   · 0x1401afa2d–0x1401afb29  BGRA 아틀라스 블릿: 행 memcpy 후 마스크 0xFF00FF00 /
            //                  0x00FF00FF (상수 0x140492ce0 / 0x1404930b0) 로 **B↔R 스왑만** 한다.
            //                  G·A 는 손대지 않고 화이트닝도 없다. GRAY(2) 는 0x1401afb2b 의 1B/px 경로.
            //   · 0x1401ac9af–0x1401ac9b9  컬러/MSDF 아틀라스는 4B/px(512×512×4 = 0x100000),
            //                  순수 흑백만 1B/px(0x40000). 0x1401ac8aa 가 "__font_atlas_color_" RGBA
            //                  텍스처를 따로 만든다(0x1401ac7f0–0x1401ac8c4).
            //   · 0x1401b3a16  컬러 글리프 배치는 materials/fonts/basefontrgba.json(COLORFONT=1)로 그린다.
            //                  assets/shaders/font.frag: `gl_FragColor = vec4(_sample.rgb, _sample.a * g_Color4.a)`
            //                  — 샘플 RGB 를 그대로 내보내고 레이어 색은 알파에만 곱한다.
            // 따라서 255 강제 대신 나눗셈으로 straight RGB 를 복원한다. 흰색 글리프는 rgb=alpha 라
            // 결과가 정확히 255 로 수렴해 종전 출력과 비트동일하다(무회귀).
            //
            // 레이어 RGB는 위 CoreText foreground에 적용하며 컬러 폰트는 이를 무시한다.
            // 소비자는 래스터에 tint를 다시 곱하지 않고 알파만 적용한다.
            let px = base.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                let a = Int(clamping: px[i + 3])   // UInt8→Int 는 확대라 트랩 없음(라벨은 인구조사용)
                if a == 0 || a == 255 { continue }   // 0=투명(rgb 무의미), 255=premul==straight
                px[i]     = unpremultiply(px[i], alpha: a)
                px[i + 1] = unpremultiply(px[i + 1], alpha: a)
                px[i + 2] = unpremultiply(px[i + 2], alpha: a)
            }
            return true
        }
        // F2(flip②): 여기서 반전하지 않는다 — 위 드로우가 이미 row0=top 규약을 만족한다(반전을 넣으면
        // 글리프 상하 미러 + 멀티라인 행 순서 역전). 소비측(SceneRendererResources.rasterize → makeTexture,
        // 텍스트 쿼드 uv(0,0)=TL)도 무반전을 전제한다.
        guard ok else { return nil }
        if style.blur { pixels = TextBitmapStyle.blur(pixels, width: w, height: h, radius: style.activeBlurSize) }
        return Raster(rgba: pixels, width: w, height: h, effectMargin: margin)
    }

    /// premultiplied 채널 → straight: `round(v · 255 / alpha)`(255 클램프).
    /// 흰색 글리프는 v == alpha 라 정확히 255 를 돌려준다 — 종전 `px[i] = 255` 와 비트동일(무회귀).
    /// 컬러 글리프(이모지)는 원래 색이 복원된다. alpha == 0 은 호출측이 걸러내지만 방어로 v 를 그대로 낸다.
    static func unpremultiply(_ v: UInt8, alpha: Int) -> UInt8 {
        guard alpha > 0 else { return v }
        // `clamping:` 은 인구조사 라벨 겸 실제 가드다 — premultiplied 불변식이 깨진 입력
        // (v > alpha) 에서도 트랩 대신 255 로 포화한다.
        return UInt8(clamping: (Int(clamping: v) * 255 + alpha / 2) / alpha)
    }

    private static func makeFont(fontData: Data?, systemFontName: String?, pointSize: CGFloat) -> CTFont {
        if let data = fontData,
           let desc = CTFontManagerCreateFontDescriptorFromData(data as CFData) {
            return withFallbackCascade(CTFontCreateWithFontDescriptor(desc, pointSize, nil))
        }
        if let name = systemFontName { return withFallbackCascade(resolveSystemFont(name, pointSize: pointSize)) }
        return withFallbackCascade(fallbackFont(pointSize))
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
