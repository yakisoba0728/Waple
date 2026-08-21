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
        XCTAssertGreaterThan(center.redComponent, corner.redComponent + 0.1,
            "정면 스팟(angles=0)이 좁은 콘으로 카메라를 향해야 하는데 중앙이 주변보다 밝지 않다 — 방향/콘 변환기 미사용 회귀")
        XCTAssertGreaterThan(center.redComponent, 0.1,
            "화면 중앙이 사실상 검다 — 볼류메트릭이 아예 발화하지 않았다")

        // **[2026-08-21] CPU↔GPU 대조를 여기서 닫는다.**
        //
        // 위 두 단언은 "대비" 만 재므로 **셰이더 산술이 통째로 몇 배 어긋나도 통과한다**.
        // 실제로 그 상태에서 "CPU 는 1.0 인데 Metal 은 0.2235, 4.5배 차" 라는 보고가 나왔고,
        // 원인은 검산 쪽이 광축(ndc=0) 레이를 풀었던 것이었다(docs/re/volumetric-light.md §6.1).
        // 그 부류를 다시 조용히 지나가게 두지 않으려면, **같은 픽셀을 CPU 로 푼 값**과
        // 실렌더 픽셀을 직접 맞대야 한다. 예측은 `VolumetricMath.pixelValue` 가 낸다.
        //
        // 기대치를 변환기(`forwardLightAxis`/`forwardSpotConeCosines`)로 만들지 않고
        // **의도한 값 자체**(방향 (0,0,1) · 콘 코사인 cos5°/cos15°)로 만든다 — 변환기가 회귀하면
        // 기대치까지 같이 움직여 단언이 무력해지기 때문이다. 변환기 자체는 아래
        // `testVolumetricMathMirrorsShaderForFixturePixel` 이 따로 못 박는다.
        let predictedCenter = VolumetricMath.pixelValue(
            Self.directionFixtureInput(radius: 20), x: 32, y: 32, width: 64, height: 64)
        let predictedCorner = VolumetricMath.pixelValue(
            Self.directionFixtureInput(radius: 20), x: 2, y: 2, width: 64, height: 64)
        // 허용오차 0.02 ≈ 5/255. bgra8Unorm 양자화(1/255)와 GPU 초월함수(pow/smoothstep)의
        // 마지막 자리 차이는 넉넉히 덮으면서, 4.4배 같은 실제 발산은 확실히 잡는 폭이다.
        XCTAssertEqual(Float(center.redComponent), predictedCenter, accuracy: 0.02,
            "Metal 실렌더 중앙 픽셀이 CPU 미러(VolumetricMath.pixelValue)와 갈렸다 — metalSource 와 VolumetricMath 가 한 벌씩 따로 논다")
        XCTAssertEqual(Float(corner.redComponent), predictedCorner, accuracy: 0.02,
            "Metal 실렌더 코너 픽셀이 CPU 미러와 갈렸다 — 콘/반경 감쇠가 화면 가장자리에서 발산")
    }

    // MARK: - 순수 산술 레인 (GPU 불필요 — `VolumetricMath` 만 쓴다)

    /// 위 Metal 테스트와 **같은 픽스처**를 CPU 로 표현한 것. 두 테스트가 같은 입력을 보게 하는 자리다.
    /// 카메라 기저는 `SceneRenderer3D.encode3D` 가 만드는 것과 같다 —
    /// eye (0,0,10) → center 원점 · up (0,1,0) ⇒ fwd (0,0,-1) · right (1,0,0) · camUp (0,1,0).
    /// near/far 는 `SceneDocument.swift:1544-1545` 의 미저작 기본값(0.1 / 10000)이다.
    private static func directionFixtureInput(radius: Float) -> VolumetricMath.PixelInput {
        VolumetricMath.PixelInput(
            eye: SIMD3(0, 0, 10), forward: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
            fovYDegrees: 50, aspect: 1, nearZ: 0.1, farZ: 10000,
            lightPosition: SIMD3(0, 0, 0), lightForward: SIMD3(0, 0, 1),
            density: 3, exponent: 1, intensity: 6,
            innerCos: cos(10 * Float.pi / 180), outerCos: cos(30 * Float.pi / 180),
            radius: radius, sampleCount: VolumetricLightPass.marchSampleCount)
    }

    /// **[2026-08-21] "4.5배 차" 사건의 회귀 못.** Metal 도 GPU 도 필요 없다 —
    /// `VolumetricMath` 는 `import Foundation` 하나로 서므로 이 값들은 리눅스에서
    /// 블록만 잘라 그대로 재현된다(docs/re/volumetric-light.md §6).
    ///
    /// > **[2026-08-21 갱신]** 아래 서술의 `4.44배` · `0.2254` · `57` · `0.2235` 는 **종전(절반 폭)
    /// > 콘에서 잰 역사 기록**이다. 콘 변환기가 정정되면서(`docs/re/scene-lighting.md` §10) 같은
    /// > 픽스처의 값이 `0.545993` · 바이트 `139` · 비 `1.8315` 로 바뀌었다. 논증(픽셀 중심 레이 ≠
    /// > 광축 레이)은 그대로 성립하고 **배율만 작아진다** — 콘이 넓어져 반 픽셀 이탈의 손해가 준다.
    /// > 위 단언들은 새 값으로 갱신했고, 옛 값은 이 문단에 기록으로 남긴다.  [VA-정정]
    ///
    /// 못 박는 사실 셋:
    /// 1. **픽셀 중심 레이**로 푼 값이 실렌더 값이다 — 64×64 의 (32,32)는 광축이 아니라
    ///    반 픽셀(ndc ±1/64) 비껴 있고, `radius` 무저작(헐 0.99)에서는 그 반 픽셀이
    ///    **4.44배**를 만든다. 광축 레이로 검산하면 GPU 와 안 맞는 것이 정상이다.
    /// 2. 그때 값 0.2254 는 `bgra8Unorm` 에서 바이트 **57** 이고, 캡처 PNG 를
    ///    `NSBitmapImageRep.colorAt` 로 읽으면 57/255 = **0.2235** 다(감마 없음 —
    ///    `OffscreenCapture.png` 가 `.deviceRGB` 로 원바이트를 싣는다). 관측치와 일치한다.
    /// 3. 픽스처가 쓰는 변환기 두 개(`forwardLightAxis`/`forwardSpotConeCosines`)가 실제로
    ///    (0,0,1) · cos5°/cos15° 를 낸다 — 위 Metal 단언의 기대치가 하드코딩인 근거.
    func testVolumetricMathMirrorsShaderForFixturePixel() throws {
        // (3) 변환기 고정 — 기대치를 손으로 적어도 되는 근거.
        let axis = SceneLight3D.forwardLightAxis(angles: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(axis.x, 0, accuracy: 1e-6)
        XCTAssertEqual(axis.y, 0, accuracy: 1e-6)
        XCTAssertEqual(axis.z, 1, accuracy: 1e-6, "angles=0 은 카메라를 향하는 +Z 여야 한다")
        let cone = SceneLight3D.forwardSpotConeCosines(inner: 10, outer: 30)
        // **[2026-08-21 정정]** 저작값이 곧 **광축에서 잰 반각(도)** 이다 — `× 0.5` 는 없다.
        // 셰이더가 `smoothstep(Direction.w, Origin.w, -dot(normalize(lightDelta), Direction.xyz))`
        // 로 두 `.w` 를 반각 코사인 슬롯으로 쓴다(`docs/re/scene-lighting.md` §10).
        // 종전에는 `cos5°`/`cos15°` 를 기대해 **콘이 WE 절반 폭**이었다.
        XCTAssertEqual(cone.inner, cos(10 * Float.pi / 180), accuracy: 1e-6)
        XCTAssertEqual(cone.outer, cos(30 * Float.pi / 180), accuracy: 1e-6)

        // (1)(2) 픽셀 값 고정 — 리눅스 실측 2026-08-21.
        let wired = Self.directionFixtureInput(radius: 20)
        XCTAssertEqual(VolumetricMath.pixelValue(wired, x: 32, y: 32, width: 64, height: 64),
                       0.506209, accuracy: 1e-4, "radius=20 픽스처의 중앙 픽셀")
        XCTAssertEqual(VolumetricMath.pixelValue(wired, x: 2, y: 2, width: 64, height: 64),
                       0.191465, accuracy: 1e-4, "radius=20 픽스처의 코너 픽셀")

        let bare = Self.directionFixtureInput(radius: 0)   // 씬이 `radius` 를 저작하지 않은 경우 → 헐 0.99
        let barePixel = VolumetricMath.pixelValue(bare, x: 32, y: 32, width: 64, height: 64)
        XCTAssertEqual(barePixel, 0.545993, accuracy: 1e-4,
            "radius 무저작 픽스처의 중앙 픽셀 — 실측 Metal 값 57/255=0.2235 와 같은 자리다")
        XCTAssertEqual((min(1, max(0, barePixel)) * 255).rounded(), 139,
            "bgra8Unorm 양자화 바이트가 캡처 PNG 의 57 과 같아야 한다")

        // 같은 입력을 **광축 레이**(1×1 = ndc 정확히 (0,0))로 풀면 1.0 이다. 이 1.0 과 위 0.2254 의
        // 비가 곧 보고된 "4.5배" 이고, 두 구현이 갈린 것이 아니라 **레이가 갈린 것**이다.
        let onAxis = VolumetricMath.pixelValue(bare, x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(onAxis, 1.0, accuracy: 1e-4, "광축 레이 값 — 종전 검산이 보던 수")
        XCTAssertEqual(onAxis / barePixel, 1.8315, accuracy: 0.01,
            "광축/픽셀중심 비 = 보고된 4.5배의 정체(반 픽셀 각도 × 좁은 콘 × 작은 헐)")
        XCTAssertEqual(VolumetricMath.pixelNDC(x: 32, y: 32, width: 64, height: 64).x, 0.015625, accuracy: 1e-7,
            "짝수 해상도의 가운데 픽셀은 광축이 아니다 — 이 반 픽셀이 위 4.44배의 원인")
    }
}
