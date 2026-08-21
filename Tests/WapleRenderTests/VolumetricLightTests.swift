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
                     "innercone":10,"outercone":30,"radius":20,
                     "castvolumetrics":true,"density":3,"volumetricsexponent":1},
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
        let corner = try XCTUnwrap(image.colorAt(x: 2, y: 2))

        // **[2026-08-21] 단언을 절대 밝기에서 대비로 바꿨다.**
        //
        // 종전은 `center.red > 0.5` 였는데, 그 문턱은 **옛 모델**(카메라 한 점에서 뷰 레이 각도로
        // 원뿔을 만들어 화면 전체에 워시를 까는 1샘플 근사)에 맞춰 잡힌 값이다. 실물 모델은
        // 라이트 반경 구 안을 훑는 레이마치라 절대 밝기가 `radius`·`intensity`·샘플 수에 함께
        // 걸리고, 그래서 이 문턱은 **이 테스트가 지키려는 성질과 무관한 축**에서 깨진다.
        //
        // 이 테스트의 성질은 "정면 스팟(angles=0)이 **카메라 쪽을 향한다**" 이고, 그건
        // **중앙이 주변보다 훨씬 밝다** 로 재는 것이 정확하다. 방향/콘 변환기가 회귀해
        // 오일러 각을 방향 벡터로 그대로 쓰면 direction 이 (0,0,0) 이 되고 콘 내적이 0 →
        // `smoothstep(cos30°, cos10°, 0) = 0` 이라 **화면이 통째로 검어져** 두 단언이 다 깨진다.
        //
        // 픽스처에 `"radius":20` 을 넣은 것도 같은 이유다 — 반경 없는 볼류메트릭 라이트는
        // 실물 모델에서 퇴화(헐 반경 1)라 WE 에서도 거의 안 보인다. 재는 대상이 아니었다.
        //
        // CPU 쪽 `VolumetricMath` 로 같은 픽스처를 풀면 center ≈ 0.506 · corner ≈ 0.047 로
        // 10배 차다(리눅스에서 단독 컴파일해 실측). Metal 실렌더는 여기서 못 돌리므로
        // 최종 검증은 macOS CI 다.
        XCTAssertGreaterThan(center.redComponent, corner.redComponent + 0.1,
            "정면 스팟(angles=0)이 좁은 콘으로 카메라를 향해야 하는데 중앙이 주변보다 밝지 않다 — 방향/콘 변환기 미사용 회귀")
        XCTAssertGreaterThan(center.redComponent, 0.1,
            "화면 중앙이 사실상 검다 — 볼류메트릭이 아예 발화하지 않았다")
    }
}
