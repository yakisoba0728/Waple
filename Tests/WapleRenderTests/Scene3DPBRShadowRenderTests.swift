import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

final class Scene3DPBRShadowRenderTests: XCTestCase {
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
            // pos3, normal3(+Z), tangent4, uv2
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

    private func capture(lightCastsShadow: Bool, tag: String,
                         roughness: Float = 0.7, metallic: Float = 0) throws -> NSBitmapImageRep {
        let scene = """
        {"camera":{"eye":"3 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,
                    "clearcolor":"0 0 0","ambientcolor":"0.04 0.04 0.04","skylightcolor":"0.04 0.04 0.04"},
         "objects":[
           {"id":1,"name":"receiver","model":"models/plane.mdl","origin":"0 0 0","scale":"2.5 2.5 2.5","castshadow":false},
           {"id":2,"name":"occluder","model":"models/plane.mdl","origin":"0 0 2","scale":"0.55 0.55 0.55","castshadow":true},
           {"id":3,"name":"key","light":"lpoint","origin":"0 0 4","color":"1 1 1","intensity":2,
            "radius":10,"exponent":2,"castshadow":\(lightCastsShadow ? "true" : "false")}
         ]}
        """
        let material = """
        {"passes":[{"textures":["white"],"constantshadervalues":{
          "roughness":\(roughness),"metallic":\(metallic)}}]}
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(material.utf8)),
            ("materials/white.tex", solidTex(255, 255, 255, w: 2, h: 2)),
        ]
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_p4_\(tag)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encodePkg(files).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "p4_\(tag)", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: "p4", tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0], toDir: output).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    private func averageLuminance(_ image: NSBitmapImageRep) -> Double {
        var total = 0.0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: x, y: y) else { continue }
                total += color.redComponent * 0.2126
                    + color.greenComponent * 0.7152
                    + color.blueComponent * 0.0722
            }
        }
        return total / Double(image.pixelsWide * image.pixelsHigh)
    }

    private func renderScene(_ scene: String, material: String, tag: String) throws -> NSBitmapImageRep {
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(material.utf8)),
            ("materials/white.tex", solidTex(255, 255, 255, w: 2, h: 2)),
        ]
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_\(tag)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encodePkg(files).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
            title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0], toDir: output).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    func testUnlitMeshKeepsAlbedoBrightnessWithoutLights() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // ambient/skylight=0 + 라이트 없음. lit(LIGHTING=1) 메시는 검정, unlit(LIGHTING=0)은 흰 albedo 유지.
        // 수정 전(SceneRenderer3D:824 mode.w=1 하드코딩)엔 둘 다 검정 → unlit center≈0 으로 이 테스트가 실패(824 회귀 가드).
        let scene = """
        {"camera":{"eye":"3 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,
                    "clearcolor":"0 0 0","ambientcolor":"0 0 0","skylightcolor":"0 0 0"},
         "objects":[{"id":1,"name":"quad","model":"models/plane.mdl","origin":"0 0 0","scale":"2.5 2.5 2.5","castshadow":false}]}
        """
        func centerRed(lighting: Int, tag: String) throws -> CGFloat {
            let mat = #"{"passes":[{"textures":["white"],"combos":{"LIGHTING":\#(lighting)}}]}"#
            let img = try renderScene(scene, material: mat, tag: tag)
            return try XCTUnwrap(img.colorAt(x: 32, y: 32)).redComponent
        }
        XCTAssertGreaterThan(try centerRed(lighting: 0, tag: "unlit"), 0.9,
                             "combos.LIGHTING=0 메시는 라이트 없이도 albedo 풀브라이트여야 함")
        XCTAssertLessThan(try centerRed(lighting: 1, tag: "lit"), 0.1,
                          "LIGHTING=1 대조군은 ambient 0·무광에서 검정이어야 함")
    }

    func testPointShadowOccluderDarkensReceiver() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let unshadowed = averageLuminance(try capture(lightCastsShadow: false, tag: "off"))
        let shadowed = averageLuminance(try capture(lightCastsShadow: true, tag: "on"))
        XCTAssertGreaterThan(unshadowed, 0.02, "test scene must be visibly lit")
        XCTAssertLessThan(shadowed, unshadowed - 0.01,
                          "a casting point light must darken the receiver behind the occluder")
    }

    func testPBRMaterialChangesResponseAndKeepsOpaqueAlpha() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let dielectric = try capture(
            lightCastsShadow: false, tag: "dielectric", roughness: 1, metallic: 0)
        let metal = try capture(
            lightCastsShadow: false, tag: "metal", roughness: 1, metallic: 1)

        let responseDelta = abs(averageLuminance(dielectric) - averageLuminance(metal))
        XCTAssertGreaterThan(responseDelta, 0.01,
                             "authored metallic must change the Cook-Torrance material response")
        let center = try XCTUnwrap(dielectric.colorAt(x: 32, y: 32))
        XCTAssertEqual(center.alphaComponent, 1, accuracy: 0.01,
                       "opaque mesh output must remain opaque")
    }
}
