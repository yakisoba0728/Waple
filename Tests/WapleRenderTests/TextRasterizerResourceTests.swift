import XCTest
@testable import WapleRender

final class TextRasterizerResourceTests: XCTestCase {
    func testRejectsNonFinitePointSizes() {
        XCTAssertNil(TextRasterizer.render(text: "Hi", fontData: nil, systemFontName: nil, pointSize: .infinity))
        XCTAssertNil(TextRasterizer.render(text: "Hi", fontData: nil, systemFontName: nil, pointSize: .nan))
    }

    func testFiniteAuthoredPointSizesClampToWEEndpoints() throws {
        let minimum = try XCTUnwrap(TextRasterizer.render(text: "Hi", fontData: nil, systemFontName: nil, pointSize: 1))
        let maximum = try XCTUnwrap(TextRasterizer.render(text: "Hi", fontData: nil, systemFontName: nil, pointSize: 256))
        let below = try XCTUnwrap(TextRasterizer.render(text: "Hi", fontData: nil, systemFontName: nil, pointSize: -10))
        let above = try XCTUnwrap(TextRasterizer.render(text: "Hi", fontData: nil, systemFontName: nil, pointSize: 1_000_000))
        XCTAssertEqual(below.rgba, minimum.rgba)
        XCTAssertEqual(below.width, minimum.width)
        XCTAssertEqual(above.rgba, maximum.rgba)
        XCTAssertEqual(above.width, maximum.width)
    }
}
