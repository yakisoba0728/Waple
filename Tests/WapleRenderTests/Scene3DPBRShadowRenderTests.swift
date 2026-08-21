import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

final class Scene3DPBRShadowRenderTests: XCTestCase {
    private func planeModel() -> Data {
        var data = Data("MDLV0023".utf8)
        data.append(0)
        func u32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func f32(_ value: Float) {
            var little = value
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        u32(0x0000000f); u32(1); u32(1)
        data.append(Data("materials/plane.json".utf8)); data.append(0)
        u32(0)
        f32(-1); f32(-1); f32(0); f32(1); f32(1); f32(0)
        u32(0x0000000f)
        let vertices: [(Float, Float, Float, Float)] = [
            (-1, -1, 0, 1), (1, -1, 1, 1), (1, 1, 1, 0), (-1, 1, 0, 0),
        ]
        u32(UInt32(vertices.count * 48))
        for (x, y, u, v) in vertices {
            // pos3, normal3(+Z), tangent4, uv2
            [x, y, 0, 0, 0, 1, 1, 0, 0, -1, u, v].forEach(f32)
        }
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        u32(UInt32(indices.count * MemoryLayout<UInt16>.stride))
        for index in indices {
            var little = index.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func capture(lightCastsShadow: Bool, tag: String,
                         roughness: Float = 0.7, metallic: Float = 0) throws -> NSBitmapImageRep {
        let scene = """
        {"camera":{"eye":"3 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,
                    "clearcolor":"0 0 0","ambientcolor":"0.04 0.04 0.04","skylightcolor":"0.04 0.04 0.04"},
         "objects":[
           {"id":1,"name":"receiver","model":"models/plane.mdl","origin":"0 0 0","scale":"2.5 2.5 2.5","castshadow":false},
           {"id":2,"name":"occluder","model":"models/plane.mdl","origin":"0 0 2","scale":"0.55 0.55 0.55","castshadow":true},
           {"id":3,"name":"key","light":"lpoint","origin":"0 0 4","color":"1 1 1","intensity":2,
            "radius":10,"exponent":2,"castshadow":\(lightCastsShadow ? "true" : "false")}
         ]}
        """
        let material = """
        {"passes":[{"textures":["white"],"constantshadervalues":{
          "roughness":\(roughness),"metallic":\(metallic)}}]}
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(material.utf8)),
            ("materials/white.tex", solidTex(255, 255, 255, w: 2, h: 2)),
        ]
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_p4_\(tag)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encodePkg(files).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "p4_\(tag)", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: "p4", tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0], toDir: output).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    private func averageLuminance(_ image: NSBitmapImageRep) -> Double {
        var total = 0.0
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: x, y: y) else { continue }
                total += color.redComponent * 0.2126
                    + color.greenComponent * 0.7152
                    + color.blueComponent * 0.0722
            }
        }
        return total / Double(image.pixelsWide * image.pixelsHigh)
    }

    private func renderScene(_ scene: String, material: String, tag: String,
                             extraFiles: [(String, Data)] = []) throws -> NSBitmapImageRep {
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/plane.mdl", planeModel()),
            ("materials/plane.json", Data(material.utf8)),
            ("materials/white.tex", solidTex(255, 255, 255, w: 2, h: 2)),
        ] + extraFiles
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_\(tag)_\(UUID().uuidString)", isDirectory: true)
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

    func testUnlitMeshKeepsAlbedoBrightnessWithoutLights() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // ambient/skylight=0 + 라이트 없음. lit(LIGHTING=1) 메시는 검정, unlit(LIGHTING=0)은 흰 albedo 유지.
        // 수정 전(SceneRenderer3D:824 mode.w=1 하드코딩)엔 둘 다 검정 → unlit center≈0 으로 이 테스트가 실패(824 회귀 가드).
        let scene = """
        {"camera":{"eye":"3 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,
                    "clearcolor":"0 0 0","ambientcolor":"0 0 0","skylightcolor":"0 0 0"},
         "objects":[{"id":1,"name":"quad","model":"models/plane.mdl","origin":"0 0 0","scale":"2.5 2.5 2.5","castshadow":false}]}
        """
        func centerRed(lighting: Int, tag: String) throws -> CGFloat {
            let mat = #"{"passes":[{"textures":["white"],"combos":{"LIGHTING":\#(lighting)}}]}"#
            let img = try renderScene(scene, material: mat, tag: tag)
            return try XCTUnwrap(img.colorAt(x: 32, y: 32)).redComponent
        }
        XCTAssertGreaterThan(try centerRed(lighting: 0, tag: "unlit"), 0.9,
                             "combos.LIGHTING=0 메시는 라이트 없이도 albedo 풀브라이트여야 함")
        XCTAssertLessThan(try centerRed(lighting: 1, tag: "lit"), 0.1,
                          "LIGHTING=1 대조군은 ambient 0·무광에서 검정이어야 함")
    }

    func testPointShadowOccluderDarkensReceiver() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let unshadowed = averageLuminance(try capture(lightCastsShadow: false, tag: "off"))
        let shadowed = averageLuminance(try capture(lightCastsShadow: true, tag: "on"))
        XCTAssertGreaterThan(unshadowed, 0.02, "test scene must be visibly lit")
        XCTAssertLessThan(shadowed, unshadowed - 0.01,
                          "a casting point light must darken the receiver behind the occluder")
    }

    // spot 콘 축이 평면 중앙을 향하는 합성 씬. 카메라 정면(+Z), 평면 scale 4로 프레임 전체를 채워
    // 모든 픽셀이 평면 위에 있음(콘 밖 어두운 픽셀이 배경 검정과 혼동되지 않도록). ambient=skylight=0.03
    // 균일 플로어로 지오메트리 존재를 증명. 광원 forward=(0,0,-1)(Ry 180°) → 평면 중앙(0,0,0) 조준.
    private func spotScene(inner: Float, outer: Float) -> String {
        """
        {"camera":{"eye":"0 0 6","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,
                    "clearcolor":"0 0 0","ambientcolor":"0.03 0.03 0.03","skylightcolor":"0.03 0.03 0.03"},
         "objects":[
           {"id":1,"name":"receiver","model":"models/plane.mdl","origin":"0 0 0","scale":"4 4 4","castshadow":false},
           {"id":2,"name":"spot","light":"lspot","origin":"0 0 4","angles":"0 3.14159265 0",
            "color":"1 1 1","intensity":3,"radius":20,"exponent":2,
            "innercone":\(inner),"outercone":\(outer),"castshadow":false}
         ]}
        """
    }

    private let litMeshMaterial =
        #"{"passes":[{"textures":["white"],"constantshadervalues":{"roughness":0.7,"metallic":0}}]}"#

    // 3×3 블록 평균 luminance(8bit 양자화·에일리어싱 완화). 중심행 기준 반경(열) 샘플.
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

    // WE 콘 시맨틱은 2026-08-21 에 **반각(도)** 으로 확정됐다 — V1 유니폼 패커가 `cos(도 * π/180)` 을
    // 그대로 싣는다(wallpaper64.exe 0x140192e64–0x140192e86 / 0x140192eaa–0x140192ebf,
    // deg2rad 0x140492628). Scene3DLighting.spotConeCosines 의 `* 0.5` 를 제거했다.
    // 이 테스트들은 여전히 판정이 아니라 **현행 구현을 GPU 픽셀로 잠그는 회귀 가드**다:
    //   ① spotPBR 경로가 실제 실행되고(콘 안=밝음), ② 셰이더 콘 수학이 CPU 유닛(spotConeCosines)과
    //   일치하게 동작(단조 falloff, 콘 밖=0)함을 증명.
    func testSpotConeGatesIlluminationAndFallsOffMonotonically() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // innercone=10/outercone=25(**반각** 도). 중심행을 중심(축상)→콘 밖으로 스캔.
        // 반각 확정 전 이 픽스처는 20/50 이었고 `* 0.5` 를 거쳐 같은 10°/25° 콘이 됐다 —
        // 저작값을 절반으로 바꿔 **렌더 결과를 비트동일로 보존**한 것이라 아래 실측 수치는 그대로다.
        let image = try renderScene(spotScene(inner: 10, outer: 25), material: litMeshMaterial, tag: "spotcone")
        // 열 32(축)→56(콘 밖). 실측: 0.643 · 0.583 · 0.390 · 0.125 · 0.031. 인접 gap ≥ 0.06.
        let profile = [32, 42, 46, 50, 56].map { blockLuminance(image, cx: $0, cy: 32) }
        // ① inner 안(축 교점)은 밝음 = spotPBR 경로가 GPU에서 실제 실행.
        XCTAssertGreaterThan(profile.first!, 0.4,
            "축상 픽셀은 콘 완전조명이어야(spotPBR 경로 미실행이면 ambient 플로어로 떨어짐)")
        // ② outer 밖은 어두움 = 콘 기여 0(ambient 플로어만). 평면이 프레임을 채우므로 배경 검정 아닌 '콘 밖 평면'.
        XCTAssertLessThan(profile.last!, 0.08, "outer 콘 밖 픽셀은 spot 기여 0 → ambient 플로어")
        XCTAssertGreaterThan(profile.first!, profile.last! * 10,
            "축상 대비 콘 밖 강한 대비가 콘 게이팅을 증명")
        // ③ inner~outer 사이 단조 감소(3+ 내부 샘플) = 셰이더 smoothstep 콘이 CPU 코사인 규약과 일치.
        for i in 1..<profile.count {
            XCTAssertGreaterThan(profile[i - 1], profile[i],
                "콘 falloff 은 축에서 밖으로 단조 감소해야(열 \([32,42,46,50,56][i-1])→\([32,42,46,50,56][i]))")
        }
    }

    func testSpotWithoutConeDataUsesHemisphereGradientFallback() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // innercone=outercone=0 → spotConeCosines (1,-1) → 셰이더 (cosAngle+1)/2 반구 그라디언트 폴백.
        // 이 픽셀 테스트가 잠그는 것: outercone=0 은 '콘 게이팅 아님'(평면 가장자리까지 광역 조명).
        // 정확한 반구 곡선(전방향 통과 vs (cosAngle+1)/2)은 이 정면 지오메트리(cosAngle≈0.85~1.0)로는
        // 분리 불가 — 곡선은 Scene3DLightingTests.spotConeCosines 유닛((1,-1) 반환)이 잠금.
        let none = try renderScene(spotScene(inner: 0, outer: 0), material: litMeshMaterial, tag: "spotnone")
        // (위와 같은 사유로 20/50 → 10/25 — 콘 자체는 동일하다.)
        let coned = try renderScene(spotScene(inner: 10, outer: 25), material: litMeshMaterial, tag: "spotconeref")
        // 같은 가장자리 픽셀: 콘 데이터 없음=밝음(광역 도달) vs 콘 있음=어두움(콘 밖 게이팅).
        let noneEdge = blockLuminance(none, cx: 62, cy: 32)      // 실측 0.469
        let conedEdge = blockLuminance(coned, cx: 62, cy: 32)    // 실측 0.031(ambient)
        XCTAssertGreaterThan(noneEdge, 0.3,
            "콘 데이터 없는 spot 은 평면 가장자리까지 광역 조명(ambient 플로어보다 훨씬 밝음)")
        XCTAssertGreaterThan(noneEdge, conedEdge * 5,
            "동일 픽셀이 콘 없으면 밝고 콘 있으면 어두움 → outercone=0 은 콘 게이팅 아닌 광역 폴백")
        // 축상은 콘 유무와 무관하게 동일(둘 다 완전조명).
        let noneCenter = blockLuminance(none, cx: 32, cy: 32)
        let conedCenter = blockLuminance(coned, cx: 32, cy: 32)
        XCTAssertEqual(noneCenter, conedCenter, accuracy: 0.05,
            "축상 픽셀은 콘 파라미터와 무관하게 완전조명")
        // 폴백은 축→가장자리로 완만 감소(거리감쇠·NL 포함), 콘처럼 급락하지 않음.
        XCTAssertGreaterThan(noneCenter, noneEdge, "광역 폴백도 축에서 가장자리로 완만 감소")
    }

    func testPBRMaterialChangesResponseAndKeepsOpaqueAlpha() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let dielectric = try capture(
            lightCastsShadow: false, tag: "dielectric", roughness: 1, metallic: 0)
        let metal = try capture(
            lightCastsShadow: false, tag: "metal", roughness: 1, metallic: 1)

        let responseDelta = abs(averageLuminance(dielectric) - averageLuminance(metal))
        XCTAssertGreaterThan(responseDelta, 0.01,
                             "authored metallic must change the Cook-Torrance material response")
        let center = try XCTUnwrap(dielectric.colorAt(x: 32, y: 32))
        XCTAssertEqual(center.alphaComponent, 1, accuracy: 0.01,
                       "opaque mesh output must remain opaque")
    }

    // F274(폐기 취소 — 실코퍼스 3706286085 RioSonicLite/SonicBODY 실측 발화): RIMLIGHTING 콤보가 실제로
    // GPU 파이프라인 끝까지 배선됐는지(콤보 파싱→유니폼→셰이더 샘플)를 픽셀로 증명. RIMLIGHTING 은
    // 절대 어둡게 만들 수 없으므로 on 이 off 보다 밝거나 같아야 하고, 아래 파라미터에서는 반드시 더 밝다.
    //
    // ⚠️ 2026-08-21: 이 씬의 라이트는 **point** 라 V1 레인(`ComputePBRLightShadow`)을 탄다. 그 레인에서
    // `metallic -= saturate(rimTerm)`(common_pbr_2.h:296)은 **효과가 없다** — `diffuse` 가 이미 :277 에서
    // 계산돼 있기 때문이다(WE 자신의 데드 연산). 반면 무한광 `ComputePBRLightShadowInfinite` 는 감산 :355
    // 다음에 diffuse :361 이라 살아 있다. Mesh3DShaders.pbrDirect 가 그 차이를 `rimAdjustsDiffuse` 로
    // 반영하면서, point 라이트에서 rim 이 밝히는 경로는 `NL = max(NL, rimTerm)` 하나만 남았다.
    // 그래서 rim 파라미터를 그 항이 확실히 발화하도록 올렸다(amount 4→12, exponent 1.5→1.0):
    // 평면 중심에서 NV≈0.857 → rimTerm = (1-0.857)^1.0 × 12 × NL(=1) ≈ 1.72 > NL 이라 NL 이 실제로 승격된다.
    // 종전 값(4 / 1.5)은 rimTerm≈0.22 < NL 이라 NL 승격이 전혀 없었고, on/off 차이가 전부 죽은
    // metallic 감산에서 나오고 있었다 — 즉 이 테스트는 **WE 에 없는 밝기**를 잠그고 있었다.
    private func rimLitScene() -> String {
        """
        {"camera":{"eye":"3 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,
                    "clearcolor":"0 0 0","ambientcolor":"0.04 0.04 0.04","skylightcolor":"0.04 0.04 0.04"},
         "objects":[
           {"id":1,"name":"receiver","model":"models/plane.mdl","origin":"0 0 0","scale":"2.5 2.5 2.5","castshadow":false},
           {"id":3,"name":"key","light":"lpoint","origin":"0 0 4","color":"1 1 1","intensity":2,
            "radius":10,"exponent":2,"castshadow":false}
         ]}
        """
    }

    private func rimMaterial(rimOn: Bool) -> String {
        #"""
        {"passes":[{"textures":["white"],
          "combos":{"LIGHTING":1,"RIMLIGHTING":\#(rimOn ? 1 : 0)},
          "constantshadervalues":{"roughness":0.7,"metallic":0,"rimamount":12,"rimexponent":1.0}}]}
        """#
    }

    func testRimLightingComboBrightensSurfaceEndToEnd() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let off = try renderScene(rimLitScene(), material: rimMaterial(rimOn: false), tag: "rimoff")
        let on = try renderScene(rimLitScene(), material: rimMaterial(rimOn: true), tag: "rimon")
        XCTAssertGreaterThan(averageLuminance(on), averageLuminance(off) + 0.01,
            "F274: RIMLIGHTING=1(rimamount=12,rimexponent=1.0)은 NL 을 max(NL,rimTerm)으로 부스트해야 함 " +
            "(common_pbr_2.h:292-295) — off 대비 더 밝지 않으면 콤보가 파싱만 되고 셰이더까지 안 이어진 것")
    }

    func testRimLightingComboOffMatchesPreExistingMaterialResponse() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // combos 자체가 없는(RIMLIGHTING 키 부재) 기존 자재와 RIMLIGHTING:0 명시가 같은 결과여야
        // 회귀가 없다(F274 배선이 무콤보 메시의 기본 경로를 건드리지 않았는지 가드).
        let noCombo = #"{"passes":[{"textures":["white"],"constantshadervalues":{"roughness":0.7,"metallic":0}}]}"#
        let explicitOff = try renderScene(rimLitScene(), material: rimMaterial(rimOn: false), tag: "rimexplicitoff")
        let implicitOff = try renderScene(rimLitScene(), material: noCombo, tag: "rimimplicitoff")
        XCTAssertEqual(averageLuminance(explicitOff), averageLuminance(implicitOff), accuracy: 1e-4,
            "RIMLIGHTING 콤보 부재(기존 자재)와 RIMLIGHTING:0 명시는 동일 렌더여야(무회귀)")
    }

    // F274: SHADINGGRADIENT 콤보가 g_Texture4(gradient/gradient_toon_smooth) 룩업까지 이어지는지 픽셀로
    // 증명. 코퍼스는 이 텍스처를 재질에서 오버라이드하지 않으므로(항상 셰이더 기본 자산) 실제 자산 대신
    // 결정적 테스트 전용 자산(단색 r=26/255≈0.10)을 패키지에 내장해 호스트 환경(WAPLE_BASE_ASSETS 유무)과
    // 무관하게 만든다 — resolveTexture 는 패키지를 base-assets 보다 먼저 본다. 이 씬(광원이 리시버 거의
    // 정면 위)의 자연 NL 은 중심 근방에서 ~1.0(밝음)이라, 강제로 낮은 값(~0.10)을 리맵하면 확연히
    // 어두워져야 한다 — 텍스처가 실제로 샘플되지 않으면(배선 누락) 밝기 그대로일 것.
    func testShadingGradientComboSamplesEmbeddedRampEndToEnd() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = rimLitScene()
        let materialOff = #"{"passes":[{"textures":["white"],"combos":{"LIGHTING":1},"constantshadervalues":{"roughness":0.7,"metallic":0}}]}"#
        let materialOn = #"{"passes":[{"textures":["white"],"combos":{"LIGHTING":1,"SHADINGGRADIENT":1},"constantshadervalues":{"roughness":0.7,"metallic":0}}]}"#
        let gradientAsset = [("materials/gradient/gradient_toon_smooth.tex", solidTex(26, 26, 26, w: 4, h: 1))]
        let off = try renderScene(scene, material: materialOff, tag: "gradientoff")
        let on = try renderScene(scene, material: materialOn, tag: "gradienton", extraFiles: gradientAsset)
        // 배경(검정, clearcolor)이 프레임 상당수를 차지해 whole-frame 평균은 희석된다 — 평면이 확실히
        // 덮는 중심 3×3 블록으로 표본(기존 spot 테스트의 blockLuminance 관례와 동일).
        let offCenter = blockLuminance(off, cx: 32, cy: 32)
        let onCenter = blockLuminance(on, cx: 32, cy: 32)
        XCTAssertGreaterThan(offCenter, 0.2,
            "대조군(그래디언트 없음)은 광원이 거의 정면 위라 자연 NL 이 높아 밝아야 함")
        XCTAssertLessThan(onCenter, offCenter - 0.1,
            "F274: SHADINGGRADIENT=1 은 NL 을 저휘도(r≈0.10) 램프로 강제 치환해 확연히 어두워야 함 — " +
            "그대로면 g_Texture4 룩업이 실제로 샘플되지 않은 것(콤보만 파싱되고 셰이더 미배선)")
    }
}
