import XCTest
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

/// tube 라이트(kind 4) + CSM 캐스케이드 선택(WE mix 체인) + mip 샘플러 활성화(1단계) 회귀.
///
/// 근거(WE 2.8.42 정본):
/// - tube: common_pbr.h:9-16 PointSegmentDelta + genericimage3.frag:115/157 · generic3.frag:110/152
///   (lightDelta=PointSegmentDelta) + A2-pbr-lighting.md §4.4/§4.5(OriginA.w=exponent, Color.w=radius,
///   shadowFactor=1.0 무섀도우).
/// - CSM: common_pbr_2.h:131-147 CalculateProjectedCoordsCascades + A2-pbr-lighting.md §4.4 mix 체인
///   (캐스케이드 투영 박스 포함 검사 — 사실상 뷰 z(far 평면) 선택).
/// - mip: mipmapLevelCount==1 텍스처에서 mip_filter::linear 는 LOD 클램프로 none 과 비트동일(렌더 A/B 입증).
final class TubeLightCSMandMipTests: XCTestCase {

    // MARK: - tube CPU 오라클: 세그먼트 최근접점

    func testPointSegmentDeltaMatchesWEFormula() {
        // common_pbr.h:9-16: saturate(dot(pos-A, B-A)/v) 로 클램프된 최근접점 - pos.
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(10, 0, 0)
        // 세그먼트 낙사 구간: closest=(4,0,0).
        XCTAssertEqual(ScenePBRMath.pointSegmentDelta(SIMD3(4, 3, 0), a, b), SIMD3(0, -3, 0))
        // A 밖: t<0 클램프 → A - pos.
        XCTAssertEqual(ScenePBRMath.pointSegmentDelta(SIMD3(-2, 1, 0), a, b), SIMD3(2, -1, 0))
        // B 밖: t>1 클램프 → B - pos.
        XCTAssertEqual(ScenePBRMath.pointSegmentDelta(SIMD3(12, 2, 0), a, b), SIMD3(-2, -2, 0))
        // 퇴화(A==B, v==0): A - pos — point 라이트와 동치.
        XCTAssertEqual(ScenePBRMath.pointSegmentDelta(SIMD3(1, 2, 0), a, a), SIMD3(-1, -2, 0))
    }

    func testTubeContributionEqualsPointAtClosestSegmentPoint() {
        // 수학 항등: tube 기여 == 최근접점에 둔 point 기여(같은 BRDF 코어로 흐르는지 고정).
        let world = SIMD3<Float>(50, 5, 5)
        let a = SIMD3<Float>(0, 0, 10), b = SIMD3<Float>(100, 0, 10)
        let closest = SIMD3<Float>(50, 0, 10)   // a + 0.5*(b-a) — float 정확
        let tube = ScenePBRMath.tubeContribution(
            world: world, segmentA: a, segmentB: b, lightColor: SIMD3(1, 1, 1),
            radius: 100, exponent: 2, normal: SIMD3(0, 0, 1), view: SIMD3(0, 0, 1),
            albedo: SIMD3(1, 1, 1), roughness: 0.7, metallic: 0, specularTint: SIMD3(1, 1, 1))
        let pointAtClosest = ScenePBRMath.pointContribution(
            world: world, lightPosition: closest, lightColor: SIMD3(1, 1, 1),
            radius: 100, exponent: 2, normal: SIMD3(0, 0, 1), view: SIMD3(0, 0, 1),
            albedo: SIMD3(1, 1, 1), roughness: 0.7, metallic: 0, specularTint: SIMD3(1, 1, 1))
        XCTAssertEqual(tube, pointAtClosest)
    }

