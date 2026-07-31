import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// M3(②): mf_normal 노멀맵 언팩 — WE DecompressNormal(common_fragment.h:18-30) 포트 회귀 가드.
/// 종전 나이브 `.xyz*2-1` 은 alpha 채널(모든 포맷의 x/y 성분 원천)을 전혀 읽지 않았다 — 아래 두 테스트는
/// "언팩에 관여하면 안 되는 바이트를 바꿔도 알파 채널 기반 신형 포맷 분기는 결과가 바뀌지 않는다" 대신,
/// **정반대로 종전 버그가 무시했던 알파-인접 바이트를 바꾸면 라이팅 결과가 실제로 달라져야 함**을 확인한다
/// (구코드는 blue/두번째 바이트를 무시 → 두 텍스처가 같은 픽셀을 렌더 → 아래 단언이 실패했을 것).
final class Scene3DMeshNormalMapDecompressTests: XCTestCase {

    /// 최소 raw RG88(fmt8) TEXV0005 컨테이너 — RG88DecodeTests.container 와 동형(TexImage.parse 가 직접
    /// .rg88 로 판별하는 무압축 2바이트/픽셀 페이로드, PNG 스니핑 경유 없음).
    private func rg88Tex(byte0: UInt8, byte1: UInt8, w: Int = 2, h: Int = 2) -> Data {
        var b = [UInt8]()
        b.append(contentsOf: Array("TEXV0005".utf8)); b.append(0)
        b.append(contentsOf: Array("TEXI0001".utf8)); b.append(0)
        b.append(contentsOf: i32(8))             // format=8(RG88)
        b.append(contentsOf: i32(0))
        b.append(contentsOf: i32(w)); b.append(contentsOf: i32(h))
        b.append(contentsOf: i32(w)); b.append(contentsOf: i32(h))
        b.append(contentsOf: Array("TEXB0003".utf8)); b.append(0)
        b.append(contentsOf: i32(1))
        b.append(contentsOf: i32(-1))
        b.append(contentsOf: i32(1))
        b.append(contentsOf: i32(w)); b.append(contentsOf: i32(h))
        b.append(contentsOf: i32(0))
        let payload = Array(repeating: [byte0, byte1], count: w * h).flatMap { $0 }
        b.append(contentsOf: i32(payload.count))
        b.append(contentsOf: i32(payload.count))
        b.append(contentsOf: payload)
        return Data(b)
    }

    private func project(files: [(String, Data)], id: String) throws -> (WallpaperProject, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_m3norm_\(id)_\(UUID().uuidString)", isDirectory: true)
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

    /// 라이트를 옆(+X)에 둔 unlit=false 평면. NORMALMAP 텍스처는 textures[1] 슬롯 존재만으로 소비된다
    /// (loadMesh3DMaterial 은 combos 게이트 없이 customTextures[1] 을 그대로 normalTextureName 으로 씀).
    private let litScene = """
    {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
     "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,
                "clearcolor":"0 0 0","ambientcolor":"0.02 0.02 0.02","skylightcolor":"0.02 0.02 0.02"},
     "objects":[
       {"id":1,"name":"quad","model":"models/plane.mdl","origin":"0 0 0","scale":"2.5 2.5 2.5","castshadow":false},
       {"id":2,"name":"key","light":"lpoint","origin":"3 0 3","color":"1 1 1","intensity":3,
        "radius":20,"exponent":2,"castshadow":false}
     ]}
    """

    private func fxMaterial() -> String {
        #"{"passes":[{"textures":["white","normalmap"],"constantshadervalues":{"roughness":0.4,"metallic":0.0}}]}"#
    }

    private func meshFiles(normalTex: Data) -> [(String, Data)] {
        [
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(fxMaterial().utf8)),
            ("materials/white.tex", solidTex(255, 255, 255, w: 2, h: 2)),
            ("materials/normalmap.tex", normalTex),
        ]
    }

