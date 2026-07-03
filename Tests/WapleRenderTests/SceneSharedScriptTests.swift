import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 씬 공유 JSContext: 씬의 모든 프로퍼티 스크립트가 하나의 컨텍스트를 공유해 `shared` 로 통신한다
/// (실물 3394601417: visible 스크립트의 컨트롤러가 shared.a 를 세팅, 43개 스크립트가 분기).
/// 각 스크립트는 IIFE 로 격리 — update/스크립트 로컬 상태는 클로저에 갇힌다.
final class SceneSharedScriptTests: XCTestCase {
    /// 컨트롤러(top-level 사이드이펙트, update 없음) → 소비자(shared 분기) 통신.
    func testSharedStateFlowsBetweenEngines() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        // 실물 bt.visible 패턴: top-level 에서 shared 초기화, cursorClick 만 export.
        let controller = """
        'use strict';
        let cl=false;
        shared.a=1;
        export function cursorClick(event) { shared.a = cl ? 1 : 0; cl = !cl; }
        """
        let ctrl = try XCTUnwrap(TextScriptEngine(script: controller, scene: scene),
                                 "update 없는 컨트롤러도 로드(사이드이펙트)돼야 함")
        XCTAssertFalse(ctrl.hasUpdate)
        XCTAssertNil(ctrl.evaluate(current: ""))

        // 실물 time_b2.alpha 패턴: shared.a 로 분기.
        let consumer = """
        'use strict';
        export function update(value) { if (shared.a==1) { value=0.2; } else { value=1; } return value; }
        """
        let cons = try XCTUnwrap(TextScriptEngine(script: consumer, scene: scene))
        XCTAssertEqual(try XCTUnwrap(cons.evaluateVec(current: [1])).first ?? -1, 0.2, accuracy: 1e-4)
    }

    /// 스크립트-로컬 상태(var/let, scriptProperties, update 이름)가 엔진 간 충돌하지 않아야 한다.
    func testScriptLocalStateStaysIsolated() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        func src(_ label: String) -> String {
            """
            var counter = 0;
            export var scriptProperties = createScriptProperties().addText({name:'tag', value:'\(label)'}).finish();
            export function update(v) { counter += 1; return scriptProperties.tag + counter; }
            """
        }
        let a = try XCTUnwrap(TextScriptEngine(script: src("A"), scene: scene))
        let b = try XCTUnwrap(TextScriptEngine(script: src("B"), scene: scene))
        XCTAssertEqual(a.evaluate(current: ""), "A1")
        XCTAssertEqual(a.evaluate(current: ""), "A2")   // A 의 counter 만 증가
        XCTAssertEqual(b.evaluate(current: ""), "B1")   // update/counter/scriptProperties 미충돌
        XCTAssertEqual(a.evaluate(current: ""), "A3")
    }

    /// visible 스크립트용 evaluateBool: 부울/숫자(0=false) 반환 해석.
    func testEvaluateBoolForVisibleScripts() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let e = try XCTUnwrap(TextScriptEngine(script: "export function update(v) { return !v; }", scene: scene))
        XCTAssertEqual(e.evaluateBool(current: false), true)
        XCTAssertEqual(e.evaluateBool(current: true), false)
        let n = try XCTUnwrap(TextScriptEngine(script: "export function update(v) { return shared.q ? 1 : 0; }", scene: scene))
        XCTAssertEqual(n.evaluateBool(current: true), false)  // shared.q 미정의 → 0 → false
    }

    /// 깨진 스크립트는 nil, 컨텍스트는 오염되지 않고 계속 사용 가능해야 한다.
    func testSyntaxErrorReturnsNilWithoutPoisoningContext() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        XCTAssertNil(TextScriptEngine(script: "syntax error (((", scene: scene))
        let ok = try XCTUnwrap(TextScriptEngine(script: "export function update(v){ return 'ok'; }", scene: scene))
        XCTAssertEqual(ok.evaluate(current: ""), "ok")
    }

    /// engine.runtime 은 씬 컨텍스트 전역 — setRuntime 이 모든 엔진에 보인다.
    func testEngineRuntimeSharedAcrossEngines() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let a = try XCTUnwrap(TextScriptEngine(script: "export function update(v){ return v + engine.runtime; }", scene: scene))
        a.setRuntime(2)
        XCTAssertEqual(try XCTUnwrap(a.evaluateVec(current: [1])).first ?? 0, 3, accuracy: 1e-4)
    }
}