    func testTubeAttenuationUsesSegmentDistanceNotEndpoint() {
        // 세그먼트 중간 가까이(거리 √50≈7.07) vs 단점 A 까지(√2550≈50.5): pow 감쇠상 tube 가 유리.
        let world = SIMD3<Float>(50, 5, 5)
        let a = SIMD3<Float>(0, 0, 10), b = SIMD3<Float>(100, 0, 10)
        let tube = ScenePBRMath.tubeContribution(
            world: world, segmentA: a, segmentB: b, lightColor: SIMD3(1, 1, 1),
            radius: 100, exponent: 2, normal: SIMD3(0, 0, 1), view: SIMD3(0, 0, 1),
            albedo: SIMD3(1, 1, 1), roughness: 0.7, metallic: 0, specularTint: SIMD3(1, 1, 1))
        let pointAtA = ScenePBRMath.pointContribution(
            world: world, lightPosition: a, lightColor: SIMD3(1, 1, 1),
            radius: 100, exponent: 2, normal: SIMD3(0, 0, 1), view: SIMD3(0, 0, 1),
            albedo: SIMD3(1, 1, 1), roughness: 0.7, metallic: 0, specularTint: SIMD3(1, 1, 1))
        XCTAssertGreaterThan(tube.x, pointAtA.x,
                             "tube 감쇠는 세그먼트 최근접 거리 기준 — 단점 A point 보다 중간부가 밝아야")
        XCTAssertGreaterThan(tube.x, 0)
    }

    func testDegenerateTubeMatchesPointLightExactly() {
        // originb 미저작(A==B) 퇴화는 동일 위치 point 와 비트 동일(WE v==0 분기).
        let world = SIMD3<Float>(3, -4, 2)
        let a = SIMD3<Float>(10, 20, 30)
        let tube = ScenePBRMath.tubeContribution(
            world: world, segmentA: a, segmentB: a, lightColor: SIMD3(0.8, 0.6, 0.4),
            radius: 50, exponent: 3, normal: SIMD3(0, 0, 1), view: SIMD3(0, 0, 1),
            albedo: SIMD3(0.9, 0.9, 0.9), roughness: 0.4, metallic: 0.2, specularTint: SIMD3(1, 1, 1))
        let point = ScenePBRMath.pointContribution(
            world: world, lightPosition: a, lightColor: SIMD3(0.8, 0.6, 0.4),
            radius: 50, exponent: 3, normal: SIMD3(0, 0, 1), view: SIMD3(0, 0, 1),
            albedo: SIMD3(0.9, 0.9, 0.9), roughness: 0.4, metallic: 0.2, specularTint: SIMD3(1, 1, 1))
        XCTAssertEqual(tube, point)
    }

    // MARK: - 2D: tube 가 point 로 폴터되지 않음

    private func tubeLight(origin: Vec3 = Vec3(x: 10, y: 20, z: 30),
                           originB: Vec3? = Vec3(x: 110, y: 20, z: 30)) -> SceneLight3D {
        SceneLight3D(id: 1, name: "tube", type: "ltube", origin: origin,
                     angles: Vec3(x: 0, y: 0, z: 0), color: Vec3(x: 1, y: 0.5, z: 0.25),
                     radius: 300, intensity: 2, exponent: 2,
                     castShadow: false, parent: nil, originB: originB)
    }

