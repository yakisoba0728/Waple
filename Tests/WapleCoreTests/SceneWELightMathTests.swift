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
        XCTAssertEqual(SceneWELightMath.hlslFalloffEpsilon, Float(1.17549435e-38))
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

    /// GGX 지접광 k 매핑 — **기대값을 동봉 WE 원문에서 파스해** 잠긴다
    /// (`Sources/WapleRender/Resources/WEAssets/shaders/common_pbr.h` 의 `Schlick_GGX`).
    ///
    /// **[정정 2026-08-30] 종전엔 `(r + 1) * (r + 1) / 8` 을 테스트 안에 지직 적었다.**
    /// 그 리터럴이 이 상수의 유일한 정본 앵서여서, 프로덕션 사본과 **양족에 같은 변이를
    /// 넣으면 그대로 통과**했다. 실주(2026-08-30, 이 수정 전 판):
    ///
    /// | 변이 | 종전 테스트 |
    /// | --- | --- |
    /// | Swift 두 사본 + 테스트 리터럴 전부 `/8`→`/2` | **통과**(오라클이 변이와 함까 움직인다) |
    /// | 라이밌 MSL 두 레인만 `/8`→`/2` | **통과**(이 테스트가 MSL 을 안 봤다) |
    ///
    /// 그래서 기대값을 헤더에서 읽고(테스드 안에서 수식을 다시 구현하지 않는다), 라이밌
    /// MSL 두 레인을 같은 파서로 통과시킨다. `Sources/WapleCore` 의 사본 둘은 데드코드이므로
    /// (`spec/engine/deviations.json` `deviation.finding.scenePBRMathIsDead`, 상태 확정) 그것만 봐서는
    /// 화면에 닿는 경로가 하나도 덮이지 않는다.
    func testSchlickRoughnessKMatchesWECanonHeader() throws {
        let header = try Self.bundledPBRHeader()
        // 헤더가 자기 식을 어떻게 적는지를 그대로 읽는다 — 원문은 `roughnessScaled`·`roughnessBase`
        // 를 쓰며, 우리 사본의 변수명(`base`/`r`/`k`)은 헤더에 없다.
        let canon = try XCTUnwrap(Self.schlickKMapping(header, kVariable: "roughnessScaled"),
                                  "원문 Schlick_GGX 의 k 식을 파스하지 못했다 — 헤더 형식이 바뀌었으면 이 파서도 같이 고치라")
        // 파서가 상수를 못 읽고 기물값을 낸 것이 아니어야 한다 — 분별자는 언제나 상수다.
        XCTAssertGreaterThan(canon.divisor, 0, "원문 분모가 0 이하로 읽혔다 — 파스 실패")

        for r in [Float(0), 0.25, 0.5, 0.7, 1] {
            let k = SceneWELightMath.schlickRoughnessK(r)
            let base = r + canon.addend
            XCTAssertEqual(k, base * base / canon.divisor, accuracy: tol,
                           "r=\(r) 에서 원문 매핑과 갈린다")
            // schlickGGX(nd) = nd / (nd*(1-k) + k) 로 재구성되는지 확인.
            // 그 분모 형태도 원문에서 확인한다(아래 별도 테스트).
            let nd: Float = 0.6
            XCTAssertEqual(ScenePBRMath.schlickGGX(nd, roughness: r),
                           nd / (nd * (1 - k) + k), accuracy: 1e-6)
        }
    }

    /// `schlickGGX` 의 **분모 형태**를 원문 `return` 문에서 확인한다.
    /// 이게 없으면 위 재구성 단언은 "우리가 생각하는 형태" 를 다시 적은 것일 뿐이다.
    func testSchlickGGXDenominatorFormIsTheHeadersOwn() throws {
        let header = try Self.bundledPBRHeader()
        let body = try XCTUnwrap(Self.functionBody(header, signature: "float Schlick_GGX(float NV, float roughness)"),
                                 "원문 Schlick_GGX 본문을 못 찾았다")
        let ret = try XCTUnwrap(Self.lines(body).first { $0.hasPrefix("return ") },
                                "Schlick_GGX 에 return 문이 없다")
        XCTAssertEqual(ret, "return NV / (NV * (1.0 - roughnessScaled) + roughnessScaled);",
                       "원문 분모 형태가 바뀜다 — 재구성 단언도 같이 고치라")
    }

    /// **화면에 닿는 레인 둘이 원문과 같은 k 매핑을 갖는가.**
    ///
    /// `ScenePBRMath`·`SceneWELightMath` 의 Swift 사본은 다 데드코드다 — 살아 있는 샤딩은
    /// `Mesh3DShaders`(모시 3D)와 `QuadShaders`(2D 포워드 라이티링) 의 MSL 문자열 둘이다.
    /// 리눅스에서 `WapleRender` 를 실행할 수 없으므로 소스를 직접 읽어 잠긴다
    /// (`GLSLTranslatorTests.testMeshVertexDescriptorWiresNormalUnderTheSameCondition` 와 같은 수법).
    func testLiveMSLLanesUseTheSameSchlickKAsTheCanonHeader() throws {
        let canon = try XCTUnwrap(Self.schlickKMapping(try Self.bundledPBRHeader(),
                                                       kVariable: "roughnessScaled"))
        let root = try TexSpriteSheetBlendTests.repoRoot()
        // 두 레인 둘 다 본다 — 한 쪽만 보면 다른 쪽이 조용히 표루한다(종전 상태).
        for relative in ["Sources/WapleRender/Mesh3DShaders.swift",
                         "Sources/WapleRender/QuadShaders.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            let live = try XCTUnwrap(Self.schlickKMapping(text, kVariable: "k"),
                                     "\(relative) 에서 Schlick k 식을 못 찾았다 — 삭제됐거나 형식이 바뀌었다")
            XCTAssertEqual(live.addend, canon.addend, accuracy: tol,
                           "\(relative) 의 roughness 가산이 원문과 갈렸다")
            XCTAssertEqual(live.divisor, canon.divisor, accuracy: tol,
                           "\(relative) 의 k 분모가 원문과 갈렸다")
        }
    }

    // MARK: 원문 헤더 파스 보조

    /// 동봉 `common_pbr.h`. 없으면(WEAssets 미배치) 스픍한다 — `BlendModeFormulaParityTests` 와 같은 관례.
    private static func bundledPBRHeader() throws -> String {
        guard let root = bundledWEAssetsRoot() else {
            throw XCTSkip("WEAssets 미배치(WAPLE_WE_ASSETS 미지정)")
        }
        let url = root.appendingPathComponent("shaders/common_pbr.h")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("동봉 common_pbr.h 없음: \(url.path)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 동봉 헤더는 **CRLF** 다. Swift `String` 은 그래툼 클러스터 단위라 `"\r\n"` 이
    /// 하나의 `Character` 이고 `"\n"` 과 같지 않다 — `split(separator: "\n")` 은 한 줄도 못
    /// 쓪는다(방법로로 함정 24). `isNewline` 으로 쓪는다.
    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// `signature` 로 시작하는 함수의 본문(중쾄톨 안)을 중쾄톨 수로 뗼어랍다.
    private static func functionBody(_ text: String, signature: String) -> String? {
        guard let head = text.range(of: signature),
              let open = text[head.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var body = ""
        for ch in text[open...] {
            if ch == "{" { depth += 1; if depth == 1 { continue } }
            if ch == "}" { depth -= 1; if depth == 0 { return body } }
            body.append(ch)
        }
        return nil
    }

    /// `k = (base * base) / divisor` 와 `base = roughness + addend` 를 한 파서로 뽑는다.
    /// 원문과 MSL 두 레인이 **같은 파서**를 통과해야 직접 비교가 의밌하다.
    /// 괄호는 있어도 없어도 된다(원문은 `(a * a) / 8.0`, 우리 MSL 은 `a * a / 8.0`).
    static func schlickKMapping(_ text: String, kVariable: String) -> (addend: Float, divisor: Float)? {
        let kPattern = "\\b\(kVariable)\\s*=\\s*\\(?\\s*(\\w+)\\s*\\*\\s*\\1\\s*\\)?\\s*/\\s*([0-9]+(?:\\.[0-9]+)?)\\s*;"
        guard let (baseName, divisorText) = firstMatch(kPattern, in: text, groups: 2)
            .map({ ($0[0], $0[1]) }),
              let divisor = Float(divisorText) else { return nil }
        let basePattern = "\\b\(NSRegularExpression.escapedPattern(for: baseName))\\s*=\\s*roughness\\s*\\+\\s*([0-9]+(?:\\.[0-9]+)?)\\s*;"
        guard let addendText = firstMatch(basePattern, in: text, groups: 1)?.first,
              let addend = Float(addendText) else { return nil }
        return (addend, divisor)
    }

    /// 상수 뒤 식을 더 붙여도 앞 숫자만 읽고 통과하던 우측 미앵커 회귀.
    /// WE 헤더가 식을 바꾸면 오라클도 반드시 실패해야 한다.
    func testSchlickKMappingRejectsTrailingArithmetic() {
        let valid = """
        roughnessBase = roughness + 1.0;
        roughnessScaled = (roughnessBase * roughnessBase) / 8.0;
        """
        XCTAssertNotNil(Self.schlickKMapping(valid, kVariable: "roughnessScaled"))
        XCTAssertNil(Self.schlickKMapping(
            valid.replacingOccurrences(of: "/ 8.0;", with: "/ 8.0 + 99.0;"),
            kVariable: "roughnessScaled"))
        XCTAssertNil(Self.schlickKMapping(
            valid.replacingOccurrences(of: "+ 1.0;", with: "+ 1.0 * 7.0;"),
            kVariable: "roughnessScaled"))
    }

    private static func firstMatch(_ pattern: String, in text: String, groups: Int) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        var out: [String] = []
        for g in 1...groups {
            guard let r = Range(m.range(at: g), in: text) else { return nil }
            out.append(String(text[r]))
        }
        return out
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

    // MARK: W-17 단계 1 — 볼류메트릭 씬 뎁스 클립 (`volumetricsfront.frag:64,71`)

    // 이 절이 여기(메시 라이팅 파일) 있는 이유: 볼류메트릭 순수 산술의 정본 파일이
    // `Sources/WapleCore/ScenePBRLighting.swift` 로 같고, `SceneVolumetricMathTests` 는 다른 레인
    // 소관이라 이번 라운드에 손대지 않았다. 옮길 자리는 그쪽이다(보고서 인계 항목).

    /// `Scene3DMath.perspective` 의 **역**이 맞는지 — 정변환을 손으로 다시 적어 왕복시킨다.
    /// 그 행렬은 `zz = far/(near−far)` 로 `clip.z = zz·vz + near·zz`, `clip.w = −vz` 를 만들므로
    /// 전방축 거리 `d = −vz` 에 대해 `ndc = zz·(near−d)/d` 다. 기대값을 역식으로 다시 적지 않고
    /// **정식으로 만들어** 넣는 것이 요점이다.
    func testViewDepthDistanceInvertsThePerspectiveDepth() {
        // near/far 비가 1000 이하면 float32 왕복이 **정확**하다(아래 표본 전부 상대오차 0).
        let near: Float = 1, far: Float = 1000
        let zz = far / (near - far)
        for d in [Float(1), 7.5, 250, 500, 1000] {
            let ndc = zz * (near - d) / d
            XCTAssertEqual(SceneWEVolumetricMath.viewDepthDistance(ndcDepth: ndc, nearZ: near, farZ: far),
                           d, accuracy: max(1e-4, d * 1e-5), "d=\(d)")
        }
        XCTAssertEqual(SceneWEVolumetricMath.viewDepthDistance(ndcDepth: 0, nearZ: near, farZ: far),
                       near, accuracy: 1e-6)
    }

    /// **클리어 뎁스(1.0)는 항상 `farZ` **이상**으로 풀린다** — 이게 W-17 클립의 무회귀 보증이다.
    /// `tExit` 은 이미 `min(·, farZ)` 이므로 그때 `min` 이 무연산이 된다.
    ///
    /// 씬 기본 절두체(`near 0.1` / `far 10000`, `SceneDocument` 미저작 기본값)에서는 float32
    /// 소거 때문에 원거리 왕복이 **정확하지 않다**(ndc=1 → 10138.6, 상대오차 1.4%). 그래도
    /// 오차가 **먼 쪽**으로 나므로 클립이 조기 발동하지 않는다. 이 성질을 값으로 못박는다 —
    /// 반대 방향(가까운 쪽)으로 틀리는 구현이 들어오면 화면이 통째로 어두워진다.
    func testClearedDepthNeverResolvesNearerThanFarPlane() {
        for (near, far) in [(Float(1), Float(1000)), (0.1, 10000), (0.01, 100000)] {
            let atClear = SceneWEVolumetricMath.viewDepthDistance(ndcDepth: 1, nearZ: near, farZ: far)
            XCTAssertGreaterThanOrEqual(atClear, far, "near=\(near) far=\(far)")
        }
        // 퇴화 입력(분모 ≤ 0, 뒤집힌 절두체)도 farZ 로 접는다 — 자르지 않는 쪽이 안전한 쪽이다.
        XCTAssertEqual(SceneWEVolumetricMath.viewDepthDistance(ndcDepth: 2, nearZ: 1, farZ: 1000),
                       1000, accuracy: tol)
        XCTAssertEqual(SceneWEVolumetricMath.viewDepthDistance(ndcDepth: 0.5, nearZ: 0, farZ: 1000),
                       1000, accuracy: tol)
    }

    /// 뎁스는 카메라 **전방축** 투영 거리고 마치는 단위 레이 파라미터 t 라, 화면 가장자리에서
    /// `t = d / cos` 로 늘어난다. 이 나눗셈을 빼먹으면 가장자리 샤프트가 너무 일찍 잘린다.
    func testSceneDepthRayLimitDividesByAxisCosine() {
        let near: Float = 0.1, far: Float = 1000
        let onAxis = SceneWEVolumetricMath.sceneDepthRayLimit(ndcDepth: 0.9, nearZ: near, farZ: far,
                                                              cosFromAxis: 1)
        let offAxis = SceneWEVolumetricMath.sceneDepthRayLimit(ndcDepth: 0.9, nearZ: near, farZ: far,
                                                              cosFromAxis: 0.5)
        XCTAssertEqual(offAxis, onAxis * 2, accuracy: max(1e-4, onAxis * 1e-5))
        // 퇴화(정상 절두체에는 없는 입력)는 **안 자르는 쪽**으로 접는다 — 자르는 쪽으로 틀리면
        // 화면이 통째로 검어진다.
        XCTAssertEqual(SceneWEVolumetricMath.sceneDepthRayLimit(ndcDepth: 0.5, nearZ: near, farZ: far,
                                                                cosFromAxis: 0), far, accuracy: tol)
        XCTAssertEqual(SceneWEVolumetricMath.sceneDepthRayLimit(ndcDepth: 0.5, nearZ: near, farZ: far,
                                                                cosFromAxis: -1), far, accuracy: tol)
    }

    /// `hullSpan` 의 `sceneLimit` — 종전 거동 보존이 이 기능의 안전성 근거다.
    func testHullSpanSceneLimitOnlyCutsWhenGeometryIsCloser() {
        let eye = SIMD3<Float>(0, 0, 10)
        let dir = SIMD3<Float>(0, 0, -1)
        let light = SIMD3<Float>(0, 0, 0)
        guard let span = SceneWEVolumetricMath.hullSpan(eye: eye, direction: dir,
                                                       lightPosition: light, hullRadius: 4,
                                                       nearZ: 0.1, farZ: 1000) else {
            return XCTFail("헐 구간이 없다 — 픽스처가 잘못됐다")
        }
        XCTAssertEqual(span.enter, 6, accuracy: 1e-5)   // 구 교차 입구 = 10 − 4
        XCTAssertEqual(span.exit, 14, accuracy: 1e-5)   // 출구 = 10 + 4

        // ① 구간 뒤쪽의 뎁스(=지오메트리가 헐보다 멀다)는 무연산.
        let farLimit = SceneWEVolumetricMath.hullSpan(eye: eye, direction: dir, lightPosition: light,
                                                      hullRadius: 4, nearZ: 0.1, farZ: 1000,
                                                      sceneLimit: 900)
        XCTAssertEqual(farLimit?.exit ?? -1, 14, accuracy: 1e-5)
        // ② 구간 한가운데의 뎁스는 출구만 자른다(입구는 그대로).
        let midLimit = SceneWEVolumetricMath.hullSpan(eye: eye, direction: dir, lightPosition: light,
                                                      hullRadius: 4, nearZ: 0.1, farZ: 1000,
                                                      sceneLimit: 11)
        XCTAssertEqual(midLimit?.enter ?? -1, 6, accuracy: 1e-5)
        XCTAssertEqual(midLimit?.exit ?? -1, 11, accuracy: 1e-5)
        // ③ 입구보다 앞의 뎁스(라이트 전체가 벽 뒤)는 구간 소멸 → nil(픽셀 기여 0).
        XCTAssertNil(SceneWEVolumetricMath.hullSpan(eye: eye, direction: dir, lightPosition: light,
                                                    hullRadius: 4, nearZ: 0.1, farZ: 1000,
                                                    sceneLimit: 3))
    }

    /// **클리어된 뎁스(1.0)는 클립을 넣기 전과 픽셀값이 한 자리도 다르지 않다.** 골든 픽스처가
    /// 전부 "지오메트리 없음" 이라 이 성질이 곧 무회귀 보증이고, MSL 쪽도 같은 식이라
    /// (`u.marchParams.z` 게이트 뒤 `min(tExit, limit)`) 두 벌이 함께 움직인다.
    func testClearedDepthLeavesPixelValueUnchanged() {
        var input = SceneWEVolumetricMath.PixelInput(
            eye: SIMD3(0, 0, 10), forward: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
            fovYDegrees: 50, aspect: 1, nearZ: 0.1, farZ: 10000,
            lightPosition: SIMD3(0, 0, 0), lightForward: SIMD3(0, 0, 1),
            density: 3, exponent: 1, intensity: 6,
            innerCos: SceneWELightMath.coneCosine(degrees: 10),
            outerCos: SceneWELightMath.coneCosine(degrees: 30),
            radius: 20, sampleCount: 8)
        let noDepth = SceneWEVolumetricMath.pixelValue(input, x: 32, y: 32, width: 64, height: 64)
        XCTAssertGreaterThan(noDepth, 0, "대조군이 0 이면 아래 비교가 무의미하다")
        input.sceneDepth = 1
        XCTAssertEqual(SceneWEVolumetricMath.pixelValue(input, x: 32, y: 32, width: 64, height: 64),
                       noDepth, accuracy: 0, "클리어 뎁스는 무연산이어야 한다(비트 동일)")

        // 라이트 앞을 가리는 지오메트리(전방축 거리 ≈ 3 < 헐 입구 ≈ 10−19.8)는 픽셀을 어둡게 만든다.
        // ndc 는 정변환 `zz·(near−d)/d` 로 만든다(역식을 다시 적지 않는다).
        let zz = input.farZ / (input.nearZ - input.farZ)
        let occluderDistance: Float = 3
        input.sceneDepth = zz * (input.nearZ - occluderDistance) / occluderDistance
        let occluded = SceneWEVolumetricMath.pixelValue(input, x: 32, y: 32, width: 64, height: 64)
        XCTAssertLessThan(occluded, noDepth, "지오메트리에 가려진 픽셀이 더 어두워야 한다")
        XCTAssertGreaterThanOrEqual(occluded, 0)
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

    /// 미저작 라이트 필드는 별도 Waple 폴백을 발명하지 않고 WE 생성자 기본값을 그대로 쓴다.
    func testParseDefaultsMatchWEConstructor() throws {
        let json = #"{"objects":[{"id":1,"light":"lpoint","origin":"0 0 0"}]}"#
        let pkg = ScenePackage.assemble([("scene.json", Data(json.utf8))])
        let doc = try SceneDocument.parse(package: pkg)
        let light = try XCTUnwrap(doc.lights3D.first)
        XCTAssertEqual(light.color, Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(light.intensity, SceneLight3D.WEDefaults.intensity)
        XCTAssertEqual(light.radius, SceneLight3D.WEDefaults.radius)
        XCTAssertEqual(light.exponent, SceneLight3D.WEDefaults.exponent)
        XCTAssertEqual(light.innerCone, SceneLight3D.WEDefaults.innerConeDegrees)
        XCTAssertEqual(light.outerCone, SceneLight3D.WEDefaults.outerConeDegrees)
    }

    /// **[2026-08-25] 원문 리터럴과 `Float.leastNormalMagnitude` 가 비트동일임을 못박는다.**
    ///
    /// `common_pbr_2.h:266` 은 `pow(falloff + 1.17549435e-38, exponent)` 라고 적는다. 그 십진
    /// 표기는 FLT_MIN(1.17549435082…e-38)보다 아주 조금 작아서 Swift 가
    /// `underflows and loses precision` 경고를 낸다 — 그런데 **Float 로 반올림된 결과는 정확히
    /// FLT_MIN**(`0x00800000`, `isNormal == true`)이다. 즉 경고는 오탐이고 값은 같다.
    ///
    /// 그래서 소스는 `.leastNormalMagnitude` 로 적고(경고 없음) 원문 표기는 주석에 보존한다.
    /// **이 테스트가 그 교체의 유일한 근거다** — 여기가 깨지면 교체를 되돌려야 한다.
    /// GPU 쪽(MSL 문자열)은 손대지 않았다: `EngineAttenuationLaneTests` 가 원문 그대로를 단언한다.
    func testHLSLFalloffEpsilonIsBitIdenticalToFLTMIN() {
        let literal = Float(1.17549435e-38)   // 원문 표기를 Double→Float로 반올림해 비트를 직접 검증한다
        XCTAssertEqual(SceneWELightMath.hlslFalloffEpsilon.bitPattern, literal.bitPattern,
                       "엡실런이 원문 리터럴과 비트동일해야 한다")
        XCTAssertEqual(SceneWELightMath.hlslFalloffEpsilon.bitPattern, 0x0080_0000,
                       "FLT_MIN 의 비트 패턴이어야 한다")
        XCTAssertTrue(SceneWELightMath.hlslFalloffEpsilon.isNormal, "정규수여야 한다(서브노멀 아님)")

        // 소비 지점에서도 같은 값을 낸다 — 상수만 같고 쓰이는 곳이 다르면 의미가 없다.
        for exponent: Float in [0, 1, 2, 8] {
            XCTAssertEqual(powf(literal, exponent),
                           powf(SceneWELightMath.hlslFalloffEpsilon, exponent),
                           "exponent=\(exponent) 에서 결과가 갈린다")
        }

        // negative control — GLSL 레인 상수는 **달라야** 한다(둘이 같으면 레인 구분이 무의미).
        XCTAssertNotEqual(SceneWELightMath.hlslFalloffEpsilon,
                          SceneWELightMath.glslFalloffEpsilon,
                          "HLSL/GLSL 두 레인의 하한은 서로 다른 값이다")
    }
}
