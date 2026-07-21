import XCTest
import AppKit
import CoreText
@testable import WapleRender

/// 감사 fix-g6 회귀 묶음 — TextScriptEngine(F470/F472/F473/F474/F475), TextRasterizer(F476),
/// BaseAssetsSettings(F471). 항목별 최소 수정의 동작 고정이 목적.
final class RenderTextFixRegressionTests: XCTestCase {

    // ── F470(F-4): 무한 루프 정적 가드의 자명 우회 차단 ─────────────────────

    /// 빈 조건 for(init/update 절 유무 무관)·베어 식별자 while 은 거부(기존 리터럴 가드 우회).
    func testUnboundedLoopGuardBypassesRejected() {
        XCTAssertNil(TextScriptEngine(script: "var x = 1; export function update(v){ while (x) { } return 'x'; }"),
                     "while(x) 베어 식별자 조건 우회가 허용됨")
        XCTAssertNil(TextScriptEngine(script: "export function update(v){ for (var i = 0;; i++) {} return 'x'; }"),
                     "for(var i=0;;i++) 빈 조건 우회가 허용됨")
        XCTAssertNil(TextScriptEngine(script: "export function update(v){ for (let i = f(1);; i++) {} return 'x'; }"),
                     "중첩 괄호 init + 빈 조건 우회가 허용됨")
        // 기존 거부 케이스는 여전히 거부.
        XCTAssertNil(TextScriptEngine(script: "export function update(v){ for (;;) {} return 'x'; }"))
        XCTAssertNil(TextScriptEngine(script: "export function update(v){ while (true) {} return 'x'; }"))
    }

    /// 정상 루프(비교 조건 while, 유한 상한 for)는 오탐 없이 로드·실행된다.
    func testBoundedLoopsStillAccepted() throws {
        let script = """
        export function update(v) {
            var t = 0;
            while (t < 3) { t += 1; }
            for (var i = 0; i < 3; i++) { t += i; }
            return 'ok' + t;
        }
        """
        let e = try XCTUnwrap(TextScriptEngine(script: script), "정상 루프 오탐 거부")
        XCTAssertEqual(e.evaluate(current: ""), "ok6")
    }

    // ── F472(F-87): 시작 판정을 놓친 정규식 내부의 import/export 보호 ────────

    /// `if (ok) /.../ ` 위치(나눗셈과 모호해 렉서가 정규식으로 못 잡는 위치)의 정규식 내부
    /// import + 문자열이 중화로 소비돼 패턴이 깨지면 안 된다.
    func testRegexInnerImportNotNeutralized() throws {
        let src = "if (ok) /a import 'x'$/.test(s);"
        XCTAssertEqual(TextScriptEngine.stripModuleSyntax(src), src, "정규식 본문이 중화로 파괴")
        // end-to-end: 삼항 분기로 정규식 결과가 관측 가능 — 패턴이 /a / 로 퇴화하면 'hit' 로 새는
        // 입력("za z")에서 'miss' 가 나와야 보존 확인.
        let script = """
        export function update(v) {
            var side = 'none';
            var ok = v.length > 0;
            if (ok) /a import 'x'$/.test(v) ? side = 'hit' : side = 'miss';
            return side;
        }
        """
        let e = try XCTUnwrap(TextScriptEngine(script: script))
        XCTAssertEqual(e.evaluate(current: "za import 'x'"), "hit")
        XCTAssertEqual(e.evaluate(current: "za z"), "miss", "정규식이 /a / 로 퇴화(중화 파괴)")
    }

    /// ASI 가 성립하는 위치(개행 경과·`;` 뒤)의 import 는 종전대로 중화된다(과교정 금지).
    func testAsiImportsStillNeutralized() {
        XCTAssertTrue(TextScriptEngine.stripModuleSyntax("var a = 1\nimport x from 'y';\nx;")
                        .contains("var x = __noopProxy();"), "개행 ASI import 중화 실패")
        XCTAssertTrue(TextScriptEngine.stripModuleSyntax("var a = 1;import x from 'y';")
                        .contains("var x = __noopProxy();"), "; 뒤 import 중화 실패")
        XCTAssertTrue(TextScriptEngine.stripModuleSyntax("var a = 1/*\n*/import x from 'y';")
                        .contains("var x = __noopProxy();"), "블록 주석 내 개행 ASI import 중화 실패")
    }

    // ── F473(F-88): 멀티라인 `export { ... }` 삭제 ──────────────────────────

    /// 멀티라인 목록·re-export 꼬리가 통째 삭제되고, 다음 문을 먹지 않는다.
    func testMultilineExportListStripped() {
        XCTAssertEqual(TextScriptEngine.stripModuleSyntax("export {\n  a,\n  b as c\n};\nvar update = 1;"),
                       "\nvar update = 1;")
        XCTAssertEqual(TextScriptEngine.stripModuleSyntax("export { a } from 'm';\nvar b = 1;"),
                       "\nvar b = 1;", "re-export 꼬리 잔존")
        XCTAssertEqual(TextScriptEngine.stripModuleSyntax("export {a}\nfoo();"),
                       "\nfoo();", "다음 문까지 소비")
        XCTAssertEqual(TextScriptEngine.stripModuleSyntax("export * from 'm';\nvar c = 1;"),
                       "\nvar c = 1;", "export * 는 기존 동작 유지")
    }

