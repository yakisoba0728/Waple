import XCTest
import AppKit
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

/// 3D/라이팅 씬 픽스 회귀(F660~F662 — S-46/S-47/S-45).
/// F660: 라이트 캡 4 → 8(3737268876 젤다 6슬롯: 5번째 lpoint + ldirectional 태양 드롭 해소).
/// F661: directional 단일 오소 섀도우 최소 근사(castshadow:true 3씬).
/// F662: scene fog(general.fogdistance*/fogheight*, 2씬) + 머티리얼 FOG 콤보.
final class Render3DSceneFixRegressionTests: XCTestCase {
    private func light(id: Int,
                       type: String,
                       origin: SIMD3<Float> = .zero,
                       radius: Float = 20,
                       intensity: Float = 2,
                       castsShadow: Bool = false) -> SceneLight3D {
        SceneLight3D(
            id: id, name: "light-\(id)", type: type,
            origin: Vec3(x: origin.x, y: origin.y, z: origin.z),
            angles: Vec3(x: 0, y: 0, z: 0),
            color: Vec3(x: 1, y: 1, z: 1),
            radius: radius, intensity: intensity, exponent: 2,
            castShadow: castsShadow, parent: nil)
    }

    // MARK: - F660 (S-46): 라이트 캡 상향

    /// 젤다 구성 재현: lpoint×5(마지막=Navi) + ldirectional(태양) — 구 first-4 는 후반 2개를 드롭.
    func testF660SixLightsAllResolvePastOldFourCap() {
        let lights = (0..<5).map { light(id: $0, type: "lpoint", origin: SIMD3(Float($0), 0, 0)) }
            + [light(id: 5, type: "ldirectional", origin: SIMD3(0, 1, 0), radius: 0)]
        let resolved = Scene3DLighting.resolveLights(lights, nodes: [:])
        XCTAssertEqual(resolved.count, 6)
        XCTAssertEqual(resolved[4].kind, .point)        // Navi Light(구 캡에서 드롭)
        XCTAssertEqual(resolved[5].kind, .directional)  // Main Light(태양, 구 캡에서 드롭)
        XCTAssertEqual(resolved.map { $0.position.x }, [0, 1, 2, 3, 4, 0])
    }

    /// 캡 초과분은 여전히 잘린다(9번째부터) — 무제한 확장 아님.
    func testF660NinthLightStillDrops() {
        let lights = (0..<10).map { light(id: $0, type: "lpoint", origin: SIMD3(Float($0), 0, 0)) }
        let resolved = Scene3DLighting.resolveLights(lights, nodes: [:])
        XCTAssertEqual(resolved.count, Scene3DLighting.maximumLights)
        XCTAssertEqual(Scene3DLighting.maximumLights, 8)
        let packed = Scene3DLighting.packLights(resolved)
        XCTAssertEqual(packed.count, Scene3DLighting.maximumLights)
        XCTAssertEqual(packed.map { $0.positionExponent.x }, [0, 1, 2, 3, 4, 5, 6, 7])
    }

    // MARK: - F661 (S-47): directional 섀도우 최소 근사

    /// directional castshadow:true 가 resolve 에서 보존(구 point-only 게이트는 directional 을 강제 false).
    func testF661DirectionalCastShadowSurvivesResolve() {
        let d = light(id: 1, type: "ldirectional", radius: 0, castsShadow: true)
        let resolved = Scene3DLighting.resolveLights([d], nodes: [:])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertTrue(resolved[0].castsShadow)
        // spot 은 여전히 스코프 밖(코퍼스 spot 전원 castshadow:false — 무회귀).
        let s = light(id: 2, type: "lspot", castsShadow: true)
        XCTAssertFalse(Scene3DLighting.resolveLights([s], nodes: [:])[0].castsShadow)
    }

