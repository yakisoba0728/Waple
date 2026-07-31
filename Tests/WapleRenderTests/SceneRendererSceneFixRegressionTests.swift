import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// fix-s6 그룹(WapleRender 씬 렌더러) 회귀 테스트 — F720(S-5) / F721(S-12) / F722(S-29) / F723(S-30) / F724(S-43).
/// 각 테스트는 수정 전 red(실패 지점 명시) → 수정 후 green 이 되도록 구성했다.
final class SceneRendererSceneFixRegressionTests: XCTestCase {

    // MARK: 공용 스캐폴드

    private func mount(scene: String, files: [(String, Data)], tag: String) throws -> (SceneRenderer, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_s6_\(tag)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encodePkg([("scene.json", Data(scene.utf8))] + files).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "s6_\(tag)", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        return (renderer, root)
    }

    private func capture(_ renderer: SceneRenderer, root: URL, times: [Float] = [0.1]) throws -> NSBitmapImageRep {
        let out = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: times, toDir: out).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    private func averageRGB(_ image: NSBitmapImageRep) -> (r: Double, g: Double, b: Double) {
        var r = 0.0, g = 0.0, b = 0.0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let c = image.colorAt(x: x, y: y) else { continue }
                r += c.redComponent; g += c.greenComponent; b += c.blueComponent
            }
        }
        let n = Double(image.pixelsWide * image.pixelsHigh)
        return (r / n, g / n, b / n)
    }

    // MARK: F720(S-5) — 2D 이펙트 패스의 _rt_imageLayerComposite_* 샘플러 바인드

    /// 효과 frag 이 g_Texture1(=_rt_imageLayerComposite_7_a, 숨김 레이어 id=7 의 빨간 텍스처)을 그대로 출력.
    /// 수정 전: `_rt_` 슬롯 continue 스킵 → 샘플러 미바인드(미정의 — 실측 검정) → red 채널 0.
    /// 수정 후: 참조 레이어 베이스 텍스처로 정적 치환 → 화면이 빨강.
    func testImageLayerCompositeSamplerBound_F650() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        void main() { gl_FragColor = texSample2D(g_Texture1, v_TexCoord); }
        """
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/w.json","origin":"32 32 0","size":"64 64",
            "effects":[{"file":"effects/comp/effect.json","passes":[{"textures":[null,"_rt_imageLayerComposite_7_a"]}]}]},
           {"id":7,"image":"models/r.json","origin":"32 32 0","size":"64 64","visible":false}
         ]}
        """
        let (renderer, root) = try mount(scene: scene, files: [
            ("models/w.json", Data(#"{"material":"materials/w.json"}"#.utf8)),
            ("materials/w.json", Data(#"{"passes":[{"textures":["w"]}]}"#.utf8)),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("models/r.json", Data(#"{"material":"materials/r.json"}"#.utf8)),
            ("materials/r.json", Data(#"{"passes":[{"textures":["r"]}]}"#.utf8)),
            ("materials/r.tex", solidTex(255, 0, 0)),
            ("effects/comp/effect.json", Data(#"{"passes":[{}]}"#.utf8)),
            ("shaders/effects/comp.vert", Data(vert.utf8)),
            ("shaders/effects/comp.frag", Data(frag.utf8)),
        ], tag: "f650")
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let rgb = averageRGB(try capture(renderer, root: root))
        NSLog("%@", "[Waple] F720 composite-sampler avg=\(rgb)")
        XCTAssertGreaterThan(rgb.r, 0.5, "_rt_imageLayerComposite_7_a 가 빨간 레이어 텍스처로 바인드돼야 (수정 전 미바인드 → ~0)")
        XCTAssertLessThan(rgb.g, 0.3, "흰색 레이어 입력이 아니라 참조 레이어(빨강)가 출력돼야")
    }

    // MARK: F721(S-12) — ortho(2D) 씬의 .mdl 오브젝트 하이브리드 렌더

    /// ortho 씬(camera3D=nil) + 중앙 배치 .mdl 평면(빨간 머티리얼, 스케일 20 → ±20px).
    /// 수정 전: build3D 미진입으로 메시 드롭 → 검정. 수정 후: 중앙에 빨간 평면.
    func testOrthoSceneRenders3DModel_F651() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"ring","model":"models/plane.mdl","origin":"32 32 0","scale":"20 20 20"}
         ]}
        """
        let (renderer, root) = try mount(scene: scene, files: [
            ("models/plane.mdl", planeModel()),
            // LIGHTING:0 = unlit(풀브라이트 albedo) — 라이트 없는 ortho 씬에서도 색이 보이게(머티리얼 기본은 lit).
            ("materials/plane.json", Data(#"{"passes":[{"textures":["white"],"combos":{"LIGHTING":0}}]}"#.utf8)),
            ("materials/white.tex", solidTex(255, 0, 0, w: 2, h: 2)),
        ], tag: "f651")
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(renderer.ortho3DHybrid, "ortho 씬 + objects3D → 하이브리드 모드 진입")
        XCTAssertEqual(renderer.meshRenderables.count, 1, ".mdl 1개가 메시로 적재돼야")
        let image = try capture(renderer, root: root)
        // 중앙 20×20 크롭의 평균 빨강 — 메시가 그려졌는지 직접 판독.
        var r = 0.0, n = 0.0
        for y in 22..<42 {
            for x in 22..<42 {
                guard let c = image.colorAt(x: x, y: y) else { continue }
                r += c.redComponent; n += 1
            }
        }
        NSLog("%@", "[Waple] F721 ortho-3D center red=\(r / max(1, n))")
        XCTAssertGreaterThan(r / max(1, n), 0.5, "ortho 씬의 .mdl 이 중앙에 렌더돼야 (수정 전 드롭 → 0)")
    }

    /// 무회귀 가드: .mdl 참조가 깨진 ortho 씬은 하이브리드 미진입(종전 2D 전용과 동일).
    func testOrthoSceneWithUnresolvableModelStaysNonHybrid_F651() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"broken","model":"models/missing.mdl","origin":"32 32 0","scale":"20 20 20"},
           {"id":2,"image":"models/w.json","origin":"32 32 0","size":"64 64"}
         ]}
        """
        let (renderer, root) = try mount(scene: scene, files: [
            ("models/w.json", Data(#"{"material":"materials/w.json"}"#.utf8)),
            ("materials/w.json", Data(#"{"passes":[{"textures":["w"]}]}"#.utf8)),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ], tag: "f651b")
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(renderer.ortho3DHybrid, "메시 0개면 하이브리드 미진입(2D 전용 폴터)")
        XCTAssertTrue(renderer.billboards.isEmpty, "빌보드 잔류 없음(2D 레이어와 이중 렌더 방지)")
        let rgb = averageRGB(try capture(renderer, root: root))
        XCTAssertGreaterThan(rgb.r + rgb.g + rgb.b, 2.0, "2D 레이어는 정상 렌더")
    }

    // MARK: F722(S-29) — $mediaThumbnail/$mediaPreviousThumbnail 라이브 아트워크

    /// 감지 유닛: 머티리얼 json 의 usertextures 시스템 키 → MediaArtworkKind.
    func testMediaArtworkKindDetection_F652() throws {
        let renderer = SceneRenderer()
        defer { renderer.teardown() }
        let pkg = ScenePackage.assemble([
            ("materials/cur.json", Data(#"{"passes":[{"textures":["cur"],"usertextures":[{"name":"$mediaThumbnail","type":"system"}]}]}"#.utf8)),
            ("materials/prev.json", Data(#"{"passes":[{"textures":["prev"],"usertextures":[{"name":"$mediaPreviousThumbnail","type":"system"}]}]}"#.utf8)),
            ("materials/plain.json", Data(#"{"passes":[{"textures":["plain"]}]}"#.utf8)),
        ])
        XCTAssertEqual(renderer.mediaArtworkKind(textureEntryName: "materials/cur.tex", package: pkg), .current)
        XCTAssertEqual(renderer.mediaArtworkKind(textureEntryName: "materials/prev.tex", package: pkg), .previous)
        XCTAssertEqual(renderer.mediaArtworkKind(textureEntryName: "materials/plain.tex", package: pkg), .none)
        XCTAssertEqual(renderer.mediaArtworkKind(textureEntryName: "materials/absent.tex", package: pkg), .none,
                       "머티리얼 json 부재는 .none 폴터(무회귀)")
    }

    /// E2E: $mediaThumbnail 레이어에 아트워크 텍스처 주입 → 캡처가 placeholder(흰) 대신 아트워크(빨강).
    /// 수정 전: 텍스처 교체 경로 부재로 정적 placeholder 영구 고정.
    func testMediaThumbnailLayerUsesLiveArtwork_F652() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/art.json","origin":"32 32 0","size":"64 64"}
         ]}
        """
        let (renderer, root) = try mount(scene: scene, files: [
            ("models/art.json", Data(#"{"material":"materials/art.json"}"#.utf8)),
            ("materials/art.json", Data(#"{"passes":[{"textures":["art"],"usertextures":[{"name":"$mediaThumbnail","type":"system"}]}]}"#.utf8)),
            ("materials/art.tex", solidTex(255, 255, 255)),
        ], tag: "f652")
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(renderer.layers.first?.mediaArtwork, .current, "마운트가 시스템 키를 감지해야")
        // 아트워크 도착 전: 정적 placeholder(흰색).
        let beforeRGB = averageRGB(try capture(renderer, root: root))
        XCTAssertGreaterThan(beforeRGB.g, 0.8, "아트워크 미수신 시 placeholder(흰) 폴터")
        // 라이브 아트워크(빨간 PNG) 주입 → MediaPoller onThumbnail 경로와 동일 상태.
        var px = [UInt8](repeating: 0, count: 8 * 8 * 4)
        for i in stride(from: 0, to: px.count, by: 4) { px[i] = 255; px[i + 3] = 255 }
        let png = try XCTUnwrap(OffscreenCapture.png(rgba: px, width: 8, height: 8))
        renderer.mediaArtworkTexture = renderer.decodeArtworkTexture(png, device: device)
        let afterRGB = averageRGB(try capture(renderer, root: root))
        NSLog("%@", "[Waple] F722 artwork before=\(beforeRGB) after=\(afterRGB)")
        XCTAssertGreaterThan(afterRGB.r, 0.5, "주입된 아트워크(빨강)가 레이어 base 가 돼야 (수정 전 placeholder 고정)")
        XCTAssertLessThan(afterRGB.g, 0.3)
    }

    // MARK: F723(S-30) — thisLayer 직접 대입 read-back

    /// update 없는 visible 스크립트의 top-level `thisLayer.visible = false` 대입.
    /// 수정 전: update() 반환값만 유효 → 초기 visible=true 유지(흰색 표시). 수정 후: 숨겨짐(검정).
    func testThisLayerVisibleAssignmentReadBack_F653() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"lay1","image":"models/w.json","origin":"32 32 0","size":"64 64",
            "visible":{"script":"thisLayer.visible = false;","value":true}}
         ]}
        """
        let (renderer, root) = try mount(scene: scene, files: [
            ("models/w.json", Data(#"{"material":"materials/w.json"}"#.utf8)),
            ("materials/w.json", Data(#"{"passes":[{"textures":["w"]}]}"#.utf8)),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ], tag: "f653")
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let rgb = averageRGB(try capture(renderer, root: root))
        NSLog("%@", "[Waple] F723 visible-assignment avg=\(rgb)")
        XCTAssertLessThan(rgb.r + rgb.g + rgb.b, 0.5,
                          "thisLayer.visible=false 직접 대입이 렌더에 반영돼야 (수정 전 흰색 표시)")
    }

    /// origin 직접 대입 read-back: `thisLayer.origin.x = 9999` → 쿼드가 화면 밖으로(검정).
    /// 수정 전: 정적 origin 에 그대로 표시(흰색).
    func testThisLayerOriginAssignmentReadBack_F653() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"lay2","image":"models/w.json","origin":"32 32 0","size":"64 64",
            "visible":true,
            "angles":"0 0 0",
            "alpha":1,
            "color":"1 1 1",
            "scale":"1 1 1"}
         ]}
        """
        // origin 바인딩에 update 없는 대입 스크립트 — WE 이디엄(훅/사이드이펙트에서 프로퍼티 쓰기).
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(scene.utf8)) as? [String: Any])
        var objects = try XCTUnwrap(obj["objects"] as? [[String: Any]])
        objects[0]["origin"] = ["script": "thisLayer.origin.x = 9999;", "value": "32 32 0"] as [String: Any]
        obj["objects"] = objects
        let sceneData = try JSONSerialization.data(withJSONObject: obj)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_s6_f653o_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files: [(String, Data)] = [
            ("scene.json", sceneData),
            ("models/w.json", Data(#"{"material":"materials/w.json"}"#.utf8)),
            ("materials/w.json", Data(#"{"passes":[{"textures":["w"]}]}"#.utf8)),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ]
        try encodePkg(files).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "s6_f653o", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: "f653o", tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let rgb = averageRGB(try capture(renderer, root: root))
        NSLog("%@", "[Waple] F723 origin-assignment avg=\(rgb)")
        XCTAssertLessThan(rgb.r + rgb.g + rgb.b, 0.5,
                          "thisLayer.origin 직접 대입이 쿼드 위치에 반영돼야 (수정 전 정적 위치 표시)")
    }

    /// read-back 식별자 회귀(실측 3394601417): **묘명** 텍스트의 트랜스폼이 layers[0](첫 이미지 레이어,
    /// 거대 scale)로 오염되면 안 된다 — 이름 조회/layers[0] 폴터는 S-34 오바인딩 경로.
    /// 인덱스 기반 read-back 은 텍스트 자기 객체(JS layers[이미지 수+uid])를 읽어 트랜스폼을 보존한다.
    func testReadBackDoesNotStompUnnamedTextTransform_F653() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"name":"bg","image":"models/b.json","origin":"32 32 0","size":"256 256","scale":"20 20 1"},
           {"id":2,"name":"","text":"1","origin":"32 32 0","size":"20 20","pointsize":16,
            "color":{"script":"export function update(value) { return value; }","value":"1 1 1"}}
         ]}
        """
        let (renderer, root) = try mount(scene: scene, files: [
            ("models/b.json", Data(#"{"material":"materials/b.json"}"#.utf8)),
            ("materials/b.json", Data(#"{"passes":[{"textures":["b"]}]}"#.utf8)),
            ("materials/b.tex", solidTex(0, 0, 0)),   // 검정 배경(layers[0], 거대 스케일)
        ], tag: "f653u")
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let rgb = averageRGB(try capture(renderer, root: root))
        let sum = rgb.r + rgb.g + rgb.b
        NSLog("%@", "[Waple] F723 unnamed-text avg=\(rgb)")
        // 정상: 작은 글리프 1자(화면의 극소수 픽셀). 오염 시: layers[0] scale(20×)로 글리프 확대 → 고루마.
        XCTAssertLessThan(sum, 0.6, "묘명 텍스트 트랜스폼이 layers[0] 거대 스케일로 오염되면 안 됨")
        XCTAssertGreaterThan(sum, 0.001, "텍스트 자체는 렌더돼야(작은 흰 글리프)")
    }

    // MARK: F724(S-43) — 텍스트 콘텐츠 스크립트 매 프레임 재평가

    /// 같은 벽시계 초 안의 두 refreshScriptedTexts 호출이 모두 update() 를 재평가해야 한다.
    /// 수정 전: 초당 1회 게이트로 두 번째 호출이 스킵(스크롤/마키 끊김). 수정 후: 서브초 갱신.
    func testScriptedTextRefreshesSubSecond_F654() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0"},
         "objects":[
           {"id":2,"name":"t1","text":{"script":"export function update(value) { return 'v' + Math.floor(engine.runtime * 100); }","value":"init"},
            "origin":"32 32 0","size":"120 20"}
         ]}
        """
        let (renderer, root) = try mount(scene: scene, files: [], tag: "f654")
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let idx = try XCTUnwrap(renderer.textLayers.indices.first, "텍스트 레이어가 빌드돼야")
        renderer.refreshScriptedTexts(device: device, time: 0.0)
        XCTAssertEqual(renderer.textLayers[idx].lastText, "v0")
        // 같은 벽시계 초 안이라고 가정할 수 있는 연속 호출 — 수정 전 1Hz 게이트는 이를 스킵했다.
        renderer.refreshScriptedTexts(device: device, time: 0.15)
        XCTAssertEqual(renderer.textLayers[idx].lastText, "v15",
                       "서브초 재평가가 반영돼야 (수정 전 초당 1회 게이트로 동결)")
        renderer.refreshScriptedTexts(device: device, time: 1.5)
        XCTAssertEqual(renderer.textLayers[idx].lastText, "v150")
    }
}
