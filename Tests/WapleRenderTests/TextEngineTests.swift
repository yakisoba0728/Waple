import XCTest
import Metal
@testable import WapleCore
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

    /// ES import 구문(실물 다수) → 바인딩을 no-op 프록시로 치환해 로드가 죽지 않아야 한다.
    func testImportStatementsNeutralized() throws {
        let script = """
        'use strict';
        import * as utils from './utils.js';
        import helper from './helper.js';
        import { a, b } from './ab.js';
        export function update(value) { utils.doThing(); return 'ran' + a; }
        """
        let engine = try XCTUnwrap(TextScriptEngine(script: script), "import 가 로드를 막으면 안 됨")
        // utils.doThing() 은 no-op 프록시로 통과; 'ran' + proxy → 문자열화
        XCTAssertNotNil(engine.evaluate(current: ""))
    }

    /// 깨진 스크립트/update 부재 → nil (텍스트 비움, graceful).
    func testBrokenScriptReturnsNil() {
        XCTAssertNil(TextScriptEngine(script: "syntax error here ((("))
        if let e = TextScriptEngine(script: "var a = 1;") {  // update 없음
            XCTAssertNil(e.evaluate(current: ""))
        }
    }

    /// 실물 난독화 텍스트 스크립트(3395777145 등): 한 줄 minified 소스의 mid-line `export` 를
    /// 벗겨야 로드된다(줄 단위 스트리퍼는 실패했던 클래스).
    func testMinifiedMidLineExportStripped() throws {
        let script = "'use strict';var _a=(function(){return 1;})();export var scriptProperties=createScriptProperties().addText({name:'t',value:'x'}).finish();export function update(v){return 'ok'+scriptProperties.t+_a;}"
        let engine = try XCTUnwrap(TextScriptEngine(script: script), "mid-line export 가 로드를 막으면 안 됨")
        XCTAssertEqual(engine.evaluate(current: ""), "okx1")
    }

    /// 한 줄에 흩뿌린 import 도 no-op 바인딩으로 치환(WEColor 는 실심).
    func testMidLineImportNeutralized() throws {
        let script = "'use strict';var x=1;import * as WEColor from 'WEColor';export function update(v){return String(x)+(typeof WEColor.hsv2rgb);}"
        let e = try XCTUnwrap(TextScriptEngine(script: script))
        XCTAssertEqual(e.evaluate(current: ""), "1function")
    }

    /// 문자열 리터럴 속 'export' 는 오폭하지 않는다.
    func testExportInsideStringLiteralPreserved() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: "'use strict';export function update(v){return 'export me';}"))
        XCTAssertEqual(e.evaluate(current: ""), "export me")
    }

    /// stripModuleSyntax 토큰 경계: 동적 import(...)/import.meta, 멤버 접근, 프로퍼티 키는 불간섭.
    func testStripModuleSyntaxDoesNotFalsePositive() {
        XCTAssertEqual(TextScriptEngine.stripModuleSyntax("var p = import('m');"), "var p = import('m');")
        XCTAssertEqual(TextScriptEngine.stripModuleSyntax("var o = {export: 1};"), "var o = {export: 1};")
        XCTAssertEqual(TextScriptEngine.stripModuleSyntax("a.export();"), "a.export();")
        let stripped = TextScriptEngine.stripModuleSyntax("export function f(){}")
        XCTAssertTrue(stripped.contains("function f"))
        XCTAssertFalse(stripped.contains("export"))
    }

    /// 회귀: 마침표로 끝나는 주석(`//...break.`) 뒤의 export 를 멤버 접근으로 오판하면 안 된다
    /// (주석은 코드 토큰이 아니므로 prevSig 불변 — 실물 다수 씬의 워크샵 헤더 주석).
    func testExportAfterCommentEndingInPeriodStripped() throws {
        let script = "'use strict';\n// Please note: Do not remove this line or asset references may break.\nexport let __workshopId = '1';\nexport function update(v){ return 'ok'; }"
        let e = try XCTUnwrap(TextScriptEngine(script: script), "마침표 주석 뒤 export 가 로드를 막으면 안 됨")
        XCTAssertEqual(e.evaluate(current: ""), "ok")
        let out = TextScriptEngine.stripModuleSyntax(script)
        XCTAssertFalse(out.contains("export "), "export 키워드가 남음")
        XCTAssertTrue(out.contains("may break."), "주석 원문은 보존")
    }

    func testRegexLiteralContainingModuleKeywordsPreserved() throws {
        let script = """
        export function update(v) {
            return /export\\s+default/.test(v) ? 'hit' : 'miss';
        }
        """
        let e = try XCTUnwrap(TextScriptEngine(script: script))
        XCTAssertEqual(e.evaluate(current: "export default"), "hit")
    }

    func testComboWithoutValueUsesDefaultOrFirstOption() throws {
        let script = """
        export var scriptProperties = createScriptProperties()
            .addCombo({ name: 'quality', options: [{ value: 'low' }, { value: 'high' }], default: 'high' })
            .addCombo({ name: 'mode', options: ['soft', 'hard'] })
            .finish();
        export function update(v) { return scriptProperties.quality + '/' + scriptProperties.mode; }
        """
        let e = try XCTUnwrap(TextScriptEngine(script: script))
        XCTAssertEqual(e.evaluate(current: ""), "high/soft")
    }

    func testObviousUnboundedLoopsRejectedBeforeUpdateCanHang() {
        XCTAssertNil(TextScriptEngine(script: "export function update(v) { while (true) { } return 'x'; }"))
        XCTAssertNil(TextScriptEngine(script: "export function update(v) { for (;;) { } return 'x'; }"))
    }
}

