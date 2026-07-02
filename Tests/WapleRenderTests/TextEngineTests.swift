import XCTest
@testable import WapleRender

final class TextEngineTests: XCTestCase {
    /// 실물 WE 시계 스크립트 패턴(createScriptProperties + export function update) → 현재 HH:MM.
    func testClockScriptReturnsCurrentTime() throws {
        let script = """
        'use strict';
        export let __workshopId = '123';
        export var scriptProperties = createScriptProperties()
            .addCheckbox({ name: 'use24hFormat', value: true })
            .addCheckbox({ name: 'showSeconds', value: false })
            .addText({ name: 'delimiter', value: ':' })
            .finish();
        export function update(value) {
            let time = new Date();
            var hours = ("00" + time.getHours()).slice(-2);
            let minutes = ("00" + time.getMinutes()).slice(-2);
            return hours + scriptProperties.delimiter + minutes;
        }
        """
        let engine = try XCTUnwrap(TextScriptEngine(script: script))
        let out = try XCTUnwrap(engine.evaluate(current: ""))
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let now = f.string(from: Date())
        let oneMinuteLater = f.string(from: Date(timeIntervalSinceNow: 60))
        XCTAssertTrue(out == now || out == oneMinuteLater, "got \(out), expected \(now)")
    }

    /// engine/shared 등 엔진 API 참조가 있어도(no-op 심) 죽지 않아야 한다.
    func testEngineAPIShimsDoNotCrash() throws {
        let script = """
        'use strict';
        export var scriptProperties = createScriptProperties().addText({name:'x', value:'v'}).finish();
        engine.registerMediaStatusListener(function(e){});
        shared.something = 1;
        export function update(value) { return 'ok' + scriptProperties.x; }
        """
        let engine = try XCTUnwrap(TextScriptEngine(script: script))
        XCTAssertEqual(engine.evaluate(current: ""), "okv")
    }

    /// 깨진 스크립트/update 부재 → nil (텍스트 비움, graceful).
    func testBrokenScriptReturnsNil() {
        XCTAssertNil(TextScriptEngine(script: "syntax error here ((("))
        if let e = TextScriptEngine(script: "var a = 1;") {  // update 없음
            XCTAssertNil(e.evaluate(current: ""))
        }
    }
}

final class TextRasterizerTests: XCTestCase {
    func testRasterizesGlyphs() throws {
        let r = try XCTUnwrap(TextRasterizer.render(text: "Hi", fontData: nil, systemFontName: nil, pointSize: 32))
        XCTAssertGreaterThan(r.width, 4)
        XCTAssertGreaterThan(r.height, 4)
        // 흰색 글리프 + 알파(straight): 알파>0 픽셀이 존재해야
        var hasInk = false
        r.rgba.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var i = 3
            while i < p.count { if p[i] > 128 { hasInk = true; break }; i += 4 }
        }
        XCTAssertTrue(hasInk, "글리프 픽셀 없음")
    }

    func testEmptyTextReturnsNil() {
        XCTAssertNil(TextRasterizer.render(text: "", fontData: nil, systemFontName: nil, pointSize: 32))
        XCTAssertNil(TextRasterizer.render(text: "   ", fontData: nil, systemFontName: nil, pointSize: 32))
    }
}
