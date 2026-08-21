import Foundation
import XCTest
@testable import WapleCore

/// WE 2.8.42 메시 라이팅 정본 수식/상수 고정(2026-08-21 셰이더 원문 + wallpaper64.exe 전수 대조).
///
/// 왜 값을 못박는가: 라이브 셰이딩은 `Mesh3DShaders.swift` 의 MSL 이라 리눅스에서 못 돈다.
/// 여기서 **CPU 순수 함수**를 고정해 두면, MSL 을 손댈 때 같은 수식을 유지했는지 사람이 대조할
/// 기준선이 남는다(ScenePBRMath 가 데드코드로 표류한 전례 — spec/engine/deviations.json).
final class SceneWELightMathTests: XCTestCase {
    private let tol: Float = 1e-6

    // MARK: V1 유한광 감쇠 — common_pbr_2.h:263-270

    func testFiniteFalloffMatchesSaturatedLinearPowered() {
        // falloff = saturate(1 - d/r)
        XCTAssertEqual(SceneWELightMath.finiteFalloff(distance: 0, radius: 10, exponent: 1), 1, accuracy: tol)
        XCTAssertEqual(SceneWELightMath.finiteFalloff(distance: 5, radius: 10, exponent: 1), 0.5, accuracy: tol)
        XCTAssertEqual(SceneWELightMath.finiteFalloff(distance: 10, radius: 10, exponent: 1), 0, accuracy: tol)
        // saturate 상한: 음수 거리(퇴화 입력)는 1 로 잘린다.
        XCTAssertEqual(SceneWELightMath.finiteFalloff(distance: -5, radius: 10, exponent: 1), 1, accuracy: tol)
        // exponent 2 는 제곱
        XCTAssertEqual(SceneWELightMath.finiteFalloff(distance: 5, radius: 10, exponent: 2), 0.25, accuracy: tol)
        XCTAssertEqual(SceneWELightMath.finiteFalloff(distance: 2, radius: 10, exponent: 2), 0.64, accuracy: 1e-5)
    }

    /// **반경 컷오프가 없다**는 것이 이 레인의 핵심 성질이다 — exponent=0 이면 반경 밖도 1.0.
    /// (`pow(0 + 1.17549435e-38, 0) == 1`.)
    func testExponentZeroIsGlobalUnattenuated() {
        XCTAssertEqual(SceneWELightMath.finiteFalloff(distance: 1e6, radius: 1, exponent: 0), 1, accuracy: tol)
        XCTAssertEqual(SceneWELightMath.finiteFalloff(distance: 0, radius: 1, exponent: 0), 1, accuracy: tol)
    }

    /// HLSL/GLSL 두 레인이 갈리는 유일한 지점: falloff < flt_min 에서 GLSL 은 hard-zero.
    /// 우리는 HLSL 레인을 채택했다(Mesh3DShaders.finiteLightFalloff 와 동일).
    func testHLSLAndGLSLLanesDivergeOnlyBelowFltMin() {
        // falloff = 0.5 — 두 레인이 사실상 같다(엡실론 차이만).
        let hlsl = SceneWELightMath.finiteFalloff(distance: 5, radius: 10, exponent: 2)
        let glsl = SceneWELightMath.finiteFalloffGLSLLane(distance: 5, radius: 10, exponent: 2)
        XCTAssertEqual(hlsl, glsl, accuracy: 1e-4)
        // 반경 밖 + exponent 0: HLSL 1.0 / GLSL 0.0 로 완전히 갈린다.
        XCTAssertEqual(SceneWELightMath.finiteFalloff(distance: 20, radius: 10, exponent: 0), 1, accuracy: tol)
        XCTAssertEqual(SceneWELightMath.finiteFalloffGLSLLane(distance: 20, radius: 10, exponent: 0), 0, accuracy: tol)
        XCTAssertEqual(SceneWELightMath.hlslFalloffEpsilon, 1.17549435e-38)
        XCTAssertEqual(SceneWELightMath.glslFalloffEpsilon, 6.103515625e-5)
    }

    /// V1 `exponent = 2` 는 레거시 레인 감쇠(`saturate((r-d)/r)^2`)와 **대수적으로 같다**.
    /// 두 레인을 잇는 유일한 접점이라 못박는다(common_fragment.h:64-65 ↔ common_pbr_2.h:263-266).
    func testLegacyAttenuationSquaredEqualsV1ExponentTwo() {
        for d in stride(from: Float(0), through: 12, by: 0.75) {
            let legacy = SceneWELightMath.legacyAttenuation(distance: d, radius: 10)
            let v1 = SceneWELightMath.finiteFalloff(distance: d, radius: 10, exponent: 2)
            XCTAssertEqual(legacy * legacy, v1, accuracy: 1e-5, "d=\(d)")
        }
    }

