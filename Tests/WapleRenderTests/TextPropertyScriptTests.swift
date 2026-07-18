import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// F218+F219: parseText 는 텍스트 '콘텐츠' 스크립트(obj["text"].script)만 캡처하고 origin/scale/alpha/
/// color/angles 프로퍼티 스크립트와 visible 바인딩을 통째로 버린다 — SceneTextLayer 에 propertyScripts
/// 맵도 initialVisible 필드도 없어(이미지 레이어 SceneLayer 와 달리) 담을 곳조차 없었다. 168씬 코퍼스
/// 실측: 텍스트 오브젝트의 script 바인딩 = scale 735건·origin 681건·alpha 132건·color 54건·angles 4건,
/// 69/168씬. 렌더러 소비는 재래스터 없이 인코드 시점 트랜스폼/알파/가시성 적용(2D 레이어와 동형).
final class TextPropertyScriptTests: XCTestCase {
    // ── 파스 캡처 + buildTexts 배선(화이트박스) ──────────────────────────────────

    /// origin/scale/alpha/color/angles+visible 6키 전부가 parseText → SceneTextLayer.propertyScripts 로
    /// 캡처되고, buildTexts 가 6개 엔진을 전부 생성해야 한다(parseLayer:731-739 와 동형).
    func testAllPropertyScriptKeysCapturedAndWired() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let src = "export function update(v){ return v; }"
        let scene: [String: Any] = [
            "general": ["orthogonalprojection": ["width": 100, "height": 100], "clearcolor": "0 0 0"],
            "objects": [[
                "id": 1, "name": "Label", "text": "hi", "font": "systemfont_arial", "pointsize": 16,
                "origin": ["value": "50 50 0", "script": src],
                "scale": ["value": "1 1 1", "script": src],
                "alpha": ["value": 1, "script": src],
                "color": ["value": "1 1 1", "script": src],
                "angles": ["value": "0 0 0", "script": src],
                "visible": ["value": true, "script": src],
            ]],
        ]
        let pkg = ScenePackage.assemble([(name: "scene.json", data: try JSONSerialization.data(withJSONObject: scene))])
        let doc = try SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.texts.count, 1)
        XCTAssertEqual(Set(doc.texts[0].propertyScripts.keys), Set(["origin", "scale", "alpha", "color", "angles", "visible"]),
                       "parseText 가 6개 키 전부의 스크립트를 캡처해야")
        XCTAssertTrue(doc.texts[0].initialVisible)

        let built = SceneRenderer().buildTexts(doc: doc, package: pkg, device: device)
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(Set(built[0].propScripts.map(\.key)), Set(["origin", "scale", "alpha", "color", "angles", "visible"]),
                       "buildTexts 가 6개 키 전부 엔진을 생성해야")
    }

    /// 가드: 스크립트 없는 정적 텍스트는 propertyScripts 가 비고 initialVisible=true(무회귀).
    func testStaticTextHasNoPropertyScripts() throws {
        let scene: [String: Any] = [
            "general": ["orthogonalprojection": ["width": 100, "height": 100]],
            "objects": [["id": 1, "text": "hi", "origin": "50 50 0", "pointsize": 16]],
        ]
        let pkg = ScenePackage.assemble([(name: "scene.json", data: try JSONSerialization.data(withJSONObject: scene))])
        let doc = try SceneDocument.parse(package: pkg)
        XCTAssertTrue(doc.texts[0].propertyScripts.isEmpty)
        XCTAssertTrue(doc.texts[0].initialVisible)
    }

    // ── 렌더러 소비: 인코드 시점 트랜스폼/가시성 적용(픽셀 e2e) ──────────────────────

    private func project(_ files: [(String, Data)], id: String) throws -> WallpaperProject {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        return WallpaperProject(id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
                                title: id, tags: [], contentRating: nil, workshopId: nil,
                                dependency: nil, folderURL: dir)
    }

    private func capture(scene: String, id: String, w: Int = 200, h: Int = 200) throws -> NSBitmapImageRep {
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: w, height: h)),
                    project: try project([("scene.json", Data(scene.utf8))], id: id))
        defer { r.teardown() }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(id + "_out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: w, height: h, times: [0.2], toDir: out).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    /// 영역 안에 빨강 잉크(글리프)가 하나라도 있으면 true(정확 픽셀 좌표 의존 없이 회전/스케일/폰트
    /// 래스터화 세부에 강건). 배경은 clearcolor 검정 — 잉크만 redComponent 가 강하다.
    private func hasRedInk(_ rep: NSBitmapImageRep, x0: Int, y0: Int, x1: Int, y1: Int) -> Bool {
        for y in stride(from: max(0, y0), to: min(rep.pixelsHigh, y1), by: 2) {
            for x in stride(from: max(0, x0), to: min(rep.pixelsWide, x1), by: 2) {
                if let c = rep.colorAt(x: x, y: y), c.redComponent > 0.6, c.greenComponent < 0.3 { return true }
            }
        }
        return false
    }

    /// 실물 호버/이동 텍스트 축소판: origin 스크립트가 고정 좌표로 텍스트를 재배치.
    func testOriginScriptMovesText() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"text":"88","font":"systemfont_arial","pointsize":28,
                     "color":"1 0 0","alpha":1,
                     "origin":{"value":"40 100 0","script":"export function update(v){ return new Vec2(160,100); }"}}]}
        """
        let rep = try capture(scene: scene, id: "waple_text_origin")
        XCTAssertTrue(hasRedInk(rep, x0: 135, y0: 75, x1: 185, y1: 125), "스크립트가 재배치한 (160,100) 부근에 글리프가 그려져야")
        XCTAssertFalse(hasRedInk(rep, x0: 15, y0: 75, x1: 65, y1: 125), "저작 초기 origin (40,100) 부근엔 더 이상 그려지면 안 됨(동결 회귀)")
    }

    /// 실물 펄스/오디오반응 라벨 축소판: scale 스크립트가 정적 1 을 5 로 확대.
    func testScaleScriptResizesText() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"text":"8","font":"systemfont_arial","pointsize":12,
                     "color":"1 0 0","alpha":1,"origin":"100 100 0",
                     "scale":{"value":"1 1 1","script":"export function update(v){ return new Vec2(5,5); }"}}]}
        """
        let rep = try capture(scene: scene, id: "waple_text_scale")
        XCTAssertTrue(hasRedInk(rep, x0: 90, y0: 90, x1: 110, y1: 110), "중심 부근은 스케일 전후 항상 그려져야(sanity)")
        XCTAssertTrue(hasRedInk(rep, x0: 60, y0: 60, x1: 85, y1: 85), "5× 확대 박스 안, 정적(pointsize 12) 박스 밖인 좌상단에 그려져야")
    }

    /// visible={value:true,script:false} 텍스트는 초기값·스크립트 평가와 무관하게 항상 그려지던 결함(F219) —
    /// 스크립트가 false 를 반환하면 어떤 프레임에도 그려지면 안 된다.
    func testVisibleScriptHidesText() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"text":"88","font":"systemfont_arial","pointsize":28,
                     "color":"1 0 0","alpha":1,"origin":"100 100 0",
                     "visible":{"value":true,"script":"export function update(v){ return false; }"}}]}
        """
        let rep = try capture(scene: scene, id: "waple_text_visible_hidden")
        XCTAssertFalse(hasRedInk(rep, x0: 0, y0: 0, x1: 200, y1: 200), "visible 스크립트가 false 면 전 화면 어디에도 그려지면 안 됨")
    }

    /// 가드: visible 스크립트가 true 를 반환하면 정상적으로 계속 그려져야(무회귀).
    func testVisibleScriptTrueStillRenders() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"text":"88","font":"systemfont_arial","pointsize":28,
                     "color":"1 0 0","alpha":1,"origin":"100 100 0",
                     "visible":{"value":true,"script":"export function update(v){ return true; }"}}]}
        """
        let rep = try capture(scene: scene, id: "waple_text_visible_shown")
        XCTAssertTrue(hasRedInk(rep, x0: 75, y0: 75, x1: 125, y1: 125), "visible 스크립트가 true 면 계속 그려져야")
    }
}
