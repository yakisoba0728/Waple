import XCTest
@testable import WapleCore

/// 이미터 `controlpoint`의 공개 parse → simulator 경로.
/// 원본 근거와 재현식은 `docs/re/particle-emitter-controlpoint-binary-2026-08-31.md`가 정본이다.
final class ParticleEmitterControlPointTests: XCTestCase {

    private let lifetime: [String: Any] = ["name": "lifetimerandom", "min": 100, "max": 100]
    private let renderer: [String: Any] = ["name": "sprite"]

    private func source(emitter: [String: Any], flags: Int = 0) -> [String: Any] {
        ["flags": flags, "emitter": [emitter], "initializer": [lifetime],
         "renderer": [renderer], "maxcount": 1]
    }

    /// `sphererandom` tag 1은 로컬 변위를 active CP 3×3으로 돌린 뒤 row3와 emitter origin을
    /// 더하고, 초기속도 방향에는 같은 3×3만 적용한다. +X 고정 입력이라 RNG 값과 무관하다.
    func testSphereEmitterUsesLiveControlPointFrame() {
        let emitter: [String: Any] = [
            "name": "sphererandom",
            "controlpoint": 1,
            "origin": "0 0 0",
            "directions": "1 0 0",
            "sign": "1 0 0",
            "distancemin": 2,
            "distancemax": 2,
            "speedmin": 4,
            "speedmax": 4,
            "rate": 0,
            "instantaneous": 1
        ]
        var override = ParticleInstanceOverride()
        override.controlPoints[1] = Vec3(x: 22, y: 0, z: 0)
        override.controlPointAngles[1] = Vec3(x: 0, y: 0, z: -Float.pi / 6)

        let def = ParticleSystemDef.parse(source(emitter: emitter, flags: 1),
                                          material: nil, instanceOverride: override)
        var simulator = ParticleSimulator(def: def, seed: 1)
        let particle = simulator.step(0)[0]

        // 독립 오라클: row0(z=-π/6)=(√3/2,-1/2,0).
        // P=(22,0,0)+2·row0, V=4·row0. production 행렬 helper를 기대값 계산에 쓰지 않는다.
        XCTAssertEqual(particle.pos.x, 23.7320508, accuracy: 1e-5)
        XCTAssertEqual(particle.pos.y, -1, accuracy: 1e-5)
        XCTAssertEqual(particle.pos.z, 0, accuracy: 1e-5)
        XCTAssertEqual(particle.vel.x, 3.4641016, accuracy: 1e-5)
        XCTAssertEqual(particle.vel.y, -2, accuracy: 1e-5)
        XCTAssertEqual(particle.vel.z, 0, accuracy: 1e-5)
    }

    /// 두 바인더가 같은 기본/클램프를 쓴다. 엔진의 `cmp ecx,7`/`cmovb`는 unsigned라
    /// 7·8뿐 아니라 -1도 CP7이 된다.
    func testSphereAndBoxParserUseCP0DefaultAndUnsignedSevenClamp() {
        let emitters: [[String: Any]] = [
            ["name": "sphererandom"],
            ["name": "boxrandom", "controlpoint": 6],
            ["name": "sphererandom", "controlpoint": 7],
            ["name": "boxrandom", "controlpoint": 8],
            ["name": "sphererandom", "controlpoint": -1]
        ]
        let parsed = ParticleSystemDef.parse(["emitter": emitters, "renderer": [renderer], "maxcount": 1],
                                             material: nil)

        XCTAssertEqual(parsed.emitters.count, 5)
        XCTAssertEqual(parsed.emitterControlPoints, [0, 6, 7, 7, 7])
    }