    /// 오소 VP: 월드 AABB 8코너가 전부 NDC x/y∈[-1,1], z∈[0,1] 에 들어오고 중심은 (0,0,0.5) 부근.
    func testF661DirectionalOrthoCoversWorldBounds() throws {
        let vp = try XCTUnwrap(DirectionalShadowMath.viewProjection(
            forward: SIMD3(0, -1, 0), minBound: SIMD3(-4, -3, -2), maxBound: SIMD3(4, 1, 2)))
        let center = vp * SIMD4<Float>(0, -1, 0, 1)
        XCTAssertEqual(center.x, 0, accuracy: 1e-4)
        XCTAssertEqual(center.y, 0, accuracy: 1e-4)
        XCTAssertEqual(center.z, 0.5, accuracy: 1e-3)
        for cx in [Float(-4), 4] {
            for cy in [Float(-3), 1] {
                for cz in [Float(-2), 2] {
                    let p = vp * SIMD4(cx, cy, cz, 1)
                    XCTAssertEqual(p.w, 1, accuracy: 1e-5)
                    XCTAssertGreaterThanOrEqual(p.x, -1.0001)
                    XCTAssertLessThanOrEqual(p.x, 1.0001)
                    XCTAssertGreaterThanOrEqual(p.y, -1.0001)
                    XCTAssertLessThanOrEqual(p.y, 1.0001)
                    XCTAssertGreaterThanOrEqual(p.z, 0)
                    XCTAssertLessThanOrEqual(p.z, 1)
                }
            }
        }
    }

    /// 라이트 forward 축 정합: 광원 진행 방향(forward)으로 더 먼 점이 더 깊은(ndc.z 큰) 깊이.
    func testF661DirectionalDepthIncreasesAlongLightForward() throws {
        let forward = SIMD3<Float>(0.3, -0.9, 0.1)
        let vp = try XCTUnwrap(DirectionalShadowMath.viewProjection(
            forward: forward, minBound: SIMD3(-2, -2, -2), maxBound: SIMD3(2, 2, 2)))
        let f = simd_normalize(forward)
        let nearP = vp * SIMD4(-f, 1)   // 광원 쪽(진행 방향 반대) → 얕은 깊이
        let farP = vp * SIMD4(f, 1)     // 진행 방향 끝 → 깊은 깊이
        XCTAssertLessThan(nearP.z, farP.z)
    }

    /// 퇴화/비유한 입력은 nil — 호출부가 해당 라이트 섀도우만 끄는 폴터 경로.
    func testF661DirectionalOrthoRejectsDegenerateInput() {
        XCTAssertNil(DirectionalShadowMath.viewProjection(
            forward: .zero, minBound: SIMD3(-1, -1, -1), maxBound: SIMD3(1, 1, 1)))
        XCTAssertNil(DirectionalShadowMath.viewProjection(
            forward: SIMD3(0, -1, 0), minBound: SIMD3(1, 0, 0), maxBound: SIMD3(-1, 0, 0)))
        XCTAssertNil(DirectionalShadowMath.viewProjection(
            forward: SIMD3(0, -1, 0), minBound: SIMD3(.nan, 0, 0), maxBound: SIMD3(1, 1, 1)))
        // 단일 점 AABB(크기 0)는 여백 확장으로 유효 VP.
        XCTAssertNotNil(DirectionalShadowMath.viewProjection(
            forward: SIMD3(0, -1, 0), minBound: .zero, maxBound: .zero))
    }

    /// 셰이더 계약 잠금: directional 분기가 directionalShadowVisibility 를 곱하고 루프 상한이 8.
    func testF661F660ShaderSourceContract() {
        let source = Mesh3DShaders.source
        XCTAssertTrue(source.contains("directionalShadowVisibility"))
        XCTAssertTrue(source.contains("clamp(int(frame.meta.x + 0.5), 0, 8)"))
    }

    // MARK: - F662 (S-45): scene fog 파스 + 머티리얼 FOG 콤보

    /// 실물 3477054430: fogdistance start 6.53 / end 500 / 밀도 0→0.98 / 검정.
    /// params 매핑(WE common_fog.h 정합) = (start, end-start, startDensity, endDensity-startDensity).
    func testF662FogDistanceParsesCorpusScene3477054430() {
        let fog = Scene3DFog.parse(general: [
            "fogdistance": true,
            "fogdistancecolor": "0.00000 0.00000 0.00000",
            "fogdistanceend": 500.0,
            "fogdistanceenddensity": 0.98000002,
            "fogdistancestart": 6.5300002,
            "fogdistancestartdensity": 0.0,
        ])
        XCTAssertTrue(fog.enabled)
        XCTAssertTrue(fog.distanceEnabled)
        XCTAssertFalse(fog.heightEnabled)
        XCTAssertEqual(fog.distanceParams.x, 6.53, accuracy: 1e-4)
        XCTAssertEqual(fog.distanceParams.y, 500 - 6.53, accuracy: 1e-3)
        XCTAssertEqual(fog.distanceParams.z, 0, accuracy: 1e-6)
        XCTAssertEqual(fog.distanceParams.w, 0.98, accuracy: 1e-4)
        XCTAssertEqual(fog.distanceColor, SIMD3(0, 0, 0))
    }

