import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// H4: 3D 메시 머티리얼 REFRACT(스크린 굴절) — 콤보/상수 파싱·파이프라인 빌드·배경 재샘플 픽셀 단언.
/// 씬 구성은 Scene3DPBRShadowRenderTests, 마운트 스캐폴드는 SceneRendererMeshCustomShaderTests 패턴.
final class SceneRendererMeshRefractTests: XCTestCase {

    // MARK: 공용 스캐폴드

    /// 좌반=적/우반=청 64×64 배경 패턴 .tex(solidTex 와 같은 TEXV0005+PNG 인코딩).
    private func splitTex() -> Data {
        let w = 64, h = 64
        var px = [UInt8](); px.reserveCapacity(w * h * 4)
        for _ in 0..<h {
            for x in 0..<w {
                if x < w / 2 { px.append(contentsOf: [255, 0, 0, 255]) }
                else { px.append(contentsOf: [0, 0, 255, 255]) }
            }
        }
        let png = OffscreenCapture.png(rgba: px, width: w, height: h)!
        var tex = Data("TEXV0005".utf8)
        tex.append(Data(repeating: 0, count: 34))
        tex.append(png)
        return tex
    }

    private func project(files: [(String, Data)], id: String) throws -> (WallpaperProject, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_h4m_\(id)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        return (WallpaperProject(id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
                                 title: id, tags: [], contentRating: nil, workshopId: nil,
                                 dependency: nil, folderURL: dir), dir)
    }

