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
        XCTAssertTrue(isRed(rep, 80, 20), "스크립트가 재배치한 씬 (80,80) — y-up 이라 이미지 y=20 — 에 사각형이 그려져야")
        XCTAssertFalse(isRed(rep, 20, 80), "저작 초기 origin 씬 (20,20)=이미지 (20,80) 에는 더 이상 그려지면 안 됨(동결 회귀)")
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

    /// 실물 3696323523 클릭 angles 축소판: 스크립트가 가로 막대를 90° 세운다.
    ///
    /// **단위 회귀 핀(반환 방향).** 종전 이 테스트는 합성 스크립트 `new Vec3(0,0,Math.PI/2)` 로
    /// "스크립트 반환값 = 라디안" 을 못 박고 있었는데 그게 틀렸다 — WE 스크립트 API 의 `angles` 는
    /// **도(degree)** 다(근거는 TextScriptEngine.evaluateAnglesVec 주석: 3477054430 id=14 가
    /// `new Vec3(0,-32,0)` 를 반환하면서 정적 value 로는 `-0.55851`(=-32.0006 rad→deg)을 저장한다).
    /// 이 테스트가 인용한 실물 3696323523 의 angles 스크립트는 **`value` 를 한 번도 쓰지 않는
    /// 컨트롤러**라 애초에 단위를 검증한 적이 없다 — 즉 종전 라디안 가정은 실물 근거 없이
    /// 합성 스크립트에만 박혀 있었다.
    ///
    /// 음성 대조: 반환값 도→라디안 변환을 빼면 90 이 90 rad(= 116.6°)로 먹혀 (50,35) 가 막대 밖이 된다.
    func testAnglesScriptRotatesQuad() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/red.json","origin":"50 50 0","size":"60 10","scale":"1 1 1",
                     "angles":{"value":"0 0 0","script":"export function update(v){ return new Vec3(0,0,90); }"}}]}
        """
        let rep = try capture(scene: scene, id: "waple_f331_angles")
        XCTAssertTrue(isRed(rep, 50, 50), "중심은 회전 전후 항상 그려져야(sanity)")
        XCTAssertTrue(isRed(rep, 50, 35), "90(도) 회전 후 세로막대 안(회전 전은 밖) (50,35) 이 그려져야")
        XCTAssertFalse(isRed(rep, 65, 50), "회전 전 가로막대 안(회전 후는 밖) (65,50) 은 더 이상 그려지면 안 됨")
    }

    /// **단위 회귀 핀(current 공급 방향).** 스크립트에 넣어 주는 현재값도 도여야 한다 — 실물
    /// 컨트롤러가 current 를 상수로 증분/누산하기 때문이다(3000562427 의 `value.z -= 20;
    /// if (value.z <= 0) value.z = 360`). 정적 angles 는 scene.json 규약대로 라디안(π = 180°)이고,
    /// 스크립트는 크기로 단위를 판별한다: 도면 180, 라디안이면 3.14.
    /// 음성 대조: current 의 라디안→도 변환을 빼면 3.14 가 들어와 분기가 0 으로 떨어지고
    /// 막대가 가로로 남아 (50,35) 는 검고 (65,50) 이 빨개진다(두 단언 모두 실패).
    func testAnglesScriptReceivesCurrentInDegrees() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let script = "export function update(v){ return new Vec3(0,0, v.z > 100 ? 90 : 0); }"
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/red.json","origin":"50 50 0","size":"60 10","scale":"1 1 1",
                     "angles":{"value":"0 0 3.14159265","script":"\(script)"}}]}
        """
        let rep = try capture(scene: scene, id: "waple_angles_current_deg")
        XCTAssertTrue(isRed(rep, 50, 35), "current 가 도(180)로 들어와야 분기가 90° 를 반환해 막대가 선다")
        XCTAssertFalse(isRed(rep, 65, 50), "current 를 라디안(3.14)으로 주면 분기가 0 이 되어 가로막대가 남는다")
    }

    /// **단위 회귀 핀(JS 노출 방향).** `thisLayer.angles` / `thisScene.layers[].angles` 도 도로
    /// 보여야 한다(TextScriptEngine.layersJSONArray). 같은 컨텍스트의 JS 심 `__mat4FromTRS` 가
    /// 이미 `Math.PI/180` 으로 도를 가정하고 있어서, 종전에는 한 컨텍스트 안에서 두 단위가 모순이었다.
    /// 음성 대조: layersJSONArray 의 rad→deg 를 빼면 thisLayer.angles.z 가 3.14 로 보여 분기가
    /// 0 으로 떨어진다.
    func testThisLayerAnglesExposedInDegrees() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let script = "export function update(v){ return new Vec3(0,0, thisLayer.angles.z > 100 ? 90 : 0); }"
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/red.json","origin":"50 50 0","size":"60 10","scale":"1 1 1",
                     "angles":{"value":"0 0 3.14159265","script":"\(script)"}}]}
        """
        let rep = try capture(scene: scene, id: "waple_angles_thislayer_deg")
        XCTAssertTrue(isRed(rep, 50, 35), "thisLayer.angles.z 가 도(180)로 보여야 분기가 90° 를 반환해 막대가 선다")
        XCTAssertFalse(isRed(rep, 65, 50), "라디안(3.14)으로 보이면 분기가 0 이 되어 가로막대가 남는다")
    }

    /// **단위 회귀 핀(read-back 방향).** F723 의 `thisLayer` 직접 대입 read-back
    /// (readBackScriptLayerState)도 도로 읽어 라디안으로 되돌려야 한다. 대입은 angles 가 아닌
    /// 다른 키(alpha)에 붙은 스크립트의 top-level 에서 한다 — 마운트 시점에 실행되므로 첫 프레임
    /// read-back 이 이를 보고, angles 키에 update 가 없어 read-back 이 적용 대상이 된다.
    /// 음성 대조: read-back 의 deg→rad 를 빼면 90 이 90 rad(=116.6°)로 먹혀 (50,35) 가 막대 밖이 된다.
    func testThisLayerAnglesReadBackIsDegrees() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let script = "thisLayer.angles = new Vec3(0,0,90); export function update(v){ return v; }"
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"image":"models/red.json","origin":"50 50 0","size":"60 10","scale":"1 1 1",
                     "angles":"0 0 0","alpha":{"value":1,"script":"\(script)"}}]}
        """
        let rep = try capture(scene: scene, id: "waple_angles_readback_deg")
        XCTAssertTrue(isRed(rep, 50, 50), "중심은 회전 전후 항상 그려져야(sanity)")
        XCTAssertTrue(isRed(rep, 50, 35), "read-back 이 90 을 도로 해석해야 막대가 선다(라디안으로 먹으면 116.6° 라 밖)")
    }
}
