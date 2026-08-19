import XCTest
import Metal
@testable import WapleCore
@testable import WapleRender

final class SceneRendererMeshCustomShaderTests: XCTestCase {
    private func project(files: [(String, Data)], id: String) throws -> WallpaperProject {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h1p2_\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        try Data(#"{"type":"scene","title":"h1p2","file":"scene.pkg"}"#.utf8).write(to: dir.appendingPathComponent("project.json"))
        return try XCTUnwrap(try? ProjectJSONParser.parse(folderURL: dir))
    }

    /// H1 Phase 2: 커스텀 셰이더가 있는 3D 메시 머티리얼이 **실제로 그 셰이더로 그려지는지**.
    ///
    /// [정정 2026-08-19] 종전 이 테스트의 픽스처는 `.mdl` 이 8바이트 매직("MDLV0023")뿐이라 파싱이
    /// 곧바로 실패했고 — 즉 이름이 말하는 커스텀 메시 경로에 **한 번도 도달하지 못한 채** —
    /// 마지막 줄이 리터럴 `XCTAssertTrue(true)` 였다. 무엇이 깨져도 초록인 테스트였다.
    /// 같은 파일에 이미 있는 `staticQuadMDL(materialPath:)` 로 실제 메시를 만들고, 커스텀 프래그먼트가
    /// **알베도를 뒤집어**(albedo 빨강 → 출력 초록) 내도록 해서 스톡 폴백(Mesh3DShaders)과 구분한다.
    func testMeshCustomShaderBuildsPipeline() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"fov":50,"clearcolor":"0 0 0","ambientcolor":"1 1 1","skylightcolor":"1 1 1"},
         "camera":{"eye":"0 0 3","center":"0 0 0","up":"0 1 0"},
         "objects":[{"model":"models/cube.mdl","origin":"0 0 0"}]}
        """
        let material = #"{"passes":[{"shader":"genericimage2","textures":["pic"]}]}"#
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        // 알베도(빨강 1,0,0)를 그대로 내지 않고 R 을 반전 — 커스텀이 돌면 (0,1,0), 스톡 폴터면 (1,0,0).
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() {
            vec4 albedo = texSample2D(g_Texture0, v_TexCoord);
            gl_FragColor = vec4(1.0 - albedo.r, 1.0, 0.0, 1.0);
        }
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/cube.mdl", staticQuadMDL(materialPath: "materials/cube.json")),
            ("materials/cube.json", material.data(using: .utf8)!),
            ("materials/pic.tex", solidTex(255, 0, 0)),
            ("shaders/genericimage2.vert", vert.data(using: .utf8)!),
            ("shaders/genericimage2.frag", frag.data(using: .utf8)!),
        ]
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)),
                    project: try project(files: files, id: "meshcustom"))
        defer { r.teardown() }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h1p2_out", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 64, times: [0.1], toDir: dir).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let c = try XCTUnwrap(rep.colorAt(x: 32, y: 32))
        XCTAssertGreaterThan(Double(c.greenComponent), 0.5,
                             "커스텀 프래그먼트 출력(G=1)이 안 나옴 — 메시 미생성 또는 스톡 폴터 의심")
        XCTAssertLessThan(Double(c.redComponent), 0.2,
                          "R = 1 - albedo.r 이어야 한다 — 스톡 폴터면 알베도 빨강이 그대로 남는다")
        XCTAssertLessThan(Double(c.blueComponent), 0.2)
    }

    /// 정적(비스키닝) 쿼드 MDLV0023 — pos3+normal3+tangent4+uv2(stride 48), formatFlag 0x0f(normal+tangent, no skin).
    /// materialPath 는 MDL 내부에 박히는 머티리얼 참조 문자열(파일명 규약과 무관 — loadMesh3DMaterial 이
    /// mesh.material 값 그대로 자산을 찾는다) — 한 테스트에서 서로 다른 머티리얼의 모델 여러 개를 쓸 때는
    /// 반드시 실제 파일 배치와 맞춰 명시해야 한다(디폴트 재사용 시 전부 같은 머티리얼을 참조하게 됨).
    private func staticQuadMDL(materialPath: String = "materials/quad.json") -> Data {
        var d = Data("MDLV0023".utf8)
        d.append(0)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func f32(_ v: Float) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u32(0x0000000f); u32(1); u32(1)
        d.append(Data(materialPath.utf8)); d.append(0)
        u32(0)
        for v: Float in [-1, -1, 0, 1, 1, 0] { f32(v) }   // AABB
        u32(0x0000000f)                                    // formatFlag: normal(0x2)+tangent(0x4), no skin
        let verts: [(Float, Float, Float, Float)] = [       // 화면 가득 채우는 정면 쿼드
            (-1, -1, 0, 1), (1, -1, 1, 1), (1, 1, 1, 0), (-1, 1, 0, 0),
        ]
        u32(UInt32(verts.count * 48))                       // 정적 스트라이드 48
        for (x, y, u, v) in verts {
            [x, y, 0, 0, 0, 1, 1, 0, 0, -1].forEach(f32)    // pos3, normal3(+Z), tangent4
            f32(u); f32(v)
        }
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        u32(UInt32(indices.count * 2))
        for i in indices { var x = i.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        return d
    }

    /// P⑥: 커스텀 3D 메시 셰이더가 (a) buffer(1)=EngineU(320B) 정본을 바인딩하는지(g_Texture1Resolution
    /// 이 아닌 값을 읽으면 MeshUniform 오독 — normalMatrix/tint 바이트가 텍셀 크기로 잡힘), (b) 정점
    /// bufferIndex 0↔4 충돌을 회피해 머티리얼 상수(buffer(0))가 있어도 파이프라인이 실제로 빌드·드로우
    /// 되는지(충돌 시 try? 가 조용히 nil→스톡 폴백, 커스텀 셰이더가 전혀 반영되지 않음), (c) 보조 텍스처
    /// (materials textures[1])가 실제로 g_Texture1 슬롯에 바인딩되는지를 한 픽셀로 동시에 검증한다.
    /// 기대 픽셀: R=머티리얼 상수(0.6, buffer(0) 정합) / G=aux 텍스처 blue 채널(0.8, 보조 텍스처 바인딩)
    /// / B=g_Texture1Resolution.x/10(0.8, aux 는 8px 폭 — EngineU.texRes 정합). 세 값 모두 0/1 이 아닌
    /// 임의값이라, 스톡 폴백(파이프라인 빌드 실패)이나 필드 오독이면 이 조합이 우연히 나오지 않는다.
    func testCustomMeshShaderBindsEngineUniformMaterialAndAuxTexture() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"fov":50,"clearcolor":"0 0 0","ambientcolor":"1 1 1","skylightcolor":"1 1 1"},
         "camera":{"eye":"0 0 3","center":"0 0 0","up":"0 1 0"},
         "objects":[{"model":"models/quad.mdl","origin":"0 0 0"}]}
        """
        let material = """
        {"passes":[{"shader":"tinttest","textures":["albedo","auxblue"],
                     "constantshadervalues":{"tint":0.6}}]}
        """
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        uniform vec4 g_Texture1Resolution;
        uniform float u_tint; // {"material":"tint","default":0.0}
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture1;
        void main() {
            vec4 aux = texSample2D(g_Texture1, v_TexCoord);
            gl_FragColor = vec4(u_tint, aux.b, g_Texture1Resolution.x / 10.0, 1.0);
        }
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/quad.mdl", staticQuadMDL()),
            ("materials/quad.json", material.data(using: .utf8)!),
            ("materials/albedo.tex", solidTex(255, 255, 255)),
            ("materials/auxblue.tex", solidTex(0, 0, 204, w: 8, h: 8)),  // 204/255≈0.8, width=8
            ("shaders/tinttest.vert", vert.data(using: .utf8)!),
            ("shaders/tinttest.frag", frag.data(using: .utf8)!),
        ]
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)),
                    project: try project(files: files, id: "engineuniform"))
        defer { r.teardown() }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h1eu_out", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 64, times: [0.1], toDir: dir).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let c = try XCTUnwrap(rep.colorAt(x: 32, y: 32))
        XCTAssertEqual(Double(c.redComponent), 0.6, accuracy: 0.05,
                       "머티리얼 상수(buffer(0)) 미반영 — bufferIndex 0/4 충돌 또는 파이프라인 폴백 의심")
        XCTAssertEqual(Double(c.greenComponent), 0.8, accuracy: 0.05,
                       "보조 텍스처(g_Texture1) 미바인딩 의심")
        XCTAssertEqual(Double(c.blueComponent), 0.8, accuracy: 0.05,
                       "g_Texture1Resolution(EngineU.texRes) 오독 의심 — MeshUniform 바인딩 잔존 가능성")
    }

    /// P⑥ 회귀: bindScene3DLighting 은 섀도우 아틀라스(depth2d_array)를 fragment texture(1)에 드로 루프
    /// 진입 "전" 1회만 바인딩한다. 커스텀 메시가 보조 텍스처(materials textures[1], 가장 흔한 aux slot)를
    /// texture(1)에 얹으면 그 바인딩이 같은 encoder 로 뒤이어 그려지는 스톡 섀도우-리시버 메시까지
    /// 지속돼(Metal encoder 상태는 draw 간 유지) 아틀라스 대신 그 색상 텍스처를 타입 불일치로 샘플하게
    /// 된다 — 원복 누락 시 리시버의 섀도우 항이 무너져 castshadow on/off 대비 밝기 차가 사라진다.
    /// 화면 밖(scale 극소, 원점에서 멀리)에 커스텀 aux 메시를 리시버보다 먼저(order) 그리게 하고,
    /// Scene3DPBRShadowRenderTests 와 동일한 오클루더/리시버 구성으로 그림자 대비가 여전히 나타나는지
    /// (평균 휘도 하락)로 간접 검증한다.
    func testCustomMeshAuxTextureAtSlot1DoesNotClobberShadowAtlasForLaterMeshes() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }

        func capture(lightCastsShadow: Bool, tag: String) throws -> NSBitmapImageRep {
            let scene = """
            {"camera":{"eye":"3 0 5","center":"0 0 0","up":"0 1 0"},
             "general":{"orthogonalprojection":null,"fov":50.0,"nearz":0.05,"farz":50,
                        "clearcolor":"0 0 0","ambientcolor":"0.04 0.04 0.04","skylightcolor":"0.04 0.04 0.04"},
             "objects":[
               {"id":0,"name":"customaux","model":"models/aux.mdl","origin":"500 500 500","scale":"0.001 0.001 0.001"},
               {"id":1,"name":"receiver","model":"models/plane.mdl","origin":"0 0 0","scale":"2.5 2.5 2.5","castshadow":false},
               {"id":2,"name":"occluder","model":"models/plane.mdl","origin":"0 0 2","scale":"0.55 0.55 0.55","castshadow":true},
               {"id":3,"name":"key","light":"lpoint","origin":"0 0 4","color":"1 1 1","intensity":2,
                "radius":10,"exponent":2,"castshadow":\(lightCastsShadow ? "true" : "false")}
             ]}
            """
            let planeMaterial = #"{"passes":[{"textures":["white"],"constantshadervalues":{"roughness":0.7,"metallic":0}}]}"#
            let auxMaterial = #"{"passes":[{"shader":"auxslot1","textures":["_unused","auxcolor"]}]}"#
            let vert = """
            uniform mat4 g_ModelViewProjectionMatrix;
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            varying vec2 v_TexCoord;
            void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
            """
            let frag = """
            varying vec2 v_TexCoord;
            uniform sampler2D g_Texture1;
            void main() { gl_FragColor = texSample2D(g_Texture1, v_TexCoord); }
            """
            let files: [(String, Data)] = [
                ("scene.json", Data(scene.utf8)),
                ("models/plane.mdl", staticQuadMDL(materialPath: "materials/plane.json")),
                ("materials/plane.json", Data(planeMaterial.utf8)),
                ("materials/white.tex", solidTex(255, 255, 255, w: 2, h: 2)),
                ("models/aux.mdl", staticQuadMDL(materialPath: "materials/aux.json")),
                ("materials/aux.json", Data(auxMaterial.utf8)),
                ("materials/_unused.tex", solidTex(255, 255, 255)),
                ("materials/auxcolor.tex", solidTex(255, 0, 255)),
                ("shaders/auxslot1.vert", Data(vert.utf8)),
                ("shaders/auxslot1.frag", Data(frag.utf8)),
            ]
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("waple_p6aux_\(tag)_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try encodePkg(files).write(to: root.appendingPathComponent("scene.pkg"))
            let project = WallpaperProject(id: "p6aux_\(tag)", type: .scene, fileName: "scene.pkg", previewName: nil,
                                           title: "p6aux", tags: [], contentRating: nil, workshopId: nil,
                                           dependency: nil, folderURL: root)
            let renderer = SceneRenderer()
            try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
            defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
            let output = root.appendingPathComponent("capture", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0], toDir: output).first)
            return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        }
        func averageLuminance(_ image: NSBitmapImageRep) -> Double {
            var total = 0.0, count = 0.0
            for y in 0..<image.pixelsHigh {
                for x in 0..<image.pixelsWide {
                    guard let c = image.colorAt(x: x, y: y) else { continue }
                    total += c.redComponent * 0.2126 + c.greenComponent * 0.7152 + c.blueComponent * 0.0722
                    count += 1
                }
            }
            return count > 0 ? total / count : 0
        }
        let withShadow = try capture(lightCastsShadow: true, tag: "on")
        let withoutShadow = try capture(lightCastsShadow: false, tag: "off")
        // 아틀라스가 aux 텍스처로 오염됐다면 castshadow on/off 가 리시버 셰이딩에 차이를 못 만든다
        // (둘 다 같은 색 텍스처를 "그림자"로 오독하거나 타입 불일치로 동일하게 깨짐).
        XCTAssertLessThan(averageLuminance(withShadow), averageLuminance(withoutShadow) - 0.01,
                          "커스텀 메시의 aux 텍스처가 texture(1)을 오염시켜 뒤이은 스톡 메시의 섀도우 항이 무너진 것으로 보임")
    }

    /// P⑥×X-⑤ 교차배치(검증 must_fix): X-⑤ 가 EngineU 에 targetRes(float4) 를 추가하며 engineUniform 의
    /// 해당 인자를 필수화했다 — 3D 커스텀 메시 경로가 이를 누락하면 컴파일은 통과한 채 g_TexelSize 가
    /// 기본값 유래 1.0(UV 전체 1텍셀)으로 조용히 깨진다. 이 경로는 다운스케일 멀티패스 체인이 없어(2D
    /// 커스텀 레이어와 동형, X-⑤ 스코프 밖) dst 기준 새 값이 아니라 종전 tex0 근사(1/texRes[0])를 그대로
    /// 유지해야 한다 — 앨비도 텍스처 8×8(solidTex 기본) 이면 g_TexelSize.x = 1/8 = 0.125 가 정답이고,
    /// targetRes 누락(기본값 1,1,1,1) 회귀 시 1.0 이 나와 이 어서션이 실패한다.
    func testCustomMeshShaderGTexelSizeMatchesAlbedoTex0Approximation() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"fov":50,"clearcolor":"0 0 0","ambientcolor":"1 1 1","skylightcolor":"1 1 1"},
         "camera":{"eye":"0 0 3","center":"0 0 0","up":"0 1 0"},
         "objects":[{"model":"models/quad.mdl","origin":"0 0 0"}]}
        """
        let material = #"{"passes":[{"shader":"texelsizetest","textures":["albedo"]}]}"#
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = vec4(g_TexelSize.x, 0.0, 0.0, 1.0); }
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/quad.mdl", staticQuadMDL()),
            ("materials/quad.json", material.data(using: .utf8)!),
            ("materials/albedo.tex", solidTex(255, 255, 255)),  // 기본 8×8 → tex0 근사 1/8=0.125
            ("shaders/texelsizetest.vert", vert.data(using: .utf8)!),
            ("shaders/texelsizetest.frag", frag.data(using: .utf8)!),
        ]
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)),
                    project: try project(files: files, id: "texelsize"))
        defer { r.teardown() }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h1tx_out", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 64, times: [0.1], toDir: dir).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let c = try XCTUnwrap(rep.colorAt(x: 32, y: 32))
        XCTAssertEqual(Double(c.redComponent), 0.125, accuracy: 0.05,
                       "targetRes 미전달 회귀 시 기본값(1,1,1,1)으로 g_TexelSize=1.0 — tex0 근사(1/8) 파리티 고정")
    }

    // MARK: - H1 스키닝: 스키닝 메시 + 커스텀 셰이더

    /// 스키닝 쿼드 MDLV0023 + MDLS0004(2본) + MDLA0006(single, 본1 을 y+2 로 이동).
    /// 바인드 포즈: y∈[-1,0](화면 하단) / 애니 t≥1/fps: y∈[1,2](화면 상단) — 픽셀로 스키닝 적용을 구분한다.
    private func skinnedQuadMDL() -> Data {
        var d = Data("MDLV0023".utf8)
        d.append(0)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func i32(_ v: Int32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func f32(_ v: Float) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u32(0x0000000f); u32(1); u32(1)
        d.append(Data("materials/skinned.json".utf8)); d.append(0)
        u32(0)
        for v: Float in [-1, -1, 0, 1, 2, 0] { f32(v) }   // AABB(바인드+애니 포즈 포괄)
        u32(0x0180000f)                                     // skinned 플래그(실측)
        let verts: [(Float, Float, Float, Float)] = [       // (x, y, u, v) — 바인드 포즈 하단 쿼드
            (-1, -1, 0, 1), (1, -1, 1, 1), (1, 0, 1, 0), (-1, 0, 0, 0),
        ]
        u32(UInt32(verts.count * 80))                       // 스키닝 스트라이드 80
        for (x, y, u, v) in verts {
            [x, y, 0, 0, 0, 1, 1, 0, 0, -1].forEach(f32)    // pos3, normal3(+Z), tangent4
            for b: UInt32 in [1, 0, 0, 0] { u32(b) }        // boneIdx4(전부 본1)
            for w: Float in [1, 0, 0, 0] { f32(w) }         // weights4
            f32(u); f32(v)
        }
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        u32(UInt32(indices.count * 2))
        for i in indices { var x = i.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        // 스켈레톤(MDLS0004): Root(항등) + Center(바인드 항등 — 애니가 곧 스킨 행렬).
        d.append(Data("MDLS0004".utf8)); d.append(0)
        u32(0); u32(2)
        for (name, parent) in [("RootNode", Int32(-1)), ("Center", Int32(0))] {
            d.append(Data(name.utf8)); d.append(0)
            u32(1); i32(parent); u32(64)
            for v: Float in [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] { f32(v) }
            d.append(0)                                     // props(빈)
        }
        // 애니(MDLA0006): single, 2키(length 1) — 본1 트랙만 key1 에서 y+2 병진.
        d.append(Data("MDLA0006".utf8)); d.append(0)
        u32(0); u32(1); u32(100); u32(0)
        func key(_ p: (Float, Float, Float)) {
            [p.0, p.1, p.2, 0, 0, 0, 1, 1, 1].forEach(f32)  // pos3, angles3, scale3
        }
        d.append(Data("test|idle_bone".utf8)); d.append(0)
        d.append(Data("single".utf8)); d.append(0)
        f32(30); u32(1); u32(0); u32(2); u32(0)
        u32(UInt32(2 * 36)); key((0, 0, 0)); key((0, 0, 0)); u32(0)   // 본0: 정지
        u32(UInt32(2 * 36)); key((0, 0, 0)); key((0, 2, 0)); u32(0)   // 본1: y+2
        return d
    }

    private func captureMesh(animated: Bool, tag: String, time: Float) throws -> NSBitmapImageRep {
        let anim = animated
            ? #","animationlayers":[{"name":"Idle","blend":1.0,"visible":true,"rate":1.0}]"#
            : ""
        let scene = """
        {"general":{"fov":50,"clearcolor":"0 0 0","ambientcolor":"0 0 0","skylightcolor":"0 0 0"},
         "camera":{"eye":"0 0 10","center":"0 0 0","up":"0 1 0"},
         "objects":[{"id":1,"name":"sk","model":"models/sk.mdl","origin":"0 0 0"\(anim)}]}
        """
        let material = #"{"passes":[{"shader":"skintest","textures":["white"]}]}"#
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
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord); }
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/sk.mdl", skinnedQuadMDL()),
            ("materials/skinned.json", material.data(using: .utf8)!),
            ("materials/white.tex", solidTex(255, 255, 255, w: 2, h: 2)),
            ("shaders/skintest.vert", vert.data(using: .utf8)!),
            ("shaders/skintest.frag", frag.data(using: .utf8)!),
        ]
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)),
                    project: try project(files: files, id: tag))
        defer { r.teardown() }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_h1s_\(tag)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 64, times: [time], toDir: dir).first)
        return try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
    }

    /// H1 스키닝: 커스텀 셰이더가 지정된 스키닝 메시는 CPU 프리스킨으로 커스텀 파이프라인을 타고,
    /// 애니메이션 포즈가 픽셀에 반영돼야 한다(스톡 mv_skin 과 동일 위치).
    func testSkinnedMeshCustomShaderFollowsAnimation() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        // 모델 픽스처 자체 검증(스켈레톤+애니 파스).
        let model = try XCTUnwrap(Model3D.parse(skinnedQuadMDL()))
        XCTAssertEqual(model.bones.count, 2)
        XCTAssertEqual(model.animations.count, 1)
        XCTAssertTrue(model.meshes[0].skinned)

        // 애니 포즈(t=1 → single 모드 마지막 키: y+2): 상단(32,21) 흰, 하단(32,35) 검정.
        let anim = try captureMesh(animated: true, tag: "skinanim", time: 1.0)
        XCTAssertGreaterThan(try XCTUnwrap(anim.colorAt(x: 32, y: 21)).redComponent, 0.9,
                             "애니 포즈의 프리스킨 쿼드가 상단에 렌더돼야 함")
        XCTAssertLessThan(try XCTUnwrap(anim.colorAt(x: 32, y: 35)).redComponent, 0.1,
                          "애니 포즈에서 하단은 비어야 함")
        // 대조군(바인드 포즈): 하단(32,35) 흰, 상단(32,21) 검정 — 상단 픽셀이 스키닝 결과임을 분리.
        let bind = try captureMesh(animated: false, tag: "skinbind", time: 1.0)
        XCTAssertGreaterThan(try XCTUnwrap(bind.colorAt(x: 32, y: 35)).redComponent, 0.9,
                             "바인드 포즈 대조군은 하단에 렌더돼야 함")
        XCTAssertLessThan(try XCTUnwrap(bind.colorAt(x: 32, y: 21)).redComponent, 0.1,
                          "바인드 포즈 대조군에서 상단은 비어야 함")
    }

    /// CPU 프리스킨 패킹(Model3DPose.cpuSkinnedPacked)이 mv_skin 수학과 동치인지 순수 검증:
    /// 애니 포즈 행렬 적용 시 위치만 y+2 이동하고 법선/UV 는 보존, 가중치 합 0 이면 바인드 포즈 통과.
    func testCPUSkinnedPackedMatchesBoneTransform() throws {
        let model = try XCTUnwrap(Model3D.parse(skinnedQuadMDL()))
        let matrices = Model3DPose.skinMatrices(model: model, animation: 0, time: 1.0)
        XCTAssertEqual(matrices.count, 2)
        let packed = Model3DPose.cpuSkinnedPacked(mesh: model.meshes[0], matrices: matrices)
        XCTAssertEqual(packed.count, model.meshes[0].vertices.count * 8)
        // 정점0: (-1,-1,0) → (-1,1,0), 법선 (0,0,1) 보존, uv (0,1) 보존.
        XCTAssertEqual(packed[0], -1, accuracy: 1e-6)
        XCTAssertEqual(packed[1], 1, accuracy: 1e-6)
        XCTAssertEqual(packed[2], 0, accuracy: 1e-6)
        XCTAssertEqual(packed[5], 1, accuracy: 1e-6)
        XCTAssertEqual(packed[6], 0, accuracy: 1e-6)
        XCTAssertEqual(packed[7], 1, accuracy: 1e-6)
        // 가중치 합 0 → 바인드 포즈 통과(mv_skin 의 weightSum>0 가드와 동치).
        var zeroWeight = model.meshes[0]
        let v0 = zeroWeight.vertices[0]
        zeroWeight = Model3D.Mesh(material: zeroWeight.material, boundsMin: zeroWeight.boundsMin,
                                  boundsMax: zeroWeight.boundsMax, skinned: true,
                                  vertices: [Model3D.Vertex(position: v0.position, normal: v0.normal,
                                                            tangent: v0.tangent, uv: v0.uv)],
                                  indices: [0, 0, 0])
        let passthrough = Model3DPose.cpuSkinnedPacked(mesh: zeroWeight, matrices: matrices)
        XCTAssertEqual(passthrough[0], -1, accuracy: 1e-6)
        XCTAssertEqual(passthrough[1], -1, accuracy: 1e-6)
    }

    // MARK: - G①: 빌트인 generic 계열 메시 셰이더 정책(env 게이트 + 화이트리스트)

    /// 순수 판정 함수 — env 뮤테이션 없이 화이트리스트×게이트 조합을 전수 검증.
    func testBuiltinMeshShaderAllowedWhitelistAndGate() throws {
        XCTAssertFalse(SceneRenderer.builtinMeshShaderAllowed("generic4", gateOn: false),
                       "게이트 OFF 는 화이트리스트 이름이어도 거부(기본 경로 비트동일 보장)")
        for name in ["generic", "generic2", "generic3", "generic4"] {
            XCTAssertTrue(SceneRenderer.builtinMeshShaderAllowed(name, gateOn: true),
                         "\(name) 은 게이트 ON 이면 허용되어야 함")
        }
        XCTAssertFalse(SceneRenderer.builtinMeshShaderAllowed("genericimage4", gateOn: true),
                       "genericimage4 는 2D 전용 빌트인 — 3D 메시 화이트리스트 밖")
        XCTAssertFalse(SceneRenderer.builtinMeshShaderAllowed("genericparticle", gateOn: true),
                       "genericparticle 는 파티클 전용 — 3D 메시 화이트리스트 밖")
        XCTAssertFalse(SceneRenderer.builtinMeshShaderAllowed("mycustom", gateOn: true),
                       "씬 저작 커스텀 이름은 화이트리스트에 없음(pkg 전용 경로로만 해석되어야 함)")
    }

    /// 게이트 OFF(기본값): 화이트리스트 이름이라도 소스가 pkg 안에 없으면(베이스 팩에만 존재) 여전히
    /// nil(스톡 폴백) — b85f8c1 pkg-전용 정책이 3D 메시 경로에서도 기본 유지됨을 마운트 레벨로 증명.
    func testBuiltinMeshShaderGateOffIgnoresBaseAssetsPack() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        unsetenv("WAPLE_BUILTIN_MESH_SHADERS")
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_g1_base_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir.appendingPathComponent("shaders"),
                                                 withIntermediateDirectories: true)
        try Self.builtinCompatibleVert.data(using: .utf8)!
            .write(to: baseDir.appendingPathComponent("shaders/generic4.vert"))
        try Self.builtinCompatibleFrag.data(using: .utf8)!
            .write(to: baseDir.appendingPathComponent("shaders/generic4.frag"))
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let mat = SceneRenderer.Mesh3DMaterialInfo(texture: try XCTUnwrap(makeSolidTexture(device: device)),
                                     tint: SIMD4(1, 1, 1, 1), roughness: 0.7, metallic: 0,
                                     specularTint: SIMD3(1, 1, 1), alphaCutoff: 0, shadowEligible: true,
                                     unlit: true, cullBack: true, additive: false, depthTest: true, depthWrite: true,
                                     rimLighting: false, shadingGradient: false, rimAmount: 0, rimExponent: 1,
                                     gradientTexture: nil, foggy: false, customShader: "generic4", customCombos: [:],
                                     customConstants: [:], customTextures: [], normalTextureName: nil,
                                     maskTextureName: nil, refract: false, refractAmount: 0.05,
                                     reflection: false, reflectivity: 0)
        let r = SceneRenderer()
        r.assetBaseRoots = [baseDir]
        let emptyPkg = try ScenePackage.parse(encodePkg([]))
        let built = r.buildCustomMeshShader(mat, package: emptyPkg, device: device)
        XCTAssertNil(built, "게이트 OFF 는 베이스 팩 전용 generic4 소스를 인정하면 안 됨(pkg 전용 정책 유지)")
    }

    /// 게이트 ON + 화이트리스트: pkg 에 없는 generic4 소스를 베이스 팩에서만 찾아 파이프라인을 빌드한다
    /// (실제 WE generic4.vert 는 a_Normal 미지원 attribute 라 MSL 컴파일 실패 — 여기선 번역기 호환
    /// (a_Position/a_TexCoord 만 참조) 대체 소스로 "베이스 팩 폴백 배선 자체"만 분리 검증).
    func testBuiltinMeshShaderGateOnLoadsWhitelistedBaseAssetsSource() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        setenv("WAPLE_BUILTIN_MESH_SHADERS", "1", 1)
        defer { unsetenv("WAPLE_BUILTIN_MESH_SHADERS") }
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_g1_base_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir.appendingPathComponent("shaders"),
                                                 withIntermediateDirectories: true)
        try Self.builtinCompatibleVert.data(using: .utf8)!
            .write(to: baseDir.appendingPathComponent("shaders/generic4.vert"))
        try Self.builtinCompatibleFrag.data(using: .utf8)!
            .write(to: baseDir.appendingPathComponent("shaders/generic4.frag"))
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let mat = SceneRenderer.Mesh3DMaterialInfo(texture: try XCTUnwrap(makeSolidTexture(device: device)),
                                     tint: SIMD4(1, 1, 1, 1), roughness: 0.7, metallic: 0,
                                     specularTint: SIMD3(1, 1, 1), alphaCutoff: 0, shadowEligible: true,
                                     unlit: true, cullBack: true, additive: false, depthTest: true, depthWrite: true,
                                     rimLighting: false, shadingGradient: false, rimAmount: 0, rimExponent: 1,
                                     gradientTexture: nil, foggy: false, customShader: "generic4", customCombos: [:],
                                     customConstants: [:], customTextures: [], normalTextureName: nil,
                                     maskTextureName: nil, refract: false, refractAmount: 0.05,
                                     reflection: false, reflectivity: 0)
        let r = SceneRenderer()
        r.assetBaseRoots = [baseDir]
        let emptyPkg = try ScenePackage.parse(encodePkg([]))
        let built = r.buildCustomMeshShader(mat, package: emptyPkg, device: device)
        XCTAssertNotNil(built, "게이트 ON + 화이트리스트(generic4) 는 베이스 팩 소스로 파이프라인을 빌드해야 함")
    }

    /// 게이트 ON 이어도 화이트리스트 밖 이름(씬 저작 커스텀)은 여전히 pkg 전용 — 베이스 팩에만 있으면 nil.
    func testBuiltinMeshShaderGateOnRejectsNonWhitelistedName() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        setenv("WAPLE_BUILTIN_MESH_SHADERS", "1", 1)
        defer { unsetenv("WAPLE_BUILTIN_MESH_SHADERS") }
        let baseDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_g1_base_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir.appendingPathComponent("shaders"),
                                                 withIntermediateDirectories: true)
        try Self.builtinCompatibleVert.data(using: .utf8)!
            .write(to: baseDir.appendingPathComponent("shaders/mycustom.vert"))
        try Self.builtinCompatibleFrag.data(using: .utf8)!
            .write(to: baseDir.appendingPathComponent("shaders/mycustom.frag"))
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let mat = SceneRenderer.Mesh3DMaterialInfo(texture: try XCTUnwrap(makeSolidTexture(device: device)),
                                     tint: SIMD4(1, 1, 1, 1), roughness: 0.7, metallic: 0,
                                     specularTint: SIMD3(1, 1, 1), alphaCutoff: 0, shadowEligible: true,
                                     unlit: true, cullBack: true, additive: false, depthTest: true, depthWrite: true,
                                     rimLighting: false, shadingGradient: false, rimAmount: 0, rimExponent: 1,
                                     gradientTexture: nil, foggy: false, customShader: "mycustom", customCombos: [:],
                                     customConstants: [:], customTextures: [], normalTextureName: nil,
                                     maskTextureName: nil, refract: false, refractAmount: 0.05,
                                     reflection: false, reflectivity: 0)
        let r = SceneRenderer()
        r.assetBaseRoots = [baseDir]
        let emptyPkg = try ScenePackage.parse(encodePkg([]))
        let built = r.buildCustomMeshShader(mat, package: emptyPkg, device: device)
        XCTAssertNil(built, "화이트리스트 밖 이름은 게이트 ON 이어도 베이스 팩 폴백을 타면 안 됨")
    }

    private func makeSolidTexture(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var px: [UInt8] = [255, 255, 255, 255]
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &px, bytesPerRow: 4)
        return tex
    }

    /// GLSLTranslator 가 지원하는 attribute(a_Position/a_TexCoord)만 참조하는 최소 정점 셰이더 —
    /// 실물 generic4.vert(a_Normal 무조건 참조)와 달리 베이스 팩 폴백 "배선"만 분리 검증하기 위한 대역.
    private static let builtinCompatibleVert = """
    uniform mat4 g_ModelViewProjectionMatrix;
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    varying vec2 v_TexCoord;
    void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
    """
    private static let builtinCompatibleFrag = """
    varying vec2 v_TexCoord;
    void main() { gl_FragColor = vec4(0.0, 1.0, 0.0, 1.0); }
    """
}