    private func capture(scene: String, files: [(String, Data)], tag: String) throws -> NSBitmapImageRep {
        let (proj, root) = try project(files: [("scene.json", Data(scene.utf8))] + files, id: tag)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: proj)
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0], toDir: output).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    /// perspective 3D 씬: 배경 평면(z=-1, split 패턴, unlit) + refract 평면(z=+1, 흰 albedo).
    private let refractScene = """
    {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
     "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,
                "clearcolor":"0 0 0","ambientcolor":"0 0 0","skylightcolor":"0 0 0"},
     "objects":[
       {"id":1,"name":"bg","model":"models/bg.mdl","origin":"0 0 -1","scale":"3 3 3","castshadow":false},
       {"id":2,"name":"fx","model":"models/fx.mdl","origin":"0 0 1","scale":"3 3 3","castshadow":false}
     ]}
    """

    /// refract 평면 머티리얼. amount=0.25 → 오프셋 x ≈ 0.25×1.035 ≈ 0.259(64px 중 ~16.6px).
    /// 노멀맵 단색 (r=255=mask, g=128→ny≈0, a=255→nx≈1.035) — RGBA PNG 디코드라 rg88=false 경로.
    private func fxMaterial(amount: Float, refractCombo: Bool = true, withNormal: Bool = true) -> String {
        let combo = refractCombo ? #","combos":{"LIGHTING":0,"REFRACT":1}"# : #","combos":{"LIGHTING":0}"#
        let textures = withNormal ? #"["white","normal"]"# : #"["white"]"#
        return #"{"passes":[{"textures":\#(textures)\#(combo),"constantshadervalues":{"ui_editor_properties_refract_amount":\#(amount)}}]}"#
    }

    private func refractFiles(amount: Float, refractCombo: Bool = true, withNormal: Bool = true) -> [(String, Data)] {
        [
            ("models/bg.mdl", planeModel(material: "materials/bg.json")),
            ("models/fx.mdl", planeModel(material: "materials/fx.json")),
            ("materials/bg.json", Data(#"{"passes":[{"textures":["split"],"combos":{"LIGHTING":0}}]}"#.utf8)),
            ("materials/fx.json", Data(fxMaterial(amount: amount, refractCombo: refractCombo, withNormal: withNormal).utf8)),
            ("materials/split.tex", splitTex()),
            ("materials/white.tex", solidTex(255, 255, 255)),
            ("materials/normal.tex", solidTex(255, 128, 128, alpha: 255)),
        ]
    }

    // MARK: 파싱/파이프라인 단언

    /// H4: REFRACT 콤보+노멀맵+amount 가 GPU3DMesh 까지 파싱되고 mf_refract 파이프라인이 빌드된다.
    func testRefractMeshParsesComboAndBuildsPipeline() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0},
         "objects":[{"id":1,"name":"fx","model":"models/fx.mdl","origin":"0 0 0"}]}
        """
        let (proj, root) = try project(files: [("scene.json", Data(scene.utf8))] + refractFiles(amount: 0.1),
                                       id: "refractparse")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: proj)
        defer { r.teardown() }
        XCTAssertEqual(r.meshRenderables.count, 1)
        let mesh = try XCTUnwrap(r.meshRenderables.first?.meshes.first)
        XCTAssertTrue(mesh.refract, "REFRACT:1 콤보 + textures[1] 노멀맵이면 mesh.refract 가 켜져야 함")
        XCTAssertNotNil(mesh.refractNormal)
        XCTAssertEqual(mesh.refractAmount, 0.1, accuracy: 1e-4,
                       "ui_editor_properties_refract_amount 상수가 전달돼야 함")
        XCTAssertNotNil(r.meshPipelineRefract, "mf_refract MSL 이 디바이스에서 컴파일/링크돼야 함")
        XCTAssertNotNil(r.meshPipelineRefractAdditive)
    }

    /// H4: REFRACT 콤보가 없으면 refract 미적용(무회귀 — 기존 파이프라인 경로 유지).
    func testMeshWithoutRefractComboNotRefracted() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0},
         "objects":[{"id":1,"name":"fx","model":"models/fx.mdl","origin":"0 0 0"}]}
        """
        let (proj, root) = try project(files: [("scene.json", Data(scene.utf8))] + refractFiles(amount: 0.1, refractCombo: false),
                                       id: "norefract")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: proj)
        defer { r.teardown() }
        let mesh = try XCTUnwrap(r.meshRenderables.first?.meshes.first)
        XCTAssertFalse(mesh.refract)
        XCTAssertNil(mesh.refractNormal)
    }

    /// H4: REFRACT:1 이어도 노멀맵(textures[1])이 없으면 미적용 — 파싱 실패 무크래시 폴터.
    func testRefractComboWithoutNormalMapFallsBack() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0},
         "objects":[{"id":1,"name":"fx","model":"models/fx.mdl","origin":"0 0 0"}]}
        """
        let (proj, root) = try project(files: [("scene.json", Data(scene.utf8))] + refractFiles(amount: 0.1, withNormal: false),
                                       id: "nonormal")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: proj)
        defer { r.teardown() }
        let mesh = try XCTUnwrap(r.meshRenderables.first?.meshes.first)
        XCTAssertFalse(mesh.refract, "노멀맵 없는 REFRACT 콤보는 적용되면 안 됨(2D 경로와 동일 게이트)")
        XCTAssertNil(mesh.refractNormal)
    }

    // MARK: 픽셀 단언(perspective)

    /// H4: refract 평면이 배경 평면을 노멀 오프셋으로 재샘플한다 — amount=0.25 면 화면 x+16.6px 위치의
    /// 배경색(청)이 나오고, amount=0 이면 제자리 샘플(적), 콤보 없음이면 albedo 그대로(흰)여야 한다.
    func testRefractMeshOffsetsBackgroundSample() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let refracted = try capture(scene: refractScene, files: refractFiles(amount: 0.25), tag: "rf025")
        let zero = try capture(scene: refractScene, files: refractFiles(amount: 0), tag: "rf0")
        let plain = try capture(scene: refractScene, files: refractFiles(amount: 0.25, refractCombo: false), tag: "rfplain")

        // (16,32): 배경은 적(좌반). 오프셋 적용 시 fb 샘플 x ≈ 33 → 청.
        let shifted = try XCTUnwrap(refracted.colorAt(x: 16, y: 32))
        XCTAssertGreaterThan(shifted.blueComponent, 0.6,
                             "refract: 오프셋만큼 이동한 배경(청)이 보여야 함 — 실측 \(shifted)")
        XCTAssertLessThan(shifted.redComponent, 0.3, "refract: 제자리 배경(적)이면 굴절이 적용되지 않은 것")
        // amount=0: 오프셋 0 → 제자리 배경(적) 그대로.
        let unshifted = try XCTUnwrap(zero.colorAt(x: 16, y: 32))
        XCTAssertGreaterThan(unshifted.redComponent, 0.6,
                             "amount=0: 제자리 배경(적)이 보여야 함 — 실측 \(unshifted)")
        // 콤보 없음: 배경 재샘플 없이 흰 albedo 불투명 → 흰색.
        let plainPx = try XCTUnwrap(plain.colorAt(x: 16, y: 32))
        XCTAssertGreaterThan(plainPx.redComponent, 0.9, "무콤보 대조군은 흰 albedo 여야 함")
        XCTAssertGreaterThan(plainPx.blueComponent, 0.9, "무콤보 대조군은 흰 albedo 여야 함")
    }

    // MARK: 픽셀 단언(ortho 하이브리드)

    /// H4: ortho(2D) 씬에 인터리브된 3D 메시의 REFRACT — 하위 order 의 2D 배경 레이어를 스냅샷해
    /// 노멀 오프셋으로 재샘플한다(runOrtho3DMeshes 분기). perspective 와 같은 오프셋 규약.
    func testOrthoHybridRefractMeshDistorts2DBackground() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/bgimg.json","origin":"32 32 0","size":"64 64","scale":"1 1 1",
            "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":true},
           {"id":2,"name":"fx","model":"models/fx.mdl","origin":"32 32 0","scale":"32 32 32"}
         ]}
        """
        let files: [(String, Data)] = [
            ("models/bgimg.json", Data(#"{"width":64,"height":64,"material":"materials/bg.json"}"#.utf8)),
            ("models/fx.mdl", planeModel(material: "materials/fx.json")),
            ("materials/bg.json", Data(#"{"passes":[{"textures":["split"]}]}"#.utf8)),
            ("materials/fx.json", Data(fxMaterial(amount: 0.25).utf8)),
            ("materials/split.tex", splitTex()),
            ("materials/white.tex", solidTex(255, 255, 255)),
            ("materials/normal.tex", solidTex(255, 128, 128, alpha: 255)),
        ]
        let refracted = try capture(scene: scene, files: files, tag: "orthorf")
        // (16,32): 2D 배경은 적(좌반). ortho 메시 refract 오프셋 적용 시 fb 샘플 x ≈ 33 → 청.
        let shifted = try XCTUnwrap(refracted.colorAt(x: 16, y: 32))
        XCTAssertGreaterThan(shifted.blueComponent, 0.6,
                             "ortho refract: 오프셋만큼 이동한 2D 배경(청)이 보여야 함 — 실측 \(shifted)")
        XCTAssertLessThan(shifted.redComponent, 0.3, "ortho refract: 제자리 배경(적)이면 굴절 미적용")

        // 대조군: 콤보 없음 → 흰 albedo 불투명(배경 재샘플 없음).
        var plainFiles = files
        plainFiles[3] = ("materials/fx.json", Data(fxMaterial(amount: 0.25, refractCombo: false).utf8))
        let plain = try capture(scene: scene, files: plainFiles, tag: "orthoplain")
        let plainPx = try XCTUnwrap(plain.colorAt(x: 16, y: 32))
        XCTAssertGreaterThan(plainPx.redComponent, 0.9, "무콤보 대조군은 흰 albedo 여야 함")
        XCTAssertGreaterThan(plainPx.blueComponent, 0.9, "무콤보 대조군은 흰 albedo 여야 함")
    }
}
