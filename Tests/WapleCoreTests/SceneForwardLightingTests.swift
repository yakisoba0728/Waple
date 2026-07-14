import Foundation
import XCTest
@testable import WapleCore

/// 2D 포워드 라이팅: 유니폼 팩 + 감쇠/합산 수식(QuadShaders f_lit 미러 오라클) + 게이트 판정.
/// 수식 정본 = assets/shaders/common_fragment.h::ComputeLight (실물). 손계산 대조값으로 고정.
final class SceneForwardLightingTests: XCTestCase {
    private func d(_ s: String) -> Data { s.data(using: .utf8)! }
    private func light(_ o: Vec3, _ c: Vec3, intensity: Float, radius: Float,
                       exponent: Float = 1) -> SceneLight3D {
        SceneLight3D(id: 0, name: "", type: "lpoint", origin: o, angles: Vec3(x: 0, y: 0, z: 0),
                     color: c, radius: radius, intensity: intensity, exponent: exponent,
                     castShadow: false, parent: nil)
    }

    // MARK: 유니폼 팩

    func testForwardUniformsPacking() {
        let u = SceneLight3D.forwardUniforms(
            [light(Vec3(x: 10, y: 20, z: 30), Vec3(x: 1, y: 0.5, z: 0.25), intensity: 4, radius: 100)],
            ambient: Vec3(x: 0.3, y: 0.2, z: 0.1), skylight: Vec3(x: 0.5, y: 0.4, z: 0.3))
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(u.positions[0], SIMD4<Float>(10, 20, 30, 1))   // .w=활성
        XCTAssertEqual(u.positions[1], .zero)                        // 미사용 .w=0
        XCTAssertEqual(u.colorRadius[0], SIMD4<Float>(4, 2, 1, 100)) // rgb=color×intensity, w=radius
        XCTAssertEqual(u.colorRadius[1], .zero)
        XCTAssertEqual(u.ambientTerm, SIMD3<Float>(0.3, 0.2, 0.1))   // genericimage4: flat ambient only
    }

