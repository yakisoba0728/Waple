import XCTest
@testable import WapleCore

/// 씬 `instanceoverride.controlpointN`/`controlpointangleN` 키프레임의 런타임 소비.
/// 파스 보존만 되고 시뮬레이터가 정적 CP 위치/프레임만 읽던 회귀를 잠근다.
final class ParticleInstanceOverrideAnimationRuntimeTests: XCTestCase {
    private func keyframe(_ frame: Float, _ value: Float) -> PropertyKeyframe {
        PropertyKeyframe(frame: frame, value: value,
                         frontEnabled: false, frontX: 0, frontY: 0,
                         backEnabled: false, backX: 0, backY: 0)
    }

    private func zRotation(from start: Float, to end: Float,
                           relative: Bool = false) -> PropertyAnimation {
        PropertyAnimation(
            tracks: [
                [keyframe(0, 0), keyframe(1, 0)],
                [keyframe(0, 0), keyframe(1, 0)],
                [keyframe(0, start), keyframe(1, end)]
            ],
            fps: 1, length: 1, mode: "single", relative: relative)
    }

    private func position(from start: Vec3, to end: Vec3,
                          relative: Bool = false) -> PropertyAnimation {
        PropertyAnimation(
            tracks: [
                [keyframe(0, start.x), keyframe(1, end.x)],
                [keyframe(0, start.y), keyframe(1, end.y)],
                [keyframe(0, start.z), keyframe(1, end.z)]
            ],
            fps: 1, length: 1, mode: "single", relative: relative)
    }

    private func sphereDef(controlPointFlags: Int = 0, staticAngle: Float = 0,
                           rate: Float = 0, maxCount: Int = 1) -> ParticleSystemDef {
        let source: [String: Any] = [
            "flags": 1,
            "controlpoint": [
                ["offset": "0 0 0"],
                ["offset": "0 0 0", "flags": controlPointFlags]
            ],
            "emitter": [[
                "name": "sphererandom", "controlpoint": 1,
                "directions": "1 0 0", "sign": "1 0 0",
                "distancemin": 2, "distancemax": 2,
                "speedmin": 4, "speedmax": 4,
                "rate": Double(rate), "instantaneous": 1
            ]],
            "initializer": [["name": "lifetimerandom", "min": 10, "max": 10]],
            "renderer": [["name": "sprite"]],
            "maxcount": maxCount
        ]
        var override = ParticleInstanceOverride()
        override.controlPointAngles[1] = Vec3(x: 0, y: 0, z: staticAngle)
        return ParticleSystemDef.parse(source, material: nil, instanceOverride: override)
    }

    /// `_step`이 시계를 전진시킨 직후 애니를 평가해야 같은 스텝에서 태어난 입자도 최신 프레임을 쓴다.
    func testAngleAnimationRotatesSphereEmitterAtCurrentSimulationTime() {
        let def = sphereDef()
        var simulator = ParticleSimulator(
            def: def,
            seed: 1,
            instanceOverrideAnimations: ["controlpointangle1": zRotation(from: 0, to: .pi / 2)])

        let particle = simulator.step(1)[0]

        XCTAssertEqual(particle.pos.x, 0, accuracy: 1e-5)
        XCTAssertEqual(particle.pos.y, 6, accuracy: 1e-5)
        XCTAssertEqual(particle.vel.x, 0, accuracy: 1e-5)
        XCTAssertEqual(particle.vel.y, 4, accuracy: 1e-5)
    }