    // MARK: V0(deprecated PBR) 역제곱 — common_pbr.h:84 + generic3.frag:132

    func testDeprecatedInverseSquareUsesRadiusAsIntensityScale() {
        // radius² / d² — 반경은 컷오프가 아니라 배율이라 d=radius 에서 정확히 1 이다.
        XCTAssertEqual(SceneWELightMath.deprecatedInverseSquareFalloff(distance: 10, radius: 10), 1, accuracy: tol)
        XCTAssertEqual(SceneWELightMath.deprecatedInverseSquareFalloff(distance: 20, radius: 10), 0.25, accuracy: tol)
        // 반경 밖에서도 0 이 아니다 — V1 과 갈리는 지점.
        XCTAssertGreaterThan(SceneWELightMath.deprecatedInverseSquareFalloff(distance: 100, radius: 10), 0)
        XCTAssertEqual(SceneWELightMath.finiteFalloff(distance: 100, radius: 10, exponent: 1), 0, accuracy: tol)
        // SHADERVERSION < 62 가지에는 radius² 배율이 없다(generic3.frag:99-104).
        XCTAssertEqual(
            SceneWELightMath.deprecatedInverseSquareFalloff(distance: 10, radius: 10, legacyShaderVersion: true),
            0.01, accuracy: tol)
    }

    // MARK: 레거시(비 PBR) 러프니스 매핑 — common_fragment.h:51-59

    func testLegacySpecularPowerAndStrength() {
        // 스톡 기본값 Rough=0/Metal=0 → 지수 404(사실상 델타 함수), 세기 0.5.
        XCTAssertEqual(SceneWELightMath.legacySpecularPower(roughness: 0, metallic: 0), 404, accuracy: 1e-3)
        XCTAssertEqual(SceneWELightMath.legacySpecularStrength(roughness: 0, metallic: 0), 0.5, accuracy: tol)
        // metallic=1 → mix(400,250,1)=250
        XCTAssertEqual(SceneWELightMath.legacySpecularPower(roughness: 0, metallic: 1), 252.5, accuracy: 1e-3)
        XCTAssertEqual(SceneWELightMath.legacySpecularStrength(roughness: 0, metallic: 1), 1, accuracy: tol)
        // roughness=1 → (1.01-1)=0.01 배
        XCTAssertEqual(SceneWELightMath.legacySpecularPower(roughness: 1, metallic: 0), 4, accuracy: 1e-3)
        XCTAssertEqual(SceneWELightMath.legacySpecularStrength(roughness: 1, metallic: 0), 0.05, accuracy: 1e-6)
    }

    /// GGX 직접광 k 매핑 `(r+1)²/8` — ScenePBRMath.schlickGGX 내부와 같은 값이어야 한다.
    func testSchlickRoughnessKMatchesScenePBRMath() {
        for r in [Float(0), 0.25, 0.5, 0.7, 1] {
            let k = SceneWELightMath.schlickRoughnessK(r)
            XCTAssertEqual(k, (r + 1) * (r + 1) / 8, accuracy: tol)
            // schlickGGX(nd) = nd / (nd*(1-k) + k) 로 재구성되는지 확인.
            let nd: Float = 0.6
            XCTAssertEqual(ScenePBRMath.schlickGGX(nd, roughness: r),
                           nd / (nd * (1 - k) + k), accuracy: 1e-6)
        }
    }

    // MARK: 프레넬 — common_pbr.h:4-7 (= common_pbr_2.h:4-7)

    func testFresnelSchlickFloorIsWEsOwn() {
        let f0 = SIMD3<Float>(repeating: 0.04)
        // cosTheta=1 → (1-1)=0 이지만 WE 는 max(...,0.001) 로 바닥을 씌운다 → F0 보다 아주 조금 크다.
        let head = ScenePBRMath.fresnel(cosTheta: 1, f0: f0)
        XCTAssertEqual(head.x, 0.04 + 0.96 * powf(0.001, 5), accuracy: 1e-12)
        // cosTheta=0 → 1.0
        let grazing = ScenePBRMath.fresnel(cosTheta: 0, f0: f0)
        XCTAssertEqual(grazing.x, 1, accuracy: 1e-6)
        // 금속(F0=albedo)은 정면에서도 albedo 를 유지한다.
        let metal = ScenePBRMath.fresnel(cosTheta: 1, f0: SIMD3<Float>(1, 0.71, 0.29))
        XCTAssertEqual(metal.y, 0.71, accuracy: 1e-6)
    }

    // MARK: spot 콘 — 조립 스니펫 0x14048c900/0x14048c960 + 패커 0x140192e64–0x140192ebf

