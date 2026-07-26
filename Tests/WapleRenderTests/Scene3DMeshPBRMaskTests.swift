import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// M2(①): mf_normal PBRMASKS(textures[2]) 채널 스왑 수정 — WE generic4.frag:96-100 규약(x/R=metallic,
/// y/G=roughness) 대조 + `mask.r>0.0` 값 기반 오폴백 게이트를 normalParams.y(hasMask) 플래그로 교체.
final class Scene3DMeshPBRMaskTests: XCTestCase {
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
            .appendingPathComponent("waple_m2mask_\(id)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        return (WallpaperProject(id: id, type: .scene, fileName: "scene.pkg", previewName: nil,
                                 title: id, tags: [], contentRating: nil, workshopId: nil,
                                 dependency: nil, folderURL: dir), dir)
    }

    /// 라이트를 옆(+X)에 둔 lit 평면 — roughness/metallic 조합에 따라 스페큘러 응답이 갈리는 각도.
    private let litScene = """
    {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
     "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,
                "clearcolor":"0 0 0","ambientcolor":"0.02 0.02 0.02","skylightcolor":"0.02 0.02 0.02"},
     "objects":[
       {"id":1,"name":"quad","model":"models/plane.mdl","origin":"0 0 0","scale":"2.5 2.5 2.5","castshadow":false},
       {"id":2,"name":"key","light":"lpoint","origin":"2 1 3","color":"1 1 1","intensity":3,
        "radius":20,"exponent":2,"castshadow":false}
     ]}
    """

    private func capture(files: [(String, Data)], tag: String) throws -> NSBitmapImageRep {
        let (proj, root) = try project(files: [("scene.json", Data(litScene.utf8))] + files, id: tag)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: proj)
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0], toDir: output).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    /// textures[1]=null(노멀 없음)·textures[2]=mask 인 재질. material 상수는 마스크가 있으면 무시돼야
    /// 하므로 대조군과 다른 값으로 일부러 채운다(오폴백 시 대조군과 우연히 일치하지 않도록).
    private func maskedMaterial(mask: Data) -> [(String, Data)] {
        let mat = #"{"passes":[{"textures":["white",null,"mask"],"constantshadervalues":{"roughness":0.5,"metallic":0.5}}]}"#
        return [
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(mat.utf8)),
            ("materials/white.tex", solidTex(255, 255, 255, w: 2, h: 2)),
            ("materials/mask.tex", mask),
        ]
    }

    private func plainMaterial(roughness: Float, metallic: Float) -> [(String, Data)] {
        let mat = #"{"passes":[{"textures":["white"],"constantshadervalues":{"roughness":\#(roughness),"metallic":\#(metallic)}}]}"#
        return [
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(mat.utf8)),
            ("materials/white.tex", solidTex(255, 255, 255, w: 2, h: 2)),
        ]
    }

    private func centerColor(_ files: [(String, Data)], tag: String) throws -> NSColor {
        try XCTUnwrap(try capture(files: files, tag: tag).colorAt(x: 32, y: 32))
    }

    private func closeColor(_ a: NSColor, _ b: NSColor, accuracy: CGFloat = 0.04) -> Bool {
        abs(a.redComponent - b.redComponent) < accuracy
            && abs(a.greenComponent - b.greenComponent) < accuracy
            && abs(a.blueComponent - b.blueComponent) < accuracy
    }

    /// ①: mask.r(R)=metallic, mask.g(G)=roughness — WE generic4.frag 규약과 정합해야 한다.
    /// mask(R=255,G=0) = metallic 1·roughness 0 이므로 상수만 넣은 metallic=1/roughness=0 대조군과
    /// 일치해야 한다. 채널이 뒤바뀐 상태(roughness=1/metallic=0)였다면 이 값과 크게 갈렸을 것.
    func testMaskChannelsMapToMetallicRoughnessNotSwapped() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let masked = try centerColor(maskedMaterial(mask: solidTex(255, 0, 0, alpha: 255)), tag: "maskMR")
        let matched = try centerColor(plainMaterial(roughness: 0, metallic: 1), tag: "matchMR")
        let swappedExpectation = try centerColor(plainMaterial(roughness: 1, metallic: 0), tag: "swapMR")
        XCTAssertTrue(closeColor(masked, matched),
                      "mask(R=1,G=0) 은 metallic=1/roughness=0 과 같아야 함 — masked=\(masked) matched=\(matched)")
        XCTAssertFalse(closeColor(masked, swappedExpectation),
                       "채널이 스왑돼 roughness=1/metallic=0 처럼 렌더되면 안 됨 — masked=\(masked) swapped=\(swappedExpectation)")
    }

    /// ①: mask 값 0(완전 비금속·완전 매끈)은 유효한 마스크 값이지 "마스크 없음" 신호가 아니다.
    /// mask(R=0,G=0) 는 재질 상수(roughness=0.5,metallic=0.5 로 일부러 다르게 채움)를 무시하고
    /// metallic=0/roughness=0 대조군과 일치해야 한다 — 값 기반(`mask.r>0.0`) 오폴백이면 재질 상수로
    /// 새 버려 대조군과 갈린다.
    func testZeroMaskValueIsNotTreatedAsMissing() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let masked = try centerColor(maskedMaterial(mask: solidTex(0, 0, 0, alpha: 255)), tag: "maskZero")
        let zeroExpectation = try centerColor(plainMaterial(roughness: 0, metallic: 0), tag: "matchZero")
        let fallbackExpectation = try centerColor(plainMaterial(roughness: 0.5, metallic: 0.5), tag: "fallbackZero")
        XCTAssertTrue(closeColor(masked, zeroExpectation),
                      "mask=(0,0) 은 metallic=0/roughness=0 대조군과 같아야 함 — masked=\(masked) zero=\(zeroExpectation)")
        XCTAssertFalse(closeColor(masked, fallbackExpectation),
                       "mask 값 0 이 재질 상수(0.5,0.5)로 오폴백되면 안 됨 — masked=\(masked) fallback=\(fallbackExpectation)")
    }

    /// 파스 확인: textures[1]=null·textures[2]=mask 인 재질이 maskTexture 만 로드하고 normalTexture 는
    /// nil 로 남는다(normalParams.z=0 게이트 — TBN 미적용 경로 회귀 가드).
    func testMaskOnlyMaterialLoadsMaskWithoutNormal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0},
         "objects":[{"id":1,"name":"quad","model":"models/plane.mdl","origin":"0 0 0"}]}
        """
        let (proj, root) = try project(files: [("scene.json", Data(scene.utf8))]
            + maskedMaterial(mask: solidTex(255, 0, 0, alpha: 255)), id: "maskonlyparse")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: proj)
        defer { r.teardown() }
        let mesh = try XCTUnwrap(r.meshRenderables.first?.meshes.first)
        XCTAssertNotNil(mesh.maskTexture)
        XCTAssertNil(mesh.normalTexture)
    }
}