    /// 같은 live 각도 배열의 두 번째 소비자인 opid 13도 정적 def가 아니라 현재 트랙 값을 읽어야 한다.
    func testAngleAnimationRotatesMapSequenceAroundBasis() {
        let def = ParticleSystemDef.parse([
            "flags": 0,
            "controlpoint": [["offset": "0 0 0"]],
            "emitter": [[
                "name": "boxrandom", "origin": "10 0 0", "rate": 0,
                "instantaneous": 1, "distancemax": "0 0 0"
            ]],
            "initializer": [
                ["name": "lifetimerandom", "min": 10, "max": 10],
                ["name": "mapsequencearoundcontrolpoint", "count": 4,
                 "bounds": "0 1", "axis": "0 0 1", "controlpoint": 0]
            ],
            "renderer": [["name": "sprite"]],
            "maxcount": 1
        ], material: nil)
        var simulator = ParticleSimulator(
            def: def, seed: 406,
            instanceOverrideAnimations: ["controlpointangle0": zRotation(from: 0, to: .pi / 2)])

        let particle = simulator.step(1)[0]

        XCTAssertEqual(particle.pos.x, -10, accuracy: 1e-4)
        XCTAssertEqual(particle.pos.y, 0, accuracy: 1e-4)
    }

    /// relative 트랙의 base는 매 프레임 정적 override여야 한다. 직전 런타임 값을 base로 쓰면
    /// step을 거듭할 때 각도가 누적된다.
    func testRelativeAngleAnimationUsesStaticOverrideAsBaseWithoutAccumulation() {
        let def = sphereDef(staticAngle: .pi / 4, rate: 1, maxCount: 2)
        XCTAssertEqual(def.maxCount, 2)
        XCTAssertEqual(def.emitters[0].rate, 1)
        let anim = zRotation(from: .pi / 4, to: .pi / 4, relative: true)
        var simulator = ParticleSimulator(
            def: def, seed: 1,
            instanceOverrideAnimations: ["controlpointangle1": anim])

        _ = simulator.step(0)
        let particles = simulator.step(1)

        XCTAssertEqual(particles.count, 2)
        for particle in particles {
            XCTAssertEqual(particle.pos.x, 0, accuracy: 1e-5)
            XCTAssertEqual(particle.pos.y, 6, accuracy: 1e-5)
            XCTAssertEqual(particle.vel.x, 0, accuracy: 1e-5)
            XCTAssertEqual(particle.vel.y, 4, accuracy: 1e-5)
        }
    }

    /// 마우스/부모부착/remap 출력 CP는 정적 override와 똑같이 동적 트랙도 건너뛴다.
    func testAngleAnimationHonorsControlPointOverrideBlockMask() {
        for blockedFlag in [0x1, 0x4, 0x1_0000] {
            let def = sphereDef(controlPointFlags: blockedFlag)
            var simulator = ParticleSimulator(
                def: def, seed: 1,
                instanceOverrideAnimations: ["controlpointangle1": zRotation(from: 0, to: .pi / 2)])

            let particle = simulator.step(1)[0]
            XCTAssertEqual(particle.pos.x, 6, accuracy: 1e-5, "flags=\(blockedFlag)")
            XCTAssertEqual(particle.pos.y, 0, accuracy: 1e-5, "flags=\(blockedFlag)")
            XCTAssertEqual(particle.vel.x, 4, accuracy: 1e-5, "flags=\(blockedFlag)")
            XCTAssertEqual(particle.vel.y, 0, accuracy: 1e-5, "flags=\(blockedFlag)")
        }
    }

    /// decimal 16은 bit4(0x10)이고 remap 출력 bit16(0x10000)이 아니다. 번들 previewvortexorb가
    /// 정확히 이 플래그를 쓰므로 양성 대조 없이 마스크를 쓰면 실자산 트랙을 잘못 차단한다.
    func testAngleAnimationAllowsControlPointFlagHex10() {
        let def = sphereDef(controlPointFlags: 0x10)
        var simulator = ParticleSimulator(
            def: def, seed: 1,
            instanceOverrideAnimations: ["controlpointangle1": zRotation(from: 0, to: .pi / 2)])

        let particle = simulator.step(1)[0]

        XCTAssertEqual(particle.pos.x, 0, accuracy: 1e-5)
        XCTAssertEqual(particle.pos.y, 6, accuracy: 1e-5)
        XCTAssertEqual(particle.vel.x, 0, accuracy: 1e-5)
        XCTAssertEqual(particle.vel.y, 4, accuracy: 1e-5)
    }