    /// **반각이다** — 도 값에 π/180 만 곱한다(0.5 배 없음).
    func testConeCosineIsHalfAngleInDegrees() {
        XCTAssertEqual(SceneWELightMath.coneCosine(degrees: 0), 1, accuracy: tol)
        XCTAssertEqual(SceneWELightMath.coneCosine(degrees: 60), 0.5, accuracy: 1e-6)
        XCTAssertEqual(SceneWELightMath.coneCosine(degrees: 90), 0, accuracy: 1e-6)
        // WE 라이트 기본값 20/30 도 → cos 0.93969/0.86603.
        XCTAssertEqual(SceneWELightMath.coneCosine(degrees: SceneLight3D.WEDefaults.innerConeDegrees),
                       0.9396926, accuracy: 1e-6)
        XCTAssertEqual(SceneWELightMath.coneCosine(degrees: SceneLight3D.WEDefaults.outerConeDegrees),
                       0.8660254, accuracy: 1e-6)
        // 종전 반각 해석(도 × 0.5)과는 명확히 다르다 — 회귀 방지용 대비 단언.
        XCTAssertNotEqual(SceneWELightMath.coneCosine(degrees: 60),
                          SceneWELightMath.coneCosine(degrees: 30), accuracy: 0.05)
    }

    func testSpotConeIsGLSLSmoothstep() {
        let inner = SceneWELightMath.coneCosine(degrees: 20)
        let outer = SceneWELightMath.coneCosine(degrees: 30)
        // 콘 안쪽(축) → 1, 콘 바깥 → 0.
        XCTAssertEqual(SceneWELightMath.spotCone(cosAngle: 1, cosInner: inner, cosOuter: outer), 1, accuracy: tol)
        XCTAssertEqual(SceneWELightMath.spotCone(cosAngle: 0, cosInner: inner, cosOuter: outer), 0, accuracy: tol)
        // 중간점 = smoothstep(0.5) = 0.5
        let mid = (inner + outer) * 0.5
        XCTAssertEqual(SceneWELightMath.spotCone(cosAngle: mid, cosInner: inner, cosOuter: outer),
                       0.5, accuracy: 1e-6)
        // 단조 증가
        var previous: Float = -1
        for step in 0...20 {
            let x = outer + (inner - outer) * Float(step) / 20
            let value = SceneWELightMath.spotCone(cosAngle: x, cosInner: inner, cosOuter: outer)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    // MARK: 반구 앰비언트 — base/model_vertex_v1.h:207-210

    /// 인자 순서가 직관과 반대다: 위를 보는 법선이 `ambientcolor`, 아래가 `skylightcolor`.
    func testHemisphereAmbientArgumentOrder() {
        let ambient = SIMD3<Float>(1, 0, 0)
        let skylight = SIMD3<Float>(0, 0, 1)
        let up = SceneWELightMath.hemisphereAmbient(normal: SIMD3(0, 1, 0), ambient: ambient, skylight: skylight)
        XCTAssertEqual(up.x, 1, accuracy: tol)
        XCTAssertEqual(up.z, 0, accuracy: tol)
        let down = SceneWELightMath.hemisphereAmbient(normal: SIMD3(0, -1, 0), ambient: ambient, skylight: skylight)
        XCTAssertEqual(down.x, 0, accuracy: tol)
        XCTAssertEqual(down.z, 1, accuracy: tol)
        let side = SceneWELightMath.hemisphereAmbient(normal: SIMD3(1, 0, 0), ambient: ambient, skylight: skylight)
        XCTAssertEqual(side.x, 0.5, accuracy: tol)
        XCTAssertEqual(side.z, 0.5, accuracy: tol)
    }

    // MARK: CombineLighting — common_pbr_2.h:365-385

    func testCombineLightingNonHDRIsPlainAdd() {
        let light = SIMD3<Float>(3, 0, 0)
        let ambient = SIMD3<Float>(0.3, 0.3, 0.3)
        let out = SceneWELightMath.combineLighting(light: light, ambient: ambient, hdr: false)
        XCTAssertEqual(out.x, 3.3, accuracy: 1e-6)
        XCTAssertEqual(out.y, 0.3, accuracy: 1e-6)
    }

    func testCombineLightingHDRSaturatesThenAddsOverbright() {
        let ambient = SIMD3<Float>(0.3, 0.3, 0.3)
        // |light| <= 2 → overbright 0 → 순수 saturate.
        let dim = SceneWELightMath.combineLighting(light: SIMD3(1.5, 0, 0), ambient: ambient, hdr: true)
        XCTAssertEqual(dim.x, 1, accuracy: 1e-6)      // saturate(1.8)
        XCTAssertEqual(dim.y, 0.3, accuracy: 1e-6)
        // |light| = 3 → overbright = saturate(1) * 0.5 / 3 = 1/6
        let bright = SceneWELightMath.combineLighting(light: SIMD3(3, 0, 0), ambient: ambient, hdr: true)
        XCTAssertEqual(bright.x, 1 + 3 * (0.5 / 3), accuracy: 1e-5)
        // |light| = 5 → saturate(3)=1 → overbright = 0.5/5 = 0.1
        let hot = SceneWELightMath.combineLighting(light: SIMD3(5, 0, 0), ambient: ambient, hdr: true)
        XCTAssertEqual(hot.x, 1 + 5 * 0.1, accuracy: 1e-5)
        // HDR 가지는 비HDR 과 실제로 다르다(현행 MSL 은 비HDR 가지만 이식 — 갭 문서화).
        let plain = SceneWELightMath.combineLighting(light: SIMD3(5, 0, 0), ambient: ambient, hdr: false)
        XCTAssertNotEqual(hot.x, plain.x, accuracy: 0.1)
    }

    // MARK: RIMLIGHTING — common_pbr_2.h:292-297 / :340-345

    func testRimTermGateThreshold() {
        // 광원색 합이 0.001 미만이면 게이트가 닫힌다(V1 레인 임계 0.001).
        let off = SceneWELightMath.rimTerm(nDotV: 0, nDotL: 1, amount: 2, exponent: 4,
                                           lightColor: SIMD3(0.0002, 0.0002, 0.0002))
        XCTAssertEqual(off, 0, accuracy: tol)
        let on = SceneWELightMath.rimTerm(nDotV: 0, nDotL: 1, amount: 2, exponent: 4,
                                          lightColor: SIMD3(1, 1, 1))
        XCTAssertEqual(on, 2, accuracy: tol)          // pow(1-0, 4) * 2 * 1
        // 정면(NV=1)에서는 림이 0.
        XCTAssertEqual(SceneWELightMath.rimTerm(nDotV: 1, nDotL: 1, amount: 2, exponent: 4,
                                                lightColor: SIMD3(1, 1, 1)), 0, accuracy: tol)
        // shadowFactor 는 선형 배율.
        XCTAssertEqual(SceneWELightMath.rimTerm(nDotV: 0, nDotL: 1, amount: 2, exponent: 4,
                                                lightColor: SIMD3(1, 1, 1), shadowFactor: 0.25),
                       0.5, accuracy: tol)
    }

    // MARK: WE 라이트 오브젝트 생성자 기본값 — 0x140190441–0x1401904ef

    /// 파스 기본값이 WE 와 갈리는 항목을 상수로 고정한다. 소비(SceneDocument.parseLight)는 별도 레인.
    func testWEDefaultsAreRecorded() {
        XCTAssertEqual(SceneLight3D.WEDefaults.radius, 1)
        XCTAssertEqual(SceneLight3D.WEDefaults.exponent, 2)
        XCTAssertEqual(SceneLight3D.WEDefaults.innerConeDegrees, 20)
        XCTAssertEqual(SceneLight3D.WEDefaults.outerConeDegrees, 30)
        XCTAssertEqual(SceneLight3D.WEDefaults.intensity, 0)
        XCTAssertEqual(SceneLight3D.WEDefaults.color, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(SceneLight3D.WEDefaults.controlPoint, SIMD3<Float>(2, 0, 0))
        XCTAssertEqual(SceneLight3D.WEDefaults.density, 2)
        XCTAssertEqual(SceneLight3D.WEDefaults.volumetricsExponent, 1)
        XCTAssertEqual(SceneLight3D.WEDefaults.cascadeDistances, SIMD3<Float>(3, 10, 100))
        XCTAssertEqual(SceneLight3D.WEDefaults.lightSourceSize, 0)
    }

    /// **현재 갈려 있는 항목**을 명시적으로 기록한다 — 고쳐지면 이 테스트가 먼저 깨져서 알려 준다.
    /// (파스는 `SceneDocument.parseLight` 소관. `exponent` 미저작은 동봉/설치본 `modeleditor` 씬의
    ///  lpoint 2개가 실제 도달이다 — WE 2 vs Waple 1.)
    func testParseDefaultsStillDivergeFromWE() throws {
        let json = #"{"objects":[{"id":1,"light":"lpoint","origin":"0 0 0","color":"1 1 1","intensity":3}]}"#
        let pkg = ScenePackage.assemble([("scene.json", Data(json.utf8))])
        let doc = try SceneDocument.parse(package: pkg)
        let light = try XCTUnwrap(doc.lights3D.first)
        // 지금 값(= WE 와 다름). 셋 중 하나라도 WE 쪽으로 고쳐지면 여기서 잡힌다.
        XCTAssertEqual(light.radius, 0)
        XCTAssertNotEqual(light.radius, SceneLight3D.WEDefaults.radius)
        XCTAssertEqual(light.exponent, 1)
        XCTAssertNotEqual(light.exponent, SceneLight3D.WEDefaults.exponent)
        XCTAssertEqual(light.innerCone, 0)
        XCTAssertEqual(light.outerCone, 0)
    }
}
