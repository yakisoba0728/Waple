import XCTest
@testable import WapleRender
@testable import WapleCore

final class VideoTextureExtractorTests: XCTestCase {
    private func i32(_ v: Int) -> [UInt8] {
        let u = UInt32(truncatingIfNeeded: v)
        return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
    }
    /// TEX 헤더 + 임의 페이로드.
    private func makeTex(format: Int, w: Int, h: Int, payload: [UInt8]) -> Data {
        var b: [UInt8] = []
        b += Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(format) + i32(0) + i32(w) + i32(h) + i32(w) + i32(h)
        b += Array("TEXB0001".utf8) + [0] + payload
        return Data(b)
    }
    private func makePkg(_ files: [(String, Data)]) -> Data {
        let ver = Array("PKGV0001".utf8)
        var out = i32(ver.count) + ver + i32(files.count)
        var off = 0
        for (name, data) in files {
            let nm = Array(name.utf8)
            out += i32(nm.count) + nm + i32(off) + i32(data.count); off += data.count
        }
        for (_, data) in files { out += [UInt8](data) }
        return Data(out)
    }
    private func scenePkg(videoTex: Bool) throws -> ScenePackage {
        let scene = Data(#"{"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},"objects":[{"image":"models/m.json","origin":"50 50 0","size":"100 100","scale":"1 1 1","angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}]}"#.utf8)
        let model = Data(#"{"material":"materials/mat.json"}"#.utf8)
        let material = Data(#"{"passes":[{"shader":"genericimage2","textures":["v"]}]}"#.utf8)
        let mp4: [UInt8] = i32(0x18) + Array("ftypisom".utf8) + [1, 2, 3]
        let tex = makeTex(format: 0, w: 100, h: 100, payload: videoTex ? mp4 : [0x89, 0x50, 0x4E, 0x47, 1, 2])
        return try ScenePackage.parse(makePkg([
            ("scene.json", scene), ("models/m.json", model), ("materials/mat.json", material), ("materials/v.tex", tex),
        ]))
    }

    func testDetectsVideoLayer() throws {
        let pkg = try scenePkg(videoTex: true)
        let doc = try SceneDocument.parse(package: pkg)
        XCTAssertEqual(VideoTextureExtractor.videoLayer(in: doc, package: pkg), "materials/v.tex")
    }

    func testNoVideoLayerForImageTex() throws {
        let pkg = try scenePkg(videoTex: false)
        let doc = try SceneDocument.parse(package: pkg)
        XCTAssertNil(VideoTextureExtractor.videoLayer(in: doc, package: pkg))
    }

    func testExtractsMP4Bytes() throws {
        let pkg = try scenePkg(videoTex: true)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WapleMP4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(VideoTextureExtractor.extractMP4(textureEntryName: "materials/v.tex", package: pkg, sceneID: "42", cacheDir: dir))
        XCTAssertEqual(url.lastPathComponent, "42.mp4")
        let bytes = [UInt8](try Data(contentsOf: url))
        // mp4 박스: [size 4][ftyp...]
        XCTAssertEqual(Array(bytes[4..<8]), Array("ftyp".utf8))
    }
}