    /// 위치 트랙도 각도와 같은 시뮬레이터 시계에서 먼저 평가돼, 같은 스텝의 이미터 변환에 들어가야 한다.
    func testPositionAnimationTranslatesEmitterAtCurrentSimulationTime() {
        let def = sphereDef()
        var simulator = ParticleSimulator(
            def: def,
            seed: 1,
            instanceOverrideAnimations: [
                "controlpoint1": position(
                    from: Vec3(x: 0, y: 0, z: 0),
                    to: Vec3(x: 10, y: 0, z: 0))
            ])

        let particle = simulator.step(1)[0]

        XCTAssertEqual(particle.pos.x, 16, accuracy: 1e-5)
        XCTAssertEqual(particle.pos.y, 0, accuracy: 1e-5)
    }

    /// 파스 때 CP 좌표를 target으로 굽는 네 오퍼레이터도 live CP의 이동분을 더해야 한다.
    /// 이미 runtime 배열을 읽는 emitter/mapsequence만 고치면 이 경로들은 정적 위치에 남는다.
    func testPositionAnimationRebindsAllBakedControlPointOperatorTargets() {
        func parsed(origin: String, cp: String, op: [String: Any],
                    initializers: [[String: Any]] = []) -> ParticleSystemDef {
            ParticleSystemDef.parse([
                "flags": 1,
                "controlpoint": [["offset": "0 0 0"], ["offset": cp]],
                "emitter": [[
                    "name": "boxrandom", "origin": origin, "distancemax": "0 0 0",
                    "rate": 0, "instantaneous": 1
                ]],
                "initializer": initializers + [["name": "lifetimerandom", "min": 10, "max": 10]],
                "operator": [op],
                "renderer": [["name": "sprite"]],
                "maxcount": 1
            ], material: nil)
        }
        let moveToTen = position(
            from: Vec3(x: 0, y: 0, z: 0),
            to: Vec3(x: 10, y: 0, z: 0))

        let attract = parsed(origin: "0 0 0", cp: "0 0 0", op: [
            "name": "controlpointattract", "controlpoint": 1,
            "scale": 10, "threshold": 100
        ])
        var attractSim = ParticleSimulator(
            def: attract, seed: 2,
            instanceOverrideAnimations: ["controlpoint1": moveToTen])
        XCTAssertGreaterThan(attractSim.step(1)[0].pos.x, 0)

        let maintain = parsed(origin: "0 0 0", cp: "0 0 0", op: [
            "name": "maintaindistancetocontrolpoint", "controlpoint": 1,
            "distance": 2, "variablestrength": 0
        ])
        var maintainSim = ParticleSimulator(
            def: maintain, seed: 3,
            instanceOverrideAnimations: ["controlpoint1": moveToTen])
        XCTAssertEqual(maintainSim.step(1)[0].pos.x, 8, accuracy: 1e-5)

        let vortex = parsed(origin: "11 0 0", cp: "0 0 0", op: [
            "name": "vortex", "controlpoint": 1, "axis": "0 0 1",
            "distanceinner": 0, "distanceouter": 10,
            "speedinner": 10, "speedouter": 0
        ])
        var vortexSim = ParticleSimulator(
            def: vortex, seed: 4,
            instanceOverrideAnimations: ["controlpoint1": moveToTen])
        XCTAssertLessThan(vortexSim.step(1)[0].pos.y, 0)

        let reduce = parsed(
            origin: "0 0 0", cp: "400 0 0",
            op: [
                "name": "reducemovementnearcontrolpoint", "controlpoint": 1,
                "distanceinner": 20, "distanceouter": 50,
                "reductioninner": 1000, "reductionouter": 0
            ],
            initializers: [[
                "name": "velocityrandom", "min": "100 0 0", "max": "100 0 0"
            ]])
        var reduceSim = ParticleSimulator(
            def: reduce, seed: 5,
            instanceOverrideAnimations: [
                "controlpoint1": position(
                    from: Vec3(x: 400, y: 0, z: 0),
                    to: Vec3(x: 0, y: 0, z: 0))
            ])
        XCTAssertEqual(reduceSim.step(1)[0].vel.x, 0, accuracy: 1e-5)
    }

