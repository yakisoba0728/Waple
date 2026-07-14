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
}