    /// 실물 3706286085: {user,value} 바인딩 언랩 + distance/height 동시. end 220(유저 슬라이더 초기값).
    func testF662FogUnwrapsUserBindingsAndHeightFog() {
        let fog = Scene3DFog.parse(general: [
            "fogdistance": true,
            "fogdistancecolor": ["user": "fogcolor", "value": "0.63529 0.74510 0.75294"],
            "fogdistanceend": ["user": "fog1size", "value": 220.0],
            "fogdistanceenddensity": 0.5,
            "fogdistancestart": -5.0,
            "fogdistancestartdensity": 0.0,
            "fogheight": true,
            "fogheightcolor": ["user": "fogcolor2", "value": "0.63137 0.80392 1.00000"],
            "fogheightend": ["user": "fog", "value": 75.0],
            "fogheightenddensity": 0.60000002,
            "fogheightstart": -8.3500004,
            "fogheightstartdensity": 0.0,
        ])
        XCTAssertTrue(fog.distanceEnabled)
        XCTAssertTrue(fog.heightEnabled)
        XCTAssertEqual(fog.distanceParams.x, -5, accuracy: 1e-4)
        XCTAssertEqual(fog.distanceParams.y, 225, accuracy: 1e-3)
        XCTAssertEqual(fog.distanceColor.x, 0.63529, accuracy: 1e-4)
        XCTAssertEqual(fog.heightParams.x, -8.35, accuracy: 1e-4)
        XCTAssertEqual(fog.heightParams.y, 75 - (-8.35), accuracy: 1e-3)
        XCTAssertEqual(fog.heightParams.w, 0.6, accuracy: 1e-4)
        XCTAssertEqual(fog.heightColor.z, 1.0, accuracy: 1e-4)
    }

    /// fog 필드 부재/general 비어있음/마스터 false → 비활성(WE 와 동일: 씬 필드 없으면 FOG 콤보 무관 미적용).
    func testF662FogAbsentOrDisabledStaysOff() {
        XCTAssertFalse(Scene3DFog.parse(general: [:]).enabled)
        XCTAssertFalse(Scene3DFog.parse(general: ["fogdistance": false]).enabled)
        let heightOnly = Scene3DFog.parse(general: [
            "fogheight": true, "fogheightstart": 0.0, "fogheightend": 10.0,
        ])
        XCTAssertTrue(heightOnly.enabled)
        XCTAssertFalse(heightOnly.distanceEnabled)
        XCTAssertTrue(heightOnly.heightEnabled)
    }

    /// end==start 퇴화는 0 나눗셈 방지(최소폭 보장), 누락 필드는 WE 기본값 추정(start 0/end 1/밀도 0→1).
    func testF662FogDegenerateAndMissingFieldsAreSafe() {
        let fog = Scene3DFog.parse(general: [
            "fogdistance": true, "fogdistancestart": 5.0, "fogdistanceend": 5.0,
        ])
        XCTAssertTrue(fog.distanceEnabled)
        XCTAssertGreaterThan(fog.distanceParams.y.magnitude, 0)
        let missing = Scene3DFog.parse(general: ["fogdistance": true])
        XCTAssertEqual(missing.distanceParams.x, 0)
        XCTAssertEqual(missing.distanceParams.y, 1)
        XCTAssertEqual(missing.distanceParams.z, 0)
        XCTAssertEqual(missing.distanceParams.w, 1)
    }

    /// F745: fog 는 렌더러 정식 저장 프로퍼티(구 ObjectIdentifier 우회 저장소 F662 대체) —
    /// 인스턴스별 독립, 기본값은 비활성.
    func testF745FogIsInstanceProperty() {
        let a = SceneRenderer(), b = SceneRenderer()
        var fog = Scene3DFog()
        fog.distanceEnabled = true
        a.scene3DFog = fog
        XCTAssertTrue(a.scene3DFog.distanceEnabled)
        XCTAssertFalse(b.scene3DFog.enabled)
    }