    /// 두 CP 선분 제약은 직전 정적 선분에서 현재 애니메이션 선분으로 축 좌표를 재매핑한다.
    /// 동봉 `maintaindistancebetweencontrolpoints` 프리뷰가 실제로 이 위치 트랙을 저작한다.
    func testPositionAnimationFeedsMaintainDistanceBetweenCurrentAndPreviousFrames() {
        let def = ParticleSystemDef.parse([
            "flags": 1,
            "controlpoint": [["offset": "0 0 0"], ["offset": "10 0 0"]],
            "emitter": [[
                "name": "boxrandom", "origin": "15 0 0", "distancemax": "0 0 0",
                "rate": 0, "instantaneous": 1
            ]],
            "initializer": [["name": "lifetimerandom", "min": 10, "max": 10]],
            "operator": [[
                "name": "maintaindistancebetweencontrolpoints",
                "controlpointstart": 0, "controlpointend": 1
            ]],
            "renderer": [["name": "sprite"]],
            "maxcount": 1
        ], material: nil)
        var simulator = ParticleSimulator(
            def: def, seed: 6,
            instanceOverrideAnimations: [
                "controlpoint1": position(
                    from: Vec3(x: 10, y: 0, z: 0),
                    to: Vec3(x: 20, y: 0, z: 0))
            ])

        XCTAssertEqual(simulator.step(1)[0].pos.x, 20, accuracy: 1e-5)
    }

    /// 상대 위치 트랙도 매 프레임 정적 def를 base로 삼고, CP override 차단 비트를 그대로 존중한다.
    func testPositionAnimationUsesStaticBaseAndHonorsOverrideMask() {
        var relativeDef = sphereDef(rate: 1, maxCount: 2)
        relativeDef.controlPoints[1] = Vec3(x: 5, y: 0, z: 0)
        let relative = position(
            from: Vec3(x: 1, y: 0, z: 0),
            to: Vec3(x: 1, y: 0, z: 0),
            relative: true)
        var relativeSim = ParticleSimulator(
            def: relativeDef, seed: 7,
            instanceOverrideAnimations: ["controlpoint1": relative])
        _ = relativeSim.step(0)
        let particles = relativeSim.step(1)
        XCTAssertEqual(particles.count, 2)
        for particle in particles {
            XCTAssertEqual(particle.pos.x, 12, accuracy: 1e-5)
        }

        for blockedFlag in [0x1, 0x4, 0x1_0000] {
            let blockedDef = sphereDef(controlPointFlags: blockedFlag)
            var blockedSim = ParticleSimulator(
                def: blockedDef, seed: 8,
                instanceOverrideAnimations: [
                    "controlpoint1": position(
                        from: Vec3(x: 0, y: 0, z: 0),
                        to: Vec3(x: 10, y: 0, z: 0))
                ])
            XCTAssertEqual(blockedSim.step(1)[0].pos.x, 6, accuracy: 1e-5,
                           "flags=\(blockedFlag)")
        }

        let allowedDef = sphereDef(controlPointFlags: 0x10)
        var allowedSim = ParticleSimulator(
            def: allowedDef, seed: 9,
            instanceOverrideAnimations: [
                "controlpoint1": position(
                    from: Vec3(x: 0, y: 0, z: 0),
                    to: Vec3(x: 10, y: 0, z: 0))
            ])
        XCTAssertEqual(allowedSim.step(1)[0].pos.x, 16, accuracy: 1e-5,
                       "decimal 16 is bit4, not the blocked bit16")
    }

