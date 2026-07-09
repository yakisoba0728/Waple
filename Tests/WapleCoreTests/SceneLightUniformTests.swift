import XCTest
@testable import WapleCore

/// WE 라이트 유니폼 팩 규약(g_LightsPosition[4] / g_LightsColorPremultiplied[3])의 확정 값 규약 고정.
/// (실측 확정 2026-07 — 라이트 3은 [0..2].w 3채널 분산, premult = color×intensity.)
/// ⚠️ 현재 소비 셰이더 없음(리포트 참조) — 이 테스트는 향후 forward-lighting 도입용 규약 스냅샷.
final class SceneLightUniformTests: XCTestCase {
    private func light(_ o: Vec3, _ c: Vec3, _ intensity: Float) -> SceneLight3D {
        SceneLight3D(id: 0, name: "", type: "lpoint", origin: o, angles: Vec3(x: 0, y: 0, z: 0),
                     color: c, radius: 0, intensity: intensity, exponent: 1, castShadow: false, parent: nil)
    }

    func testEmptyIsZeroExceptAmbient() {
        let u = SceneLight3D.packUniforms([], ambient: Vec3(x: 0.3, y: 0.2, z: 0.1))
        XCTAssertEqual(u.positions, [SIMD3<Float>](repeating: .zero, count: 4))
        XCTAssertEqual(u.colorsPremultiplied, [SIMD4<Float>](repeating: .zero, count: 3))
        XCTAssertEqual(u.ambient, SIMD3<Float>(0.3, 0.2, 0.1))
    }

    /// premult = color × intensity; 단일 라이트는 [0] 에만, 나머지 0.
    func testSingleLightPremultiply() {
        let u = SceneLight3D.packUniforms([light(Vec3(x: 10, y: 20, z: 30), Vec3(x: 1, y: 0.5, z: 0.25), 4)])
        XCTAssertEqual(u.positions[0], SIMD3<Float>(10, 20, 30))
        XCTAssertEqual(u.positions[1], .zero)
        XCTAssertEqual(u.colorsPremultiplied[0], SIMD4<Float>(4, 2, 1, 0))  // rgb=color×4, .w=L3 없음=0
        XCTAssertEqual(u.colorsPremultiplied[1], .zero)
        XCTAssertEqual(u.colorsPremultiplied[2], .zero)
    }

    /// 4 라이트 팩: L0..2 는 [i].rgb, L3 은 [0].w,[1].w,[2].w = L3.r,g,b.
    func testFourLightPacking() {
        let lights = [
            light(Vec3(x: 1, y: 0, z: 0), Vec3(x: 1, y: 0, z: 0), 1),   // L0 red
            light(Vec3(x: 0, y: 1, z: 0), Vec3(x: 0, y: 1, z: 0), 2),   // L1 green×2
            light(Vec3(x: 0, y: 0, z: 1), Vec3(x: 0, y: 0, z: 1), 1),   // L2 blue
            light(Vec3(x: 9, y: 9, z: 9), Vec3(x: 0.1, y: 0.2, z: 0.3), 10),  // L3 → .w lanes
        ]
        let u = SceneLight3D.packUniforms(lights)
        XCTAssertEqual(u.positions[3], SIMD3<Float>(9, 9, 9))
        XCTAssertEqual(u.colorsPremultiplied[0], SIMD4<Float>(1, 0, 0, 1.0))   // L0.rgb, .w=L3.r=0.1×10
        XCTAssertEqual(u.colorsPremultiplied[1], SIMD4<Float>(0, 2, 0, 2.0))   // L1.rgb=green×2, .w=L3.g=0.2×10
        XCTAssertEqual(u.colorsPremultiplied[2], SIMD4<Float>(0, 0, 1, 3.0))   // L2.rgb, .w=L3.b=0.3×10
    }

    /// 4개 초과 → 앞 4개만(5번째 무시).
    func testMoreThanFourTakesFirstFour() {
        var lights = (0..<5).map { light(Vec3(x: Float($0), y: 0, z: 0), Vec3(x: 1, y: 1, z: 1), 1) }
        lights[4] = light(Vec3(x: 999, y: 0, z: 0), Vec3(x: 1, y: 1, z: 1), 1)
        let u = SceneLight3D.packUniforms(lights)
        XCTAssertEqual(u.positions[3], SIMD3<Float>(3, 0, 0))  // 4번째(idx3), 5번째(999)는 미포함
    }
}
