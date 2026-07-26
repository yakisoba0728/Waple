import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

final class VolumetricLightTests: XCTestCase {
    /// H5: castVolumetrics 라이트가 있는 3D 씬에서 VolumetricLightPass 가 빌드된다.
    func testVolumetricLightPassBuildsForCastVolumetricsScene() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"fov":50},
         "camera":{"eye":"0 0 10","center":"0 0 0","up":"0 1 0"},
         "objects":[{"light":"point","origin":"0 5 5","color":"1 0.9 0.8","intensity":2,"radius":20,
                     "castvolumetrics":true,"density":2.5,"volumetricsexponent":1.5}]}
        """
        let files: [(String, Data)] = [("scene.json", scene.data(using: .utf8)!)]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h5_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        try Data(#"{"type":"scene","title":"h5","file":"scene.pkg"}"#.utf8).write(to: dir.appendingPathComponent("project.json"))
        let project = try XCTUnwrap(try? ProjectJSONParser.parse(folderURL: dir))
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        XCTAssertNotNil(r.volumetricLightPass)
    }

    /// H5: castVolumetrics 없는 3D 씬은 패스 미빌드.
    func testNoVolumetricLightPassWithoutCastVolumetrics() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"fov":50},
         "camera":{"eye":"0 0 10","center":"0 0 0","up":"0 1 0"},
         "objects":[{"light":"point","origin":"0 5 5","color":"1 0.9 0.8","intensity":2,"radius":20}]}
        """
        let files: [(String, Data)] = [("scene.json", scene.data(using: .utf8)!)]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h5_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        try Data(#"{"type":"scene","title":"h5","file":"scene.pkg"}"#.utf8).write(to: dir.appendingPathComponent("project.json"))
        let project = try XCTUnwrap(try? ProjectJSONParser.parse(folderURL: dir))
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        XCTAssertNil(r.volumetricLightPass)
    }

    /// P④: 호출부가 오일러 각(angles)을 그대로 "방향"으로, 콘 원값(도)을 코사인 슬롯에 바인딩하던
    /// 버그의 회귀 테스트. angles="0 0 0"(항등 회전)은 SceneLight3D.forwardLightAxis 로 변환하면
    /// 카메라를 정면으로 바라보는 (0,0,1) 이 되어야 한다 — 좁은 콘(10/30도)이 카메라 축과 정렬돼
    /// 화면 중앙이 밝아진다. 종전 버그는 angles 원값을 그대로 방향 벡터로 바인딩해 (0,0,0) 이 되고
    /// (셰이더가 코사인 슬롯도 도(度) 원값으로 오염돼) dot(viewRay, -direction)=0 이 항상 콘 임계값보다
    /// 훨씬 작아 화면 전체가 검게(무발화) 남는다.
    func testVolumetricLightDirectionUsesForwardConverterNotRawEulerAngles() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // build3D/is3D 는 SceneRenderer.swift:1144 `doc.camera3D != nil && !doc.objects3D.isEmpty` 로
        // 진입한 뒤 `!meshRenderables.isEmpty || !billboards.isEmpty` 를 요구한다(:1147) — 라이트뿐인
        // 씬은 volumetricLightPass 가 빌드돼도(:1063, camera3D 게이트뿐) encode3D 자체가 결코 호출되지
        // 않아(2D 폴백) 전혀 발화하지 않는다. Scene3DRenderCorrectnessTests.captureBlendModeCenterPixel
        // 과 동일한 관례로 없는 .mdl(objects3D 게이트만 충족, 로드 실패는 무해)과 화면 밖 무텍스처
        // (flat) billboard(billboards 비게이트 충족, 중앙 픽셀엔 무영향)를 함께 둔다.
        let scene = """
        {"camera":{"eye":"0 0 10","center":"0 0 0","up":"0 1 0"},
         "general":{"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[{"id":0,"model":"models/missing.mdl"},
                    {"id":1,"light":"point","origin":"0 0 0","angles":"0 0 0","color":"1 1 1","intensity":6,
                     "innercone":10,"outercone":30,"castvolumetrics":true,"density":0,"volumetricsexponent":1},
                    {"id":2,"image":"models/offscreen.json","origin":"1000 1000 1000","size":"1 1"}]}
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/offscreen.json", Data(#"{"material":"materials/offscreen.json"}"#.utf8)),
            ("materials/offscreen.json", Data(#"{"passes":[{"shader":"flat","depthtest":"disabled","depthwrite":"disabled"}]}"#.utf8)),
        ]
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_volumetric_dir_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try encodePkg(files).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "volumetric_dir", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: "volumetric_dir", tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        defer { renderer.teardown() }
        XCTAssertNotNil(renderer.volumetricLightPass)
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0], toDir: output).first)
        let image = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let center = try XCTUnwrap(image.colorAt(x: 32, y: 32))
        XCTAssertGreaterThan(center.redComponent, 0.5,
            "정면 스팟(angles=0)이 좁은 콘으로 카메라를 정확히 향해야 하는데 화면 중앙이 검다 — 방향/콘 변환기 미사용 회귀")
    }
}
