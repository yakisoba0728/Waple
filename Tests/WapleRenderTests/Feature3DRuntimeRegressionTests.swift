import XCTest
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

final class Feature3DRuntimeRegressionTests: XCTestCase {
    private func renderer(objects: String, files: [(String, Data)] = []) throws -> SceneRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let json = """
        {"camera":{"eye":"0 0 10","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50},"objects":[
         {"id":999,"model":"models/nonexistent.mdl"},\(objects)]}
        """
        let package = ScenePackage.assemble([("scene.json", Data(json.utf8))] + files)
        let document = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        renderer.device = device
        renderer.projW = 320; renderer.projH = 180
        let descriptors = SceneRenderer.sceneScriptLayers(from: document)
        renderer.sceneScript = try XCTUnwrap(SceneScriptContext(layers: descriptors))
        renderer.sceneScriptBaseDescriptors = descriptors
        renderer.build3D(doc: document, package: package, device: device)
        XCTAssertNotNil(renderer.meshPipelineOver, "The actual mesh shader must compile")
        return renderer
    }

    func testTextContentUpdatesOnceAndResizesItsActualTexture() throws {
        let renderer = try renderer(objects: #"""
        {"id":1,"name":"clock","pointsize":12,"text":{"value":"I","script":
        "shared.calls=0; export function update(v) { shared.calls++; return engine.runtime < 0.5 ? 'I' : 'MMMM'; }"}}
        """#)
        let text = try XCTUnwrap(renderer.billboards.first { $0.id == 1 })
        let firstTexture = text.texture
        let firstWidth = text.size.x
        renderer.evaluate3DScripts(time: 1)
        XCTAssertEqual(text.textState?.content, "MMMM")
        XCTAssertGreaterThan(text.size.x, firstWidth)
        XCTAssertFalse(text.texture === firstTexture)
        XCTAssertEqual(text.interactionSize, text.size)
        let reader = try XCTUnwrap(TextScriptEngine(script: "export function update(v) { return shared.calls; }",
                                                   scene: try XCTUnwrap(renderer.sceneScript)))
        XCTAssertEqual(reader.evaluateVec(current: [0]), [2], "Priming and one real frame; rasterization never reruns JS")
        let lookup = try XCTUnwrap(TextScriptEngine(script: "export function update(v) { return thisScene.getLayer('clock').text; }",
                                                   scene: try XCTUnwrap(renderer.sceneScript)))
        XCTAssertEqual(lookup.evaluate(current: ""), "MMMM")
    }

    func testInitiallyEmptyTextCanAppearAndBecomeEmptyAgain() throws {
        let renderer = try renderer(objects: #"""
        {"id":1,"pointsize":12,"text":{"value":"","script":
        "export function update(v) { return engine.runtime >= 1 && engine.runtime < 2 ? 'Visible' : ''; }"}}
        """#)
        let text = try XCTUnwrap(renderer.billboards.first { $0.id == 1 })
        XCTAssertEqual(text.textState?.hasContent, false)
        renderer.evaluate3DScripts(time: 1)
        XCTAssertEqual(text.textState?.hasContent, true)
        XCTAssertGreaterThan(text.size.x, 0)
        renderer.evaluate3DScripts(time: 2)
        XCTAssertEqual(text.textState?.hasContent, false)
        XCTAssertEqual(text.size, .zero)
    }

    func testTextColorAndAlphaScriptsUpdateActualRuntimeState() throws {
        let renderer = try renderer(objects: #"""
        {"id":1,"text":"X","pointsize":12,
         "color":{"value":"1 0 0","script":"export function update(v) { return new Vec3(0, 1, 0); }"},
         "alpha":{"value":1,"script":"export function update(v) { return 0.25; }"}}
        """#)
        let text = try XCTUnwrap(renderer.billboards.first { $0.id == 1 })
        renderer.evaluate3DScripts(time: 1)
        XCTAssertEqual(text.tint, SIMD4<Float>(0, 1, 0, 0.25))
        XCTAssertEqual(text.textState?.color, SIMD3<Float>(0, 1, 0))
    }

    func testTextConsumesDepthSettingAndEffectVisibilityEngine() throws {
        let renderer = try renderer(objects: #"""
        {"id":1,"text":"X","pointsize":12,"depthtest":"disabled",
         "effects":[{"file":"effects/tint/effect.json","visible":{"value":true,
         "script":"export function update(v) { return engine.runtime > 0.5; }"}}]}
        """#)
        let text = try XCTUnwrap(renderer.billboards.first { $0.id == 1 })
        XCTAssertFalse(text.depthTest)
        let effect = try XCTUnwrap(text.effects.first)
        XCTAssertNotNil(effect.visibleGate)
        XCTAssertFalse(renderer.effectVisible(effect, time: 0))
        XCTAssertTrue(renderer.effectVisible(effect, time: 1))
    }

    func testImageBillboardUsesSharedEffectVisibilityBuilder() throws {
        let renderer = try renderer(objects: #"""
        {"id":1,"image":"models/solid.json","size":"2 2",
         "effects":[{"file":"effects/tint/effect.json","visible":{"value":true,
         "script":"export function update(v) { return engine.runtime > 0.5; }"}}]}
        """#, files: [
            ("models/solid.json", Data(#"{"material":"materials/solid.json"}"#.utf8)),
            ("materials/solid.json", Data(#"{"passes":[{"shader":"flat"}]}"#.utf8))
        ])
        let image = try XCTUnwrap(renderer.billboards.first { $0.id == 1 })
        let effect = try XCTUnwrap(image.effects.first)
        XCTAssertNotNil(effect.visibleGate)
        XCTAssertFalse(renderer.effectVisible(effect, time: 0))
        XCTAssertTrue(renderer.effectVisible(effect, time: 1))
    }

    func testVolumetricPointVariantComesFromLightTypeRatherThanConeWidth() throws {
        func light(_ type: String) -> SceneLight3D {
            SceneLight3D(id: 1, name: "light", type: type,
                         origin: Vec3(x: 0, y: 0, z: 0), angles: Vec3(x: 0, y: 0, z: 0),
                         color: Vec3(x: 1, y: 1, z: 1), radius: 5, intensity: 1, exponent: 1,
                         innerCone: 0, outerCone: 0, castShadow: false, parent: nil,
                         castVolumetrics: true)
        }
        let point = try XCTUnwrap(Scene3DLighting.volumetricParameters(for: light("lpoint"), nodes: [:]))
        let spot = try XCTUnwrap(Scene3DLighting.volumetricParameters(for: light("lspot"), nodes: [:]))
        let directional = try XCTUnwrap(Scene3DLighting.volumetricParameters(for: light("ldirectional"), nodes: [:]))
        XCTAssertEqual(point.outerCone, spot.outerCone, "Degenerate cones deliberately match")
        XCTAssertTrue(point.isPointLight)
        XCTAssertFalse(spot.isPointLight)
        XCTAssertFalse(directional.isPointLight)
    }
}
