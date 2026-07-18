import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

final class Scene3DRenderCorrectnessTests: XCTestCase {
    private func pkg(_ files: [(String, Data)]) throws -> ScenePackage {
        try ScenePackage.parse(encodePkg(files))
    }

    private func mirrorValue<T>(_ value: Any, _ label: String, as type: T.Type) -> T? {
        Mirror(reflecting: value).children.first { $0.label == label }?.value as? T
    }

    func test3DMaterialLookupFallsBackCaseInsensitivelyInPackageAndBaseAssets() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let renderer = SceneRenderer()
        let package = ScenePackage.assemble([
            (name: "Materials/Models/Ship/Body.JSON", data: Data("pkg".utf8)),
        ])

        XCTAssertEqual(renderer.quietAssetData("materials/models/ship/body.json", package: package), Data("pkg".utf8))

        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_case_assets", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Materials/Models/Ship", isDirectory: true),
                                                withIntermediateDirectories: true)
        try Data("base".utf8).write(to: base.appendingPathComponent("Materials/Models/Ship/Glow.JSON"))
        renderer.assetBaseDir = base

        XCTAssertEqual(renderer.quietAssetData("materials/models/ship/glow.json", package: ScenePackage.assemble([])),
                       Data("base".utf8))
    }

    func test3DBuildKeepsSolidAndFramebufferBillboardsWithState() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"model":"models/missing.mdl"},
           {"id":2,"image":"models/solid.json","origin":"0 0 0","size":"2 2",
            "angles":"0 0 0.7853982","color":"1 1 1","alpha":1,
            "effects":[{"file":"effects/tint/effect.json","passes":[{"constantshadervalues":{"color":"1 0 0","alpha":1}}]}]},
           {"id":3,"image":"models/fb.json","origin":"0 0 -0.1","size":"2 2","color":"1 1 1","alpha":1}
         ]}
        """
        let package = try pkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/solid.json", #"{"material":"materials/solid.json"}"#.data(using: .utf8)!),
            ("materials/solid.json", #"{"passes":[{"shader":"flat","depthtest":"disabled","depthwrite":"disabled"}]}"#.data(using: .utf8)!),
            ("models/fb.json", #"{"material":"materials/fb.json","fullscreen":true}"#.data(using: .utf8)!),
            ("materials/fb.json", #"{"passes":[{"shader":"passthrough","textures":["_rt_FullFrameBuffer"]}]}"#.data(using: .utf8)!),
        ])
        let doc = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        renderer.sceneScript = SceneScriptContext()
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)
        renderer.build3D(doc: doc, package: package, device: device)

        XCTAssertEqual(renderer.billboards.count, 2, "solid and _rt_ billboard layers must not be dropped")
        let solid = renderer.billboards[0]
        let angle = try XCTUnwrap(mirrorValue(solid, "angleZ", as: Float.self))
        XCTAssertEqual(angle, 0.7853982, accuracy: 1e-6)
        XCTAssertEqual(mirrorValue(solid, "depthTest", as: Bool.self), false)
        XCTAssertEqual(mirrorValue(solid, "depthWrite", as: Bool.self), false)
        XCTAssertEqual(mirrorValue(solid, "effects", as: [SceneRenderer.EffectGPU].self)?.count, 1)
        XCTAssertEqual(mirrorValue(renderer.billboards[1], "isFrameBuffer", as: Bool.self), true)
    }

    func test3DMaterialRuntimeCompositeUsesReferencedImageTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let package = try pkg([
            ("materials/mesh.json", #"{"passes":[{"textures":["_rt_imageLayerComposite_42_a"]}]}"#.data(using: .utf8)!),
            ("materials/face.tex", solidTex(255, 0, 0, w: 8, h: 2))
        ])
        let renderer = SceneRenderer()

        let material = try XCTUnwrap(renderer.loadMesh3DMaterial("materials/mesh.json",
                                                                 package: package,
                                                                 device: device,
                                                                 compositeImageTextures: [42: "materials/face.tex"]))

        XCTAssertEqual(material.texture.width, 8)
        XCTAssertEqual(material.texture.height, 2)
    }

    func test3DMeshMaterialKeepsPBRConstantsWithoutUpperClamping() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let package = try pkg([
            ("materials/mesh.json", #"{"passes":[{"textures":["white"],"constantshadervalues":{"roughness":5,"metallic":0.25,"speculartint":"0.2 0.4 0.6"}}]}"#.data(using: .utf8)!),
            ("materials/white.tex", solidTex(255, 255, 255, w: 1, h: 1)),
        ])
        let renderer = SceneRenderer()

        let material = try XCTUnwrap(renderer.loadMesh3DMaterial(
            "materials/mesh.json", package: package, device: device))

        XCTAssertEqual(material.roughness, 5)
        XCTAssertEqual(material.metallic, 0.25)
        XCTAssertEqual(material.specularTint, SIMD3(0.2, 0.4, 0.6))
    }

    func test3DMeshLightingComboZeroParsesAsUnlit() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let renderer = SceneRenderer()
        func unlit(_ materialJSON: String) throws -> Bool {
            let package = try pkg([
                ("materials/mesh.json", Data(materialJSON.utf8)),
                ("materials/white.tex", solidTex(255, 255, 255, w: 1, h: 1)),
            ])
            return try XCTUnwrap(renderer.loadMesh3DMaterial(
                "materials/mesh.json", package: package, device: device)).unlit
        }
        // combos.LIGHTING=0 → unlit(풀브라이트 albedo, generic4.frag:124-125)
        XCTAssertTrue(try unlit(#"{"passes":[{"textures":["white"],"combos":{"LIGHTING":0}}]}"#))
        // 키 대소문자 무시(2D SceneDocument:646 규약)
        XCTAssertTrue(try unlit(#"{"passes":[{"textures":["white"],"combos":{"lighting":0}}]}"#))
        // 미명시 → lit(WE 기본 LIGHTING=1)
        XCTAssertFalse(try unlit(#"{"passes":[{"textures":["white"]}]}"#))
        // 명시 1 → lit
        XCTAssertFalse(try unlit(#"{"passes":[{"textures":["white"],"combos":{"LIGHTING":1}}]}"#))
    }

    func test3DBillboardKeepsLightingAndPBRMaterialState() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"model":"models/missing.mdl"},
           {"id":2,"image":"models/lit.json","origin":"0 0 0","size":"2 2","color":"1 1 1","alpha":1}
         ]}
        """
        let package = try pkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/lit.json", #"{"material":"materials/lit.json"}"#.data(using: .utf8)!),
            ("materials/lit.json", #"{"passes":[{"textures":["white"],"combos":{"LIGHTING":1},"constantshadervalues":{"roughness":0.4,"metallic":0.6,"speculartint":"0.8 0.7 0.5"}}]}"#.data(using: .utf8)!),
            ("materials/white.tex", solidTex(255, 255, 255, w: 1, h: 1)),
        ])
        let doc = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        renderer.sceneScript = SceneScriptContext()
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)

        renderer.build3D(doc: doc, package: package, device: device)

        let billboard = try XCTUnwrap(renderer.billboards.first)
        XCTAssertEqual(mirrorValue(billboard, "lighting", as: Bool.self), true)
        XCTAssertEqual(mirrorValue(billboard, "roughness", as: Float.self), 0.4)
        XCTAssertEqual(mirrorValue(billboard, "metallic", as: Float.self), 0.6)
        XCTAssertEqual(mirrorValue(billboard, "specularTint", as: SIMD3<Float>.self), SIMD3(0.8, 0.7, 0.5))
    }

    /// F309 최소 재현: 골든 3470948192 실물 체인(비가시 노드 id=56 origin 스크립트가 shared.xx 를 세팅 →
    /// text id=181 이 shared.xx 를 읽어 shared.vvv 생산 → mesh id=115 scale 이 shared.vvv 소비)을 축약.
    /// text3DControllers 는 항상 eval3DOrder 보다 먼저 평가되므로, build3D 가 마운트 직후 1회 프라이밍하지
    /// 않으면 최초 real 호출(여기서는 build3D 직후의 단일 evaluate3DScripts 호출로 흉내)에서 id=181 이
    /// 미정의 shared.xx 를 읽어 NaN 을 낳고 id=115 의 scale 이 그 NaN 을 물려받는다(단일 프레임 캡처·라이브
    /// 첫 프레임 모두 영향).
    func test3DTextControllerPrimingSettlesSharedChainBeforeFirstRealFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":56,"origin":{"value":"0 0 0",
             "script":"export function update(value) { value.x = value.x + 1; shared.xx = value.x; return value; }"}},
           {"id":181,"text":{"value":"0",
             "script":"export function update(value) { shared.vvv = (shared.xx - 0) / 5 + 0.6; return String(shared.vvv); }"}},
           {"id":115,"model":"models/missing.mdl","scale":{"value":"1 1 1",
             "script":"export function update(value) { let k = (shared.vvv - 0.73) / 0.73; value.x = 1 - 2 * k; return value; }"}}
         ]}
        """
        let package = try pkg([("scene.json", scene.data(using: .utf8)!)])
        let doc = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        renderer.sceneScript = SceneScriptContext()
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)

        // build3D 자체가 프라이밍(F309)을 내장 — 그 뒤 단 한 번의 evaluate3DScripts 호출이 encode3D 의
        // 최초 real 프레임과 동형(순서·인자 동일). 프라이밍이 없으면 이 한 번의 호출만으로 NaN 이 나온다.
        renderer.build3D(doc: doc, package: package, device: device)
        renderer.evaluate3DScripts(time: 1.0 / 60)

        let mesh = try XCTUnwrap(renderer.nodes3D.first { $0.id == 115 })
        XCTAssertTrue(mesh.scale.x.isFinite,
                      "프라이밍 없으면 text 가 첫 호출에서 undefined shared.xx 를 읽어 shared.vvv=NaN → scale.x=NaN")
        // shared.xx=1(프라이밍의 eval3DOrder 스텝에서 세팅) → shared.vvv=(1-0)/5+0.6=0.8
        // → k=(0.8-0.73)/0.73=7/73 → scale.x=1-14/73=59/73.
        XCTAssertEqual(mesh.scale.x, Float(59.0 / 73.0), accuracy: 1e-4)
    }
}
