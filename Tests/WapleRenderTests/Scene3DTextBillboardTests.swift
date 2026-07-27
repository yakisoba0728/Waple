import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// W-①(B3-3d-video): 3D 씬 text 오브젝트 배선 — 규약은 "screen overlay" 가 아니라 image 레이어와 동형의
/// world placement(코퍼스 실측 3509243656 등: origin/scale 이 카메라 eye/center 와 동일 스케일의 소수 단위
/// 3성분, composeTextParentTransforms 는 camera3D!=nil 이면 미실행이라 로컬 값 그대로 부모 체인에 태움).
/// build3D 가 doc.texts 를 TextRasterizer 로 래스터 → Billboard3D 로 배선하는지, 그리고 origin 프로퍼티
/// 스크립트가 미정 shared 값을 읽어 NaN 을 낳는 경우(1프레임 캡처는 F309 프라이밍 이후에도 재발 가능 — 라이브의
/// 자가치유 1프레임 지연과 달리 캡처는 못 고침) encodeBillboard 가 조용히 스킵하는지(불투명 사각형 아티팩트
/// 방지, 실측: 3509243656 id=2054/449 클러스터)를 검증한다.
final class Scene3DTextBillboardTests: XCTestCase {
    private func pkg(_ files: [(String, Data)]) throws -> ScenePackage {
        try ScenePackage.parse(encodePkg(files))
    }

    /// doc.texts 가 3D 씬(camera3D!=nil)에서 Billboard3D 로 배선되고, origin 이 2D 픽셀 합성(screen overlay)
    /// 이 아니라 scene.json 로컬 Vec3 값 그대로(world placement) 보존되는지 확인.
    func test3DTextBuildsWorldPlacedBillboardNotScreenOverlay() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":0,"model":"models/missing.mdl"},
           {"id":9,"text":"Hello","origin":"0.4 0.2 1.5","scale":"0.01 0.01 0.01","font":"systemfont_arial",
            "pointsize":16,"color":"1 1 1","alpha":1}
         ]}
        """
        let package = try pkg([("scene.json", Data(scene.utf8))])
        let doc = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        renderer.sceneScript = SceneScriptContext()
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)
        renderer.build3D(doc: doc, package: package, device: device)

        XCTAssertEqual(renderer.billboards.count, 1, "text 오브젝트가 3D 빌보드로 배선돼야 함")
        let bb = try XCTUnwrap(renderer.billboards.first)
        // world placement: scene.json origin 로컬값(소수 단위) 그대로 — 2D 픽셀(0..1920) 로 재해석되지 않음.
        XCTAssertEqual(bb.origin.x, 0.4, accuracy: 1e-5)
        XCTAssertEqual(bb.origin.y, 0.2, accuracy: 1e-5)
        XCTAssertEqual(bb.origin.z, 1.5, accuracy: 1e-5, "origin.z(3성분)는 SceneTextLayer.originZ 경유로 보존돼야 함")
        XCTAssertEqual(bb.scale.x, 0.01, accuracy: 1e-6)
    }

    /// depthWrite 는 텍스트 빌보드에서 항상 false — true 였다면 알파 배경(비-글리프 영역)까지 뎁스를 채워
    /// 뒤에 그려질 콘텐츠를 사각형째로 가리는 아티팩트가 재현된다(실측 3509243656 id=2054).
    func test3DTextBillboardDoesNotWriteDepth() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":0,"model":"models/missing.mdl"},
           {"id":9,"text":"Hi","origin":"0 0 0","scale":"0.01 0.01 0.01","font":"systemfont_arial",
            "pointsize":16,"color":"1 1 1","alpha":1}
         ]}
        """
        let package = try pkg([("scene.json", Data(scene.utf8))])
        let doc = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        renderer.sceneScript = SceneScriptContext()
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)
        renderer.build3D(doc: doc, package: package, device: device)
        let bb = try XCTUnwrap(renderer.billboards.first)
        XCTAssertFalse(bb.depthWrite, "텍스트 쿼드는 depthWrite=false — 알파 배경이 뒤 콘텐츠를 가리면 안 됨")
        XCTAssertTrue(bb.depthTest, "depthTest 는 유지(다른 메시/빌보드에 정상적으로 가려져야 함)")
    }

    /// F309 프라이밍 이후에도 텍스트 origin 프로퍼티 스크립트가 미정 shared 값을 읽으면 NaN 이 나올 수 있다
    /// (예: 다른 노드의 스크립트가 그 프레임에 아직 값을 세팅하지 않은 order 배치). encodeBillboard 의
    /// center.isFinite 가드가 없으면 화면 어딘가에 불투명 사각형(검은 상자)이 찍힌다 — 배경 흰 솔리드
    /// 중심 픽셀이 그대로 흰색으로 남아야 한다(NaN 쿼드가 중심을 가리지 않음 = 스킵됨).
    func test3DTextBillboardWithNaNOriginDoesNotPaintOverBackground() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":0,"model":"models/missing.mdl"},
           {"id":1,"image":"models/solid.json","origin":"0 0 0","size":"20 20","color":"1 1 1","alpha":1},
           {"id":9,"text":"Ghost","font":"systemfont_arial","pointsize":16,"color":"1 1 1","alpha":1,
            "scale":"0.01 0.01 0.01",
            "origin":{"value":"0 0 0",
              "script":"export function update(value) { value.x = shared.undefinedVar1 + 0.4; return value; }"}}
         ]}
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/solid.json", #"{"material":"materials/solid.json"}"#.data(using: .utf8)!),
            ("materials/solid.json", #"{"passes":[{"shader":"flat","depthtest":"disabled","depthwrite":"disabled"}]}"#.data(using: .utf8)!),
        ]
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_text3d_nan_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encodePkg(files).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "text3d_nan", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: "text3d_nan", tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }

        // 배선 확인: NaN origin 텍스트도 빌보드 자체는 생성된다(스킵은 evaluate 이후 encode 단계) — 배경
        // 솔리드(id=1) + 텍스트(id=9) = 2.
        XCTAssertEqual(renderer.billboards.count, 2)

        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0], toDir: output).first)
        let image = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let center = try XCTUnwrap(image.colorAt(x: 32, y: 32))
        // 배경 솔리드(흰색)가 NaN 쿼드에 가려지지 않고 그대로 보여야 함(무크래시 + 무아티팩트).
        XCTAssertGreaterThan(center.redComponent, 0.9, "NaN origin 텍스트 빌보드가 배경을 가리면 안 됨(center.isFinite 가드)")
        XCTAssertGreaterThan(center.greenComponent, 0.9)
        XCTAssertGreaterThan(center.blueComponent, 0.9)
    }
}
