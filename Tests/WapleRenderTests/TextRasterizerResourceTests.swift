import XCTest
@testable import WapleRender

final class TextRasterizerResourceTests: XCTestCase {
    func testRejectsNonFiniteAndHugePointSizes() {
        XCTAssertNil(TextRasterizer.render(text: "Hi", fontData: nil, systemFontName: nil, pointSize: .infinity))
        XCTAssertNil(TextRasterizer.render(text: "Hi", fontData: nil, systemFontName: nil, pointSize: 1_000_000))
    }
}