/// 렌더 통합: visible 스크립트 레이어(draw 스킵/부활) + shared 컨트롤러→소비자(실물 3394601417 축소판).
final class SceneVisibleScriptRenderTests: XCTestCase {
    private func i32(_ n: Int) -> Data { var v = UInt32(n).littleEndian; return Data(bytes: &v, count: 4) }

    private func encodePkg(_ files: [(String, Data)]) -> Data {
        var out = Data()
        let version = "PKGV0001"
        out.append(i32(version.utf8.count)); out.append(version.data(using: .utf8)!)
        out.append(i32(files.count))
        var offset = 0
        for (name, data) in files {
            out.append(i32(name.utf8.count)); out.append(name.data(using: .utf8)!)
            out.append(i32(offset)); out.append(i32(data.count)); offset += data.count
        }
        for (_, data) in files { out.append(data) }
        return out
    }

    private func solidTex(_ r: UInt8, _ g: UInt8, _ b: UInt8, w: Int = 8, h: Int = 8) -> Data {
        var px = [UInt8](); px.reserveCapacity(w * h * 4)
        for _ in 0..<(w * h) { px.append(contentsOf: [r, g, b, 255]) }
        let png = OffscreenCapture.png(rgba: px, width: w, height: h)!
        var tex = Data("TEXV0005".utf8)
        tex.append(Data(repeating: 0, count: 34))
        tex.append(png)
        return tex
    }

    /// 오브젝트: 흰 bg → 초록(alpha 스크립트: shared.a==1 → 1) → 컨트롤러(visible 스크립트 top-level 이
    /// shared.a=1, update 없음) → 빨강 풀스크린(visible 스크립트 false → draw 스킵)
    /// → 파랑 좌반(정적 visible false + 스크립트 true → 부활).
    func testSharedControllerAndVisibleScriptsEndToEnd() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/bg.json","origin":"960 540 0","size":"1920 1080"},
           {"id":2,"image":"models/green.json","origin":"960 540 0","size":"1920 1080",
            "alpha":{"value":0,"script":"'use strict';\\nexport function update(v){ if(shared.a==1){ v=1; } else { v=0; } return v; }"}},
           {"id":3,"image":"models/ctrl.json","origin":"4 4 0","size":"2 2",
            "visible":{"value":true,"script":"'use strict';\\nlet cl=false;\\nshared.a=1;\\nexport function cursorClick(e){ shared.a=cl?1:0; cl=!cl; }"}},
           {"id":4,"image":"models/red.json","origin":"960 540 0","size":"1920 1080",
            "visible":{"value":true,"script":"'use strict';\\nexport function update(v){ return false; }"}},
           {"id":5,"image":"models/blue.json","origin":"480 540 0","size":"960 1080",
            "visible":{"value":false,"script":"'use strict';\\nexport function update(v){ return true; }"}}
         ]}
        """
        var files: [(String, Data)] = [("scene.json", scene.data(using: .utf8)!)]
        for (name, tex) in [("bg", solidTex(255, 255, 255)), ("green", solidTex(0, 255, 0)),
                            ("ctrl", solidTex(255, 255, 255)), ("red", solidTex(255, 0, 0)),
                            ("blue", solidTex(0, 0, 255))] {
            files.append(("models/\(name).json", Data(#"{"material":"materials/\#(name).json"}"#.utf8)))
            files.append(("materials/\(name).json", Data(#"{"passes":[{"textures":["\#(name)"]}]}"#.utf8)))
            files.append(("materials/\(name).tex", tex))
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_sharedjs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: "sharedjs", type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: "sharedjs", tags: [], contentRating: nil, workshopId: nil,
                                       dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_sharedjs")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.5], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        func px(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            let c = rep.colorAt(x: x, y: y)!
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        // 우반: 초록(컨트롤러의 shared.a=1 → alpha 1). 빨강(visible false)은 어디에도 없어야.
        let right = px(48, 18)
        XCTAssertGreaterThan(right.g, 0.8, "shared 소비자 alpha 미적용(초록이어야): \(right)")
        XCTAssertLessThan(right.r, 0.2, "빨강 visible-false 레이어가 그려짐: \(right)")
        // 좌반: 파랑(정적 false + 스크립트 true → 부활).
        let left = px(16, 18)
        XCTAssertGreaterThan(left.b, 0.8, "정적 false + 스크립트 true 레이어 미부활(파랑이어야): \(left)")
        XCTAssertLessThan(left.r, 0.2, "빨강 visible-false 레이어가 그려짐: \(left)")
    }
}