final class ScriptedTextRuntimeTests: XCTestCase {
    func testRefreshScriptedTextsUpdatesEngineRuntime() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let engine = try XCTUnwrap(TextScriptEngine(script: "export function update(v) { return String(parseInt(engine.runtime)); }"))
        let def = SceneTextLayer(text: "", script: nil, font: "systemfont_arial", pointSize: 16,
                                 color: Vec3(x: 1, y: 1, z: 1), alpha: 1,
                                 horizontalAlign: "center", verticalAlign: "center",
                                 origin: Vec2(x: 0, y: 0), scale: Vec2(x: 1, y: 1))
        let renderer = SceneRenderer()
        renderer.hasScriptedText = true
        renderer.lastTextRefreshSecond = -1
        renderer.textLayers = [SceneRenderer.GPUText(texture: nil, vertexBuffer: nil,
                                                     tint: SIMD4<Float>(1, 1, 1, 1), order: 0,
                                                     engine: engine, lastText: "0",
                                                     fontData: nil, systemFontName: "systemfont_arial",
                                                     def: def)]

        renderer.refreshScriptedTexts(device: device, time: 3.2)

        XCTAssertEqual(renderer.textLayers.first?.lastText, "3")
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

/// 효과 상수 스크립트: WEColor 실심 + engine.runtime + evaluateVec (실물 컬러 사이클 패턴).
final class ConstantScriptTests: XCTestCase {
    private let hueCycle = """
    export let scriptProperties = createScriptProperties()
        .addSlider({ name: 'speed', value: 0.25, min: 0, max: 1 }).finish();
    import * as WEColor from 'WEColor';
    export function update(value) {
        return WEColor.hsv2rgb({ x: engine.runtime * scriptProperties.speed, y: 1, z: 1 });
    }
    """

    func testHueCycleUsesRuntimeAndWEColor() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: hueCycle))
        e.setRuntime(0)
        let red = try XCTUnwrap(e.evaluateVec(current: [1, 0, 0]))
        XCTAssertEqual(red[0], 1, accuracy: 1e-4)
        XCTAssertEqual(red[1], 0, accuracy: 1e-4)
        e.setRuntime(2.0)  // hue = 0.5 → cyan
        let cyan = try XCTUnwrap(e.evaluateVec(current: [1, 0, 0]))
        XCTAssertEqual(cyan[0], 0, accuracy: 1e-4)
        XCTAssertEqual(cyan[1], 1, accuracy: 1e-4)
        XCTAssertEqual(cyan[2], 1, accuracy: 1e-4)
    }

    func testScalarScript() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: "export function update(v) { return v * 2 + engine.runtime; }"))
        e.setRuntime(1)
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [3])).first ?? 0, 7, accuracy: 1e-4)
    }

    func testVec2ScriptReturnsTwoComponents() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: "export function update(v) { return new Vec2(v.x * 2, v.y * 3); }"))

        let out = try XCTUnwrap(e.evaluateVec(current: [2, 4, 1]))

        XCTAssertEqual(out, [4, 12])
    }
}