    func testForwardUniformsTakesFirstFour() {
        let lights = (0..<5).map { light(Vec3(x: Float($0), y: 0, z: 0), Vec3(x: 1, y: 1, z: 1), intensity: 1, radius: 10) }
        let u = SceneLight3D.forwardUniforms(lights, ambient: Vec3(x: 0, y: 0, z: 0), skylight: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(u.count, 4)
        XCTAssertEqual(u.positions[3], SIMD4<Float>(3, 0, 0, 1))     // 4번째(idx3), 5번째 미포함
    }

    func testParsedExponentReachesPackedForwardUniform() throws {
        let scene = #"{"objects":[{"id":1,"light":"lpoint","origin":"0 0 5","color":"1 1 1","intensity":1,"radius":10,"exponent":3}]}"#
        let pkg = ScenePackage.assemble([("scene.json", d(scene))])
        let doc = try SceneDocument.parse(package: pkg)
        let parsed = try XCTUnwrap(doc.lights3D.first)
        XCTAssertEqual(parsed.exponent, 3)

        let u = SceneLight3D.forwardUniforms(
            doc.lights3D,
            ambient: Vec3(x: 0, y: 0, z: 0),
            skylight: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(u.positions[0], SIMD4<Float>(0, 0, 5, 3))
        XCTAssertEqual(u.positions[1], .zero)
    }

    func testParsesPBRMaterialConstantsAndDefaults() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[
           {"id":1,"name":"authored","image":"models/authored.json","origin":"25 50 0"},
           {"id":2,"name":"defaulted","image":"models/defaulted.json","origin":"75 50 0"}
         ]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("models/authored.json", d(#"{"material":"materials/authored.json"}"#)),
            ("models/defaulted.json", d(#"{"material":"materials/defaulted.json"}"#)),
            ("materials/authored.json", d(#"{"passes":[{"textures":["authored"],"constantshadervalues":{"roughness":5,"metallic":0.25,"speculartint":"0.2 0.4 0.6"}}]}"#)),
            ("materials/defaulted.json", d(#"{"passes":[{"textures":["defaulted"]}]}"#)),
            ("materials/authored.tex", d("not-a-real-tex")),
            ("materials/defaulted.tex", d("not-a-real-tex")),
        ])

        let doc = try SceneDocument.parse(package: pkg)
        let authored = try XCTUnwrap(doc.layers.first { $0.name == "authored" })
        let defaulted = try XCTUnwrap(doc.layers.first { $0.name == "defaulted" })
        XCTAssertEqual(authored.roughness, 5)
        XCTAssertEqual(authored.metallic, 0.25)
        XCTAssertEqual(authored.specularTint, Vec3(x: 0.2, y: 0.4, z: 0.6))
        XCTAssertEqual(defaulted.roughness, 0.7)
        XCTAssertEqual(defaulted.metallic, 0)
        XCTAssertEqual(defaulted.specularTint, Vec3(x: 1, y: 1, z: 1))
    }

    // MARK: 감쇠/합산 수식 (손계산 대조 — 실씬 3047405322 spot)

    func testAmbientFloorWhenLightOutOfRange() {
        // 라이트 반경 밖 → 기여 0 → 정확히 앰비언트(전흑 방지의 근거).
        let u = SceneLight3D.forwardUniforms(
            [light(Vec3(x: 4134.5, y: 2319.7, z: 565), Vec3(x: 1, y: 1, z: 1), intensity: 4.87, radius: 2048)],
            ambient: Vec3(x: 0.3, y: 0.3, z: 0.3), skylight: Vec3(x: 0.3, y: 0.3, z: 0.3))
        let c = SceneLight3D.evaluateLighting(at: SIMD3(1920, 1080, 0), u)  // dist 2600 > radius 2048
        XCTAssertEqual(c.x, 0.3, accuracy: 1e-4)
        XCTAssertEqual(c.y, 0.3, accuracy: 1e-4)
    }

    func testAttenuationMatchesHandComputation() {
        // 3047405322 스팟이 (3500,2000,0)에 만드는 값: dist≈907.8, attn²≈0.310, dot≈0.6224
        // → 4.87·0.6224·0.310 ≈ 0.9396, +ambient 0.3 = 1.2396 (손계산·python 대조).
        let u = SceneLight3D.forwardUniforms(
            [light(Vec3(x: 4134.5, y: 2319.7, z: 565), Vec3(x: 1, y: 1, z: 1),
                   intensity: 4.87, radius: 2048, exponent: 2)],
            ambient: Vec3(x: 0.3, y: 0.3, z: 0.3), skylight: Vec3(x: 0.3, y: 0.3, z: 0.3))
        let c = SceneLight3D.evaluateLighting(at: SIMD3(3500, 2000, 0), u)
        XCTAssertEqual(c.x, 1.2396, accuracy: 5e-3)
    }

    func testAttenuationUsesPackedLightExponent() {
        let u = SceneLight3D.forwardUniforms(
            [light(Vec3(x: 0, y: 0, z: 5), Vec3(x: 1, y: 1, z: 1),
                   intensity: 1, radius: 10, exponent: 3)],
            ambient: Vec3(x: 0, y: 0, z: 0),
            skylight: Vec3(x: 0, y: 0, z: 0))

        let c = SceneLight3D.evaluateLighting(at: SIMD3(0, 0, 0), u)
        let eps: Float = 6.103515625e-5
        XCTAssertEqual(c.x, powf(0.5 + eps, 3), accuracy: 1e-5)
        XCTAssertEqual(c.y, c.x, accuracy: 1e-6)
        XCTAssertEqual(c.z, c.x, accuracy: 1e-6)
    }

    func testZeroExponentIsUnclampedInsideRadiusAndZeroOutside() {
        let u = SceneLight3D.forwardUniforms(
            [light(Vec3(x: 0, y: 0, z: 5), Vec3(x: 1, y: 1, z: 1),
                   intensity: 1, radius: 10, exponent: 0)],
            ambient: Vec3(x: 0, y: 0, z: 0),
            skylight: Vec3(x: 0, y: 0, z: 0))

        let inside = SceneLight3D.evaluateLighting(at: SIMD3(0, 0, 0), u)
        let outside = SceneLight3D.evaluateLighting(at: SIMD3(0, 0, -10), u)
        XCTAssertEqual(inside.x, 1, accuracy: 1e-6)
        XCTAssertEqual(outside.x, 0, accuracy: 1e-6)
    }

    func testZeroRadiusLightContributesNothing() {
        // parseLight 는 radius 부재 시 0 → 0나눗셈 없이 기여 0.
        let u = SceneLight3D.forwardUniforms(
            [light(Vec3(x: 0, y: 0, z: 10), Vec3(x: 1, y: 1, z: 1), intensity: 5, radius: 0)],
            ambient: Vec3(x: 0.1, y: 0.1, z: 0.1), skylight: Vec3(x: 0.1, y: 0.1, z: 0.1))
        let c = SceneLight3D.evaluateLighting(at: SIMD3(0, 0, 0), u)
        XCTAssertEqual(c, SIMD3(0.1, 0.1, 0.1))
    }

    func testColorAndSummation() {
        // 2 라이트 색 합산: 각각 z-축상 근접(dot≈1, attn≈1)이면 근사 (color×intensity) 합.
        // r=1000, dist=10 → attn=(990/1000)²=0.9801, dot=1 → 기여 = color×i×0.9801.
        let u = SceneLight3D.forwardUniforms([
            light(Vec3(x: 0, y: 0, z: 10), Vec3(x: 1, y: 0, z: 0), intensity: 2, radius: 1000, exponent: 2),   // red×2
            light(Vec3(x: 0, y: 0, z: 10), Vec3(x: 0, y: 0, z: 1), intensity: 3, radius: 1000, exponent: 2),   // blue×3
        ], ambient: Vec3(x: 0, y: 0, z: 0), skylight: Vec3(x: 0, y: 0, z: 0))
        let c = SceneLight3D.evaluateLighting(at: SIMD3(0, 0, 0), u)
        XCTAssertEqual(c.x, 2 * 0.9801, accuracy: 1e-3)   // red
        XCTAssertEqual(c.y, 0, accuracy: 1e-6)
        XCTAssertEqual(c.z, 3 * 0.9801, accuracy: 1e-3)   // blue
    }

    // MARK: 게이트 판정

    func testForwardLit2DGate() {
        let base = SceneDocument(projectionWidth: 100, projectionHeight: 100,
                                 clearColor: Vec3(x: 0, y: 0, z: 0), parallaxEnabled: false,
                                 parallaxAmount: 1, parallaxMouseInfluence: 1, parallaxDelay: 0,
                                 layers: [], particles: [])
        // 라이트 없음 → 비활성.
        XCTAssertFalse(base.forwardLit2D)
        // 2D(camera3D nil) + 라이트 → 활성.
        var lit = base
        lit.lights3D = [light(Vec3(x: 0, y: 0, z: 0), Vec3(x: 1, y: 1, z: 1), intensity: 1, radius: 10)]
        XCTAssertTrue(lit.forwardLit2D)
        // 원근 3D 씬(camera3D 존재) → 라이트 있어도 비활성(메시 경로 담당).
        var persp = lit
        persp.camera3D = SceneCamera3D(eye: Vec3(x: 0, y: 0, z: 1), center: Vec3(x: 0, y: 0, z: 0),
                                       up: Vec3(x: 0, y: 1, z: 0), fov: 50, nearZ: 0.01, farZ: 100)
        XCTAssertFalse(persp.forwardLit2D)
    }

    func testParseLightingComboAndAmbient() {
        // 2D 씬 + lpoint + LIGHTING:1 머티리얼 레이어 → layer.lighting true, ambient 파스, 게이트 활성.
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100},
          "ambientcolor":"0.3 0.3 0.3","skylightcolor":"0.5 0.5 0.5"},
         "objects":[
           {"id":1,"image":"models/x.json","origin":"50 50 0"},
           {"id":2,"light":"lpoint","origin":"50 50 20","color":"1 1 1","intensity":4,"radius":80}
         ]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("models/x.json", d(#"{"material":"materials/x.json"}"#)),
            ("materials/x.json", d(#"{"passes":[{"textures":["x"],"combos":{"LIGHTING":1}}]}"#)),
            ("materials/x.tex", d("not-a-real-tex")),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertEqual(doc.ambientColor, Vec3(x: 0.3, y: 0.3, z: 0.3))
        XCTAssertEqual(doc.skylightColor, Vec3(x: 0.5, y: 0.5, z: 0.5))
        XCTAssertEqual(doc.lights3D.count, 1)
        XCTAssertNil(doc.camera3D)                       // ortho dict → 2D
        XCTAssertTrue(doc.forwardLit2D)
        XCTAssertTrue(try XCTUnwrap(doc.layers.first).lighting)  // LIGHTING:1 콤보
    }

    func testLightingComboAbsentDefaultsUnlit() {
        // LIGHTING 콤보 없는 머티리얼 → layer.lighting false(무회귀 — 기존 unlit 경로 유지).
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"id":1,"image":"models/x.json","origin":"50 50 0"}]}
        """
        let pkg = ScenePackage.assemble([
            ("scene.json", d(scene)),
            ("models/x.json", d(#"{"material":"materials/x.json"}"#)),
            ("materials/x.json", d(#"{"passes":[{"textures":["x"]}]}"#)),
            ("materials/x.tex", d("not-a-real-tex")),
        ])
        let doc = try! SceneDocument.parse(package: pkg)
        XCTAssertFalse(try XCTUnwrap(doc.layers.first).lighting)
        XCTAssertFalse(doc.forwardLit2D)                 // 라이트 없음
    }
}