    /// end-to-end: 손으로 포매팅된 멀티라인 export 목록을 쓰는 스크립트가 로드된다.
    func testMultilineExportListScriptLoads() throws {
        let script = """
        export var scriptProperties = createScriptProperties().finish();
        export {
          scriptProperties
        };
        export function update(v) { return 'ok'; }
        """
        let e = try XCTUnwrap(TextScriptEngine(script: script), "멀티라인 export 목록 잔여 줄 SyntaxError")
        XCTAssertEqual(e.evaluate(current: ""), "ok")
    }

    // ── F474(F-89): export default function 의 이름 바인딩 보존 ─────────────

    /// 기명 function 은 선언문으로 남고(`var __default =` 대입 아님), 익명은 기존 대입 유지.
    func testExportDefaultNamedFunctionKeepsDeclaration() {
        let named = TextScriptEngine.stripModuleSyntax("export default function update(v) { return v; }")
        XCTAssertTrue(named.contains("function update(v)"), named)
        XCTAssertFalse(named.contains("__default"), named)
        XCTAssertFalse(named.contains("export"), named)
        let anon = TextScriptEngine.stripModuleSyntax("export default function(v){ return v; }")
        XCTAssertTrue(anon.contains("var __default = function(v)"), anon)
    }

    /// end-to-end: default-export 형태 update 가 훅 수집된다(단독/씬 경로 모두).
    func testExportDefaultUpdateHookCollected() throws {
        let solo = try XCTUnwrap(TextScriptEngine(script: "export default function update(v) { return 'ok'; }"),
                                 "단독 경로: update 전역 부재로 로드 실패")
        XCTAssertEqual(solo.evaluate(current: ""), "ok")
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: "export default function update(v) { return 'ok'; }",
                                               scene: scene))
        XCTAssertTrue(e.hasUpdate, "씬 경로: update 훅 수집 실패(무음 정적 폴섹)")
        XCTAssertEqual(e.evaluate(current: ""), "ok")
    }

    // ── F475(F-90): 공유 컨텍스트의 지연 createScriptProperties 오버라이드 격리 ──

    /// init 안에서 createScriptProperties() 를 지연 호출하는 스크립트가, 이후 로드된 타 엔진의
    /// 오버라이드가 아니라 자기 오버라이드를 읽는다.
    func testLazyScriptPropertiesReadsOwnOverrides() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let a = try XCTUnwrap(TextScriptEngine(script: """
        var captured = null;
        function init() { captured = createScriptProperties().addSlider({ name: 'speed', value: 5 }).finish(); }
        function update(v) { return String(captured.speed); }
        """, scene: scene, scriptPropsJSON: #"{"speed": 42}"#))
        let b = try XCTUnwrap(TextScriptEngine(script: "function update(v) { return v; }",
                                               scene: scene, scriptPropsJSON: #"{"speed": 99}"#))
        XCTAssertEqual(a.evaluate(current: "x"), "42", "타 엔진(B) 오버라이드 99 를 읽음")
        XCTAssertEqual(b.evaluate(current: "x"), "x", "무관 엔진 회귀")
    }

    // ── F476(F-91): 폴섹 글리프 실측 메트릭을 캔버스 높이에 반영 ────────────

    /// CJK·이모지 등 캐스케이드 폴섹 글리프의 실제 런 메트릭이 기본 폰트보다 크면 캔버스가 그만큼
    /// 커져야 한다(작으면 상하단 클리핑). render() 와 동일한 폰트/스케일로 실측치를 재현해 비교.
    func testFallbackGlyphMetricsExpandCanvas() throws {
        let text = "한😀"
        let pointSize: Float = 48
        let raster = try XCTUnwrap(TextRasterizer.render(text: text, fontData: nil, systemFontName: nil,
                                                         pointSize: pointSize))
        let effective = CGFloat(pointSize) * 300 / 72   // render() 내부 DPI 스케일과 동일
        let font = CTFontCreateUIFontForLanguage(.system, effective, nil)!
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        XCTAssertGreaterThanOrEqual(CGFloat(raster.height), ceil(ascent + descent + leading) + 2,
                                    "폴섹 런 실측(\(ascent + descent + leading))보다 캔버스가 작으면 클리핑")
    }

    // ── F471(F-29): 자동 탐지 후보의 WE 기본 에셋 팩 정합성 ────────────────

    /// shaders/common.h 단독으론 부족 — materials/ 디렉터리까지 갖춰야 팩으로 인정.
    func testBaseAssetsPackValidation() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("waple-f471-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        XCTAssertFalse(BaseAssetsSettings.isValidBaseAssetsPack(tmp), "빈 폴터")
        let shaders = tmp.appendingPathComponent("shaders")
        try fm.createDirectory(at: shaders, withIntermediateDirectories: true)
        try "// stub".write(to: shaders.appendingPathComponent("common.h"), atomically: true, encoding: .utf8)
        XCTAssertFalse(BaseAssetsSettings.isValidBaseAssetsPack(tmp), "common.h 만으로는 부족(F471)")
        try fm.createDirectory(at: tmp.appendingPathComponent("materials"), withIntermediateDirectories: true)
        XCTAssertTrue(BaseAssetsSettings.isValidBaseAssetsPack(tmp))
    }
}
