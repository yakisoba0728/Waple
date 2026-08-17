import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// WE `g_Brightness` — HDR 씬에서 메시 최종색에 곱하는 머티리얼 배율.
///
/// 이 유니폼이 오래 누락돼 있었던 이유가 두 가지고, 테스트도 그 둘을 정면으로 겨눈다:
///  ① **철자**. `generic2` 의 머티리얼 키는 `Brigtness` 다 — WE 자신의 오타이고(generic2.frag:7
///     `// {"material":"Brigtness","default":1,"range":[0,10]}`) 교정해서 읽으면 영영 안 맞는다.
///  ② **게이트**. `#if HDR` 안에서만 곱한다. HDR 매크로는 머티리얼이 아니라 엔진이 주입하는
///     콤보라 씬 단위다 — 비HDR 씬에서 저작값이 있어도 화면이 변하면 안 된다.
///
/// 스캐폴드는 SceneRendererMeshReflectTests(M6) 패턴 재사용.
final class SceneRendererMeshBrightnessTests: XCTestCase {

    // MARK: - 상수 파싱(레인별 키)

    /// generic2 는 오타 철자 `Brigtness` 만 읽는다. 올바른 철자는 그 셰이더에 존재하지 않는 키다.
    func testGeneric2ReadsWETypoSpellingOnly() {
        let typo = Scene3DMaterialValues.parse(["Brigtness": 1.5], shader: "generic2")
        XCTAssertEqual(typo.brightness, 1.5, accuracy: 1e-6,
                       "generic2.frag:7 이 노출하는 키는 Brigtness(오타 원문)다")

        let corrected = Scene3DMaterialValues.parse(["Brightness": 1.5], shader: "generic2")
        XCTAssertEqual(corrected.brightness, 1, accuracy: 1e-6,
                       "generic2 에 `Brightness`(정상 철자) 키는 없다 — 읽으면 오독")
    }

    /// 미저작이면 선언 기본값 1(generic2.frag:7 `"default":1`).
    func testBrightnessDefaultsToOne() {
        XCTAssertEqual(Scene3DMaterialValues.parse(nil, shader: "generic2").brightness, 1, accuracy: 1e-6)
        XCTAssertEqual(Scene3DMaterialValues.parse(["Alpha": 1], shader: "generic2").brightness, 1, accuracy: 1e-6)
    }

    /// 같은 레거시 레인이어도 `generic` 에는 g_Brightness 선언 자체가 없다(generic.frag uniform 전수:
    /// Metal/Rough/Light/Color/Alpha + 샘플러). 레인으로 뭉뚱그려 읽으면 WE 가 무시하는 값을 곱하게 된다.
    func testGenericShaderHasNoBrightnessUniform() {
        XCTAssertEqual(Scene3DMaterialValues.parse(["Brigtness": 3], shader: "generic").brightness, 1,
                       accuracy: 1e-6)
    }

    /// {user,value} / {script,value} 바인딩은 기존 상수와 같은 규약으로 초기값을 꺼낸다
    /// (코퍼스 실물: 3589454154 `s1/DefaultMaterial` 이 newproperty15 바인딩).
    func testBrightnessUnwrapsPropertyBinding() {
        let bound = Scene3DMaterialValues.parse(["Brigtness": ["user": "newproperty15", "value": 2.5]],
                                                shader: "generic2")
        XCTAssertEqual(bound.brightness, 2.5, accuracy: 1e-6)
    }

    // MARK: - 공용 스캐폴드

    private func project(files: [(String, Data)], id: String) throws -> (WallpaperProject, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_bright_\(id)_\(UUID().uuidString)", isDirectory: true)
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

    /// 카메라 정면 평면 하나. 라이팅 기여를 상수로 고정하려고 ambient/skylight 를 흰색으로 못박는다
    /// (LIGHTING:1 경로에서 lit = ambient×albedo 가 되어 배율만 남는다).
    private func scene(hdr: Bool) -> String {
        """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,"hdr":\(hdr),
                    "clearcolor":"0 0 0","ambientcolor":"1 1 1","skylightcolor":"1 1 1"},
         "objects":[
           {"id":1,"name":"fx","model":"models/fx.mdl","origin":"0 0 0","scale":"3 3 3","castshadow":false}
         ]}
        """
    }

    /// 알베도는 중간 회색(0.392) — ×2 를 해도 saturate 클램프(1.0)에 닿지 않아 배율이 픽셀에 그대로 남는다.
    private func files(brigtness: Float?, lighting: Int = 0, key: String = "Brigtness",
                       shader: String = "generic2") -> [(String, Data)] {
        let csv = brigtness.map { #","constantshadervalues":{"\#(key)":\#($0)}"# } ?? ""
        let material = #"{"passes":[{"shader":"\#(shader)","textures":["gray"],"combos":{"LIGHTING":\#(lighting)}\#(csv)}]}"#
        return [
            ("models/fx.mdl", planeModel(material: "materials/fx.json")),
            ("materials/fx.json", Data(material.utf8)),
            ("materials/gray.tex", solidTex(100, 100, 100)),
        ]
    }

    private func centerLuma(_ rep: NSBitmapImageRep) throws -> CGFloat {
        try XCTUnwrap(rep.colorAt(x: 32, y: 32)).redComponent
    }

    // MARK: - 배선(파스 → GPU3DMesh)

    func testBrigtnessReachesGPUMesh() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let (proj, root) = try project(files: [("scene.json", Data(scene(hdr: true).utf8))]
                                       + files(brigtness: 1.5), id: "bright-parse")
        defer { try? FileManager.default.removeItem(at: root) }
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: proj)
        defer { r.teardown() }
        XCTAssertTrue(r.sceneIsHDR, "general.hdr:true 면 HDR 파이프라인이 서야 한다(게이트 전제)")
        let mesh = try XCTUnwrap(r.meshRenderables.first?.meshes.first)
        XCTAssertEqual(mesh.brightness, 1.5, accuracy: 1e-4,
                       "generic2 의 Brigtness 상수가 GPU3DMesh 까지 와야 한다")
    }