    /// 로컬 공간 CP0은 row3 위치는 더하지만 3×3 회전은 건너뛴다. 생략된 controlpoint가 CP0인지도
    /// 공개 parse→step 결과로 함께 검증한다.
    func testLocalSpaceCP0AddsTranslationWithoutApplyingItsBasis() {
        let emitter: [String: Any] = [
            "name": "sphererandom", "origin": "3 4 0", "directions": "1 0 0", "sign": "1 0 0",
            "distancemin": 2, "distancemax": 2, "speedmin": 4, "speedmax": 4,
            "rate": 0, "instantaneous": 1
        ]
        var override = ParticleInstanceOverride()
        override.controlPoints[0] = Vec3(x: 5, y: 6, z: 0)
        override.controlPointAngles[0] = Vec3(x: 0, y: 0, z: .pi / 2)

        let def = ParticleSystemDef.parse(source(emitter: emitter), material: nil,
                                          instanceOverride: override)
        var simulator = ParticleSimulator(def: def, seed: 1)
        let particle = simulator.step(0)[0]

        XCTAssertEqual(particle.pos.x, 10, accuracy: 1e-5) // origin.x + CP0.x + local.x
        XCTAssertEqual(particle.pos.y, 10, accuracy: 1e-5) // origin.y + CP0.y; local +X is not rotated
        XCTAssertEqual(particle.vel.x, 4, accuracy: 1e-5)
        XCTAssertEqual(particle.vel.y, 0, accuracy: 1e-5)
    }

    /// 파티클 본문의 `controlpoint[].angles`는 보존 필드일 뿐 원본 CP 생성자가 base 3×3에 쓰지 않는다.
    /// 같은 숫자를 scene instance override로 줬을 때만 회전해야 한다.
    func testParticleAuthoredControlPointAnglesRemainInertForEmitterFrame() {
        let emitter: [String: Any] = [
            "name": "sphererandom", "controlpoint": 1,
            "directions": "1 0 0", "sign": "1 0 0",
            "distancemin": 2, "distancemax": 2, "speedmin": 4, "speedmax": 4,
            "rate": 0, "instantaneous": 1
        ]
        var raw = source(emitter: emitter)
        raw["controlpoint"] = [
            ["offset": "0 0 0"],
            ["offset": "10 20 0", "angles": "0 0 1.5707963"]
        ]

        let def = ParticleSystemDef.parse(raw, material: nil)
        var simulator = ParticleSimulator(def: def, seed: 1)
        let particle = simulator.step(0)[0]

        XCTAssertEqual(particle.pos.x, 12, accuracy: 1e-5)
        XCTAssertEqual(particle.pos.y, 20, accuracy: 1e-5)
        XCTAssertEqual(particle.vel.x, 4, accuracy: 1e-5)
        XCTAssertEqual(particle.vel.y, 0, accuracy: 1e-5)
    }

    /// box도 local displacement와 초기속도 방향을 같은 CP 3×3에 태운다. 위치는 고정 입력으로
    /// 닫고, 랜덤 속도는 같은 seed의 무회전 대조군을 90° 돌린 관계로 독립 검증한다.
    func testBoxEmitterUsesLiveControlPointFrameForPositionAndVelocity() {
        let emitter: [String: Any] = [
            "name": "boxrandom", "controlpoint": 1, "origin": "3 4 0",
            "distancemin": "2 0 0", "distancemax": "2 0 0",
            "speedmin": 4, "speedmax": 4, "rate": 0, "instantaneous": 1
        ]
        var rotatedOverride = ParticleInstanceOverride()
        rotatedOverride.controlPoints[1] = Vec3(x: 10, y: 20, z: 0)
        rotatedOverride.controlPointAngles[1] = Vec3(x: 0, y: 0, z: .pi / 2)
        var plainOverride = rotatedOverride
        plainOverride.controlPointAngles[1] = Vec3(x: 0, y: 0, z: 0)

        let rotatedDef = ParticleSystemDef.parse(source(emitter: emitter), material: nil,
                                                 instanceOverride: rotatedOverride)
        let plainDef = ParticleSystemDef.parse(source(emitter: emitter), material: nil,
                                               instanceOverride: plainOverride)
        var rotatedSimulator = ParticleSimulator(def: rotatedDef, seed: 7)
        var plainSimulator = ParticleSimulator(def: plainDef, seed: 7)
        let rotated = rotatedSimulator.step(0)[0]
        let plain = plainSimulator.step(0)[0]

        // P = emitter.origin + CP.row3 + (2,0,0)·Rz(π/2).
        XCTAssertEqual(rotated.pos.x, 13, accuracy: 1e-5)
        XCTAssertEqual(rotated.pos.y, 26, accuracy: 1e-5)
        XCTAssertEqual(rotated.pos.z, 0, accuracy: 1e-5)
        // (x,y,z)·Rz(π/2) = (-y,x,z); row3 translation is intentionally absent from velocity.
        XCTAssertEqual(rotated.vel.x, -plain.vel.y, accuracy: 1e-5)
        XCTAssertEqual(rotated.vel.y, plain.vel.x, accuracy: 1e-5)
        XCTAssertEqual(rotated.vel.z, plain.vel.z, accuracy: 1e-5)
    }

