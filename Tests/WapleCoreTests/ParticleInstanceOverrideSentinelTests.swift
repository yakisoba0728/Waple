import XCTest
@testable import WapleCore

/// typed `ParticleInstanceOverride`도 원본 프로퍼티백 writer의 x=FLT_MAX 미지정 규약을 보존한다.
final class ParticleInstanceOverrideSentinelTests: XCTestCase {

    private var source: [String: Any] {
        [
            "emitter": [["name": "sphererandom", "rate": 0]],
            "renderer": [["name": "sprite"]],
            "controlpoint": [["offset": "1 2 3", "angles": "0.1 0.2 0.3"]],
            "maxcount": 1
        ]
    }

    func testPositionSentinelSkipsWhileOrdinaryAngleStillApplies() {
        var override = ParticleInstanceOverride()
        override.controlPoints[0] = Vec3(x: .greatestFiniteMagnitude, y: 90, z: 90)
        override.controlPointAngles[0] = Vec3(x: 0, y: 0, z: 1)

        let def = ParticleSystemDef.parse(source, material: nil, instanceOverride: override)

        XCTAssertEqual(def.controlPoints[0], Vec3(x: 1, y: 2, z: 3))
        XCTAssertEqual(def.controlPointAngles[0], Vec3(x: 0, y: 0, z: 1))
        XCTAssertEqual(def.controlPointFrameAngles[0], Vec3(x: 0, y: 0, z: 1))
    }

    func testAngleSentinelSkipsWhileOrdinaryPositionStillApplies() {
        var override = ParticleInstanceOverride()
        override.controlPoints[0] = Vec3(x: 4, y: 5, z: 6)
        override.controlPointAngles[0] = Vec3(x: .greatestFiniteMagnitude, y: 90, z: 90)

        let def = ParticleSystemDef.parse(source, material: nil, instanceOverride: override)

        XCTAssertEqual(def.controlPoints[0], Vec3(x: 4, y: 5, z: 6))
        XCTAssertEqual(def.controlPointAngles[0], Vec3(x: 0.1, y: 0.2, z: 0.3))
        XCTAssertEqual(def.controlPointFrameAngles[0], Vec3(x: 0, y: 0, z: 0))
    }

    /// `ucomiss`의 unordered(NaN) 분기는 같음으로 빠지지 않으므로 NaN은 미지정이 아니라 지정값이다.
    func testNaNXRemainsSpecifiedForBothOverrideDictionaries() {
        var override = ParticleInstanceOverride()
        override.controlPoints[0] = Vec3(x: .nan, y: 5, z: 6)
        override.controlPointAngles[0] = Vec3(x: .nan, y: 0.5, z: 0.6)

        let def = ParticleSystemDef.parse(source, material: nil, instanceOverride: override)

        XCTAssertTrue(def.controlPoints[0].x.isNaN)
        XCTAssertEqual(def.controlPoints[0].y, 5)
        XCTAssertTrue(def.controlPointAngles[0].x.isNaN)
        XCTAssertEqual(def.controlPointAngles[0].y, 0.5)
        XCTAssertTrue(def.controlPointFrameAngles[0].x.isNaN)
    }
}
