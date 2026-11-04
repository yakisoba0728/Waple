import XCTest
@testable import WapleCore
@testable import WapleRender

final class TextStyleRegressionTests: XCTestCase {
    private func raster(_ text: String = "III", style: TextRasterizer.Style = .init(),
                        tint: SIMD3<Float> = .init(repeating: 1)) throws -> TextRasterizer.Raster {
        try XCTUnwrap(TextRasterizer.render(text: text, fontData: nil, systemFontName: "systemfont_arial",
                                           pointSize: 12, style: style, tint: tint))
    }

    func testSpacingMovesGlyphsAndAddsOnlyInterlineDistance() throws {
        let base = try raster()
        var style = TextRasterizer.Style()
        style.spacing.x = 10
        let spaced = try raster(style: style)
        XCTAssertGreaterThanOrEqual(spaced.width - base.width, 19)
        XCTAssertLessThanOrEqual(spaced.width - base.width, 31)
        style.spacing = SIMD2(0, 20)
        let two = try raster("I\nI")
        let spacedTwo = try raster("I\nI", style: style)
        XCTAssertEqual(spacedTwo.height - two.height, 20)
        XCTAssertEqual(try raster("I", style: style).height, try raster("I").height)
    }

    func testPaddingIsConditionalAndBackgroundColorUsesBrightness() throws {
        let plain = try raster()
        var style = TextRasterizer.Style()
        style.padding = SIMD2(8, 12)
        XCTAssertEqual(try raster(style: style).rgba, plain.rgba)
        style.opaqueBackground = true
        style.backgroundColor = SIMD3(0.4, 0.8, 0.2)
        style.backgroundBrightness = 0.5
        let padded = try raster(style: style)
        XCTAssertEqual(padded.width, plain.width + 16)
        XCTAssertEqual(padded.height, plain.height + 24)
        let bytes = [UInt8](padded.rgba)
        XCTAssertEqual(Double(bytes[0]), 51, accuracy: 1)
        XCTAssertEqual(Double(bytes[1]), 102, accuracy: 1)
        XCTAssertEqual(Double(bytes[2]), 26, accuracy: 1)
        XCTAssertEqual(bytes[3], 255)
    }

    func testOutlineKeepsItsOwnColorAroundTintedGlyph() throws {
        var style = TextRasterizer.Style()
        style.outline = true
        style.outlineThickness = 4
        style.outlineColor = SIMD3(0, 0, 1)
        let value = try raster("M", style: style, tint: SIMD3(1, 0, 0))
        let p = [UInt8](value.rgba)
        var red = 0, blue = 0
        for i in stride(from: 0, to: p.count, by: 4) where p[i + 3] > 100 {
            if p[i] > 200 && p[i + 2] < 50 { red += 1 }
            if p[i + 2] > 200 && p[i] < 50 { blue += 1 }
        }
        XCTAssertGreaterThan(red, 0)
        XCTAssertGreaterThan(blue, 0)
    }

    func testColoredEmojiKeepsColorWhenMonochromeGlyphsAreRed() throws {
        let value = try raster("M😀", tint: SIMD3(1, 0, 0))
        let p = [UInt8](value.rgba)
        var red = 0, colored = 0
        for i in stride(from: 0, to: p.count, by: 4) where p[i + 3] > 200 {
            if p[i] > 200 && p[i + 1] < 20 && p[i + 2] < 20 { red += 1 }
            if p[i + 1] > 80 && p[i] > 80 { colored += 1 }
        }
        XCTAssertGreaterThan(red, 0)
        XCTAssertGreaterThan(colored, 0, "emoji RGB must bypass layer RGB tint")
    }

    func testDropShadowAndBlurChangeVisibleCoverage() throws {
        let original = try raster("I")
        var shadow = TextRasterizer.Style()
        shadow.dropShadow = true
        shadow.dropShadowColor = SIMD3(0, 1, 0)
        shadow.dropShadowOffset = SIMD2(10, 0)
        let withShadow = try raster("I", style: shadow)
        XCTAssertGreaterThan(withShadow.width, original.width)
        let p = [UInt8](withShadow.rgba)
        XCTAssertTrue(stride(from: 0, to: p.count, by: 4).contains { p[$0 + 1] > 100 && p[$0] < 20 && p[$0 + 3] > 20 })
        var blur = TextRasterizer.Style()
        blur.blur = true
        XCTAssertNotEqual(try raster("I", style: blur).rgba, original.rgba)
    }