    /// 동봉 정본의 전 도달: 명시 CP 6개(1×4, 2×2)가 4개 물리 파일/2개 고유 바이트에 있고,
    /// 생략된 droplets 첫 이미터는 CP0으로 보존된다.
    func testBundledDrippingWaterCorpusReachesAllSixDeclarationsAcrossFourFiles() throws {
        let relativePaths = [
            "presets/water/particles/presets/dripping_water.json",
            "presets/water/particles/presets/dripping_water_droplets.json",
            "presets/water/previewdrippingwater/particles/presets/dripping_water.json",
            "presets/water/previewdrippingwater/particles/presets/dripping_water_droplets.json"
        ]
        guard let root = bundledWEAssetsRoot() else {
            return XCTFail("동봉 WEAssets 루트를 못 찾았다")
        }
        let urls = relativePaths.map(root.appendingPathComponent)
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("WAPLE_WE_ASSETS 오버라이드에 dripping-water 정본 네 파일이 없다")
        }

        var parsedByFile: [[Int]] = []
        var explicitValues: [Int] = []
        var bytesByFile: [Data] = []
        for url in urls {
            let data = try Data(contentsOf: url)
            let raw = try XCTUnwrap(AssetJSON.dictionary(data), url.path)
            let emitters = raw["emitter"] as? [[String: Any]] ?? []
            explicitValues += emitters.compactMap { $0["controlpoint"] as? Int }
            parsedByFile.append(ParticleSystemDef.parse(raw, material: nil).emitterControlPoints)
            bytesByFile.append(data)
        }

