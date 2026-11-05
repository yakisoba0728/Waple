import XCTest
@testable import WapleCore

final class FeatureParticleContractsTests: XCTestCase {
    private func definition(_ extra: String) throws -> ParticleSystemDef {
        let json = """
        {"emitter":[{"name":"boxrandom","distancemax":"0 0 0","rate":0,"instantaneous":1,"controlpoint":1}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10}],"maxcount":8,\(extra)}
        """
        return ParticleSystemDef.parse(try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]), material: nil)
    }

    func testRemapOutputMarksCPBeforeConflictingInstanceOverride() throws {
        for section in ["operator", "initializer"] {
            let element = section == "operator" ? "remapvalue" : "remapinitialvalue"
            // maxcount 부재의 파서 기본은0: 방출을 관측하는 fixture는 용량을 명시해야 한다.
            let raw: [String: Any] = ["maxcount": 8, "emitter": [["name": "boxrandom", "distancemax": "0 0 0", "rate": 0,
                                                 "instantaneous": 1, "controlpoint": 1]],
                                      "controlpoint": [["offset": "0 0 0"], ["offset": "2 3 0"]],
                                      section: [["name": element, "output": "controlpoint", "outputcontrolpoint0": 1]]]
            var override = ParticleInstanceOverride()
            override.controlPoints = [1: Vec3(x: 40, y: 50, z: 0)]
            let def = ParticleSystemDef.parse(raw, material: nil, instanceOverride: override)
            XCTAssertEqual(def.controlPointFlags[1] & ParticleControlPointFlag.remapOutput, 0x10000)
            var sim = ParticleSimulator(def: def, seed: 1)
            let p = try XCTUnwrap(sim.step(0.01).first)
            XCTAssertEqual(p.pos, SIMD3(2, 3, 0), "\(section): CP override must not replace a remap-owned slot")
        }
    }

    func testRemapInputSelectorsUseUnsignedSevenClamp() throws {
        let def = try definition(#""operator":[{"name":"remapvalue","input":"distancetocontrolpoint","operation":"remap","output":"size","inputcontrolpoint0":-1,"inputcontrolpoint1":99,"outputcontrolpoint0":-2,"outputcontrolpoint1":8}]"#)
        guard case let .remapValueEx(spec) = def.operators.first else { return XCTFail("Expected remap") }
        XCTAssertEqual(spec.inputCP0, 7)
        XCTAssertEqual(spec.inputCP1, 7)
        XCTAssertEqual(spec.outputCP0, 7)
        XCTAssertEqual(spec.outputCP1, 7)
    }

    func testUnknownRemapOperationIsNoOpInsteadOfDefaultMultiply() throws {
        let def = try definition(#""operator":[{"name":"remapvalue","operation":"not-an-operation","input":"lifetimefraction","output":"size","outputrangemin":9,"outputrangemax":9}]"#)
        var sim = ParticleSimulator(def: def, seed: 1)
        XCTAssertEqual(try XCTUnwrap(sim.step(0.1).first).size, 1)
    }

    func testSceneProjectionReachesRootAndChildParticleDefaults() throws {
        let child = #"{"maxcount":8,"emitter":[{"name":"boxrandom","rate":0,"instantaneous":1}],"initializer":[{"name":"lifetimerandom","min":10,"max":10},{"name":"sizerandom"}]}"#
        let root = #"{"maxcount":8,"emitter":[{"name":"boxrandom","rate":0,"instantaneous":1}],"initializer":[{"name":"lifetimerandom","min":10,"max":10},{"name":"sizerandom"}],"children":[{"name":"particles/child.json","type":"static"}]}"#
        for orthographic in [false, true] {
            let projection = orthographic ? #""orthogonalprojection":{"width":100,"height":100}"# : ""
            let scene = """
            {"general":{\(projection)},"objects":[{"id":1,"particle":"particles/root.json"}]}
            """
            let doc = try SceneDocument.parse(package: ScenePackage.assemble([
                ("scene.json", Data(scene.utf8)), ("particles/root.json", Data(root.utf8)),
                ("particles/child.json", Data(child.utf8))]))
            var sim = ParticleSimulator(def: try XCTUnwrap(doc.particles.first).def, seed: 7)
            let rootParticle = try XCTUnwrap(sim.step(0.01).first)
            let childParticle = try XCTUnwrap(sim.childDisplay(0).first)
            for p in [rootParticle, childParticle] {
                if orthographic {
                    XCTAssertGreaterThanOrEqual(p.size, 5)
                    XCTAssertLessThanOrEqual(p.size, 50)
                    XCTAssertEqual(p.pos.z, 0)
                } else {
                    XCTAssertGreaterThanOrEqual(p.size, 0.001)
                    XCTAssertLessThanOrEqual(p.size, 1)
                    XCTAssertLessThanOrEqual(abs(p.pos.x), 1)
                    XCTAssertLessThanOrEqual(abs(p.pos.y), 1)
                    XCTAssertLessThanOrEqual(abs(p.pos.z), 1)
                }
            }
        }
    }

    func testStopClearsDescendantSnapshotsAndPlayRestartsStaticChildren() throws {
        let child = try definition(#""operator":[]"#)
        let def = ParticleSystemDef(emitters: child.emitters, initializers: child.initializers,
                                    operators: child.operators, renderer: child.renderer,
                                    maxCount: child.maxCount, startTime: child.startTime, material: child.material,
                                    children: [ChildLink(def: child, trigger: .always, maxInstances: 1, probability: 1,
                                                          origin: Vec3(x: 0, y: 0, z: 0))])
        var sim = ParticleSimulator(def: def, seed: 7)
        _ = sim.step(0.1)
        XCTAssertTrue(sim.isPlaying)
        XCTAssertEqual(sim.liveCount, 1)
        XCTAssertEqual(sim.childDisplay(0).count, 1)
        sim.stop()
        XCTAssertFalse(sim.isPlaying)
        XCTAssertEqual(sim.liveCount, 0)
        XCTAssertTrue(sim.childDisplay(0).isEmpty)
        XCTAssertTrue(sim.step(0.1).isEmpty)
        sim.play()
        XCTAssertEqual(sim.step(0).count, 1)
        XCTAssertEqual(sim.childDisplay(0).count, 1)
    }
}