    /// CP 인덱스를 직접 보존하는 opid 14/13도 동일 live 위치 배열을 읽는다.
    func testPositionAnimationFeedsMapSequenceBetweenAndAround() {
        let between = ParticleSystemDef.parse([
            "flags": 1,
            "controlpoint": [["offset": "0 0 0"], ["offset": "10 0 0"]],
            "emitter": [[
                "name": "boxrandom", "origin": "0 0 0", "distancemax": "0 0 0",
                "rate": 0, "instantaneous": 2
            ]],
            "initializer": [
                ["name": "lifetimerandom", "min": 10, "max": 10],
                ["name": "mapsequencebetweencontrolpoints", "count": 2,
                 "controlpointstart": 0, "controlpointend": 1]
            ],
            "renderer": [["name": "sprite"]],
            "maxcount": 2
        ], material: nil)
        var betweenSim = ParticleSimulator(
            def: between, seed: 10,
            instanceOverrideAnimations: [
                "controlpoint1": position(
                    from: Vec3(x: 10, y: 0, z: 0),
                    to: Vec3(x: 20, y: 0, z: 0))
            ])
        XCTAssertEqual(betweenSim.step(1).map(\.pos.x), [0, 20])

        let around = ParticleSystemDef.parse([
            "flags": 0,
            "controlpoint": [["offset": "0 0 0"]],
            "emitter": [[
                "name": "boxrandom", "origin": "10 0 0", "distancemax": "0 0 0",
                "rate": 0, "instantaneous": 1
            ]],
            "initializer": [
                ["name": "lifetimerandom", "min": 10, "max": 10],
                ["name": "mapsequencearoundcontrolpoint", "count": 4,
                 "bounds": "0 1", "axis": "0 0 1", "controlpoint": 0]
            ],
            "renderer": [["name": "sprite"]],
            "maxcount": 1
        ], material: nil)
        var staticAround = ParticleSimulator(def: around, seed: 11)
        let staticParticle = staticAround.step(1)[0]
        var movingAround = ParticleSimulator(
            def: around, seed: 11,
            instanceOverrideAnimations: [
                "controlpoint0": position(
                    from: Vec3(x: 0, y: 0, z: 0),
                    to: Vec3(x: 10, y: 0, z: 0))
            ])
        let movingParticle = movingAround.step(1)[0]
        XCTAssertEqual(movingParticle.pos.x - staticParticle.pos.x, 10, accuracy: 1e-5)
        XCTAssertEqual(movingParticle.pos.y, staticParticle.pos.y, accuracy: 1e-5)
        XCTAssertEqual(movingParticle.vel, staticParticle.vel)
    }

    /// remapvalue의 CP 입력은 파스 시 target을 굽지 않고 매 적분에서 live CP를 조회한다.
    func testPositionAnimationFeedsRemapControlPointInputs() {
        let def = ParticleSystemDef.parse([
            "flags": 1,
            "controlpoint": [["offset": "0 0 0"], ["offset": "0 0 0"]],
            "emitter": [[
                "name": "boxrandom", "origin": "0 0 0", "distancemax": "0 0 0",
                "rate": 0, "instantaneous": 1
            ]],
            "initializer": [["name": "lifetimerandom", "min": 10, "max": 10]],
            "operator": [[
                "name": "remapvalue", "input": "distancetocontrolpoint",
                "inputcontrolpoint0": 1,
                "inputrangemin": 0, "inputrangemax": 10,
                "output": "velocity", "operation": "remap",
                "outputrangemin": "0 0 0", "outputrangemax": "10 0 0"
            ]],
            "renderer": [["name": "sprite"]],
            "maxcount": 1
        ], material: nil)
        var simulator = ParticleSimulator(
            def: def, seed: 12,
            instanceOverrideAnimations: [
                "controlpoint1": position(
                    from: Vec3(x: 0, y: 0, z: 0),
                    to: Vec3(x: 10, y: 0, z: 0))
            ])

        let particle = simulator.step(1)[0]
        XCTAssertEqual(particle.vel, SIMD3<Float>(10, 0, 0))
        XCTAssertEqual(particle.pos, SIMD3<Float>(10, 0, 0))
    }
}