    func testAnchorOffsetsUseAllFourScreenEdges() {
        // Asymmetric edges detect swapped signs and accidental reuse of projection dimensions.
        XCTAssertEqual(TextLayout.anchorOffset(anchor: "topleft", screenLeft: 10, screenTop: 20, screenRight: 30, screenBottom: 60), SIMD2(10, -20))
        XCTAssertEqual(TextLayout.anchorOffset(anchor: "center", screenLeft: 10, screenTop: 20, screenRight: 30, screenBottom: 60), SIMD2(-10, 20))
        XCTAssertEqual(TextLayout.anchorOffset(anchor: "bottomright", screenLeft: 10, screenTop: 20, screenRight: 30, screenBottom: 60), SIMD2(-30, 60))
        XCTAssertEqual(TextLayout.anchorOffset(anchor: "none", screenLeft: 10, screenTop: 20, screenRight: 30, screenBottom: 60), .zero)
    }

    func testTilesReconstructTheSameAuthoredPixelsAcrossGlyphAndBlurBoundaries() throws {
        var style = TextRasterizer.Style()
        style.blur = true
        style.blurSize = 2
        let full = try raster("Wide text\nSecond line", style: style)
        let tiled = try XCTUnwrap(TextRasterizer.renderTiles(text: "Wide text\nSecond line", fontData: nil,
                                                            systemFontName: "systemfont_arial", pointSize: 12,
                                                            style: style, tileDimension: 32))
        XCTAssertGreaterThan(tiled.tiles.count, 1)
        XCTAssertEqual(tiled.width, full.width)
        XCTAssertEqual(tiled.height, full.height)
        var reconstructed = Data(count: full.rgba.count)
        for tile in tiled.tiles {
            XCTAssertLessThanOrEqual(tile.width, 34)
            XCTAssertLessThanOrEqual(tile.height, 34)
            for row in 0..<tile.height {
                let dst = ((tile.y + row) * tiled.width + tile.x) * 4
                let src = row * tile.width * 4
                reconstructed.replaceSubrange(dst..<(dst + tile.width * 4), with: tile.rgba[src..<(src + tile.width * 4)])
            }
        }
        XCTAssertEqual(reconstructed, full.rgba)
    }

    func testLongTextTilesKeepSingleGlyphHeightInsteadOfShrinking() throws {
        let glyph = try raster("M")
        let text = String(repeating: "M", count: 220)
        let tiled = try XCTUnwrap(TextRasterizer.renderTiles(text: text, fontData: nil,
                                                            systemFontName: "systemfont_arial", pointSize: 12))
        XCTAssertGreaterThan(tiled.width, 8192)
        XCTAssertEqual(tiled.height, glyph.height)
        XCTAssertGreaterThan(tiled.tiles.count, 1)
    }

    func testBlurClampsHugeFiniteRadiusBeforeIntegerConversion() {
        let pixels = Data([255, 128, 64, 255])
        XCTAssertEqual(TextBitmapStyle.blur(pixels, width: 1, height: 1, radius: .greatestFiniteMagnitude),
                       TextBitmapStyle.blur(pixels, width: 1, height: 1, radius: 511))
        XCTAssertEqual(TextBitmapStyle.blur(pixels, width: 1, height: 1, radius: .infinity), pixels)
        XCTAssertEqual(TextBitmapStyle.blur(pixels, width: 1, height: 1, radius: .nan), pixels)
    }

    func testTileBudgetRejectsInvalidDimensionsAndExcessiveTileCount() {
        XCTAssertNil(TextRasterizer.renderTiles(text: "A", fontData: nil, systemFontName: nil,
                                               pointSize: 12, tileDimension: 0))
        XCTAssertNil(TextRasterizer.renderTiles(text: "A", fontData: nil, systemFontName: nil,
                                               pointSize: 12, tileDimension: 8193))
        XCTAssertNil(TextRasterizer.renderTiles(text: String(repeating: "M", count: 220), fontData: nil,
                                               systemFontName: "systemfont_arial", pointSize: 12, tileDimension: 1))
    }
}