    /// 프레임 유니폼 레이아웃: fog 4×float4 확장 후에도 Swift/MSL 정렬 일치(128B).
    func testF662FrameUniformCarriesFogFields() {
        XCTAssertEqual(MemoryLayout<Scene3DFrameUniform>.stride, 8 * MemoryLayout<SIMD4<Float>>.stride)
        var u = Scene3DFrameUniform(cameraEye: .zero, ambient: .zero, skylight: .zero, meta: .zero)
        u.fogDistanceColor = SIMD4(1, 0, 0, 1)
        u.fogHeightParams = SIMD4(-8.35, 83.35, 0, 0.6)
        XCTAssertEqual(u.fogDistanceColor.w, 1)
        XCTAssertEqual(u.fogHeightParams.y, 83.35, accuracy: 1e-4)
        // 셰이더 측 계약 잠금.
        XCTAssertTrue(Mesh3DShaders.source.contains("applySceneFog"))
        XCTAssertTrue(Mesh3DShaders.source.contains("fogDistanceParams"))
        XCTAssertTrue(Mesh3DShaders.source.contains("fogHeightParams"))
    }

    // MARK: - GPU end-to-end(합성 씬 — Scene3DPBRShadowRenderTests 하네스 동형)

    private let litMeshMaterial =
        #"{"passes":[{"textures":["white"],"constantshadervalues":{"roughness":0.7,"metallic":0}}]}"#