    func testForwardUniformsPacksTubeKindAndSegmentB() {
        let u = SceneLight3D.forwardUniforms([tubeLight()], ambient: Vec3(x: 0, y: 0, z: 0),
                                             skylight: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(u.kindCone[0].x, 4, accuracy: 1e-6, "tube 는 kind 4 — point(0) 폴터 제거")
        // positions.w=exponent / colorRadius.w=radius 패킹은 point 와 동형(A2 §4.5).
        XCTAssertEqual(u.positions[0], SIMD4<Float>(10, 20, 30, 2))
        XCTAssertEqual(u.colorRadius[0], SIMD4<Float>(2, 1, 0.5, 300))
        // axisCone 슬롯 = 세그먼트 단점 B(forward 아님).
        XCTAssertEqual(u.axisCone[0], SIMD4<Float>(110, 20, 30, 0))
    }

    func testForwardUniformsTubeWithoutOriginBPacksDegenerateSegment() {
        let u = SceneLight3D.forwardUniforms([tubeLight(originB: nil)], ambient: Vec3(x: 0, y: 0, z: 0),
                                             skylight: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(u.kindCone[0].x, 4, accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[0], SIMD4<Float>(10, 20, 30, 0), "A==B 퇴화 — 셰이더 point 동치 경로")
    }

    func testEvaluateLightingRoutesTubeKindToSegmentPath() {
        let uniforms = SceneLight3D.forwardUniforms([tubeLight()], ambient: Vec3(x: 0, y: 0, z: 0),
                                                    skylight: Vec3(x: 0, y: 0, z: 0))
        // 세그먼트 중간 위(x=60, A/B 중점) 정면(z=0, 라이트 z=30 앞)에서 평가 — point-at-A 와 달라야 한다.
        let world = SIMD3<Float>(60, 20, 0)
        let lit = SceneLight3D.evaluateLighting(at: world, uniforms)
        let expected = ScenePBRMath.tubeContribution(
            world: world, segmentA: SIMD3(10, 20, 30), segmentB: SIMD3(110, 20, 30),
            lightColor: SIMD3(2, 1, 0.5), radius: 300, exponent: 2,
            normal: SIMD3(0, 0, 1), view: SIMD3(0, 0, 1),
            albedo: SIMD3(1, 1, 1), roughness: 0.7, metallic: 0, specularTint: SIMD3(1, 1, 1))
        XCTAssertEqual(lit, expected)
        // 같은 유니폼을 point(kind 0)로 평가하면(=종전 오분류 폴터) 다른 값 — 폴터 제거의 실질 증거.
        var asPoint = uniforms
        asPoint.kindCone[0] = .zero
        let litAsPoint = SceneLight3D.evaluateLighting(at: world, asPoint)
        XCTAssertNotEqual(lit, litAsPoint)
        XCTAssertGreaterThan(lit.x, litAsPoint.x)
    }

    func testParseOriginBSurvivesIntoForwardPack() throws {
        let scene = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[
           {"id":1,"light":"ltube","origin":"10 20 30","originb":"110 20 30",
            "color":"1 0.5 0.25","intensity":2,"radius":300,"exponent":2}
         ]}
        """
        let pkg = ScenePackage.assemble([("scene.json", scene.data(using: .utf8)!)])
        let doc = try SceneDocument.parse(package: pkg)
        let light = try XCTUnwrap(doc.lights3D.first)
        XCTAssertEqual(light.originB, Vec3(x: 110, y: 20, z: 30), "scene.json originb 파스")
        let u = SceneLight3D.forwardUniforms(doc.lights3D, ambient: Vec3(x: 0, y: 0, z: 0),
                                             skylight: Vec3(x: 0, y: 0, z: 0))
        XCTAssertEqual(u.kindCone[0].x, 4, accuracy: 1e-6)
        XCTAssertEqual(u.axisCone[0], SIMD4<Float>(110, 20, 30, 0))
    }

    // MARK: - 3D: resolve / pack

    func testScene3DTubeResolvesSegmentBInParentSpace() {
        // 부모(1000,0,0) 아래 tube: A=(1,2,3), B=(4,2,3) → 월드 (1001,2,3)/(1004,2,3).
        // 라이트 자체 회전(Ry 90°)은 forward 만 바꾸고 B 는 부모 공간 그대로여야(A/B 동일 공간 규약).
        let light = SceneLight3D(
            id: 2, name: "tube", type: "ltube", origin: Vec3(x: 1, y: 2, z: 3),
            angles: Vec3(x: 0, y: Float.pi / 2, z: 0), color: Vec3(x: 1, y: 1, z: 1),
            radius: 50, intensity: 1, exponent: 2,
            castShadow: true,   // WE: tube 무섀도우 — 캐스터여도 드롭되어야
            parent: 7, originB: Vec3(x: 4, y: 2, z: 3))
        let nodes: [Int: Scene3DMath.Node] = [
            7: Scene3DMath.Node(origin: SIMD3(1000, 0, 0), angles: .zero,
                                scale: SIMD3(1, 1, 1), parent: nil, visible: true),
        ]
        let resolved = Scene3DLighting.resolveLights([light], nodes: nodes)
        XCTAssertEqual(resolved.count, 1, "tube 는 nil 드롭되지 않고 해석되어야")
        XCTAssertEqual(resolved[0].kind, .tube)
        XCTAssertEqual(resolved[0].position, SIMD3(1001, 2, 3))
        XCTAssertEqual(resolved[0].originB, SIMD3(1004, 2, 3),
                       "originb 는 부모 체인으로만 월드화(라이트 자체 회전 미적용)")
        XCTAssertFalse(resolved[0].castsShadow, "tube 무섀도우(WE 정본 shadowFactor=1.0)")

        let packed = Scene3DLighting.packLights(resolved)
        XCTAssertEqual(packed[0].shadow.z, 4, accuracy: 1e-6, "MSL kind 플래그 4")
        XCTAssertEqual(packed[0].shadow.x, -1, accuracy: 1e-6, "섀도우 슬라이스 미할당")
        XCTAssertEqual(packed[0].axis, SIMD4<Float>(1004, 2, 3, 0), "axis 슬롯 = 단점 B")
        XCTAssertEqual(packed[0].positionExponent, SIMD4<Float>(1001, 2, 3, 2),
                       "OriginA.w=exponent 패킹(A2 §4.5)")
        XCTAssertEqual(packed[0].cascades, .zero)
    }

    func testScene3DTubeWithoutOriginBDegeneratesToPoint() {
        let light = SceneLight3D(
            id: 2, name: "tube", type: "ltube", origin: Vec3(x: 5, y: 6, z: 7),
            angles: Vec3(x: 0, y: 0, z: 0), color: Vec3(x: 1, y: 1, z: 1),
            radius: 50, intensity: 1, exponent: 1, castShadow: false, parent: nil)
        let resolved = Scene3DLighting.resolveLights([light], nodes: [:])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].originB, SIMD3(5, 6, 7), "originb 부재 = A==B 퇴화(드롭 아님)")
    }

    func testNonTubeKindsKeepAxisAndShadowPackingBitIdentical() {
        // 무회귀: 기존 3종은 axis=forward/cone, shadow.z=0/1/2 그대로.
        func light(_ type: String, cone: Bool = false) -> SceneLight3D {
            SceneLight3D(id: 1, name: "", type: type, origin: Vec3(x: 0, y: 0, z: 5),
                         angles: Vec3(x: 0, y: 0, z: 0), color: Vec3(x: 1, y: 1, z: 1),
                         radius: 20, intensity: 1, exponent: 1,
                         innerCone: cone ? 30 : 0, outerCone: cone ? 60 : 0,
                         castShadow: false, parent: nil)
        }
        let packed = Scene3DLighting.packLights(Scene3DLighting.resolveLights(
            [light("lpoint"), light("ldirectional"), light("lspot", cone: true)], nodes: [:]))
        XCTAssertEqual(packed[0].shadow.z, 0); XCTAssertEqual(packed[0].axis, SIMD4<Float>(0, 0, 1, 0))
        XCTAssertEqual(packed[1].shadow.z, 1); XCTAssertEqual(packed[1].axis, SIMD4<Float>(0, 0, 1, 0))
        XCTAssertEqual(packed[2].shadow.z, 2)
        XCTAssertEqual(packed[2].axis.z, 1, accuracy: 1e-6)
        XCTAssertGreaterThan(packed[2].axis.w, -1, "spot axis.w = cone outer cos(채워짐)")
    }

    // MARK: - MSL 소스 단언 + Metal 컴파일

    func testMeshShaderCarriesTubePathAndCompiles() throws {
        let source = Mesh3DShaders.source
        XCTAssertTrue(source.contains("inline float3 pointSegmentDelta"))
        XCTAssertTrue(source.contains("inline float3 tubePBR"))
        // 4개 프래그먼트(mf_main/mf_normal/mf_refract/mf_reflect) 전부 tube 분기 보유.
        XCTAssertEqual(source.components(separatedBy: "tubePBR(in.worldPos").count - 1, 4)
        XCTAssertTrue(source.contains("kind < 2.5"), "spot 경계 명시화 — kind 4 와 분리")
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let lib = try device.makeLibrary(source: source, options: nil)
        for fn in ["mf_main", "mf_normal", "mf_refract", "mf_reflect"] {
            XCTAssertNotNil(lib.makeFunction(name: fn), "\(fn) 링크(tubePBR 포함 컴파일)")
        }
    }

    func testQuadShaderCarriesTubePathAndCompiles() throws {
        let source = QuadShaders.source
        XCTAssertTrue(source.contains("kind == 4"), "f_lit tube 분기")
        XCTAssertTrue(source.contains("clamp(dot(world - a, ab) / vv, 0.0, 1.0)"),
                      "PointSegmentDelta 클램프 수식(common_pbr.h:15)")
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let lib = try device.makeLibrary(source: source, options: nil)
        XCTAssertNotNil(lib.makeFunction(name: "f_lit"))
        // nearest 변형도 동일 규약으로 치환되어 컴파일되어야(치환 문자열 동기 회귀 가드).
        XCTAssertNotEqual(QuadShaders.nearestSource, source)
        XCTAssertTrue(QuadShaders.nearestSource.contains(
            "constexpr sampler s(filter::nearest, mip_filter::linear, address::clamp_to_edge);"))
        _ = try device.makeLibrary(source: QuadShaders.nearestSource, options: nil)
    }

    // MARK: - CSM 캐스케이드 선택(view-z 등가 mix 체인)

    func testCSMSelectionIsProjectionBoundsMixChainNotRadialDistance() {
        let source = Mesh3DShaders.source
        // WE CalculateProjectedCoordsCascades(common_pbr_2.h:131-147): 0.99 NDC 박스 + mix 체인.
        // 캐스케이드 xy 피팅이 카메라 프러스텀 슬라이스라 이 선택은 사실상 뷰 z(far 평면) 기준.
        XCTAssertTrue(source.contains("step(0.99, max(abs(ndc0.x)"))
        XCTAssertTrue(source.contains("mix(mix(0.0, 1.0, out0), 2.0, out1)"))
        XCTAssertTrue(source.contains("mix(mix(ndc0, ndc1, out0), ndc2, out1)"))
        XCTAssertFalse(source.contains("distance(frame.cameraEye.xyz, worldPos)"),
                       "종전 radial 거리 선택은 제거(fog 의 viewDist 와 무관)")
    }

    // MARK: - mip 샘플러 활성화

    /// 소스의 `constexpr sampler <이름>(<인자>);` 선언 전수 — 이름 → 인자 문자열.
    /// (인자에 중첩 괄호가 없는 형태만 쓰인다 — 선언부 전수 확인됨.)
    /// MSL 소스에서 주석(`/* */` 블록 · `//` 줄)을 지운다.
    ///
    /// 리터럴 검사의 대상은 셰이더 **코드**지 설명이 아니다. 실제로 이 결함(fbSampler 가
    /// mip_filter 를 생략해 MSL 기본값 none 을 먹던 것)을 설명하는 주석이 Mesh3DShaders 에
    /// 들어가자, `source.contains("mip_filter::none")` 단언이 그 산문에 걸려 깨졌다(2026-08-19 CI).
    private func strippingComments(_ source: String) -> String {
        var noBlock = ""
        var first = true
        for part in source.components(separatedBy: "/*") {
            if first { noBlock += part; first = false; continue }
            if let end = part.range(of: "*/") { noBlock += part[end.upperBound...] }
        }
        return noBlock.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                if let slashes = line.range(of: "//") { return line[..<slashes.lowerBound] }
                return line
            }
            .joined(separator: "\n")
    }

    private func samplerDeclarations(_ source: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in source.components(separatedBy: "constexpr sampler ").dropFirst() {
            guard let open = raw.firstIndex(of: "("), let close = raw.firstIndex(of: ")"), open < close else { continue }
            let name = raw[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            out[name] = String(raw[raw.index(after: open)..<close])
        }
        return out
    }

    /// `.sample(<샘플러>, …, level(…))` — **명시 LOD** 로 샘플되는 샘플러 이름 전수(괄호 균형 파스).
    private func samplersUsedWithExplicitLOD(_ source: String) -> Set<String> {
        var out = Set<String>()
        for raw in source.components(separatedBy: ".sample(").dropFirst() {
            var depth = 1
            var call = ""
            for ch in raw {
                if ch == "(" { depth += 1 }
                if ch == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                call.append(ch)
            }
            guard depth == 0, call.contains("level(") else { continue }
            let name = (call.components(separatedBy: ",").first ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { out.insert(name) }
        }
        return out
    }

    func testAllTargetSamplersEnableLinearMip() {
        XCTAssertEqual(QuadShaders.source.components(
            separatedBy: "constexpr sampler s(filter::linear, mip_filter::linear,").count - 1, 6,
            "QuadShaders 6곳(f_main/f_main_premul/f_compose/f_blend/f_refract/f_lit)")
        XCTAssertEqual(Mesh3DShaders.source.components(
            separatedBy: "constexpr sampler s(filter::linear, mip_filter::linear,").count - 1, 5,
            "Mesh3DShaders 5곳(sf_cutout/mf_main/mf_normal/mf_refract/mf_reflect)")
        XCTAssertEqual(ParticleShaders.source.components(
            separatedBy: "constexpr sampler s(filter::linear, mip_filter::linear,").count - 1, 3,
            "ParticleShaders 3곳(pf_main/pf3d_fog/pf_refract)")
        // 주석을 걷어내고 본다 — 위 strippingComments 주석 참조.
        XCTAssertFalse(strippingComments(Mesh3DShaders.source).contains("mip_filter::none"))
        XCTAssertFalse(strippingComments(QuadShaders.source).contains("mip_filter::none"))
        XCTAssertFalse(strippingComments(ParticleShaders.source).contains("mip_filter::none"))

        // [정정 2026-08-19] 위 두 종류 단언은 **이름이 `s` 인 샘플러 하나**만 리터럴로 셌고, 없는 토큰
        // (`mip_filter::none`)의 부재를 확인했다. mf_reflect 의 `fbSampler` 는 식별자가 다르고
        // mip_filter 를 **아예 적지 않았을** 뿐이라(MSL 기본값이 none) 두 단언을 모두 통과하면서
        // `level(reflectLod)` 를 무시하고 있었다 — 결함이 살아 있는 동안 이 테스트는 계속 초록이었다.
        // 아래는 하드코딩된 이름이 아니라 **명시 LOD 로 샘플되는 모든 샘플러**를 소스에서 찾아 검사한다.
        var checked = 0
        for (label, source) in [("QuadShaders", QuadShaders.source),
                                ("QuadShaders.nearest", QuadShaders.nearestSource),
                                ("Mesh3DShaders", Mesh3DShaders.source),
                                ("ParticleShaders", ParticleShaders.source)] {
            let decls = samplerDeclarations(source)
            for name in samplersUsedWithExplicitLOD(source).sorted() {
                guard let decl = decls[name] else {
                    XCTFail("\(label): level() 로 샘플되는 \(name) 의 constexpr sampler 선언을 못 찾았다")
                    continue
                }
                XCTAssertTrue(decl.contains("mip_filter::linear"),
                              "\(label): \(name) 은 level(...) 로 샘플되는데 mip_filter 가 없다 — "
                              + "MSL 기본 mip_filter::none 이면 명시 LOD 가 통째로 무시된다(선언: \(decl))")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0, "level() 샘플이 하나도 안 잡히면 이 오라클은 죽은 것이다")
    }

    func testTranslatedShaderSamplersEnableLinearMip() throws {
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            vec4 a = texSample2D(g_Texture0, v_TexCoord);
            vec4 b = texSample2DLod(g_Texture0, v_TexCoord, 0.5);
            gl_FragColor = a + b;
        }
        """
        let t = try XCTUnwrap(GLSLTranslator.translate(vertex: vert, fragment: frag, combos: [:]))
        XCTAssertTrue(t.msl.contains("constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);"), t.msl)
        XCTAssertTrue(t.msl.contains("constexpr sampler smpRepeat(filter::linear, mip_filter::linear, address::repeat);"), t.msl)
        XCTAssertTrue(t.msl.contains("constexpr sampler smpNearest(filter::nearest, mip_filter::linear, address::clamp_to_edge);"), t.msl)
        XCTAssertTrue(t.msl.contains("constexpr sampler smpRepeatNearest(filter::nearest, mip_filter::linear, address::repeat);"), t.msl)
        // sample() 암시 LOD 와 level() 명시 LOD 가 공존 — level() 번역 형태는 그대로(구조적 무영향).
        XCTAssertTrue(t.msl.contains("level(0.5)"), t.msl)
    }

    /// mip_filter::none vs linear — **mipmapLevelCount==1** 텍스처를 축소 샘플(암시 LOD>0 유도)한 뒤
    /// 두 변형의 렌더가 비트동일해야 한다(LOD 클램프 — mip 활성화의 무회귀 증명).
    func testLinearMipOnSingleLevelTextureIsBitIdentical() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        // 8×8 비균일 패턴(필터링 식별 가능) 단일 레벨 텍스처.
        var src = [UInt8](repeating: 0, count: 8 * 8 * 4)
        for i in 0..<(8 * 8) {
            src[i * 4 + 0] = UInt8((i * 37) & 0xff)
            src[i * 4 + 1] = UInt8((i * 91) & 0xff)
            src[i * 4 + 2] = UInt8((i * 53) & 0xff)
            src[i * 4 + 3] = 255
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: 8, height: 8, mipmapped: false)
        td.usage = [.shaderRead]; td.storageMode = .shared
        let tex = try XCTUnwrap(device.makeTexture(descriptor: td))
        XCTAssertEqual(tex.mipmapLevelCount, 1, "전제: 단일 레벨")
        tex.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: src, bytesPerRow: 32)

