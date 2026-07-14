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

    private func capture(lightCastsShadow: Bool, tag: String) throws -> NSBitmapImageRep {
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
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(#"{"passes":[{"textures":["white"],"constantshadervalues":{"roughness":0.7,"metallic":0}}]}"#.utf8)),
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

    func testPointShadowOccluderDarkensReceiver() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let unshadowed = averageLuminance(try capture(lightCastsShadow: false, tag: "off"))
        let shadowed = averageLuminance(try capture(lightCastsShadow: true, tag: "on"))
        XCTAssertGreaterThan(unshadowed, 0.02, "test scene must be visibly lit")
        XCTAssertLessThan(shadowed, unshadowed - 0.01,
                          "a casting point light must darken the receiver behind the occluder")
    }
}
