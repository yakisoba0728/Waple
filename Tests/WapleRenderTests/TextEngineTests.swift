import XCTest
import Metal
import CoreText
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
        XCTAssertNil(TextScriptEngine(script: "export function update(v) { while (1) { } return 'x'; }"))
        XCTAssertNil(TextScriptEngine(script: "export function update(v) { for (;;) { } return 'x'; }"))
        XCTAssertNil(TextScriptEngine(script: "export function update(v) { for (let i = 0; i < 1e12; i++) {} return 'x'; }"))
        // 문자열을 스킵해도(감사 W-B6) 조건식 자체의 거대 상한은 여전히 거부.
        XCTAssertNil(TextScriptEngine(script: "export function update(v) { for (var i = 0; i < \"x\".length + 99999999; i++) {} return 'x'; }"))
    }

    /// 감사 W-B4 회귀: `)` 뒤 정규식 리터럴(`if (ok) /export /`)은 렉서의 정규식 판정이 놓치는 위치 —
    /// 내부 export 를 키워드로 삭제하면 `/ /` 오염이 생긴다. 원문이 그대로 보존돼야 한다.
    func testRegexLiteralAfterParenKeepsExportInside() {
        let src = "if (ok) /export /.test(s) && run();"
        XCTAssertEqual(TextScriptEngine.stripModuleSyntax(src), src)
    }

    /// 감사 W-B5 회귀: minified `import*as e from"m"` (as 주변 공백 없음)도 네임스페이스 바인딩을 만든다.
    func testMinifiedNamespaceImportKeepsBinding() {
        let out = TextScriptEngine.stripModuleSyntax("import*as e from\"m\";e.x();")
        XCTAssertTrue(out.contains("var e = __noopProxy();"), "바인딩 소실: \(out)")
        XCTAssertTrue(out.contains("e.x();"), out)
    }

    /// 감사 W-B6 회귀: for 조건의 문자열 리터럴 속 8자리 숫자(`table["16094592"]`)는
    /// 무한루프 오탐 사유가 아니다 — 정상 스크립트가 로드·실행돼야 한다.
    func testForLoopBoundInsideStringLiteralNotRejected() throws {
        let script = """
        export function update(v) {
            var table = { "16094592": ["a", "b"] };
            var s = "";
            for (var i = 0; i < table["16094592"].length; i++) { s += table["16094592"][i]; }
            return s;
        }
        """
        let e = try XCTUnwrap(TextScriptEngine(script: script), "문자열 속 숫자를 루프 상한으로 오탐")
        XCTAssertEqual(e.evaluate(current: ""), "ab")
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

    private func family(_ f: CTFont) -> String { CTFontCopyFamilyName(f) as String }

    func testComicSansAliasResolvesRealFamily() {
        // 번들 스모크: Comic Sans MS 미설치 환경이면 단언 완화(비-"Comicsans" 실폰트만 확인)
        let smoke = CTFontCreateWithName("Comic Sans MS" as CFString, 12, nil)
        let f = TextRasterizer.resolveSystemFont("systemfont_comicsans", pointSize: 16)
        if family(smoke) == "Comic Sans MS" {
            XCTAssertEqual(family(f), "Comic Sans MS")
        } else {
            XCTAssertNotEqual(family(f).lowercased(), "comicsans")
        }
    }

    func testSansserifResolvesRealSystemFont() {
        let fam = family(TextRasterizer.resolveSystemFont("systemfont_sansserif", pointSize: 16))
        XCTAssertFalse(fam.isEmpty)
        XCTAssertNotEqual(fam.lowercased(), "sansserif", "비실존 'Sansserif' 이름이 그대로 새면 안 됨")
    }

    func testUnknownNameDemotesToSystemFallback() throws {
        // 미설치명: 조용한 오폰트 대신 명시적 시스템 폴백 — 크래시/빈 렌더 없음
        let fam = family(TextRasterizer.resolveSystemFont("systemfont_notarealfontxyz", pointSize: 16))
        XCTAssertNotEqual(fam.lowercased(), "notarealfontxyz")
        let r = try XCTUnwrap(TextRasterizer.render(
            text: "Hi", fontData: nil, systemFontName: "systemfont_notarealfontxyz", pointSize: 32))
        XCTAssertGreaterThan(r.width, 4)
        XCTAssertGreaterThan(r.height, 4)
    }

    func testArialNoRegression() {
        XCTAssertEqual(family(TextRasterizer.resolveSystemFont("systemfont_arial", pointSize: 16)), "Arial")
        // 별칭 외 설치 폰트(예: menlo)도 검증 통과로 유지되는지 — 강등 오탐 방지
        XCTAssertEqual(family(TextRasterizer.resolveSystemFont("systemfont_menlo", pointSize: 16)), "Menlo")
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

    func testEvaluateVecPassesVecObjectsWithCopyAndMultiply() throws {
        let vec2 = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            return v.copy().multiply(new Vec2(2, 3));
        }
        """))
        XCTAssertEqual(try XCTUnwrap(vec2.evaluateVec(current: [2, 4])), [4, 12])

        let vec3 = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            return v.copy().multiply(new Vec3(2, 3, 4));
        }
        """))
        XCTAssertEqual(try XCTUnwrap(vec3.evaluateVec(current: [2, 4, 6])), [4, 12, 24])
    }

    func testInitReceivesCopiedVecAndRunsOnceBeforeFirstStandaloneUpdate() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: """
        var initCount = 0;
        var seeded = new Vec3(0, 0, 0);
        export function init(value) {
            initCount += 1;
            seeded = value.copy().multiply(new Vec3(2, 3, 4));
            value.x = 99;
        }
        export function update(value) {
            return new Vec3(seeded.x + value.x + initCount,
                            seeded.y + value.y + initCount,
                            seeded.z + value.z + initCount);
        }
        """))

        let first = try XCTUnwrap(e.evaluateVec(current: [1, 2, 3]))
        XCTAssertEqual(first, [4, 9, 16])

        let second = try XCTUnwrap(e.evaluateVec(current: [4, 5, 6]))
        XCTAssertEqual(second, [7, 12, 19])
    }

    func testBasicWallpaperEngineSceneTextureCameraAudioShims() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(value) {
            var camera = thisScene.getCamera();
            var texture = thisLayer.getTexture(0);
            texture.animation.setFrame(3);
            return new Vec3(camera.position.copy().x + texture.size.x,
                            thisScene.size.copy().y + texture.animation.frame,
                            engine.audio.left[0] + audioBuffer.right[0]);
        }
        """))

        let out = try XCTUnwrap(e.evaluateVec(current: [0, 0, 0]))

        XCTAssertEqual(out, [1, 1083, 0])
    }

    func testWallpaperEngineSceneLayerCompatibilityShims() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(value) {
            shared.camera.targetPosition = new Vec3(0, 0.82, 0);
            shared.miTextContainerScale.x = 2;
            var created = thisScene.createLayer("child");
            created.getTextureAnimation().setFrame(5);
            created.getAnimationLayer("Surprise").setBlend(0.5).getTextureAnimation().setRate(2);
            thisLayer.addChild(created);
            var camera = thisScene.getCameraTransforms();
            camera.targetAngles = new Vec3(1, 2, 3);
            thisScene.setCameraTransforms(camera);
            return new Vec3(thisScene.getLayerIndex(thisLayer) + thisScene.enumerateLayers().length,
                            created.getParent() === thisLayer ? created.getTextureAnimation().getFrame() : -1,
                            shared.miTextContainerScale.x + thisScene.getCameraTransforms().targetAngles.z);
        }
        """))

        let out = try XCTUnwrap(e.evaluateVec(current: [0, 0, 0]))

        XCTAssertEqual(out, [2, 5, 5])
    }

    func testColorMixAndRootParentCompatibilityShims() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: """
        import * as WEColor from 'WEColor';
        shared.miPrimaryColor = WEColor.hsv2rgb({ x: 0, y: 1, z: 1 });
        shared.miTextBgColor = new Vec3(0, 0, 1);
        export function update(value) {
            var mixed = shared.miPrimaryColor.mix(shared.miTextBgColor, 0.25);
            var parent = thisLayer.getParent().getParent();
            return new Vec3(mixed.x, mixed.z, parent.visible ? 1 : 0);
        }
        """))

        let out = try XCTUnwrap(e.evaluateVec(current: [0, 0, 0]))

        XCTAssertEqual(out[0], 0.75, accuracy: 1e-4)
        XCTAssertEqual(out[1], 0.25, accuracy: 1e-4)
        XCTAssertEqual(out[2], 1, accuracy: 1e-4)
    }

    func testNamedLayerFallbacksForMusicPlayerScripts() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: """
        let playerLayers = [];
        let playerExceptions = [];
        let appearAnim = thisScene.getLayer("playeroutlineanim").getTextureAnimation();
        export function init(value) {
            thisScene.enumerateLayers().forEach(element => {
                if (element.name.includes("player") && element.visible) {
                    if (element.name.includes("exception")) {
                        playerExceptions.push(element);
                    }
                    playerLayers.push(element);
                }
            });
            appearAnim.setFrame(3);
        }
        export function update(value) {
            playerLayers.forEach(element => { element.alpha = Math.max(element.alpha - 0.25, 0); });
            shared.uiopacity = playerLayers[0].alpha;
            return value + shared.uiopacity + appearAnim.getFrame();
        }
        """))

        let out = try XCTUnwrap(e.evaluateVec(current: [1]))

        XCTAssertEqual(out[0], 4.75, accuracy: 1e-4)
    }
}
