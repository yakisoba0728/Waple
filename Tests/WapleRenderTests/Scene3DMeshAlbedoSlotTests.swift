import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// M3(③): 3D 메시 albedo 선택은 textures[0] 슬롯 규약이어야 한다 — 종전 "첫 non-null 문자열" 규약은
/// textures[0]=null 인 재질(실코퍼스 3662790108 generic4 `{"textures":[null,"foil_silver_normal"]}`)에서
/// slot1 노멀맵을 알베도로 승격시켰다.
final class Scene3DMeshAlbedoSlotTests: XCTestCase {
    private func planeModel() -> Data {
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
        data.append(Data("materials/plane.json".utf8)); data.append(0)
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
            .appendingPathComponent("waple_m3albedo_\(id)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        return (WallpaperProject(id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
                                 title: id, tags: [], contentRating: nil, workshopId: nil,
                                 dependency: nil, folderURL: dir), dir)
    }

    private let unlitScene = """
    {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
     "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,"clearcolor":"0 0 0"},
     "objects":[{"id":1,"name":"quad","model":"models/plane.mdl","origin":"0 0 0","scale":"2.5 2.5 2.5"}]}
    """

    /// 실코퍼스 3662790108 패턴 재현: textures=[null,"greenmap"] — 노멀맵 자리에 뚜렷한 초록을 넣어
    /// "albedo 로 승격됐는지" 를 색으로 직접 판별한다. combos.LIGHTING:0(unlit) 로 조명 변수 제거.
    private func materialFiles() -> [(String, Data)] {
        let mat = #"{"passes":[{"textures":[null,"greenmap"],"combos":{"LIGHTING":0}}]}"#
        return [
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(mat.utf8)),
            ("materials/greenmap.tex", solidTex(0, 255, 0, w: 2, h: 2)),
        ]
    }

    private func capture(files: [(String, Data)], tag: String) throws -> NSBitmapImageRep {
        let (proj, root) = try project(files: [("scene.json", Data(unlitScene.utf8))] + files, id: tag)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: proj)
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0], toDir: output).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    /// ③: textures[0]=null·textures[1]=초록 재질은 흰(1×1 폴백) albedo 여야 한다 — 종전 "첫 non-null"
    /// 규약이면 초록(slot1 노멀맵)이 그대로 화면에 나왔을 것.
    func testNullFirstSlotFallsBackToWhiteNotSlotOneTexture() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let img = try capture(files: materialFiles(), tag: "nullslot0")
        let c = try XCTUnwrap(img.colorAt(x: 32, y: 32))
        // 흰(1,1,1)은 세 채널이 모두 높다 — slot1 이 알베도로 승격됐다면 순수 초록(0,1,0)이라
        // red/blue 가 거의 0 이 된다. green 값 자체(둘 다 1에 가까움)로는 구분되지 않으므로 red/blue 로 판별.
        XCTAssertGreaterThan(c.redComponent, 0.9,
                             "textures[0]=null 은 흰 폴백이어야 함(slot1 초록 승격이면 red≈0) — 실측 \(c)")
        XCTAssertGreaterThan(c.blueComponent, 0.9,
                             "textures[0]=null 은 흰 폴백이어야 함(slot1 초록 승격이면 blue≈0) — 실측 \(c)")
    }

    /// 파스 확인: normalTextureName 은 여전히 slot1 을 정확히 가리켜야 한다(③ 은 albedo 선택만 변경,
    /// normalTextureName 규약은 무회귀).
    func testNormalTextureNameStillReadsSlotOne() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let (proj, root) = try project(files: [("scene.json", Data(unlitScene.utf8))] + materialFiles(), id: "slot1parse")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: proj)
        defer { r.teardown() }
        let mesh = try XCTUnwrap(r.meshRenderables.first?.meshes.first)
        XCTAssertNotNil(mesh.normalTexture, "normalTextureName(slot1) 로드는 무회귀여야 함")
    }
}
