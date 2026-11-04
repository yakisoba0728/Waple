import XCTest
@testable import WapleCore
@testable import WapleRender

final class SceneScriptRuntimeTests: XCTestCase {
    func testBundledVectorAndMatrixMathAndJSONCompatibility() throws {
        let engine = try XCTUnwrap(TextScriptEngine(script: """
        export function update() {
          let v = new Vec3({x:3,y:4,z:0});
          let p = Mat4.fromTranslation(new Vec3(2,3,4)).multiply(Mat4.fromScale(2));
          let transformed = p.multiply(new Vec4(1,2,3,1));
          return [v.length(), v.distance(new Vec3(0)), new Vec2(0).normalize().length(),
                  transformed.x, transformed.y, transformed.z, transformed.w];
        }
        """))
        XCTAssertEqual(engine.evaluateVec(current: []), [5, 5, 0, 4, 7, 10, 1])
    }

    func testModuleNamespaceAndNamedAliasesUseModulePath() throws {
        let engine = try XCTUnwrap(TextScriptEngine(script: """
        import * as math from 'WEMath';
        import { normalizeColor as normalized } from 'WEColor';
        import { angleVector2 as direction } from 'scripts/jsmodules/wevector.js';
        export function update() {
          return [math.mix(2,10,0.25), normalized(new Vec3(255,128,0)).x, direction(90).y];
        }
        """))
        let result = try XCTUnwrap(engine.evaluateVec(current: []))
        XCTAssertEqual(result[0], 4, accuracy: 0.0001)
        XCTAssertEqual(result[1], 1, accuracy: 0.0001)
        XCTAssertEqual(result[2], 1, accuracy: 0.0001)
    }