    /// "그 외(비압축)" 분기(PNG 임베디드 → formatCode=2) — WE 규약상 blue 채널은 x/y 언팩에 전혀
    /// 관여하지 않는다(x=alpha, y=green). 구코드(`.xyz*2-1`)는 blue 를 z 로 직접 썼으므로 blue 만 바꾸면
    /// 노멀이 뒤집혀(z: -1↔+1) 라이팅이 크게 갈렸다 — 수정 후엔 blue 무관 불변이어야 한다.
    func testUncompressedNormalMapIgnoresBlueChannel() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // r=128(구코드 x≈0 중립 기준선 — r=0 이면 구코드도 x=-1 극단이라 두 케이스가 우연히 둘 다
        // 암전으로 수렴해 blue 민감도를 가려버림), g=128(y≈0), a=128(x≈0) → 거의 중립 노멀(z≈1).
        // blue 만 0↔255 로 바꿔 z 성분만 흔든다 — 구코드는 z=blue*2-1 이라 이 스윙에 최대로 민감했다.
        let blueLow = try capture(scene: litScene, files: meshFiles(normalTex: solidTex(128, 128, 0, alpha: 128)), tag: "blue0")
        let blueHigh = try capture(scene: litScene, files: meshFiles(normalTex: solidTex(128, 128, 255, alpha: 128)), tag: "blue255")
        let a = try XCTUnwrap(blueLow.colorAt(x: 32, y: 32))
        let b = try XCTUnwrap(blueHigh.colorAt(x: 32, y: 32))
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.03,
                       "DecompressNormal 은 blue 채널을 읽지 않아야 함(수정 전엔 z 반전으로 크게 갈렸음) — \(a) vs \(b)")
        XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.03)
        XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.03)
    }

    /// RG88 분기(formatCode=1) — WE 는 x=.r(byte0), y=.g(byte1, Waple 디코드에선 .a) 를 독립적으로 쓴다.
    /// 구코드는 `.xyz` 로 (byte0,byte0,byte0) 만 읽어(byte1 은 .a 에만 있고 `.xyz` 는 안 읽음) byte1 변화에
    /// 완전히 불변이었다 — 수정 후엔 byte1(=y 성분)만 바꿔도 라이팅이 달라져야 한다.
    func testRG88NormalMapRespondsToSecondByte() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let yLow = try capture(scene: litScene, files: meshFiles(normalTex: rg88Tex(byte0: 128, byte1: 30)), tag: "rg88ylo")
        let yHigh = try capture(scene: litScene, files: meshFiles(normalTex: rg88Tex(byte0: 128, byte1: 225)), tag: "rg88yhi")
        let a = try XCTUnwrap(yLow.colorAt(x: 32, y: 32))
        let b = try XCTUnwrap(yHigh.colorAt(x: 32, y: 32))
        let delta = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent)
            + abs(a.blueComponent - b.blueComponent)
        XCTAssertGreaterThan(delta, 0.02,
                             "RG88 두번째 바이트(y 성분)가 라이팅에 반영돼야 함(수정 전엔 byte1 무시로 불변) — \(a) vs \(b)")
    }

    /// 파스 확인: normalTextureName 이 GPU3DMesh 까지 전달되고 normalTextureFormat 이 RG88(1) 로 분류된다.
    func testNormalTextureFormatClassifiesRG88() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0},
         "objects":[{"id":1,"name":"quad","model":"models/plane.mdl","origin":"0 0 0"}]}
        """
        let (proj, root) = try project(files: [("scene.json", Data(scene.utf8))]
            + meshFiles(normalTex: rg88Tex(byte0: 128, byte1: 128)), id: "rg88fmt")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: proj)
        defer { r.teardown() }
        let mesh = try XCTUnwrap(r.meshRenderables.first?.meshes.first)
        XCTAssertNotNil(mesh.normalTexture)
        XCTAssertEqual(mesh.normalTextureFormat, 1, "RG88 페이로드는 formatCode=1 로 분류돼야 함")
    }
}
