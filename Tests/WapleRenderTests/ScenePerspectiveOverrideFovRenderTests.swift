import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// W-7/W-8: `general.perspectiveoverridefov` 의 2D perspective 레이어 소비.
///
/// 원본 `wallpaper64.exe` 근거:
/// - `0x140189278`–`0x1401892c4`: 정사영 씬의 실효 FOV = `perspectiveoverridefov`
/// - `0x140189b1a`–`0x140189b4c`: 매 프레임 `[0.1, 179.9]` 클램프
/// - `0x140184f17`–`0x140184fb3`: `d=H/(2*tan(fov/2))`, `s(z)=d/(d-z)`
///
/// 종전 렌더러는 FOV 95를 두 경로에 하드코딩하고, 실제 원근행렬 대신 쿼드 상단 x만 임의로
/// 축소했다. 그 근사는 `z=0`도 정사영과 다르게 만들어 바이너리의 핵심 불변식을 깨뜨렸다.
final class ScenePerspectiveOverrideFovRenderTests: XCTestCase {
    private func captureTextScene(_ scene: String, id: String) throws -> NSBitmapImageRep {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([("scene.json", Data(scene.utf8))]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: id, tags: [], contentRating: nil, workshopId: nil,
                                       dependency: nil, folderURL: dir)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)),
                           project: project)
        defer { renderer.teardown() }
        let output = dir.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let png = try XCTUnwrap(renderer.captureFrames(width: 200, height: 200, times: [0.2],
                                                       toDir: output).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: png)))
    }

    private func captureImageScene(_ scene: String, id: String) throws -> NSBitmapImageRep {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", Data(scene.utf8)),
            ("models/x.json", Data(#"{"material":"materials/x.json"}"#.utf8)),
            ("materials/x.json", Data(#"{"passes":[{"textures":["x"]}]}"#.utf8)),
            ("materials/x.tex", solidTex(255, 255, 255)),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: id, tags: [], contentRating: nil, workshopId: nil,
                                       dependency: nil, folderURL: dir)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200)),
                           project: project)
        defer { renderer.teardown() }
        let output = dir.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let png = try XCTUnwrap(renderer.captureFrames(width: 200, height: 200, times: [0.2],
                                                       toDir: output).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: png)))
    }

    private func inkBounds(_ bitmap: NSBitmapImageRep) -> CGRect? {
        var minX = bitmap.pixelsWide, minY = bitmap.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let c = bitmap.colorAt(x: x, y: y), c.redComponent > 0.4 else { continue }
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private func layer(perspective: Bool, originZ: Float) -> SceneLayer {
        var layer = SceneLayer(
            textureEntryName: "materials/x.tex",
            origin: Vec2(x: 100, y: 75),
            size: Vec2(x: 40, y: 20),
            scale: Vec2(x: 1, y: 1),
            angleZ: 0,
            alpha: 1,
            color: Vec3(x: 1, y: 1, z: 1),
            brightness: 1,
            parallaxDepth: Vec2(x: 1, y: 1),
            effects: []
        )
        layer.perspective = perspective
        layer.originZ = originZ
        return layer
    }

    /// 실물 카메라는 z=0 평면이 정사영과 같은 크기가 되도록 거리를 역산한다. FOV가 달라도
    /// z=0이면 정점 여섯 개가 비트동일해야 한다(종전 "상단만 축소" 근사는 여기서 실패).
    func testPerspectiveAtZeroDepthIsBitIdenticalToOrthographic() {
        let orthographic = SceneRenderer.quadVertices(
            layer: layer(perspective: false, originZ: 0), projW: 400, projH: 200,
            perspectiveFov: 90.760002
        )
        let perspective = SceneRenderer.quadVertices(
            layer: layer(perspective: true, originZ: 0), projW: 400, projH: 200,
            perspectiveFov: 90.760002
        )

        XCTAssertEqual(perspective, orthographic,
                       "WE: z=0 perspective 평면은 정사영과 픽셀/정점 동일")
    }

    /// 카메라 쪽(+z) 레이어는 캔버스 중심을 기준으로 `s=d/(d-z)` 만큼 커진다. 상단만 찌그러뜨리는
    /// 사다리꼴이 아니라 네 코너 모두 같은 배율을 받는 평면 원근이다.
    func testPerspectiveDepthUsesBinaryDerivedUniformScaleAroundCanvasCenter() {
        let fov: Float = 60
        let z: Float = 25
        let vertices = SceneRenderer.quadVertices(
            layer: layer(perspective: true, originZ: z), projW: 400, projH: 200,
            perspectiveFov: fov
        )

        let scale = SceneCameraMath.layerPerspectiveScale(z: z, orthoHeight: 200, fovDegrees: fov)
        // 회전 0인 TL의 정사영 픽셀 좌표 = (80, 85), 캔버스 중심 = (200, 100).
        let expectedX = (200 + (80 - 200) * scale) / 400 * 2 - 1
        let expectedY = (100 + (85 - 100) * scale) / 200 * 2 - 1
        XCTAssertEqual(vertices[0].x, expectedX, accuracy: 1e-6)
        XCTAssertEqual(vertices[0].y, expectedY, accuracy: 1e-6)

        // 같은 평면의 폭/높이는 모두 동일 배율 — 사다리꼴(상단-only 축소) 회귀를 직접 차단.
        let topWidth = vertices[1].x - vertices[0].x
        let bottomWidth = vertices[2].x - vertices[5].x
        XCTAssertEqual(topWidth, bottomWidth, accuracy: 1e-6)
    }

    /// `preview3dclock` 스크립트가 대입하는 x/y 각은 z-회전처럼 2D 평면에서 버릴 값이
    /// 아니다. Rx 회전으로 상단은 카메라에 가깝고 하단은 멀어진 각 코너를 각자 원근나눗한다.
    func testPerspectiveConsumesTextAnglesXYPerVertex() {
        let fov: Float = 60
        let angleX = Float.pi / 6
        let vertices = SceneRenderer.quadVertices(
            origin: Vec2(x: 200, y: 100), size: Vec2(x: 40, y: 20),
            scale: Vec2(x: 1, y: 1), angleZ: 0, alignment: "center",
            projW: 400, projH: 200, perspective: true, perspectiveFov: fov,
            originZ: 0, angleX: angleX, angleY: 0
        )

        let d = SceneCameraMath.layerPerspectiveDistance(orthoHeight: 200, fovDegrees: fov)
        let topZ = Float(10) * sin(angleX)
        let topY = Float(100) + Float(10) * cos(angleX)
        let topScale = d / (d - topZ)
        let expectedX = (200 + (180 - 200) * topScale) / 400 * 2 - 1
        let expectedY = (100 + (topY - 100) * topScale) / 200 * 2 - 1
        XCTAssertEqual(vertices[0].x, expectedX, accuracy: 1e-6)
        XCTAssertEqual(vertices[0].y, expectedY, accuracy: 1e-6)

        let topWidth = vertices[1].x - vertices[0].x
        let bottomWidth = vertices[2].x - vertices[5].x
        XCTAssertGreaterThan(topWidth, bottomWidth,
                             "Rx 회전으로 카메라에 가까운 상단이 더 넓어야")

        let angleY = Float.pi / 6
        let yawed = SceneRenderer.quadVertices(
            origin: Vec2(x: 200, y: 100), size: Vec2(x: 40, y: 20),
            scale: Vec2(x: 1, y: 1), angleZ: 0, alignment: "center",
            projW: 400, projH: 200, perspective: true, perspectiveFov: fov,
            originZ: 0, angleX: 0, angleY: angleY
        )
        // Ry 에서 왼쪽 코너 x=-20은 z=+10으로 카메라에 가까워지고,
        // x 좌표 자체는 -20*cos(30°)로 줄어든 뒤 코너별 원근나눗된다.
        let leftZ = Float(20) * sin(angleY)
        let leftX = Float(200) - Float(20) * cos(angleY)
        let leftScale = d / (d - leftZ)
        let expectedYawX = (200 + (leftX - 200) * leftScale) / 400 * 2 - 1
        let expectedYawY = (100 + (110 - 100) * leftScale) / 200 * 2 - 1
        XCTAssertEqual(yawed[0].x, expectedYawX, accuracy: 1e-6)
        XCTAssertEqual(yawed[0].y, expectedYawY, accuracy: 1e-6)

        let leftHeight = yawed[0].y - yawed[5].y
        let rightHeight = yawed[1].y - yawed[2].y
        XCTAssertGreaterThan(leftHeight, rightHeight,
                             "Ry 회전으로 카메라에 가까운 왼쪽 변이 더 높아야")
    }

    /// 레이어 카메라는 near=5, far=max(15000,d+1000)을 쓴다. 정점 소비가 이 클립을
    /// 건너뛰면 카메라 뒤 z에서 음수 배율로 뒤집힌 쿼드가 나오고, far 밖 레이어도 계속 그려진다.
    func testPerspectiveConsumesBinaryNearFarClip() {
        let fov: Float = 60
        let d = SceneCameraMath.layerPerspectiveDistance(orthoHeight: 200, fovDegrees: fov)
        let clip = SceneCameraMath.layerPerspectiveClip(distance: d)
        func vertices(at z: Float) -> [SIMD4<Float>] {
            SceneRenderer.quadVertices(
                origin: Vec2(x: 200, y: 100), size: Vec2(x: 40, y: 20),
                scale: Vec2(x: 1, y: 1), angleZ: 0, alignment: "center",
                projW: 400, projH: 200, perspective: true, perspectiveFov: fov,
                originZ: z
            )
        }

        XCTAssertTrue(vertices(at: d + 1).isEmpty, "카메라 뒤(depth<0)는 클립")
        XCTAssertTrue(vertices(at: d - (clip.near - 0.01)).isEmpty, "near 안쪽은 클립")
        XCTAssertEqual(vertices(at: d - clip.near).count, 6, "near 평면은 포함")
        XCTAssertEqual(vertices(at: d - clip.far).count, 6, "far 평면은 포함")
        XCTAssertTrue(vertices(at: d - (clip.far + 1)).isEmpty, "far 밖은 클립")
    }

    /// 회전 평면이 near를 가로질러도 전체를 버리지 않고, 보이는 부분을 near 평면에서
    /// 잘라 유한한 삼각형으로 남겨야 한다. 쿼드 단위 all-or-nothing 가드의 사각지대를 막는다.
    func testTiltedPerspectiveQuadIsClippedAtNearPlaneInsteadOfDropped() {
        let fov: Float = 60
        let d = SceneCameraMath.layerPerspectiveDistance(orthoHeight: 200, fovDegrees: fov)
        let vertices = SceneRenderer.quadVertices(
            origin: Vec2(x: 200, y: 100), size: Vec2(x: 40, y: 40),
            scale: Vec2(x: 1, y: 1), angleZ: 0, alignment: "center",
            projW: 400, projH: 200, perspective: true, perspectiveFov: fov,
            originZ: d - 10, angleX: .pi / 3, angleY: 0
        )

        XCTAssertFalse(vertices.isEmpty)
        XCTAssertEqual(vertices.count % 3, 0)
        XCTAssertTrue(vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        // 상단 두 코너는 near 뒤, 하단은 안에 있어 클립 경계가 새 정점으로 생긴다.
        XCTAssertEqual(vertices.count, 6)
    }

    /// 클램프는 파서가 아니라 렌더 소비에서 일어난다. NaN의 `minss` 피연산자 규칙까지 옮긴
    /// `CameraMotion.clampedFovDegrees`를 실제 정점 경로가 사용해야 한다.
    ///
    /// [정정 2026-09-01] 종전 이 테스트는 `originZ = 25`를 썼다. 상한 FOV(179.9°)에서
    /// `d = H/(2·tan(fov/2)) = 100/tan(89.95°) ≈ 0.087`이므로 `depth = d − 25 < near(5)`라
    /// **세 결과가 전부 `[]`**였고, 단언 셋은 `[] == []`이 됐다. `clampedFovDegrees` 호출을
    /// 통째로 지워도 초록이었다 — 잠근다고 적힌 것을 하나도 잠그지 않았다.
    /// `originZ = −200`이면 `depth = d + 200 ≈ 200.09`로 `[near 5, far 15000]` 안이라
    /// 상한 FOV가 정점 여섯 개를 낸다. 클램프가 빠지면
    /// `fov=1000` → `d = 100/tan(500°) ≈ −119.2`로 배율 부호가 갈리고,
    /// `fov=NaN` → `d`가 NaN이라 near 비교가 거짓이 되어 `[]`가 되므로 두 단언이 모두 깨진다.
    func testPerspectiveFovIsClampedAtRenderConsumption() {
        let l = layer(perspective: true, originZ: -200)
        let over = SceneRenderer.quadVertices(layer: l, projW: 400, projH: 200,
                                              perspectiveFov: 1_000)
        let nan = SceneRenderer.quadVertices(layer: l, projW: 400, projH: 200,
                                             perspectiveFov: .nan)
        let capped = SceneRenderer.quadVertices(layer: l, projW: 400, projH: 200,
                                                perspectiveFov: 179.89999389648438)
        // 모집단 하한 — 세 결과가 전부 빈 배열이면 아래 두 단언은 아무것도 잠그지 않는다.
        XCTAssertEqual(capped.count, 6, "상한 FOV·z=−200은 near/far 안이라 쿼드가 남아야 한다")
        XCTAssertEqual(over, capped)
        XCTAssertEqual(nan, capped)
    }

    /// 정적 GPU 레이어 빌드가 문서의 저작값을 실제 vertexBuffer까지 전달한다. 기본 95와 다른
    /// 60도를 써 z!=0에서 차이를 가시화한다(95가 계속 하드코딩되면 실패).
    func testBuildLayersConsumesAuthoredPerspectiveOverrideFov() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":400,"height":200},
                    "perspectiveoverridefov":60},
         "objects":[{"id":1,"image":"models/x.json","origin":"100 75 25","size":"40 20",
                     "perspective":true}]}
        """
        let package = ScenePackage.assemble([
            ("scene.json", Data(scene.utf8)),
            ("models/x.json", Data(#"{"material":"materials/x.json"}"#.utf8)),
            ("materials/x.json", Data(#"{"passes":[{"textures":["x"]}]}"#.utf8)),
            ("materials/x.tex", solidTex(255, 255, 255)),
        ])
        let doc = try SceneDocument.parse(package: package)
        let built = SceneRenderer().buildLayers(doc: doc, package: package, device: device,
                                                sceneID: "perspective-fov")
        let gpu = try XCTUnwrap(built.first)
        let actual = gpu.vertexBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 6)
        let expected = SceneRenderer.quadVertices(layer: doc.layers[0], projW: 400, projH: 200,
                                                  perspectiveFov: 60)
        for index in 0..<6 {
            XCTAssertEqual(actual[index], expected[index], "vertex \(index)")
        }

        let hardCoded95 = SceneRenderer.quadVertices(layer: doc.layers[0], projW: 400, projH: 200,
                                                     perspectiveFov: 95)
        XCTAssertNotEqual(actual[0], hardCoded95[0], "저작 60°가 리터럴 95°에 먹히면 안 됨")
    }

    /// 텍스트의 실제 래스터 GPU 버퍼가 파서에 남은 perspective/origin.z/x·y·z 각과
    /// 문서 FOV를 모두 소비한다. 순수 기하 테스트와 달리 이 테스트는 `buildTexts`의
    /// 실제 버퍼를 읽어 정적 텍스트 경로 배선 누락을 잡는다.
    func testBuildTextsConsumesPerspectiveOriginAndAllAngles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":400,"height":200},
                    "perspectiveoverridefov":60},
         "objects":[{"id":1,"name":"tilted","text":"M","font":"systemfont_arial",
                     "pointsize":16,"origin":"200 100 12","angles":"0.31 -0.22 0.17",
                     "scale":"1.1 0.8 1","perspective":true}]}
        """
        let package = ScenePackage.assemble([("scene.json", Data(scene.utf8))])
        let doc = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        renderer.projW = 400; renderer.projH = 200
        renderer.layerPerspectiveFov = doc.perspectiveOverrideFov
        let gpu = try XCTUnwrap(renderer.buildTexts(doc: doc, package: package, device: device).first)
        let buffer = try XCTUnwrap(gpu.vertexBuffer)
        let expected = SceneRenderer.quadVertices(
            origin: doc.texts[0].origin,
            size: Vec2(x: gpu.rasterWidth, y: gpu.rasterHeight), scale: doc.texts[0].scale,
            angleZ: doc.texts[0].angleZ,
            alignment: SceneRenderer.textAlignmentString(h: doc.texts[0].horizontalAlign,
                                                         v: doc.texts[0].verticalAlign),
            projW: 400, projH: 200, perspective: true, perspectiveFov: 60,
            originZ: 12, angleX: 0.31, angleY: -0.22
        )
        XCTAssertEqual(gpu.vertexCount, expected.count)
        let actual = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: gpu.vertexCount)
        for index in expected.indices {
            XCTAssertEqual(actual[index], expected[index], "text vertex \(index)")
        }
    }

    /// 동봉 시계와 동형으로 **text content update** 스크립트가 `thisLayer.angles`를 직접
    /// 대입하는 경로를 픽셀로 잠그다. 이 스크립트는 `propertyScripts["angles"]`가 아니므로
    /// read-back을 propScripts 유무로만 게이트하면 60° Rx가 손실돼 기준 신과 똑같이 그려진다.
    func testTextContentScriptAngleAssignmentReachesPerspectivePixels() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func scene(angleXDegrees: Int) -> String {
            """
            {"general":{"orthogonalprojection":{"width":200,"height":200},
                        "perspectiveoverridefov":60,"clearcolor":"0 0 0"},
             "objects":[{"id":1,"name":"clock","font":"systemfont_arial","pointsize":16,
                         "color":"1 1 1","origin":"100 100 0","perspective":true,
                         "text":{"value":"MMMM","script":"export function update(value){ thisLayer.angles = new Vec3(\(angleXDegrees), 0, 0); return value; }"}}]}
            """
        }
        let flat = try captureTextScene(scene(angleXDegrees: 0), id: "waple_perspective_text_flat")
        let tilted = try captureTextScene(scene(angleXDegrees: 60), id: "waple_perspective_text_tilted")
        let flatBounds = try XCTUnwrap(inkBounds(flat))
        let tiltedBounds = try XCTUnwrap(inkBounds(tilted))

        XCTAssertGreaterThan(flatBounds.height, 20)
        XCTAssertLessThan(tiltedBounds.height, flatBounds.height * 0.8,
                          "content update의 Rx=60°가 원근 텍스트 정점까지 도달해야")
    }

    /// 이미지 레이어의 다른 프로퍼티 스크립트가 `thisLayer.angles`를 직접 대입하는 표준
    /// read-back 경로도 세 각을 모두 보존해야 한다. 종전 encodeLayer는 z만 되읽어 Rx가
    /// 정적 0으로 남았고, perspective 이미지가 평면 쿼드와 똑같이 그려졌다.
    func testImageAngleXYReadBackReachesPerspectivePixels() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func scene(angleXDegrees: Int) -> String {
            """
            {"general":{"orthogonalprojection":{"width":200,"height":200},
                        "perspectiveoverridefov":60,"clearcolor":"0 0 0"},
             "objects":[{"id":1,"image":"models/x.json","origin":"100 100 0","size":"80 60",
                         "scale":"1 1 1","angles":"0 0 0","perspective":true,
                         "alpha":{"value":1,"script":"thisLayer.angles = new Vec3(\(angleXDegrees), 0, 0); export function update(value){ return value; }"}}]}
            """
        }
        let flat = try captureImageScene(scene(angleXDegrees: 0), id: "waple_perspective_image_readback_flat")
        let tilted = try captureImageScene(scene(angleXDegrees: 60), id: "waple_perspective_image_readback_tilted")
        let flatBounds = try XCTUnwrap(inkBounds(flat))
        let tiltedBounds = try XCTUnwrap(inkBounds(tilted))

        XCTAssertGreaterThan(flatBounds.height, 50)
        XCTAssertLessThan(tiltedBounds.height, flatBounds.height * 0.8,
                          "thisLayer.angles.x=60°가 이미지 원근 정점까지 도달해야")
    }

    /// perspective 이미지의 origin은 Vec3 전체가 카메라 입력이다. 다른 키에 붙은 스크립트가
    /// `thisLayer.origin.z`를 직접 바꾸면 중심은 유지한 채 쿼드가 가까워진 비율만큼 커져야 한다.
    func testImageOriginZReadBackReachesPerspectivePixels() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func scene(originZ: Int) -> String {
            """
            {"general":{"orthogonalprojection":{"width":200,"height":200},
                        "perspectiveoverridefov":60,"clearcolor":"0 0 0"},
             "objects":[{"id":1,"image":"models/x.json","origin":"100 100 0","size":"80 60",
                         "scale":"1 1 1","angles":"0 0 0","perspective":true,
                         "alpha":{"value":1,"script":"thisLayer.origin = new Vec3(100, 100, \(originZ)); export function update(value){ return value; }"}}]}
            """
        }
        let flat = try captureImageScene(scene(originZ: 0), id: "waple_perspective_image_originz_flat")
        let nearer = try captureImageScene(scene(originZ: 40), id: "waple_perspective_image_originz_nearer")
        let flatBounds = try XCTUnwrap(inkBounds(flat))
        let nearerBounds = try XCTUnwrap(inkBounds(nearer))

        XCTAssertGreaterThan(nearerBounds.width, flatBounds.width * 1.2,
                             "thisLayer.origin.z=40이 이미지 원근 스케일에 도달해야")
    }

    /// `angles` 자체의 update 반환값도 Vec3 전부를 소비해야 한다. 직접 대입 read-back과는
    /// 별도 입력 채널이므로, 둘 중 하나만 3D로 올리고 다른 쪽을 종전 angleZ 전용으로 남기는
    /// 회귀를 픽셀 경계에서 차단한다.
    func testImageAngleXYPropertyUpdateReachesPerspectivePixels() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func scene(angleXDegrees: Int) -> String {
            """
            {"general":{"orthogonalprojection":{"width":200,"height":200},
                        "perspectiveoverridefov":60,"clearcolor":"0 0 0"},
             "objects":[{"id":1,"image":"models/x.json","origin":"100 100 0","size":"80 60",
                         "scale":"1 1 1","perspective":true,
                         "angles":{"value":"0 0 0","script":"export function update(value){ return new Vec3(\(angleXDegrees), 0, 0); }"}}]}
            """
        }
        let flat = try captureImageScene(scene(angleXDegrees: 0), id: "waple_perspective_image_update_flat")
        let tilted = try captureImageScene(scene(angleXDegrees: 60), id: "waple_perspective_image_update_tilted")
        let flatBounds = try XCTUnwrap(inkBounds(flat))
        let tiltedBounds = try XCTUnwrap(inkBounds(tilted))

        XCTAssertLessThan(tiltedBounds.height, flatBounds.height * 0.8,
                          "angles update의 x 성분이 이미지 원근 정점까지 도달해야")
    }

    /// 프로퍼티 키프레임은 c0/c1/c2가 각각 x/y/z 각이다. encodeLayer가 c2만 읽으면
    /// t=0.2의 Rx=60°도 평면과 같은 높이로 남는다.
    func testImageAngleXYAnimationReachesPerspectivePixels() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func scene(animated: Bool) -> String {
            let angles = animated
                ? #"{"value":"0 0 0","animation":{"c0":[{"frame":0,"value":0},{"frame":6,"value":1.04719755}],"c1":[{"frame":0,"value":0},{"frame":6,"value":0}],"c2":[{"frame":0,"value":0},{"frame":6,"value":0}],"options":{"fps":30,"length":6,"mode":"single"}}}"#
                : #""0 0 0""#
            return """
            {"general":{"orthogonalprojection":{"width":200,"height":200},
                        "perspectiveoverridefov":60,"clearcolor":"0 0 0"},
             "objects":[{"id":1,"image":"models/x.json","origin":"100 100 0","size":"80 60",
                         "scale":"1 1 1","angles":\(angles),"perspective":true}]}
            """
        }
        let flat = try captureImageScene(scene(animated: false), id: "waple_perspective_image_anim_flat")
        let tilted = try captureImageScene(scene(animated: true), id: "waple_perspective_image_anim_tilted")
        let flatBounds = try XCTUnwrap(inkBounds(flat))
        let tiltedBounds = try XCTUnwrap(inkBounds(tilted))

        XCTAssertLessThan(tiltedBounds.height, flatBounds.height * 0.8,
                          "angles c0 키프레임의 x 회전이 이미지 원근 정점까지 도달해야")
    }

    /// 동봉 `preview3dclock`은 단순 예제가 아니라 텍스트 스크립트가 커서 위치로부터
    /// x/y 회전을 매 프레임 대입하는 실도달 자산이다. 파서가 `perspective`나 3D 초기값을
    /// 흘리면 뒤 렌더 경로를 고쳐도 스크립트 디스크립터는 정사영으로 남는다.
    func testBundledPreview3DClockPreservesTextPerspectiveState() throws {
        let root = try XCTUnwrap(bundledWEAssetsRoot())
        let sceneURL = root
            .appendingPathComponent("presets/clock/preview3dclock/scene.json")
        let package = ScenePackage.assemble([("scene.json", try Data(contentsOf: sceneURL))])
        let doc = try SceneDocument.parse(package: package)

        let text = try XCTUnwrap(doc.texts.first { $0.name == "3D Clock" })
        XCTAssertTrue(text.perspective)
        XCTAssertEqual(text.originZ, 0)
        XCTAssertEqual(text.angleX, 0)
        XCTAssertEqual(text.angleY, 0)
        XCTAssertTrue(try XCTUnwrap(text.script).contains("thisLayer.angles = rotation"),
                      "실자산이 x/y 라이브 회전 소비 경로에 도달함을 지킨")

        let descriptor = try XCTUnwrap(
            SceneRenderer.sceneScriptLayers(from: doc).first { $0.name == "3D Clock" }
        )
        XCTAssertTrue(descriptor.perspective)
        XCTAssertEqual(descriptor.origin.z, 0)
        XCTAssertEqual(descriptor.angles, SIMD3<Float>(repeating: 0))
    }

    /// `0x1401ed0d0`의 두 perspective 검사는 scene parent가 아니라
    /// transformAttachmentToTexture의 thisLayer/attachmentLayer OR다. 실제 렌더 래퍼는 자기
    /// bit7만 보므로 파서가 조상의 true를 자식에 전파하면 안 된다.
    func testPerspectiveFlagDoesNotPropagateFromSceneParent() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200}},
         "objects":[
           {"id":1,"text":"parent","origin":"100 100 0","perspective":true},
           {"id":2,"parent":1,"text":"child","origin":"0 0 0","perspective":false}
         ]}
        """
        let doc = try SceneDocument.parse(package: .assemble([("scene.json", Data(scene.utf8))]))
        XCTAssertTrue(try XCTUnwrap(doc.texts.first { $0.id == 1 }).perspective)
        XCTAssertFalse(try XCTUnwrap(doc.texts.first { $0.id == 2 }).perspective)
    }
}
