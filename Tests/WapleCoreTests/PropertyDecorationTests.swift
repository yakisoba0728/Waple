import XCTest
@testable import WapleCore

final class PropertyDecorationTests: XCTestCase {
    private func prop(key: String, text: String? = nil, condition: String? = nil) -> WallpaperProperty {
        WallpaperProperty(key: key, type: "bool", value: .bool(true),
                          order: nil, condition: condition, text: text)
    }

    func testImgsrcKeysHidden() {
        XCTAssertTrue(PropertyDecoration.isDecoration(prop(key: "imgsrc_banner")))
        XCTAssertTrue(PropertyDecoration.isDecoration(prop(key: "brimgsrc1")))
        XCTAssertTrue(PropertyDecoration.isDecoration(prop(key: "IMGSRC_ad")), "대소문자 무시")
    }

    func testHtmlTextHidden() {
        XCTAssertTrue(PropertyDecoration.isDecoration(prop(key: "note", text: "<img src=ad.png>")))
        XCTAssertTrue(PropertyDecoration.isDecoration(prop(key: "note", text: "Visit <A HREF=x>here</A>")))
        XCTAssertTrue(PropertyDecoration.isDecoration(prop(key: "sep", text: "<hr>")))
    }

    func testNormalPropertiesVisible() {
        XCTAssertFalse(PropertyDecoration.isDecoration(prop(key: "brightness", text: "Brightness")))
        XCTAssertFalse(PropertyDecoration.isDecoration(prop(key: "color")), "text nil → 편집 대상")
        XCTAssertFalse(PropertyDecoration.isDecoration(prop(key: "wave", text: "Wave amount")),
                       "일반 단어(wave)는 <a 아님")
    }

    func testVisibleIndicesComposesConditionAndDecoration() {
        let props = [
            prop(key: "brightness", text: "Brightness"),        // 0: 표시
            prop(key: "imgsrc_ad", text: "ad"),                 // 1: 장식(key)
            prop(key: "note", text: "<img>"),                   // 2: 장식(text)
            prop(key: "hidden", text: "H", condition: "false"), // 3: 조건으로 숨김
        ]
        XCTAssertEqual(PropertyDecoration.visibleIndices(in: props), [0],
                       "조건 통과 + 비장식만 표시")
    }

    /// WE 브라우저 템플릿이 아는 유일한 장식 타입 — 편집 위젯 없이 `<hr>` 하나를 그린다
    /// (`browseruserproperties.html`: `ng-if="property.type==\'divider\'"`).
    func testDividerTypeIsDecorationRegardlessOfKeyAndText() {
        XCTAssertTrue(PropertyDecoration.isDecoration(
            WallpaperProperty(key: "sep1", type: "divider", value: .none, order: 0, condition: nil)))
        XCTAssertTrue(PropertyDecoration.isDecoration(
            WallpaperProperty(key: "sep2", type: "DIVIDER", value: .none, order: 0, condition: nil,
                              text: "Section")), "대소문자 무시")
        XCTAssertFalse(PropertyDecoration.isDecoration(
            WallpaperProperty(key: "amount", type: "slider", value: .number(1), order: 0, condition: nil,
                              text: "Amount")), "일반 위젯은 그대로 편집 대상")
    }
}