        XCTAssertEqual(parsedByFile, [[1, 2], [0, 1], [1, 2], [0, 1]])
        XCTAssertEqual(explicitValues.filter { $0 == 1 }.count, 4)
        XCTAssertEqual(explicitValues.filter { $0 == 2 }.count, 2)
        XCTAssertEqual(Set(bytesByFile).count, 2, "preview 두 파일은 원본 두 파일의 바이트 미러다")
    }

    /// bit2 parent-attached CP의 world/world 분기는 부모 current 4×4를 wholesale copy한다.
    /// 자식 authored offset/angle은 schema에 보존하되 live frame에는 합성하지 않는다.
    func testWorldSpaceChildEmitterInheritsParentControlPointRotation() {
        let child = ParticleSystemDef.parse([
            "flags": 3,
            "controlpoint": [["offset": "9 9 0", "angles": "0 0 0.25",
                              "flags": 4, "parentcontrolpoint": 1]],
            "emitter": [["name": "sphererandom", "controlpoint": 0,
                         "directions": "1 0 0", "sign": "1 0 0",
                         "distancemin": 2, "distancemax": 2,
                         "speedmin": 4, "speedmax": 4,
                         "rate": 0, "instantaneous": 1]],
            "initializer": [lifetime], "renderer": [renderer], "maxcount": 1,
        ], material: nil)
        var override = ParticleInstanceOverride()
        override.controlPoints[1] = Vec3(x: 22, y: 0, z: 0)
        override.controlPointAngles[1] = Vec3(x: 0, y: 0, z: -Float.pi / 6)
        let parent = ParticleSystemDef.parse([
            "flags": 1,
            "controlpoint": [["offset": "0 0 0"], ["offset": "0 0 0"]],
            "children": [["name": "child.json", "type": "static", "maxcount": 1]],
            "renderer": [renderer], "maxcount": 0,
        ], material: nil, instanceOverride: override) { path in
            path == "child.json" ? child : nil
        }

        let inherited = parent.children[0].def
        XCTAssertEqual(inherited.controlPoints[0], Vec3(x: 22, y: 0, z: 0))
        XCTAssertEqual(inherited.controlPointAngles[0], Vec3(x: 0, y: 0, z: 0.25),
                       "authored schema value must remain preserved")
        XCTAssertEqual(inherited.controlPointFrameAngles[0].z, -Float.pi / 6,
                       accuracy: 1e-6)

        var simulator = ParticleSimulator(def: inherited, seed: 1)
        let particle = simulator.step(0)[0]
        XCTAssertEqual(particle.pos.x, 23.7320508, accuracy: 1e-5)
        XCTAssertEqual(particle.pos.y, -1, accuracy: 1e-5)
        XCTAssertEqual(particle.vel.x, 3.4641016, accuracy: 1e-5)
        XCTAssertEqual(particle.vel.y, -2, accuracy: 1e-5)
    }

    /// 부모/자식이 모두 local이고 transform-stack bridge가 identity이면 compose 분기도 부모
    /// current frame 그대로다. wholesale 전용으로만 각도를 넘기면 이 유효 입력이 identity로 퇴행한다.
    func testLocalSpaceChildEmitterInheritsParentFrameThroughIdentityBridge() {
        let child = ParticleSystemDef.parse([
            "flags": 0,
            "controlpoint": [["offset": "0 0 0"],
                             ["offset": "9 9 0", "flags": 4, "parentcontrolpoint": 1]],
            "emitter": [["name": "sphererandom", "controlpoint": 1,
                         "directions": "1 0 0", "sign": "1 0 0",
                         "distancemin": 2, "distancemax": 2,
                         "speedmin": 4, "speedmax": 4,
                         "rate": 0, "instantaneous": 1]],
            "initializer": [lifetime], "renderer": [renderer], "maxcount": 1,
        ], material: nil)
        var override = ParticleInstanceOverride()
        override.controlPoints[1] = Vec3(x: 22, y: 0, z: 0)
        override.controlPointAngles[1] = Vec3(x: 0, y: 0, z: -Float.pi / 6)
        let parent = ParticleSystemDef.parse([
            "flags": 0,
            "controlpoint": [["offset": "0 0 0"], ["offset": "0 0 0"]],
            "children": [["name": "child.json", "type": "static", "maxcount": 1]],
            "renderer": [renderer], "maxcount": 0,
        ], material: nil, instanceOverride: override) { _ in child }

        let inherited = parent.children[0].def
        XCTAssertEqual(inherited.controlPointFrameAngles[1].z, -Float.pi / 6,
                       accuracy: 1e-6)
        var simulator = ParticleSimulator(def: inherited, seed: 1)
        let particle = simulator.step(0)[0]
        XCTAssertEqual(particle.pos.x, 23.7320508, accuracy: 1e-5)
        XCTAssertEqual(particle.pos.y, -1, accuracy: 1e-5)
        XCTAssertEqual(particle.vel.x, 3.4641016, accuracy: 1e-5)
        XCTAssertEqual(particle.vel.y, -2, accuracy: 1e-5)
    }
}
