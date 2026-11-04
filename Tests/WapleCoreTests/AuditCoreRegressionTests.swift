import XCTest
@testable import WapleCore

final class AuditCoreRegressionTests: XCTestCase {
    private func emitter(_ burst: Int = 1) -> Emitter {
        .box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0, y: 0, z: 0),
             rate: 0, burst: burst)
    }

    private func system(lifetime: Float = 100, emitters: [Emitter]? = nil,
                        operators: [ParticleOperator] = [], children: [ChildLink] = []) -> ParticleSystemDef {
        ParticleSystemDef(emitters: emitters ?? [emitter()],
                          initializers: [.lifetimeRandom(min: lifetime, max: lifetime),
                                         .velocityRandom(min: Vec3(x: 1, y: 0, z: 0),
                                                         max: Vec3(x: 1, y: 0, z: 0))],
                          operators: operators, renderer: .sprite, maxCount: 8,
                          startTime: 0, material: nil, children: children)
    }

    private func link(_ def: ParticleSystemDef, _ trigger: ChildTrigger) -> ChildLink {
        ChildLink(def: def, trigger: trigger, maxInstances: 1, probability: 1,
                  origin: Vec3(x: 0, y: 0, z: 0))
    }

    func testOneShotChildRetainsLivingDeathBurstGrandchildren() {
        let child = system(lifetime: 0.1, children: [link(system(lifetime: 1), .deathBurst)])
        var sim = ParticleSimulator(def: system(children: [link(child, .spawnBurst)]), seed: 7)
        _ = sim.step(0.05)
        _ = sim.step(0.1)
        XCTAssertEqual(sim.childDisplay(0).count, 0)
        XCTAssertEqual(sim.descendantDisplay(path: [0, 0]).count, 1)
        _ = sim.step(0.1)
        XCTAssertEqual(sim.descendantDisplay(path: [0, 0]).count, 1)
        _ = sim.step(1)
        XCTAssertTrue(sim.descendantDisplay(path: [0, 0]).isEmpty)
    }

    func testOrphanedFollowChildRetainsLivingGrandchildren() {
        let child = system(lifetime: 0.03, children: [link(system(lifetime: 1), .spawnBurst)])
        var sim = ParticleSimulator(def: system(lifetime: 0.03,
                                                children: [link(child, .follow)]), seed: 7)
        _ = sim.step(0.02)
        sim.emissionPaused = true
        _ = sim.step(0.04)
        XCTAssertTrue(sim.childDisplay(0).isEmpty)
        XCTAssertEqual(sim.descendantDisplay(path: [0, 0]).count, 1)
    }

    func testFiniteAlwaysGrandchildrenReleaseOneShotInstanceLimit() {
        var grandchild = system(lifetime: 0.125)
        grandchild.emitterWindow = [EmitterWindow(duration: 0.125, delay: 0)]
        let child = system(lifetime: 0.125, children: [link(grandchild, .always)])
        for trigger in [ChildTrigger.spawnBurst, .deathBurst] {
            var sim = ParticleSimulator(def: system(lifetime: 0.125,
                                                    children: [link(child, trigger)]), seed: 7)
            var counts: [Int] = []
            for _ in 0..<4 {
                _ = sim.step(0.125)
                counts.append(sim.descendantDisplay(path: [0, 0]).count)
            }
            XCTAssertEqual(counts, trigger == .spawnBurst ? [1, 0, 1, 0] : [0, 1, 0, 1],
                           "maxInstances=1 슬롯이 드레인 뒤 두 번째 이벤트에 재사용되어야 한다: \(trigger)")
        }
    }

    func testDelayedFiniteAlwaysGrandchildrenKeepTheirEmissionOpportunity() {
        var grandchild = system(lifetime: 0.125)
        grandchild.emitterWindow = [EmitterWindow(duration: 0.125, delay: 0.5)]
        let child = system(lifetime: 0.125, children: [link(grandchild, .always)])
        var sim = ParticleSimulator(def: system(children: [link(child, .spawnBurst)]), seed: 7)
        var counts: [Int] = []
        for _ in 0..<6 {
            _ = sim.step(0.125)
            counts.append(sim.descendantDisplay(path: [0, 0]).count)
        }
        XCTAssertEqual(counts, [0, 0, 0, 0, 1, 0])
    }

    func testFiniteAlwaysGrandchildrenReleaseSlotOnlyAfterTheirParticlesDie() {
        var grandchild = system(lifetime: 0.375)
        grandchild.emitterWindow = [EmitterWindow(duration: 0.125, delay: 0)]
        let child = system(lifetime: 0.125, children: [link(grandchild, .always)])
        var sim = ParticleSimulator(def: system(lifetime: 0.125,
                                                children: [link(child, .spawnBurst)]), seed: 7)
        var ages: [Float?] = []
        for _ in 0..<5 {
            _ = sim.step(0.125)
            ages.append(sim.descendantDisplay(path: [0, 0]).first?.age)
        }
        XCTAssertEqual(ages, [0.125, 0.25, 0.375, nil, 0.125])
    }

    func testUnboundedAlwaysGrandchildrenKeepEmittingAfterOneShotParentDrains() {
        let child = system(lifetime: 0.125, children: [link(system(lifetime: 0.125), .always)])
        var sim = ParticleSimulator(def: system(lifetime: 0.125,
                                                children: [link(child, .spawnBurst)]), seed: 7)
        var uids: [Int?] = []
        for _ in 0..<5 {
            _ = sim.step(0.125)
            uids.append(sim.descendantDisplay(path: [0, 0]).first?.uid)
        }
        XCTAssertEqual(uids, [1, nil, 2, nil, 3], "무한 always 인스턴스를 빈 프레임에 제거하거나 재시작하면 안 된다")
    }

    func testBasisChangesReachExistingAlwaysDescendants() throws {
        let gravity = ParticleOperator.movement(gravity: Vec3(x: 0, y: -200, z: 0), drag: 0, flags: 1)
        let middle = system(emitters: [], children: [link(system(operators: [gravity]), .always)])
        var sim = ParticleSimulator(def: system(emitters: [], children: [link(middle, .always)]), seed: 7)
        sim.worldBasis = ParticleWorldBasis(worldColumns: SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1))
        _ = sim.step(0.1)
        let first = try XCTUnwrap(sim.descendantDisplay(path: [0, 0]).first)
        XCTAssertEqual(first.vel.x, -19, accuracy: 1e-4)
        XCTAssertEqual(first.vel.y, 0, accuracy: 1e-4)
        sim.worldBasis = .identity
        _ = sim.step(0.1)
        let second = try XCTUnwrap(sim.descendantDisplay(path: [0, 0]).first)
        XCTAssertEqual(second.vel.x, -19, accuracy: 1e-4)
        XCTAssertEqual(second.vel.y, -20, accuracy: 1e-4)
    }

    func testBasisChangesReachAnExistingFollowChild() throws {
        let gravity = ParticleOperator.movement(gravity: Vec3(x: 0, y: -200, z: 0), drag: 0, flags: 1)
        var sim = ParticleSimulator(def: system(children: [link(system(operators: [gravity]), .follow)]), seed: 7)
        _ = sim.step(0.1)
        sim.worldBasis = ParticleWorldBasis(worldColumns: SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1))
        _ = sim.step(0.1)
        let child = try XCTUnwrap(sim.childDisplay(0).first)
        XCTAssertEqual(child.vel.x, -19, accuracy: 1e-4)
        XCTAssertEqual(child.vel.y, -20, accuracy: 1e-4)
    }

    func testZeroStepDoesNotReapplyPhysicalRemapsOrChangeSubsequentSteps() throws {
        func remap(_ channel: RemapChannel, _ operation: RemapOperation, _ value: Float) -> ParticleOperator {
            let v = Vec3(x: value, y: value, z: value)
            return .remapValueEx(spec: RemapSpec(outputChannel: channel, operation: operation,
                                               input: .lifetimeFraction, transform: nil,
                                               octaves: 3, inputScale: 1, outMin: v, outMax: v,
                                               blendInStart: 0, blendInEnd: 0,
                                               blendOutStart: 1, blendOutEnd: 1,
                                               inputCP0: 0, inputCP1: 1, outputCP0: 0, outputCP1: 1))
        }
        let operators = [remap(.rotation, .add, 2), remap(.position, .add, 3),
                         remap(.velocity, .multiply, 2)]
        let def = system(operators: operators, children: [link(system(operators: operators), .always)])
        var queried = ParticleSimulator(def: def, seed: 7)
        var reference = ParticleSimulator(def: def, seed: 7)
        let initial = try XCTUnwrap(queried.step(0.1).first)
        let initialChild = try XCTUnwrap(queried.childDisplay(0).first)
        _ = reference.step(0.1)
        for _ in 0..<3 {
            let snapshot = try XCTUnwrap(queried.step(0).first)
            XCTAssertEqual(snapshot.pos, initial.pos)
            XCTAssertEqual(snapshot.rotation, initial.rotation)
            XCTAssertEqual(snapshot.vel, initial.vel)
            XCTAssertEqual(snapshot.age, initial.age)
            XCTAssertEqual(queried.childDisplay(0).first?.pos, initialChild.pos)
            XCTAssertEqual(queried.childDisplay(0).first?.rotation, initialChild.rotation)
        }
        let actual = try XCTUnwrap(queried.step(0.1).first)
        let expected = try XCTUnwrap(reference.step(0.1).first)
        XCTAssertEqual(actual.pos, expected.pos)
        XCTAssertEqual(actual.rotation, expected.rotation)
        XCTAssertEqual(actual.vel, expected.vel)
    }

    func testInitialZeroStepKeepsBurstAndRepeatedSnapshotsImmutable() throws {
        var sim = ParticleSimulator(def: system(), seed: 7)
        let initial = try XCTUnwrap(sim.step(0).first)
        let snapshot = try XCTUnwrap(sim.step(0).first)
        XCTAssertEqual(snapshot.pos, initial.pos)
        XCTAssertEqual(snapshot.uid, initial.uid)
        XCTAssertEqual(sim.liveCount, 1)
    }

    func testOneShotChildrenWaitForEveryEmitterAndDoNotRestartCompletedEmitters() {
        for trigger in [ChildTrigger.spawnBurst, .deathBurst] {
            for lifetime: Float in [0.125, 2] {
                var child = system(lifetime: lifetime, emitters: [emitter(), emitter()])
                child.emitterWindow = [EmitterWindow(duration: 0, delay: 0.25),
                                       EmitterWindow(duration: 0, delay: 0.5)]
                let root = system(lifetime: trigger == .deathBurst ? 0.0625 : 100,
                                  children: [link(child, trigger)])
                var sim = ParticleSimulator(def: root, seed: 7)
                var counts: [Int] = []
                for _ in 0..<7 {
                    _ = sim.step(0.125)
                    sim.emissionPaused = true
                    counts.append(sim.childDisplay(0).count)
                }
                XCTAssertEqual(counts, lifetime < 1 ? [0, 0, 1, 0, 1, 0, 0] : [0, 0, 1, 1, 2, 2, 2],
                               "\(trigger), lifetime=\(lifetime)")
            }
        }
    }

    func testAnimationMarkerModesMatchValueModeNormalization() {
        let event = AnimationMarker(name: "event", frame: 5)
        for mode in ["loop", "LOOP", "unknown"] {
            XCTAssertEqual(PropertyAnimation.firedMarkers(events: [event], length: 30, mode: mode,
                                                          prevF: 34, curF: 36), ["event"])
        }
        for mode in ["mirror", "MIRROR"] {
            XCTAssertEqual(PropertyAnimation.firedMarkers(events: [event], length: 30, mode: mode,
                                                          prevF: 54, curF: 56), ["event"])
        }
        XCTAssertTrue(PropertyAnimation.firedMarkers(events: [event], length: 30, mode: "SINGLE",
                                                      prevF: 34, curF: 36).isEmpty)
    }

    func testBoundedCStringReadsExactByteLimitAndRejectsLongTails() {
        for limit in [16, 96] {
            let exact = [UInt8](repeating: 0x41, count: limit) + [0]
            XCTAssertEqual(readCString(exact, at: 0, maxLength: limit)?.next, limit + 1)
            XCTAssertNil(readCString(exact, at: 0, maxLength: limit - 1))
            XCTAssertNil(readCString(Array(exact.dropLast()), at: 0, maxLength: limit))
            XCTAssertNil(readCString([UInt8](repeating: 0x41, count: 65_536), at: 0, maxLength: limit))
        }
        XCTAssertNil(readCString([0], at: Int.max, maxLength: 96))
        XCTAssertNil(readCString([0], at: 0, maxLength: -1))
        XCTAssertEqual(readCString([0], at: 0, maxLength: 0)?.value, "")
        XCTAssertEqual(readCString([0x41, 0], at: 0, maxLength: Int.max)?.value, "A")
    }

    func testWebFeatureReadBudgetBoundsActualBytesRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0x41, count: 1024).write(to: url)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        XCTAssertNil(WallpaperCompatibilityAnalyzer.readWebFeatureData(file, maxBytes: 32))
        XCTAssertEqual(try file.offset(), 33, "초과 판정용 한 바이트까지만 읽어야 한다")
        try file.seek(toOffset: 0)
        XCTAssertEqual(WallpaperCompatibilityAnalyzer.readWebFeatureData(file, maxBytes: 1024)?.count, 1024)
        try file.seek(toOffset: 0)
        XCTAssertNil(WallpaperCompatibilityAnalyzer.readWebFeatureData(file, maxBytes: -1))
        XCTAssertEqual(try file.offset(), 0)
    }
}
