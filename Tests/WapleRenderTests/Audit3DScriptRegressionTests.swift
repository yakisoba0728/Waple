import XCTest
import simd
@testable import WapleCore
@testable import WapleRender

final class Audit3DScriptRegressionTests: XCTestCase {
    func testTimerUsesOriginatingScriptOverridesWhenSiblingPumps() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let a = try XCTUnwrap(TextScriptEngine(script: """
        shared.gain = 0;
        engine.setTimeout(function() {
            shared.gain = createScriptProperties().addSlider({name:'gain', value:0}).finish().gain;
        }, 1000);
        export function update(v) { return shared.gain; }
        """, scene: scene, scriptPropsJSON: #"{"gain":11}"#))
        let b = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            return createScriptProperties().addSlider({name:'gain', value:0}).finish().gain;
        }
        """, scene: scene, scriptPropsJSON: #"{"gain":22}"#))
        b.setRuntime(1)
        XCTAssertEqual(a.evaluateVec(current: [0]), [11])
        XCTAssertEqual(b.evaluateVec(current: [0]), [22])
    }

    func testZeroDelayTimerAdvancesOnceForEachDistinctSceneTime() throws {
        let scene = try XCTUnwrap(SceneScriptContext())
        let a = try XCTUnwrap(TextScriptEngine(script: """
        shared.ticks = 0;
        function tick() { shared.ticks += 1; engine.setTimeout(tick, 0); }
        engine.setTimeout(tick, 0);
        export function update(v) { return shared.ticks; }
        """, scene: scene))
        let b = try XCTUnwrap(TextScriptEngine(script: "export function update(v) { return v; }", scene: scene))
        a.setRuntime(0)
        b.setRuntime(0)
        a.setRuntime(0)
        XCTAssertEqual(a.evaluateVec(current: [0]), [1])
        b.setRuntime(1)
        a.setRuntime(1)
        XCTAssertEqual(a.evaluateVec(current: [0]), [2])
        a.setRuntime(0)
        b.setRuntime(0)
        a.setRuntime(1)
        b.setRuntime(1)
        XCTAssertEqual(a.evaluateVec(current: [0]), [3])
    }

    func testNodeBuilderBindsModelsAndGroupsToOwnLiveDescriptors() throws {
        let doc = try document("""
        {"id":1,"origin":"3 0 0","scale":"1 1 1",
         "visible":{"value":true,"script":"export function update(v) { return thisObject === thisLayer && thisObject.origin.x === 3; }"}},
        {"id":2,"name":"model","model":"models/missing.mdl","origin":{"value":"1 0 0",
         "script":"export function update(v) { return thisLayer.origin; }"}}
        """)
        let renderer = SceneRenderer()
        renderer.sceneScript = try XCTUnwrap(SceneScriptContext(layers: [
            SceneScriptLayerDescriptor(name: "first-image", origin: SIMD3(10, 0, 0))
        ]))
        renderer.build3DTransformNodes(doc: doc)
        renderer.rebuild3DDrawOrders()
        renderer.evaluate3DScripts(time: 0)
        let model = try XCTUnwrap(renderer.nodes3D.first { $0.id == 2 })
        let group = try XCTUnwrap(renderer.nodes3D.first { $0.id == 1 })
        XCTAssertEqual(model.origin, SIMD3<Float>(1, 0, 0))
        XCTAssertTrue(group.visible)
        XCTAssertEqual(group.origin, SIMD3<Float>(3, 0, 0))
        let reader = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) { return thisScene.getLayer('model').origin; }
        """, scene: try XCTUnwrap(renderer.sceneScript)))
        let move = try XCTUnwrap(TextScriptEngine(script: "export function update(v) { return new Vec3(7, 0, 0); }",
                                                 scene: try XCTUnwrap(renderer.sceneScript),
                                                 currentLayerIndex: model.scriptLayerIndex))
        model.scripts = [SceneRenderer.Script3D(key: "origin", engine: move)]
        renderer.evaluate3DScripts(time: 1)
        XCTAssertEqual(reader.evaluateVec(current: [0, 0, 0]), [7, 0, 0])
    }

    func testGroupOrderSurvivesProductionNodeBuilder() throws {
        let doc = try document("""
        {"id":2,"model":"models/missing.mdl","origin":{"value":"0 0 0",
         "script":"export function update(v) { shared.before = shared.flag || 0; return v; }"}},
        {"id":1,"visible":{"value":true,"script":"export function update(v) { shared.flag = 1; return v; }"}}
        """)
        let renderer = SceneRenderer()
        renderer.sceneScript = try XCTUnwrap(SceneScriptContext())
        renderer.build3DTransformNodes(doc: doc)
        renderer.rebuild3DDrawOrders()
        renderer.evaluate3DScripts(time: 0)
        XCTAssertEqual(renderer.nodes3D.first { $0.id == 1 }?.order, 1)
        let reader = try XCTUnwrap(TextScriptEngine(script: "export function update(v) { return shared.before; }",
                                                   scene: try XCTUnwrap(renderer.sceneScript)))
        XCTAssertEqual(reader.evaluateVec(current: [0]), [0])
    }

    func testNodeAppendPreservesLayerCreatedByCameraInEmptyDescriptorScene() throws {
        let renderer = SceneRenderer()
        let scene = try XCTUnwrap(SceneScriptContext())
        renderer.sceneScript = scene
        // build3D loads camera top-level scripts before registering model/group descriptors.
        let camera = try XCTUnwrap(TextScriptEngine(script: """
        shared.cameraLayer = thisScene.createLayer({name:'camera-generated', origin:'9 0 0'});
        export function update(v) { return shared.cameraLayer === thisScene.getLayer('camera-generated'); }
        """, scene: scene))
        XCTAssertEqual(camera.evaluateBool(current: false), true)
        let doc = try document("""
        {"id":2,"name":"model","model":"models/missing.mdl","origin":"1 0 0"}
        """)
        renderer.build3DTransformNodes(doc: doc)
        let model = try XCTUnwrap(renderer.nodes3D.first)
        XCTAssertEqual(model.scriptLayerIndex, 1)
        XCTAssertEqual(camera.evaluateBool(current: false), true)
        scene.updateSceneLayers([SceneScriptLayerDescriptor(name: "model", origin: SIMD3(7, 0, 0))],
                                startingAt: try XCTUnwrap(model.scriptLayerIndex))
        let reader = try XCTUnwrap(TextScriptEngine(script: """
        export function update(v) {
            return new Vec3(shared.cameraLayer.origin.x, thisScene.getLayer('model').origin.x,
                            thisScene.layers.length);
        }
        """, scene: scene))
        XCTAssertEqual(reader.evaluateVec(current: [0, 0, 0]), [9, 7, 2])
    }

    func testVolumetricLightUsesSameParentTransformAndVisibilityAsPBR() throws {
        let light = SceneLight3D(id: 2, name: "shaft", type: "lspot", origin: Vec3(x: 1, y: 0, z: 0),
                                 angles: Vec3(x: 0, y: 0, z: 0), color: Vec3(x: 1, y: 1, z: 1), radius: 10,
                                 intensity: 1, exponent: 1, castShadow: false, parent: 1,
                                 castVolumetrics: true)
        let parent = Scene3DMath.Node(origin: SIMD3(100, 0, 0),
                                      angles: SIMD3(0, 0, Float.pi / 2), scale: SIMD3(repeating: 1),
                                      parent: nil, visible: true)
        let nodes = [1: parent]
        let volume = try XCTUnwrap(Scene3DLighting.volumetricParameters(for: light, nodes: nodes))
        let pbr = try XCTUnwrap(Scene3DLighting.resolveLights([light], nodes: nodes).first)
        XCTAssertEqual(volume.position.x, 100, accuracy: 1e-5)
        XCTAssertEqual(volume.position.y, 1, accuracy: 1e-5)
        XCTAssertEqual(volume.position, pbr.position)
        XCTAssertEqual(volume.direction.x, 0, accuracy: 1e-5)
        XCTAssertEqual(volume.direction.y, 1, accuracy: 1e-5)
        let hidden = Scene3DMath.Node(origin: parent.origin, angles: parent.angles, scale: parent.scale,
                                      parent: nil, visible: false)
        XCTAssertNil(Scene3DLighting.volumetricParameters(for: light, nodes: [1: hidden]))
        XCTAssertNil(Scene3DLighting.volumetricParameters(for: light, nodes: [:]))
    }

    private func document(_ objects: String) throws -> SceneDocument {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null},"objects":[\(objects)]}
        """
        return try SceneDocument.parse(package: ScenePackage.assemble([("scene.json", Data(scene.utf8))]))
    }
}
