import XCTest
@testable import Waple

final class PropertyLabelTests: XCTestCase {
    func testHTMLStripped() {
        XCTAssertEqual(PropertyLabel.pretty(text: "<b>Color</b>", key: "c"), "Color")
    }
    func testLocalizationKeyPrettified() {
        XCTAssertEqual(PropertyLabel.pretty(text: "ui_browse_properties_scheme_color", key: "schemecolor"),
                       "Scheme color")
        XCTAssertEqual(PropertyLabel.pretty(text: nil, key: "playback_speed"), "Playback speed")
    }
    func testNormalTextPassesThrough() {
        XCTAssertEqual(PropertyLabel.pretty(text: "재생 속도", key: "rate"), "재생 속도")
    }
}
