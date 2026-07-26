import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// M6(⑥): 3D 메시 머티리얼 REFLECTION(스크린공간 반사) — 콤보/상수 파싱·파이프라인 빌드·
/// 프레넬 가중 acc 스냅샷 가산 픽셀 단언. 스캐폴드는 SceneRendererMeshRefractTests(H4) 패턴 재사용.
final class SceneRendererMeshReflectTests: XCTestCase {

    // MARK: 공용 스캐폴드

    /// 유효 MDLV0023(비스키닝, ±1 XY 평면 4정점 — 로컬 노멀 (0,0,1) 고정, SceneRendererMeshRefractTests.planeModel 과 동일 레이아웃).
    private func planeModel(material: String) -> Data {
        var data = Data("MDLV0023".utf8)
        data.append(0)
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func f32(_ value: Float) {
            var little = value
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        u32(0x0000000f); u32(1); u32(1)
        data.append(Data(material.utf8)); data.append(0)
        u32(0)
        f32(-1); f32(-1); f32(0); f32(1); f32(1); f32(0)
        u32(0x0000000f)
        let vertices: [(Float, Float, Float, Float)] = [
            (-1, -1, 0, 1), (1, -1, 1, 1), (1, 1, 1, 0), (-1, 1, 0, 0),
        ]
        u32(UInt32(vertices.count * 48))
        for (x, y, u, v) in vertices {
            [x, y, 0, 0, 0, 1, 1, 0, 0, -1, u, v].forEach(f32)
        }
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        u32(UInt32(indices.count * MemoryLayout<UInt16>.stride))
        for index in indices {
            var little = index.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func project(files: [(String, Data)], id: String) throws -> (WallpaperProject, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_m6_\(id)_\(UUID().uuidString)", isDirectory: true)
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

    /// perspective 3D 씬: 흰 배경 평면(z=-1, unlit) + Y축 60° 로 기울인 검정 reflect 평면(z=+1, unlit).
    /// 기울임은 dot(N,V)=cos60°=0.5 로 프레넬 항을 0/1 극값에서 떼어놓기 위함(정면 평면은 fresnel=1 →
    /// (1-fresnel)=0 이라 반사가 항상 0으로 나와 "미구현"과 "구현했지만 항상 0" 을 구분 못 함).
    private let reflectScene = """
    {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
     "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,
                "clearcolor":"0 0 0","ambientcolor":"0 0 0","skylightcolor":"0 0 0"},
     "objects":[
       {"id":1,"name":"bg","model":"models/bg.mdl","origin":"0 0 -1","scale":"3 3 3","castshadow":false},
       {"id":2,"name":"fx","model":"models/fx.mdl","origin":"0 0 1","scale":"3 3 3","angles":"0 1.0471976 0","castshadow":false}
     ]}
    """

    private func fxMaterial(reflectCombo: Bool = true, reflectivity: Float? = nil) -> String {
        let combo = reflectCombo ? #","combos":{"LIGHTING":0,"REFLECTION":1}"# : #","combos":{"LIGHTING":0}"#
        let csv = reflectivity.map { #","constantshadervalues":{"reflectivity":\#($0)}"# } ?? ""
        // nocull: Y축 60° 회전 후 카메라에서 본 와인딩이 뒤집혀 기본 cullmode(백페이스 컬)면 평면이
        // 통째로 사라진다 — 이 테스트는 컬링이 아니라 REFLECTION 가산 자체를 검증하는 것이 목적.
        return #"{"passes":[{"textures":["black"],"cullmode":"nocull"\#(combo)\#(csv)}]}"#
    }

    private func reflectFiles(reflectCombo: Bool = true, reflectivity: Float? = nil) -> [(String, Data)] {
        [
            ("models/bg.mdl", planeModel(material: "materials/bg.json")),
            ("models/fx.mdl", planeModel(material: "materials/fx.json")),
            ("materials/bg.json", Data(#"{"passes":[{"textures":["white"],"combos":{"LIGHTING":0}}]}"#.utf8)),
            ("materials/fx.json", Data(fxMaterial(reflectCombo: reflectCombo, reflectivity: reflectivity).utf8)),
            ("materials/white.tex", solidTex(255, 255, 255)),
            ("materials/black.tex", solidTex(0, 0, 0)),
        ]
    }

    // MARK: 파싱/파이프라인 단언

    /// M6(⑥): REFLECTION 콤보 + reflectivity 상수가 GPU3DMesh 까지 파싱되고 mf_reflect 파이프라인이 빌드된다.
    func testReflectMeshParsesComboAndBuildsPipeline() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0},
         "objects":[{"id":1,"name":"fx","model":"models/fx.mdl","origin":"0 0 0"}]}
        """
        let (proj, root) = try project(files: [("scene.json", Data(scene.utf8))] + reflectFiles(reflectivity: 0.6),
                                       id: "reflectparse")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: proj)
        defer { r.teardown() }
        XCTAssertEqual(r.meshRenderables.count, 1)
        let mesh = try XCTUnwrap(r.meshRenderables.first?.meshes.first)
        XCTAssertTrue(mesh.reflection, "REFLECTION:1 콤보면 mesh.reflection 이 켜져야 함")
        XCTAssertEqual(mesh.reflectivity, 0.6, accuracy: 1e-4,
                       "constantshadervalues.reflectivity 상수가 전달돼야 함")
        XCTAssertNotNil(r.meshPipelineReflect, "mf_reflect MSL 이 디바이스에서 컴파일/링크돼야 함")
        XCTAssertNotNil(r.meshPipelineReflectAdditive)
    }

    /// M6(⑥): REFLECTION 콤보가 없으면 미적용(무회귀 — 기존 파이프라인 경로 유지, 기본 reflectivity=1 보존).
    func testMeshWithoutReflectComboNotReflective() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0},
         "objects":[{"id":1,"name":"fx","model":"models/fx.mdl","origin":"0 0 0"}]}
        """
        let (proj, root) = try project(files: [("scene.json", Data(scene.utf8))] + reflectFiles(reflectCombo: false),
                                       id: "noreflect")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: proj)
        defer { r.teardown() }
        let mesh = try XCTUnwrap(r.meshRenderables.first?.meshes.first)
        XCTAssertFalse(mesh.reflection)
        XCTAssertEqual(mesh.reflectivity, 1.0, accuracy: 1e-4)
    }

    // MARK: 픽셀 단언(perspective)

    /// M6(⑥): REFLECTION 콤보를 켠 기울어진 검정 평면이 흰 배경을 acc 스냅샷에서 프레넬 가중으로
    /// 가산해 회색으로 보인다. REFLECTION:0 대조군은 검정 그대로(콤보가 실제로 반사를 게이트함을 증명).
    /// 결함 재현: 종전 "REFLECTION 콤보 전무"였다면 이 콤보는 무의미하고 두 캡처가 동일(둘 다 검정)했다.
    func testReflectMeshBlendsBackgroundByFresnel() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let reflected = try capture(scene: reflectScene, files: reflectFiles(), tag: "refl-on")
        let plain = try capture(scene: reflectScene, files: reflectFiles(reflectCombo: false), tag: "refl-off")

        let onPx = try XCTUnwrap(reflected.colorAt(x: 32, y: 32))
        let offPx = try XCTUnwrap(plain.colorAt(x: 32, y: 32))

        XCTAssertLessThan(offPx.redComponent, 0.05,
                          "REFLECTION:0 대조군은 검정 albedo 그대로여야 함 — 실측 \(offPx)")
        XCTAssertGreaterThan(onPx.redComponent, 0.05,
                             "REFLECTION:1 이면 흰 배경이 프레넬 가중으로 섞여 검정보다 밝아야 함 — 실측 \(onPx)")
        XCTAssertLessThan(onPx.redComponent, 0.9,
                          "fresnel≈0.5·reflectivity=1·metallic=0 조합은 pow(0.5,2)=0.25 근방이어야 함(과도 가산 아님) — 실측 \(onPx)")
        // 그레이스케일(무채색 반사) — R/G/B 채널이 서로 크게 어긋나면 안 됨.
        XCTAssertEqual(onPx.redComponent, onPx.greenComponent, accuracy: 0.05)
        XCTAssertEqual(onPx.redComponent, onPx.blueComponent, accuracy: 0.05)
    }

    /// M6(⑥): reflectivity 를 낮추면(0.2) 반사 기여가 줄어 reflectivity=1 대비 더 어둡다(단조성).
    func testReflectMeshScalesWithReflectivity() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let full = try capture(scene: reflectScene, files: reflectFiles(reflectivity: 1.0), tag: "refl-full")
        let low = try capture(scene: reflectScene, files: reflectFiles(reflectivity: 0.2), tag: "refl-low")
        let fullPx = try XCTUnwrap(full.colorAt(x: 32, y: 32))
        let lowPx = try XCTUnwrap(low.colorAt(x: 32, y: 32))
        XCTAssertLessThan(lowPx.redComponent, fullPx.redComponent,
                          "reflectivity 가 낮을수록 반사 가산이 줄어야 함 — full=\(fullPx) low=\(lowPx)")
    }

    // MARK: 픽셀 단언(ortho 하이브리드)

    /// M6(⑥): ortho(2D) 씬에 인터리브된 3D 메시의 REFLECTION(runOrtho3DMeshes 분기) — 코퍼스 실측
    /// REFLECTION 7씬 중 3047405322/3351179520/3538758087 3씬이 orthogonalprojection 실값(비-null)을
    /// 가져 이 경로를 탄다(encode3D 미도달). 2D 흰 배경 위 기울어진 검정 3D 평면이 회색으로 섞여야 한다.
    func testOrthoHybridReflectMeshBlends2DBackground() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/bgimg.json","origin":"32 32 0","size":"64 64","scale":"1 1 1",
            "angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":true},
           {"id":2,"name":"fx","model":"models/fx.mdl","origin":"32 32 0","scale":"32 32 32","angles":"0 1.0471976 0"}
         ]}
        """
        func files(reflectCombo: Bool) -> [(String, Data)] {
            [
                ("models/bgimg.json", Data(#"{"width":64,"height":64,"material":"materials/bg.json"}"#.utf8)),
                ("models/fx.mdl", planeModel(material: "materials/fx.json")),
                ("materials/bg.json", Data(#"{"passes":[{"textures":["white"]}]}"#.utf8)),
                ("materials/fx.json", Data(fxMaterial(reflectCombo: reflectCombo).utf8)),
                ("materials/white.tex", solidTex(255, 255, 255)),
                ("materials/black.tex", solidTex(0, 0, 0)),
            ]
        }
        let reflected = try capture(scene: scene, files: files(reflectCombo: true), tag: "ortho-refl-on")
        let plain = try capture(scene: scene, files: files(reflectCombo: false), tag: "ortho-refl-off")
        let onPx = try XCTUnwrap(reflected.colorAt(x: 32, y: 32))
        let offPx = try XCTUnwrap(plain.colorAt(x: 32, y: 32))
        XCTAssertLessThan(offPx.redComponent, 0.05,
                          "ortho REFLECTION:0 대조군은 검정 albedo 그대로여야 함 — 실측 \(offPx)")
        XCTAssertGreaterThan(onPx.redComponent, 0.05,
                             "ortho REFLECTION:1 이면 흰 배경이 섞여 검정보다 밝아야 함 — 실측 \(onPx)")
    }
}