    func testSortKeepsPropertyOwnerAndLiveUpdatesOnOriginalSlot() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [
            .init(name: "first", origin: SIMD3(1, 0, 0)), .init(name: "second", origin: SIMD3(2, 0, 0))
        ]))
        let engine = try XCTUnwrap(TextScriptEngine(script: """
        export function init() { thisScene.sortLayer('second',0); }
        export function update() { return thisLayer.origin.x; }
        """, scene: scene, currentLayerIndex: 0))
        XCTAssertEqual(engine.evaluateVec(current: [0]), [1])
        scene.updateSceneLayers([.init(name: "first", origin: SIMD3(9, 0, 0))])
        XCTAssertEqual(engine.evaluateVec(current: [0]), [9])
        XCTAssertEqual(scene.drainRuntimeCommands().map(\.operation), [.sort])
        XCTAssertEqual(scene.context.evaluateScript("thisScene.layers[0].name")?.toString(), "second")
    }

    func testSnapshotAnimationHandleSurvivesOtherAnimationRemoval() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [.init(name: "puppet")]))
        scene.publishRuntimeLayers([.init(slot: 0, values: ["animationLayers": [
            ["id": 10, "name": "first", "frame": 1, "playing": true],
            ["id": 11, "name": "second", "frame": 7, "playing": true]
        ]])])
        scene.context.evaluateScript("var saved = thisScene.getLayer(0).getAnimationLayer(1);")
        scene.publishRuntimeLayers([.init(slot: 0, values: ["animationLayers": [
            ["id": 11, "name": "second", "frame": 9, "playing": true]
        ]])])
        XCTAssertEqual(scene.context.evaluateScript("saved.getFrame()")?.toInt32(), 9)
        scene.context.evaluateScript("saved.pause(); saved.blend = 0.25;")
        let commands = scene.drainRuntimeCommands()
        XCTAssertEqual(commands.map(\.operation), [.animation, .animation])
        XCTAssertEqual(commands[0].arguments["layerID"] as? Int, 11)
        XCTAssertEqual(commands[1].arguments["action"] as? String, "setBlend")
        XCTAssertTrue(scene.drainRuntimeCommands().isEmpty)
    }

    func testBoneSnapshotQueriesAndMutationCommand() throws {
        let scene = try XCTUnwrap(SceneScriptContext(layers: [.init(name: "model")]))
        scene.publishRuntimeLayers([.init(slot: 0, values: ["bones": [[
            "name": "root", "parent": -1, "origin": [1, 2, 3],
            "transform": [1,0,0,0,0,1,0,0,0,0,1,0,7,8,9,1]
        ]]])])
        XCTAssertEqual(scene.context.evaluateScript("thisScene.getLayer(0).getBoneTransform('root').translation().y")?.toInt32(), 8)
        XCTAssertEqual(scene.context.evaluateScript("thisScene.getLayer(0).getBoneIndex('missing')")?.toInt32(), -1)
        scene.context.evaluateScript("thisScene.getLayer(0).setLocalBoneOrigin('root',new Vec3(4,5,6));")
        let command = try XCTUnwrap(scene.drainRuntimeCommands().first)
        XCTAssertEqual(command.operation, .bone)
        XCTAssertEqual(command.arguments["action"] as? String, "setLocalOrigin")
        XCTAssertEqual((command.arguments["value"] as? [String: Int])?["y"], 5)
    }

    func testStorageDisplayIsolationAndLiveGlobalSharing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ScriptLocalStorage(sceneId: "wallpaper", screenId: "display-a", baseDirectory: directory, debounce: 3600)
        let second = ScriptLocalStorage(sceneId: "wallpaper", screenId: "display-b", baseDirectory: directory, debounce: 3600)
        let a = try XCTUnwrap(SceneScriptContext(localStorageStore: first))
        let b = try XCTUnwrap(SceneScriptContext(localStorageStore: second))
        a.context.evaluateScript("localStorage.set('position', 12); localStorage.set('theme', 'dark', 'global');")
        XCTAssertTrue(b.context.evaluateScript("localStorage.get('position') === undefined")?.toBool() == true)
        XCTAssertEqual(b.context.evaluateScript("localStorage.get('theme', 'global')")?.toString(), "dark")
        b.context.evaluateScript("localStorage.set('theme','light','global'); localStorage.set('position',24);")
        XCTAssertEqual(a.context.evaluateScript("localStorage.get('theme','global')")?.toString(), "light")
        XCTAssertEqual(a.context.evaluateScript("localStorage.get('position')")?.toInt32(), 12)
        a.context.evaluateScript("localStorage.clear('screen');")
        XCTAssertEqual(b.context.evaluateScript("localStorage.get('position')")?.toInt32(), 24)
        XCTAssertEqual(a.context.evaluateScript("localStorage.get('theme','global')")?.toString(), "light")
    }

    func testStorageRemovalRetiresLateWritersAndPreservesNeighbor() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = ScriptLocalStorage(sceneId: "removed", screenId: "display", baseDirectory: directory, debounce: 3600)
        let neighbor = ScriptLocalStorage(sceneId: "removed-neighbor", baseDirectory: directory, debounce: 3600)
        old.set(key: "value", json: "1"); old.set(key: "shared", json: "2", location: .global); old.flush()
        neighbor.set(key: "value", json: "9"); neighbor.flush()
        try ScriptLocalStorage.remove(sceneId: "removed", baseDirectory: directory)
        old.set(key: "late", json: "3"); old.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("removed.scopes").path))
        XCTAssertEqual(neighbor.get(key: "value"), "9")
        let replacement = ScriptLocalStorage(sceneId: "removed", screenId: "display", baseDirectory: directory, debounce: 3600)
        XCTAssertNil(replacement.get(key: "value"))
        replacement.set(key: "fresh", json: "4"); replacement.flush()
        old.set(key: "late", json: "5", location: .global); old.flush()
        XCTAssertNil(replacement.get(key: "late", location: .global))
        XCTAssertEqual(replacement.get(key: "fresh"), "4")
    }
}