    private func renderScene(_ scene: String, material: String, tag: String,
                             extraFiles: [(String, Data)] = []) throws -> NSBitmapImageRep {
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(material.utf8)),
            ("materials/white.tex", solidTex(255, 255, 255, w: 2, h: 2)),
        ] + extraFiles
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_f66x_\(tag)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encodePkg(files).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
            title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0], toDir: output).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    private func blockLuminance(_ image: NSBitmapImageRep, cx: Int, cy: Int) -> Double {
        var total = 0.0, n = 0
        for dy in -1...1 {
            for dx in -1...1 {
                guard let c = image.colorAt(x: cx + dx, y: cy + dy) else { continue }
                total += c.redComponent * 0.2126 + c.greenComponent * 0.7152 + c.blueComponent * 0.0722
                n += 1
            }
        }
        return n > 0 ? total / Double(n) : 0
    }

    /// F661 e2e: directional(angles Ryπ → forward (0,0,-1), L=+Z)이 +Z 평면을 실제로 비춘다.
    /// 대조군(라이트 없음)은 ambient 0 이라 검정 — 밝아지면 directional 경로가 GPU 까지 살아있는 것.
    func testF661DirectionalLightIlluminatesPlaneEndToEnd() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func scene(withLight: Bool) -> String {
            let light = withLight ? """
            ,{"id":2,"name":"sun","light":"ldirectional","origin":"0 0 4","angles":"0 3.14159265 0",
              "color":"1 1 1","intensity":2,"castshadow":false}
            """ : ""
            return """
            {"camera":{"eye":"0 0 6","center":"0 0 0","up":"0 1 0"},
             "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,
                        "clearcolor":"0 0 0","ambientcolor":"0 0 0","skylightcolor":"0 0 0"},
             "objects":[{"id":1,"name":"receiver","model":"models/plane.mdl","origin":"0 0 0",
                          "scale":"4 4 4","castshadow":false}\(light)]}
            """
        }
        let dark = try renderScene(scene(withLight: false), material: litMeshMaterial, tag: "doff")
        let lit = try renderScene(scene(withLight: true), material: litMeshMaterial, tag: "don")
        XCTAssertLessThan(blockLuminance(dark, cx: 32, cy: 32), 0.02, "무광 대조군은 검정")
        XCTAssertGreaterThan(blockLuminance(lit, cx: 32, cy: 32), 0.2,
            "directional 한 장이 평면을 밝혀야 함 — 아니면 kind 분기/유니폼이 GPU 에 도달하지 않은 것")
    }

    /// F661 e2e: castshadow:true directional + 오큘루더 → 리시버가 어두워진다(단일 오소 섀도우 동작).
    /// 태양을 경사(angles Ry≈2.678 → forward (0.447,0,-0.894))로 두어 오큘루더(x=0)의 그림자가
    /// 리시버 x≈+1 로 어긋나게 — 침침 정면이면 그림자 영역이 오큘루더 자체에 가려 관측 불가라 경사 필수.
    /// 오큘루더 뒤(x≈1) 픽셀(화면 열 ≈43)을 비교한다.
    func testF661DirectionalShadowOccluderDarkensReceiver() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func scene(cast: Bool) -> String {
            """
            {"camera":{"eye":"0 0 6","center":"0 0 0","up":"0 1 0"},
             "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,
                        "clearcolor":"0 0 0","ambientcolor":"0.03 0.03 0.03","skylightcolor":"0.03 0.03 0.03"},
             "objects":[
               {"id":1,"name":"receiver","model":"models/plane.mdl","origin":"0 0 0","scale":"4 4 4","castshadow":false},
               {"id":2,"name":"occluder","model":"models/plane.mdl","origin":"0 0 2","scale":"0.55 0.55 0.55","castshadow":true},
               {"id":3,"name":"sun","light":"ldirectional","origin":"0 0 4","angles":"0 2.6779450 0",
                "color":"1 1 1","intensity":2,"castshadow":\(cast ? "true" : "false")}
             ]}
            """
        }
        let open = try renderScene(scene(cast: false), material: litMeshMaterial, tag: "dshadowoff")
        let shaded = try renderScene(scene(cast: true), material: litMeshMaterial, tag: "dshadowon")
        // 그림자 예상 지점: 리시버 (1,0,0) ≈ 화면 (43,32). 침침 직교(X=화면 x): NDC x=1/(6·tan25°)≈0.357.
        let openSpot = blockLuminance(open, cx: 43, cy: 32)
        let shadedSpot = blockLuminance(shaded, cx: 43, cy: 32)
        XCTAssertGreaterThan(openSpot, 0.15, "섀도우 없는 대조군의 해당 지점은 태양에 밝아야 함")
        XCTAssertLessThan(shadedSpot, openSpot - 0.05,
            "F661: castshadow directional 은 오큘루더 뒤 리시버를 어둡게 해야 함 — 같으면 오소 섀도우가 미동작")
        // 오큘루더 바깥 리시버(x≈-1, 열 ≈21)는 섀도우 유무와 무관하게 밝음(오소 상자 밖=lit 폴터 확인).
        let openFar = blockLuminance(open, cx: 21, cy: 32)
        let shadedFar = blockLuminance(shaded, cx: 21, cy: 32)
        XCTAssertEqual(shadedFar, openFar, accuracy: 0.05,
            "오큘루더와 무관한 영역은 섀도우 on/off 무관 동일해야(과도한 암화/아티팩트 없음)")
    }

    /// F662 e2e: fogdistance(start 가까움/end 짧음, 적색, 밀도→1)가 원거리 지오메트리를 fog 색으로 믹스.
    /// 침침-평면 거리 ≈6 ≫ end 3 이라 factor=1 — 평면이 적색화되면 파스→유니폼→셰이더 전 구간 동작.
    func testF662SceneFogTintsDistantGeometryEndToEnd() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func scene(fog: Bool) -> String {
            let fogFields = fog ? """
            ,"fogdistance":true,"fogdistancecolor":"1 0 0","fogdistancestart":0.1,
             "fogdistanceend":3,"fogdistancestartdensity":0,"fogdistanceenddensity":1
            """ : ""
            return """
            {"camera":{"eye":"0 0 6","center":"0 0 0","up":"0 1 0"},
             "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,
                        "clearcolor":"0 0 0","ambientcolor":"0.05 0.05 0.05","skylightcolor":"0.05 0.05 0.05"\(fogFields)},
             "objects":[
               {"id":1,"name":"receiver","model":"models/plane.mdl","origin":"0 0 0","scale":"4 4 4","castshadow":false},
               {"id":2,"name":"key","light":"lpoint","origin":"0 0 4","color":"1 1 1","intensity":2,
                "radius":10,"exponent":2,"castshadow":false}
             ]}
            """
        }
        let clear = try renderScene(scene(fog: false), material: litMeshMaterial, tag: "fogoff")
        let fogged = try renderScene(scene(fog: true), material: litMeshMaterial, tag: "fogon")
        let clearCenter = try XCTUnwrap(clear.colorAt(x: 32, y: 32))
        let fogCenter = try XCTUnwrap(fogged.colorAt(x: 32, y: 32))
        XCTAssertGreaterThan(clearCenter.redComponent, 0.2, "무-fog 대조군은 라이트에 밝음")
        XCTAssertLessThan(abs(clearCenter.redComponent - clearCenter.greenComponent), 0.05,
                          "무-fog 대조군은 무채색(백색 광/흰 자재)")
        XCTAssertGreaterThan(fogCenter.redComponent, fogCenter.greenComponent + 0.3,
            "F662: 적색 fog(밀도 1 도달)는 평면을 강하게 적색화해야 함 — 무채색 그대로면 fog 경로 미동작")
    }
}
