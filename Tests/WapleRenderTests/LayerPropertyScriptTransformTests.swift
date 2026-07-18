import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// F331: 2D 이미지 레이어의 origin/scale/angles 프로퍼티 스크립트가 파싱은 되지만(SceneDocument.parseLayer)
/// 렌더러가 소비하지 않아, 스크립트 구동 레이어(오디오반응 스케일·클릭 angles·호버 origin)가 저작
/// 초기값에 얼어붙는다. 3D 빌보드 경로(SceneRenderer3D.Billboard3D.evaluateScripts)는 이미 동일
/// layer.propertyScripts 를 소비 — 2D encodeLayer 에 그 규약을 이식(실증 씬 2885492021 오디오반응
/// 스케일·3696323523 클릭 angles·3538758087 호버 origin).
final class LayerPropertyScriptTransformTests: XCTestCase {
    private func project(_ files: [(String, Data)], id: String) throws -> WallpaperProject {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        return WallpaperProject(id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
                                title: id, tags: [], contentRating: nil, workshopId: nil,
                                dependency: nil, folderURL: dir)
    }

    private func capture(scene: String, id: String) throws -> NSBitmapImageRep {
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/red.json", Data(#"{"material":"materials/red.json"}"#.utf8)),
            ("materials/red.json", Data(#"{"passes":[{"textures":["red"]}]}"#.utf8)),
            ("materials/red.tex", solidTex(255, 0, 0)),
        ]
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), project: try project(files, id: id))
        defer { r.teardown() }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(id + "_out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 100, height: 100, times: [0.2], toDir: out).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    private func isRed(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Bool {
        guard let c = rep.colorAt(x: x, y: y) else { return false }
        return c.redComponent > 0.8 && c.greenComponent < 0.2
    }

    /// 실물 3538758087 호버 origin 축소판: 스크립트가 고정 좌표로 origin 을 재배치.
    func testOriginScriptMovesQuad() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/red.json","size":"10 10","scale":"1 1 1","angles":"0 0 0",
                     "origin":{"value":"20 20 0","script":"export function update(v){ return new Vec2(80,80); }"}}]}
        """
        let rep = try capture(scene: scene, id: "waple_f331_origin")
        XCTAssertTrue(isRed(rep, 80, 80), "스크립트가 재배치한 (80,80) 에 사각형이 그려져야")
        XCTAssertFalse(isRed(rep, 20, 20), "저작 초기 origin (20,20) 에는 더 이상 그려지면 안 됨(동결 회귀)")
    }

    /// 실물 2885492021 오디오반응 스케일 축소판: 스크립트가 정적 scale(1)을 3배로 재계산.
    func testScaleScriptResizesQuad() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/red.json","origin":"50 50 0","size":"20 20","angles":"0 0 0",
                     "scale":{"value":"1 1 1","script":"export function update(v){ return new Vec2(3,3); }"}}]}
        """
        let rep = try capture(scene: scene, id: "waple_f331_scale")
        XCTAssertTrue(isRed(rep, 50, 50), "중심은 스케일 전후 항상 그려져야(sanity)")
        XCTAssertTrue(isRed(rep, 30, 50), "3× 스케일 박스(반폭 30) 안, 정적 박스(반폭 10) 밖인 (30,50) 이 그려져야")
    }

    /// 실물 3696323523 클릭 angles 축소판: 스크립트가 가로 막대를 90°(π/2) 세운다.
    func testAnglesScriptRotatesQuad() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/red.json","origin":"50 50 0","size":"60 10","scale":"1 1 1",
                     "angles":{"value":"0 0 0","script":"export function update(v){ return new Vec3(0,0,Math.PI/2); }"}}]}
        """
        let rep = try capture(scene: scene, id: "waple_f331_angles")
        XCTAssertTrue(isRed(rep, 50, 50), "중심은 회전 전후 항상 그려져야(sanity)")
        XCTAssertTrue(isRed(rep, 50, 35), "90° 회전 후 세로막대 안(회전 전은 밖) (50,35) 이 그려져야")
        XCTAssertFalse(isRed(rep, 65, 50), "회전 전 가로막대 안(회전 후는 밖) (65,50) 은 더 이상 그려지면 안 됨")
    }
}