        func render(_ mipFilter: String) throws -> [UInt8] {
            let sh = """
            #include <metal_stdlib>
            using namespace metal;
            struct VO { float4 pos [[position]]; float2 uv; };
            vertex VO v(uint i [[vertex_id]]) {
              float2 p[6] = {{-1,-1},{1,-1},{-1,1},{1,-1},{1,1},{-1,1}};
              float2 u[6] = {{0,1},{1,1},{0,0},{1,1},{1,0},{0,0}};
              VO o; o.pos = float4(p[i],0,1); o.uv = u[i]; return o;
            }
            fragment float4 f(VO i [[stage_in]], texture2d<float> t [[texture(0)]]) {
              // 4×4 타깃에 8×8 텍스처 전체 UV → 축소(암시 LOD≈1) — mip 있으면 level 1 이 섞일 조건.
              constexpr sampler s(filter::linear, mip_filter::\(mipFilter), address::clamp_to_edge);
              return t.sample(s, i.uv);
            }
            """
            let lib = try device.makeLibrary(source: sh, options: nil)
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = lib.makeFunction(name: "v")
            pd.fragmentFunction = lib.makeFunction(name: "f")
            pd.colorAttachments[0].pixelFormat = .rgba8Unorm
            let pipe = try device.makeRenderPipelineState(descriptor: pd)
            let rtDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: 4, height: 4, mipmapped: false)
            rtDesc.usage = [.renderTarget, .shaderRead]; rtDesc.storageMode = .shared
            let rt = try XCTUnwrap(device.makeTexture(descriptor: rtDesc))
            let q = try XCTUnwrap(device.makeCommandQueue())
            let cb = try XCTUnwrap(q.makeCommandBuffer())
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = rt
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].storeAction = .store
            let enc = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: rp))
            enc.setRenderPipelineState(pipe)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
            var px = [UInt8](repeating: 0, count: 4 * 4 * 4)
            rt.getBytes(&px, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
            return px
        }

        let none = try render("none")
        let linear = try render("linear")
        XCTAssertEqual(none, linear,
                       "mipmapLevelCount==1 에서 mip_filter::linear 는 LOD 클램프로 none 과 비트동일이어야")
        XCTAssertFalse(Set(none).isSubset(of: [0, 255]), "렌더가 실제 필터링됐는지(무의미한 상수 프레임 방지)")
    }
}