    // MARK: - 픽셀 단언

    /// HDR 씬 + unlit(LIGHTING:0). WE 의 `#if HDR` 곱은 LIGHTING 콤보와 무관하게 발화하므로
    /// unlit 조기 반환 경로도 배율을 받아야 한다 — 코퍼스 실물이 그렇다(3470948192 `uc/材质`:
    /// generic2 + LIGHTING:0 + Brigtness 0.5).
    func testHDRSceneScalesUnlitMeshByBrigtness() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let plain = try centerLuma(capture(scene: scene(hdr: true), files: files(brigtness: nil),
                                           tag: "hdr-unlit-none"))
        let scaled = try centerLuma(capture(scene: scene(hdr: true), files: files(brigtness: 2),
                                            tag: "hdr-unlit-2x"))
        XCTAssertGreaterThan(plain, 0.2, "대조군이 검정이면 배율을 잴 수 없다 — 실측 \(plain)")
        XCTAssertEqual(scaled, plain * 2, accuracy: 0.03,
                       "Brigtness 2 는 최종색을 2배로 만들어야 함 — plain=\(plain) scaled=\(scaled)")
    }

    /// 1 미만도 같은 식으로 작동한다(0.5 → 절반). 곱이 아니라 on/off 플래그로 잘못 배선되면 여기서 걸린다.
    func testHDRSceneDarkensWhenBrigtnessBelowOne() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let plain = try centerLuma(capture(scene: scene(hdr: true), files: files(brigtness: nil),
                                           tag: "hdr-unlit-none2"))
        let halved = try centerLuma(capture(scene: scene(hdr: true), files: files(brigtness: 0.5),
                                            tag: "hdr-unlit-half"))
        XCTAssertEqual(halved, plain * 0.5, accuracy: 0.03,
                       "Brigtness 0.5 는 최종색을 절반으로 — plain=\(plain) halved=\(halved)")
    }

    /// 라이팅 경로(LIGHTING:1, ambient 흰색)도 같은 배율을 받는다.
    func testHDRSceneScalesLitMeshByBrigtness() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let plain = try centerLuma(capture(scene: scene(hdr: true), files: files(brigtness: nil, lighting: 1),
                                           tag: "hdr-lit-none"))
        let scaled = try centerLuma(capture(scene: scene(hdr: true), files: files(brigtness: 2, lighting: 1),
                                            tag: "hdr-lit-2x"))
        XCTAssertGreaterThan(plain, 0.2, "대조군이 검정이면 배율을 잴 수 없다 — 실측 \(plain)")
        XCTAssertEqual(scaled, plain * 2, accuracy: 0.03,
                       "라이팅 경로도 최종색에 곱해야 함 — plain=\(plain) scaled=\(scaled)")
    }

    /// **게이트**: 비HDR 씬은 저작값이 있어도 픽셀이 바뀌면 안 된다(WE 의 `#if HDR`).
    /// 이게 깨지면 코퍼스의 비HDR 씬(genericimage 계열 `Bright`/`Brightness` 저작 2씬)까지 오염된다.
    func testNonHDRSceneIgnoresBrigtness() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let plain = try centerLuma(capture(scene: scene(hdr: false), files: files(brigtness: nil),
                                           tag: "ldr-none"))
        let authored = try centerLuma(capture(scene: scene(hdr: false), files: files(brigtness: 2),
                                              tag: "ldr-2x"))
        XCTAssertGreaterThan(plain, 0.2, "대조군이 검정이면 게이트를 잴 수 없다 — 실측 \(plain)")
        XCTAssertEqual(authored, plain, accuracy: 0.005,
                       "비HDR 씬에서 Brigtness 는 발화하면 안 됨 — plain=\(plain) authored=\(authored)")
    }

    /// 정상 철자로 저작하면 generic2 에서는 아무 일도 없어야 한다(철자 규약이 실제로 픽셀을 가른다).
    func testCorrectSpellingIsInertOnGeneric2() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let plain = try centerLuma(capture(scene: scene(hdr: true), files: files(brigtness: nil),
                                           tag: "hdr-none3"))
        let corrected = try centerLuma(capture(scene: scene(hdr: true),
                                               files: files(brigtness: 2, key: "Brightness"),
                                               tag: "hdr-correctspelling"))
        XCTAssertEqual(corrected, plain, accuracy: 0.005,
                       "generic2 에 Brightness 키는 존재하지 않는다 — plain=\(plain) corrected=\(corrected)")
    }
}
