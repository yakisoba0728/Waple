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
        // out(JS, L26)은 now(Swift, L28)보다 항상 먼저 읽힌다 — 그 사이에 분 경계를 넘으면 out 은
        // "이전" 분을 가리킨다. 따라서 물리적으로 도달 가능한 창은 {now-1, now}뿐이고 now+1 은 불가능
        // (감사 T4 — 종전엔 반대 방향(now+1)을 허용하고 실제로 발생하는 now-1 은 안 잡아 드물게 spurious FAIL).
        let oneMinuteEarlier = f.string(from: Date(timeIntervalSinceNow: -60))
        XCTAssertTrue(out == now || out == oneMinuteEarlier, "got \(out), expected \(now) or \(oneMinuteEarlier)")
    }

    /// W3-③: 스크립트가 undefined 피연산자로 NaN 을 만들어내고(WEMath.mix(a,b,undefined) 패턴) 그 값을
    /// **기존 Vec3 를 직접 변경**(재구성 아닌 프로퍼티 대입)해 반환하면 evaluateVec 은 그 NaN 성분을
    /// 그대로 통과시키면 안 되고 nil(호출부가 "이전 프레임 값 유지"로 처리)을 반환해야 한다. `new Vec3(x,y,z)`
    /// 재구성 경로는 생성자의 `x||0` 관용구가 NaN 을 0 으로 이미 가리므로(별개의 기존 완화), 프로퍼티
    /// 직접 대입 경로가 Swift 경계에 원시 NaN 이 실제로 도달하는 대표 사례다.
    func testEvaluateVecRejectsNaNComponent() throws {
        let engine = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v){ v.z = v.z * undefined; return v; }"))
        XCTAssertNil(engine.evaluateVec(current: [1, 2, 3]), "NaN 성분 포함 벡터는 거부(이전값 유지)돼야 함")
    }

    /// Infinity 성분(0 나눗셈 등)도 동일하게 거부 — 스칼라 단일값 경로도 함께 커버.
    func testEvaluateVecRejectsInfiniteScalar() throws {
        let engine = try XCTUnwrap(TextScriptEngine(script: "export function update(v){ return 1 / 0; }"))
        XCTAssertNil(engine.evaluateVec(current: [1]), "Infinity 스칼라는 거부돼야 함")
    }

    /// 회귀 가드: 유한값 벡터는 종전대로 통과.
    func testEvaluateVecPassesFiniteVector() throws {
        let engine = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v){ return new Vec3(v.x + 1, v.y + 1, v.z + 1); }"))
        XCTAssertEqual(engine.evaluateVec(current: [1, 2, 3]), [2, 3, 4])
    }

    /// createScriptProperties 심이 저장된 scriptproperties(사용자 오버라이드)를 소스 기본값보다 우선하는지.
    /// 미주입 시 Background color 스크립트가 소스 기본값 흰색(new Vec3(1,1,1))을 fallback 으로 반환 →
    /// 텍스처 tint=(1,1,1) 로 전화면 백화(3300031038 luma 0.9999). addColor 오버라이드는 "r g b" 문자열이라
    /// Vec3 로 변환해야 스크립트의 .x/.y/.z·.subtract 접근이 성립(문자열 주입 시 예외로 오히려 악화).
    func testScriptPropertiesOverrideInjection() throws {
        let script = """
        export var scriptProperties = createScriptProperties()
            .addColor({ name: 'c', value: new Vec3(1, 1, 1) })
            .addSlider({ name: 's', value: 0 })
            .addCheckbox({ name: 'flag', value: false })
            .finish();
        export function update(value) {
            var c = scriptProperties.c;
            return c.x.toFixed(3) + ' ' + c.y.toFixed(3) + ' ' + c.z.toFixed(3)
                + ' s=' + scriptProperties.s + ' flag=' + scriptProperties.flag;
        }
        """
        // 오버라이드 미주입 → 소스 기본값(흰색·0·false) 유지(무회귀 경로).
        let base = try XCTUnwrap(TextScriptEngine(script: script))
        XCTAssertEqual(base.evaluate(current: ""), "1.000 1.000 1.000 s=0 flag=false")
        // 오버라이드 주입: addColor 는 "r g b" 문자열→Vec3, slider=숫자, checkbox=bool.
        let ov = #"{"c":"0.322 0.231 0.416","s":5,"flag":true}"#
        let fixed = try XCTUnwrap(TextScriptEngine(script: script, scriptPropsJSON: ov))
        XCTAssertEqual(fixed.evaluate(current: ""), "0.322 0.231 0.416 s=5 flag=true")
    }

    /// end-to-end 재현체(코퍼스 3000562427 mainClock 등 117씬 패턴): 텍스트 레이어의 저장
    /// `scriptproperties`(showSeconds=true override, 소스 기본 false)가 parseText→buildTexts→
    /// makeScriptEngine 를 관통해 초기 렌더 텍스트에 반영되는지. 미배선 시 소스 기본값으로 폴백해
    /// 초 없는 "HH:MM"(콜론 1)만 나온다. captureDateEpochMillis 로 시각 고정(초="00" 결정성).
    func testTextScriptPropsWiredThroughBuildTexts() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        TextScriptEngine.captureDateEpochMillis = 1_704_110_400_000
        defer { TextScriptEngine.captureDateEpochMillis = nil }
        let clock = """
        'use strict';
        export var scriptProperties = createScriptProperties()
            .addCheckbox({ name: 'showSeconds', value: false })
            .addText({ name: 'delimiter', value: ':' })
            .finish();
        export function update(value) {
            var t = new Date();
            var hh = ("00" + t.getHours()).slice(-2);
            var mm = ("00" + t.getMinutes()).slice(-2);
            var out = hh + scriptProperties.delimiter + mm;
            if (scriptProperties.showSeconds) { out += scriptProperties.delimiter + ("00" + t.getSeconds()).slice(-2); }
            return out;
        }
        """
        func firstRenderedText(withOverride: Bool) throws -> String {
            var text: [String: Any] = ["script": clock, "value": ""]
            if withOverride { text["scriptproperties"] = ["showSeconds": true] }
            let scene: [String: Any] = [
                "general": ["orthogonalprojection": ["width": 100, "height": 100], "clearcolor": "0 0 0"],
                "objects": [["id": 1, "name": "Clock", "text": text, "font": "systemfont_arial",
                             "origin": "50 50 0", "pointsize": 16]]
            ]
            let pkg = ScenePackage.assemble([(name: "scene.json", data: try JSONSerialization.data(withJSONObject: scene))])
            let doc = try SceneDocument.parse(package: pkg, userProps: [:])
            if withOverride {
                let js = try XCTUnwrap(doc.texts.first?.scriptProps, "파스가 scriptProps 보존")
                XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(js.utf8)) as? [String: Any])?["showSeconds"] as? Bool, true)
            } else {
                XCTAssertNil(doc.texts.first?.scriptProps, "오버라이드 없으면 nil(무회귀)")
            }
            return try XCTUnwrap(SceneRenderer().buildTexts(doc: doc, package: pkg, device: device).first?.lastText)
        }
        let base = try firstRenderedText(withOverride: false)
        let fixed = try firstRenderedText(withOverride: true)
        XCTAssertEqual(base.filter { $0 == ":" }.count, 1, "override 미주입 = 초 없음(base): \(base)")
        XCTAssertEqual(fixed.filter { $0 == ":" }.count, 2, "override 주입 = 초 표시(fix): \(fixed)")
        XCTAssertNotEqual(base, fixed, "저장 오버라이드가 렌더 텍스트를 WE 방향(초 표시)으로 이동")
    }

    /// captureDateEpochMillis 설정 시 시계 스크립트가 실 벽시계 대신 고정 epoch 를 렌더(캡처 결정성).
    /// S4①(2026-07-27) 정정: getHours() 는 dateOverrideJS 가 KST(UTC+9) 고정 오프셋으로 재계산하므로
    /// 기대값도 `TimeZone.current`(=호스트 TZ, 수정 전 버그와 동형 계산이라 같은 TZ 머신에서 우연히 통과)가
    /// 아니라 명시적 Asia/Seoul 로 계산 — CI/개발자 머신이 KST 가 아니어도 이 테스트가 그 사실을 잡아낸다.
    /// defer 로 프로세스 전역 static 을 리셋(XCTest 단일 프로세스 — 미복원 시 testClockScriptReturnsCurrentTime
    /// (실시각 검증)에 누수).
    func testCaptureDateEpochPinsClockAndDateNow() throws {
        let fixed: Double = 1_704_110_400_000   // 2024-01-01 12:00:00 UTC = 2024-01-01 21:00:00 KST
        TextScriptEngine.captureDateEpochMillis = fixed
        defer { TextScriptEngine.captureDateEpochMillis = nil }
        let script = """
        'use strict';
        export function update(value) {
            let t = new Date();
            var hh = ("00" + t.getHours()).slice(-2);
            var mm = ("00" + t.getMinutes()).slice(-2);
            var ss = ("00" + t.getSeconds()).slice(-2);
            return hh + ":" + mm + ":" + ss + "|" + Date.now();
        }
        """
        let engine = try XCTUnwrap(TextScriptEngine(script: script))
        let out = try XCTUnwrap(engine.evaluate(current: ""))
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        f.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"), "테스트 환경에 Asia/Seoul TZ 데이터 필요")
        let expected = f.string(from: Date(timeIntervalSince1970: fixed / 1000)) + "|\(Int(fixed))"
        XCTAssertEqual(out, expected, "고정 epoch 주입 시 Date 무인자/now 가 벽시계 아닌 FIXED(KST 해석)를 반환해야")
    }

    /// S4①(2026-07-27) 회귀: dateOverrideJS 의 로컬 getter(getHours 등)가 JS 엔진/OS 의 실제 시스템 TZ 로
    /// 위임하면 안 된다 — 위임하면 캡처를 실행하는 머신의 TZ 설정에 따라 hours 조건부 씬(예: 실물
    /// 3563096027, `hours>=21&&hours<24`)이 같은 커밋에서도 다른 픽셀을 낸다(실측: WapleCompat --capture 를
    /// TZ=Asia/Seoul vs TZ=UTC 로 동일 씬에 실행 시 56,578/2,073,600 바이트 상이, BACKLOG.md:144-145 참고).
    /// getTimezoneOffset()이 항상 -540(KST, DST 없음)을 반환하면 로컬 getter 가 R.prototype(호스트 TZ)이
    /// 아니라 하드코딩 오프셋 산술로 계산됐다는 증거 — 이 값은 호스트 TZ 데이터베이스를 전혀 참조하지
    /// 않으므로 이 테스트는 머신 TZ 와 무관하게 항상 같은 결과를 내야 한다.
    func testCaptureDateEpochLocalGettersAreTimezoneIndependent() throws {
        TextScriptEngine.captureDateEpochMillis = 1_704_110_400_000
        defer { TextScriptEngine.captureDateEpochMillis = nil }
        let script = """
        'use strict';
        export function update(value) { return String(new Date().getTimezoneOffset()); }
        """
        let engine = try XCTUnwrap(TextScriptEngine(script: script))
        XCTAssertEqual(try XCTUnwrap(engine.evaluate(current: "")), "-540",
                        "로컬 getter 는 호스트 TZ 가 아니라 KST 고정 오프셋 산술로 계산돼야(하네스 신뢰성)")
    }

    /// 인자 있는 `new Date(ms)` 는 오버라이드 무관(무인자/now 만 핀) — 실 Date 계산 보존 확인.
    func testCaptureDateEpochLeavesArgumentedDateIntact() throws {
        TextScriptEngine.captureDateEpochMillis = 1_704_110_400_000
        defer { TextScriptEngine.captureDateEpochMillis = nil }
        let script = """
        'use strict';
        export function update(value) { return String(new Date(0).getTime()) + "," + String(new Date(1000).getTime()); }
        """
        let engine = try XCTUnwrap(TextScriptEngine(script: script))
        XCTAssertEqual(try XCTUnwrap(engine.evaluate(current: "")), "0,1000")
    }

    /// H4: engine.registerAudioBuffers(res) 는 AudioBuffers{left,right,average}(res 길이) 동기반환, engine.audio.average
    /// 도 접근 가능해야 한다. 종전엔 registerAudioBuffers 가 콜백-등록(undefined 반환)이고 average 키가 없어
    /// buffers.average / audio.average.[i] 접근이 TypeError → 오디오응답 스크립트가 런타임에 죽었다(capture.log 30회).
    func testRegisterAudioBuffersAndAverageAvailable() throws {
        let script = """
        'use strict';
        export var scriptProperties = createScriptProperties().addText({name:'x', value:'v'}).finish();
        var buffers = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_64);
        export function update(value) {
            return String(buffers.average.length) + "," + String(engine.audio.average.length);
        }
        """
        let engine = try XCTUnwrap(TextScriptEngine(script: script))
        let out = try XCTUnwrap(engine.evaluate(current: ""))
        XCTAssertEqual(out, "64,64")
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

    /// isScreensaver 실배선: 프로세스 옵션이 engine.isScreensaver() 로 관측된다.
    /// 기본 false(하드코딩 제거 후에도 데스크탑 배경/캡처 경로 무변화 가드) + 옵션 true 반영.
    func testIsScreensaverReflectsProcessOption() throws {
        TextScriptEngine.isScreensaver = false
        let off = try XCTUnwrap(SceneScriptContext())
        XCTAssertEqual(off.context.evaluateScript("engine.isScreensaver()")?.toBool(), false,
                       "기본 false → 관측 false(캡처/기존 앱 무변화 가드)")

        TextScriptEngine.isScreensaver = true
        defer { TextScriptEngine.isScreensaver = false }
        let on = try XCTUnwrap(SceneScriptContext())
        XCTAssertEqual(on.context.evaluateScript("engine.isScreensaver()")?.toBool(), true,
                       "옵션 true → 관측 true")
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

    // ── 씬 스크립트 실데이터 주입(canvasSize/setTimeout/audio — 감사 O5/백로그) ────────

    /// 주입한 프로젝션 크기가 engine.canvasSize·thisScene.size/screenSize 로 보인다.
    /// 미주입(기본) 컨텍스트는 1920×1080 유지(무회귀).
    func testCanvasSizeReflectsInjectedProjectionSize() throws {
        let scene = try XCTUnwrap(SceneScriptContext(width: 2560, height: 1440))
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            return engine.canvasSize.x + 'x' + engine.canvasSize.y + '/' + thisScene.size.y + '/' + thisScene.screenSize.x;
        }
        """, scene: scene))
        XCTAssertEqual(e.evaluate(current: ""), "2560x1440/1440/2560")

        let def = try XCTUnwrap(SceneScriptContext())
        let d = try XCTUnwrap(TextScriptEngine(
            script: "export function update(v) { return engine.canvasSize.x + '/' + thisScene.size.y; }",
            scene: def))
        XCTAssertEqual(d.evaluate(current: ""), "1920/1080")
    }

    func testEngineBooleanCapabilitiesAreConcreteAndUnknownProxyRemainsTruthy() throws {
        let script = """
        export function update(value) {
            return [
                engine.isWallpaper(),
                engine.isDesktopDevice(),
                engine.isMobileDevice(),
                engine.isScreensaver(),
                engine.isRunningInEditor(),
                engine.isPortrait(),
                engine.isLandscape(),
                engine.unknownCapability().stillChains
            ].map(function(v) { return v ? '1' : '0'; }).join('');
        }
        """

        func flags(width: Float, height: Float) throws -> String {
            let scene = try XCTUnwrap(SceneScriptContext(width: width, height: height))
            let engine = try XCTUnwrap(TextScriptEngine(script: script, scene: scene))
            return try XCTUnwrap(engine.evaluate(current: ""))
        }

        XCTAssertEqual(try flags(width: 1920, height: 1080), "11000011")
        XCTAssertEqual(try flags(width: 600, height: 800), "11000101")
        XCTAssertEqual(try flags(width: 900, height: 900), "11000011")
    }

    /// engine.setTimeout: runtime 0→2 전진 시 만기순(동일 만기는 등록순) 1회 발화, clearTimeout 은 취소.
    func testEngineSetTimeoutFiresOnRuntimeAdvance() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        var fired = [];
        engine.setTimeout(function(){ fired.push('a'); }, 500);
        engine.setTimeout(function(){ fired.push('b'); }, 500);
        engine.setTimeout(function(){ fired.push('c'); }, 1000);
        var dead = engine.setTimeout(function(){ fired.push('x'); }, 100);
        engine.clearTimeout(dead);
        export function update(v) { return fired.join(''); }
        """, scene: scene))
        XCTAssertEqual(e.evaluate(current: ""), "")     // runtime 0 — 미발화
        e.setRuntime(2.0)
        XCTAssertEqual(e.evaluate(current: ""), "abc")  // 0.5s 2개 등록순 → 1.0s, x 는 취소
        e.setRuntime(3.0)
        XCTAssertEqual(e.evaluate(current: ""), "abc")  // 재발화 없음(1회)
    }

    /// setAudio: 스크립트가 audioBuffer.left16/engine.audio.left64/g_AudioSpectrum32Left 실값을 읽고,
    /// registerAudioBuffers 콜백이 setAudio 시 발화한다. (검사값은 2의 거듭제곱 분수 — 문자열 비교 안전)
    func testSetAudioFillsBuffersAndFiresRegisteredCallback() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: """
        var cb = -1;
        engine.registerAudioBuffers(function(buf) { cb = buf.right64[0]; });
        export function update(v) {
            return [audioBuffer.left16[0], engine.audio.left64[3], g_AudioSpectrum32Left[0], cb].join(',');
        }
        """, scene: scene))
        XCTAssertEqual(e.evaluate(current: ""), "0,0,0,-1")  // 주입 전: 버퍼 0, 콜백 미발화
        var l = [Float](repeating: 0, count: 64)
        l[0] = 0.25; l[1] = 0.75; l[2] = 0.25; l[3] = 0.75   // left16[0]=0.5, left32[0]=0.5
        var r = [Float](repeating: 0, count: 64)
        r[0] = 0.5
        scene.setAudio(left64: l, right64: r)
        XCTAssertEqual(e.evaluate(current: ""), "0.5,0.75,0.5,0.5")
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

    /// 감사 W-B7 회귀: 정규식 리터럴(/while (true)/, /for (;;)/) 내부의 루프 패턴은 무한루프 오탐
    /// 사유가 아니다 — 정상 스크립트가 로드·실행돼야 한다. 스킵 후의 실제 while (true) 는 여전히 거부.
    func testRegexLiteralContainingLoopPatternNotRejected() throws {
        // return 직후(키워드 경로)
        let e = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            return /while (true)/.source + '|' + v;
        }
        """), "return 직후 정규식 내부를 스캔해 오탐 거부")
        // .source 비교 — 패턴 속 괄호는 정규식 그룹이라 test() 리터럴 매칭은 부적합.
        XCTAssertEqual(e.evaluate(current: "ok"), "while (true)|ok")

        // 대입 연산자 직후(연산자 경로) + 플래그
        let e2 = try XCTUnwrap(TextScriptEngine(script: """
        var re = /for (;;)/g;
        export function update(v) { return re.source; }
        """), "= 직후 정규식 내부를 스캔해 오탐 거부")
        XCTAssertEqual(e2.evaluate(current: ""), "for (;;)")

        // 정규식 스킵이 뒤 코드를 삼키지 않음 — 실제 while (true) 는 여전히 거부.
        XCTAssertNil(TextScriptEngine(script: "var re = /x/; export function update(v) { while (true) {} return 'x'; }"))
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
        // F724: 1Hz 게이트(lastTextRefreshSecond) 폐기 — refresh 는 호출 즉시 재평가한다.
        renderer.textLayers = [SceneRenderer.GPUText(texture: nil, vertexBuffer: nil,
                                                     tint: SIMD4<Float>(1, 1, 1, 1), order: 0,
                                                     engine: engine, lastText: "0",
                                                     fontData: nil, systemFontName: "systemfont_arial",
                                                     def: def, uid: 0)]

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

    // ── B1: 멀티라인 세로 쌓기 + pointSize 300-DPI 스케일 (lane-01-text-raster) ──

    /// D-A: `\n` 분리 텍스트는 세로로 쌓여야 한다(단일 baseline 붕괴 금지).
    /// 붕괴 시 "A\nB\nC" → `\n` 제로폭 → "ABC" 한 줄(높이=1줄, 폭≈3배). 스케일 무관 비율로 단언.
    func testMultilineStacksVerticallyNotCollapsed() throws {
        let one = try XCTUnwrap(TextRasterizer.render(text: "A", fontData: nil, systemFontName: nil, pointSize: 24))
        let three = try XCTUnwrap(TextRasterizer.render(text: "A\nB\nC", fontData: nil, systemFontName: nil, pointSize: 24))
        XCTAssertGreaterThan(three.height, one.height * 2,
                             "3줄 높이가 1줄의 <2배 — 세로로 안 쌓임(baseline 붕괴)")
        XCTAssertLessThan(three.width, one.width * 2,
                          "3줄 폭이 1줄의 ≥2배 — 가로로 이어붙음(붕괴 증상)")
    }

    /// D-A: 빈 줄(`\n\n`, 앵커 2867182492 "Small Text" 실내용)도 한 줄 높이를 차지해야 한다.
    func testBlankLineOccupiesRow() throws {
        let two = try XCTUnwrap(TextRasterizer.render(text: "A\nB", fontData: nil, systemFontName: nil, pointSize: 24))
        let blank = try XCTUnwrap(TextRasterizer.render(text: "A\n\nB", fontData: nil, systemFontName: nil, pointSize: 24))
        XCTAssertGreaterThan(blank.height, two.height, "빈 줄이 높이에 반영되지 않음")
    }

    /// F2(flip②): TextRasterizer 가 래스터 끝에서 불필요한 상하반전을 하면 첫 줄과 마지막 줄이 뒤바뀐다.
    /// 잉크 밀도가 뚜렷이 다른 두 줄(빽빽한 첫 줄 "MMMMMM" vs 성긴 둘째 줄 ".")로 순서를 직접 단언 —
    /// 반전 버그가 있으면 상단 밴드(row 낮은 쪽)의 잉크가 적고 하단 밴드가 많다(뒤집힘).
    func testMultilineRowOrderNotFlipped() throws {
        let r = try XCTUnwrap(TextRasterizer.render(text: "MMMMMM\n.", fontData: nil, systemFontName: nil, pointSize: 24))
        let bytesPerRow = r.width * 4
        func inkCount(_ rowRange: Range<Int>) -> Int {
            var count = 0
            r.rgba.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                for row in rowRange {
                    let base = row * bytesPerRow
                    for x in stride(from: 0, to: bytesPerRow, by: 4) where p[base + x + 3] > 0 { count += 1 }
                }
            }
            return count
        }
        let mid = r.height / 2
        let topHalf = inkCount(0..<mid)
        let bottomHalf = inkCount(mid..<r.height)
        XCTAssertGreaterThan(topHalf, bottomHalf * 3,
                             "첫 줄(빽빽한 'MMMMMM')이 상단 밴드에 있어야 함 — 반전되면 성긴 '.'이 위로 옴 " +
                             "(top=\(topHalf), bottom=\(bottomHalf))")
    }

    /// D-B: pointSize 는 300-DPI 규약(≈×300/72≈4.17) — 화면 픽셀로 pointSize 의 ~5배 높이.
    /// 미적용 시 ~1.3배(asc+desc+lead)라 WE 대비 4~5배 작다. 하한 3×·상한 10×로 팩터를 괄호(정확값은 컨트롤러 픽셀대조).
    func testPointSizeScaledForWEDPI() throws {
        let ps: Float = 24
        let r = try XCTUnwrap(TextRasterizer.render(text: "A", fontData: nil, systemFontName: nil, pointSize: ps))
        XCTAssertGreaterThan(Float(r.height), ps * 3, "텍스트가 너무 작음(300-DPI 스케일 미적용)")
        XCTAssertLessThan(Float(r.height), ps * 10, "스케일 과대(팩터 오적용)")
    }

    /// 회귀 가드(2026-07-13 리뷰 Important): 4.17× DPI 스케일이 8192 래스터 상한을 조기 격발하는
    /// 장문/대형 텍스트가 nil(=드로우 스킵=조용한 소실) 이 아니라 축소 raster 로 수렴해야 한다.
    /// 종전(가드가 nil 반환)엔 XCTUnwrap 이 red — 텍스트가 통째로 사라졌다.
    func testOversizedTextScalesDownNotSilentlyLost() throws {
        let long = String(repeating: "A", count: 400)   // ps300×4.17DPI 면 폭 수십만 px = 8192 초과
        let r = try XCTUnwrap(TextRasterizer.render(text: long, fontData: nil, systemFontName: nil, pointSize: 300),
                              "장문 대형 텍스트가 nil(소실) 이 아니라 축소 raster 여야")
        XCTAssertLessThanOrEqual(r.width, 8192)
        XCTAssertLessThanOrEqual(r.height, 8192)
        XCTAssertGreaterThan(r.width, 1)
    }

    // ── P2: 폭 기반 워드랩 + 행 제한 + 말줄임 (limitwidth/maxwidth·limitrows/maxrows·limituseellipsis,
    //        WE 에디터 라벨 "Limit width/Max width/Limit rows/Max rows/Overflow ellipsis" 실측) ──

    /// 공백 단어 경계 워드랩: maxWidth 를 넘는 텍스트는 세로로 접히고 래스터 폭은 maxWidth 이내.
    func testWordWrapBreaksAtWordBoundary() throws {
        let flat = try XCTUnwrap(TextRasterizer.render(text: "aaaa bbbb", fontData: nil, systemFontName: nil, pointSize: 24))
        let mw = Float(flat.width) * 0.7
        let wrapped = try XCTUnwrap(TextRasterizer.render(text: "aaaa bbbb", fontData: nil, systemFontName: nil,
                                                          pointSize: 24, maxWidth: mw))
        XCTAssertGreaterThan(wrapped.height, flat.height, "폭 제한 초과인데 줄바꿈 안 됨")
        XCTAssertLessThanOrEqual(wrapped.width, Int(mw.rounded(.up)) + 2, "래스터 폭이 maxWidth 초과")
    }

    /// 여유 maxWidth(제한 비격발)면 무제한 경로와 동일 치수 — 워드랩 경로 자체의 무회귀.
    func testGenerousMaxWidthKeepsSingleLine() throws {
        let flat = try XCTUnwrap(TextRasterizer.render(text: "aaaa bbbb", fontData: nil, systemFontName: nil, pointSize: 24))
        let wide = try XCTUnwrap(TextRasterizer.render(text: "aaaa bbbb", fontData: nil, systemFontName: nil,
                                                       pointSize: 24, maxWidth: Float(flat.width) * 2))
        XCTAssertEqual(wide.width, flat.width)
        XCTAssertEqual(wide.height, flat.height)
    }

    /// 공백 없는 CJK(한글)도 문자 경계로 접힘(UAX#14 — CTTypesetter, 한글은 음절 단위 줄바꿈).
    func testWordWrapCJKBreaksPerCharacter() throws {
        let flat = try XCTUnwrap(TextRasterizer.render(text: "가나다라마바사", fontData: nil, systemFontName: nil, pointSize: 24))
        let wrapped = try XCTUnwrap(TextRasterizer.render(text: "가나다라마바사", fontData: nil, systemFontName: nil,
                                                          pointSize: 24, maxWidth: Float(flat.width) / 2))
        XCTAssertGreaterThan(wrapped.height, flat.height, "CJK 문자 단위 줄바꿈 안 됨")
    }

    /// maxWidth 보다 긴 단일 단어는 단어 내부 강제 분리(소실/오버플로 금지).
    func testWordWrapForcesBreakInsideOverlongWord() throws {
        let flat = try XCTUnwrap(TextRasterizer.render(text: "aaaaaaaaaaaaaaaa", fontData: nil, systemFontName: nil, pointSize: 24))
        let wrapped = try XCTUnwrap(TextRasterizer.render(text: "aaaaaaaaaaaaaaaa", fontData: nil, systemFontName: nil,
                                                          pointSize: 24, maxWidth: Float(flat.width) / 2))
        XCTAssertGreaterThan(wrapped.height, flat.height, "장단어 내부 분리 안 됨")
    }

    /// 행 제한: maxRows 초과 행은 잘림(높이 = maxRows 행 높이).
    func testRowLimitDropsExcessRows() throws {
        let two = try XCTUnwrap(TextRasterizer.render(text: "A\nB", fontData: nil, systemFontName: nil, pointSize: 24))
        let limited = try XCTUnwrap(TextRasterizer.render(text: "A\nB\nC\nD", fontData: nil, systemFontName: nil,
                                                          pointSize: 24, maxRows: 2))
        XCTAssertEqual(limited.height, two.height, "maxRows=2 인데 2행 높이가 아님")
    }

    /// 말줄임: 행 잘림 발생 시 마지막 행에 U+2026 부착("A…" 래스터와 동일 폭).
    func testEllipsisAppendedWhenRowsOverflow() throws {
        let one = try XCTUnwrap(TextRasterizer.render(text: "A", fontData: nil, systemFontName: nil, pointSize: 24))
        let ref = try XCTUnwrap(TextRasterizer.render(text: "A\u{2026}", fontData: nil, systemFontName: nil, pointSize: 24))
        let ell = try XCTUnwrap(TextRasterizer.render(text: "A\nB", fontData: nil, systemFontName: nil,
                                                      pointSize: 24, maxRows: 1, ellipsis: true))
        XCTAssertEqual(ell.height, one.height, "1행이어야")
        XCTAssertEqual(ell.width, ref.width, "마지막 행에 … 미부착")
    }

    /// 말줄임 + 폭 제한: U+2026 포함 마지막 행도 maxWidth 이내로 끝을 잘라 수렴.
    func testEllipsisTruncatesWithinMaxWidth() throws {
        let flat = try XCTUnwrap(TextRasterizer.render(text: "aaaa bbbb cccc", fontData: nil, systemFontName: nil, pointSize: 24))
        let one = try XCTUnwrap(TextRasterizer.render(text: "A", fontData: nil, systemFontName: nil, pointSize: 24))
        let mw = Float(flat.width) * 0.4
        let r = try XCTUnwrap(TextRasterizer.render(text: "aaaa bbbb cccc", fontData: nil, systemFontName: nil,
                                                    pointSize: 24, maxWidth: mw, maxRows: 1, ellipsis: true))
        XCTAssertEqual(r.height, one.height, "maxRows=1 인데 1행이 아님")
        XCTAssertLessThanOrEqual(r.width, Int(mw.rounded(.up)) + 2, "…행이 maxWidth 초과")
    }

    /// Justify(blockalign): 문단 중간 워드랩 줄은 maxWidth 로 스트레치(래스터 폭 ≈ maxWidth).
    func testJustifyStretchesWrappedLines() throws {
        let flat = try XCTUnwrap(TextRasterizer.render(text: "aa bb cc dd ee ff", fontData: nil, systemFontName: nil, pointSize: 24))
        let mw = Float(flat.width) * 0.6
        let j = try XCTUnwrap(TextRasterizer.render(text: "aa bb cc dd ee ff", fontData: nil, systemFontName: nil,
                                                    pointSize: 24, maxWidth: mw, justify: true))
        XCTAssertGreaterThan(j.height, flat.height, "워드랩이 선행돼야")
        XCTAssertGreaterThanOrEqual(Float(j.width), mw * 0.98, "justify 줄이 maxWidth 로 안 늘어남")
        XCTAssertLessThanOrEqual(j.width, Int(mw.rounded(.up)) + 2)
    }

    /// 멀티라인 center 정렬: 짧은 행의 잉크가 좌측 flush(종전) 대신 블록 중앙으로 온다.
    /// F2(flip②) 수정 후 버퍼 행 순서 = 화면 순서(row0=top=첫 줄) — 짧은 행 'A'(둘째 줄)는
    /// 버퍼 하단 절반에 온다.
    func testMultilineCenterAlignsShortRow() throws {
        func firstInkX(_ r: TextRasterizer.Raster, rows: Range<Int>) -> Int? {
            var minX: Int? = nil
            r.rgba.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
                for y in rows {
                    for x in 0..<r.width where p[(y * r.width + x) * 4 + 3] > 32 {
                        minX = min(minX ?? x, x)
                    }
                }
            }
            return minX
        }
        let left = try XCTUnwrap(TextRasterizer.render(text: "WWWWWWWW\nA", fontData: nil, systemFontName: nil, pointSize: 24))
        let centered = try XCTUnwrap(TextRasterizer.render(text: "WWWWWWWW\nA", fontData: nil, systemFontName: nil,
                                                           pointSize: 24, align: "center"))
        XCTAssertEqual(centered.width, left.width, "정렬은 래스터 치수를 바꾸지 않아야")
        let l = try XCTUnwrap(firstInkX(left, rows: (left.height / 2)..<left.height))
        let c = try XCTUnwrap(firstInkX(centered, rows: (centered.height / 2)..<centered.height))
        XCTAssertGreaterThan(c, l + 4, "짧은 행 'A' 가 중앙 정렬되지 않음")
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

    /// WEMath 실심(코퍼스 58씬): 공개 d.ts 표면 smoothStep/mix. noopProxy 폴백이면 전부 0/비수치로 붕괴.
    /// smoothStep 0.15625 는 Hermite 가정 고정값(선형 클램프면 0.25) — 골든 A/B 가 반박하면 심과 함께 갱신.
    func testWEMathSmoothStepAndMix() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: """
        import * as WEMath from 'WEMath';
        export function update(value) {
            return new Vec2(WEMath.smoothStep(0, 1, 0.25), WEMath.mix(10, 20, 0.25));
        }
        """))
        let out = try XCTUnwrap(e.evaluateVec(current: [0, 0]), "WEMath 심 부재(noopProxy 는 비수치)")
        XCTAssertEqual(out[0], 0.15625, accuracy: 1e-6)
        XCTAssertEqual(out[1], 12.5, accuracy: 1e-6)
    }

    /// smoothStep 구간 밖 클램프 + min==max 퇴화(step, NaN 누출 금지).
    func testWEMathSmoothStepClampAndDegenerate() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: """
        import * as WEMath from 'WEMath';
        export function update(value) {
            return new Vec3(WEMath.smoothStep(2, 6, 1),
                            WEMath.smoothStep(2, 6, 9),
                            WEMath.smoothStep(3, 3, 3));
        }
        """))
        XCTAssertEqual(try XCTUnwrap(e.evaluateVec(current: [0, 0, 0])), [0, 1, 1])
    }

    /// WEMath 각도 상수(d.ts: deg2rad/rad2deg).
    func testWEMathAngleConstants() throws {
        let e = try XCTUnwrap(TextScriptEngine(script: """
        import * as WEMath from 'WEMath';
        export function update(value) { return new Vec2(WEMath.deg2rad * 90, WEMath.rad2deg); }
        """))
        let out = try XCTUnwrap(e.evaluateVec(current: [0, 0]))
        XCTAssertEqual(out[0], .pi / 2, accuracy: 1e-5)
        XCTAssertEqual(out[1], 180 / .pi, accuracy: 1e-3)
    }
}
