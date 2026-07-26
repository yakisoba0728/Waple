import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

final class Scene3DRenderCorrectnessTests: XCTestCase {
    private func pkg(_ files: [(String, Data)]) throws -> ScenePackage {
        try ScenePackage.parse(encodePkg(files))
    }

    private func mirrorValue<T>(_ value: Any, _ label: String, as type: T.Type) -> T? {
        Mirror(reflecting: value).children.first { $0.label == label }?.value as? T
    }

    func test3DMaterialLookupFallsBackCaseInsensitivelyInPackageAndBaseAssets() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let renderer = SceneRenderer()
        let package = ScenePackage.assemble([
            (name: "Materials/Models/Ship/Body.JSON", data: Data("pkg".utf8)),
        ])

        XCTAssertEqual(renderer.quietAssetData("materials/models/ship/body.json", package: package), Data("pkg".utf8))

        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_case_assets", isDirectory: true)
        try? FileManager.default.removeItem(at: base)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Materials/Models/Ship", isDirectory: true),
                                                withIntermediateDirectories: true)
        try Data("base".utf8).write(to: base.appendingPathComponent("Materials/Models/Ship/Glow.JSON"))
        renderer.assetBaseDir = base

        XCTAssertEqual(renderer.quietAssetData("materials/models/ship/glow.json", package: ScenePackage.assemble([])),
                       Data("base".utf8))
    }

    func test3DBuildKeepsSolidAndFramebufferBillboardsWithState() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"model":"models/missing.mdl"},
           {"id":2,"image":"models/solid.json","origin":"0 0 0","size":"2 2",
            "angles":"0 0 0.7853982","color":"1 1 1","alpha":1,
            "effects":[{"file":"effects/tint/effect.json","passes":[{"constantshadervalues":{"color":"1 0 0","alpha":1}}]}]},
           {"id":3,"image":"models/fb.json","origin":"0 0 -0.1","size":"2 2","color":"1 1 1","alpha":1}
         ]}
        """
        let package = try pkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/solid.json", #"{"material":"materials/solid.json"}"#.data(using: .utf8)!),
            ("materials/solid.json", #"{"passes":[{"shader":"flat","depthtest":"disabled","depthwrite":"disabled"}]}"#.data(using: .utf8)!),
            ("models/fb.json", #"{"material":"materials/fb.json","fullscreen":true}"#.data(using: .utf8)!),
            ("materials/fb.json", #"{"passes":[{"shader":"passthrough","textures":["_rt_FullFrameBuffer"]}]}"#.data(using: .utf8)!),
        ])
        let doc = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        renderer.sceneScript = SceneScriptContext()
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)
        renderer.build3D(doc: doc, package: package, device: device)

        XCTAssertEqual(renderer.billboards.count, 2, "solid and _rt_ billboard layers must not be dropped")
        let solid = renderer.billboards[0]
        let angle = try XCTUnwrap(mirrorValue(solid, "angleZ", as: Float.self))
        XCTAssertEqual(angle, 0.7853982, accuracy: 1e-6)
        XCTAssertEqual(mirrorValue(solid, "depthTest", as: Bool.self), false)
        XCTAssertEqual(mirrorValue(solid, "depthWrite", as: Bool.self), false)
        XCTAssertEqual(mirrorValue(solid, "effects", as: [SceneRenderer.EffectGPU].self)?.count, 1)
        XCTAssertEqual(mirrorValue(renderer.billboards[1], "isFrameBuffer", as: Bool.self), true)
    }

    func test3DMaterialRuntimeCompositeUsesReferencedImageTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let package = try pkg([
            ("materials/mesh.json", #"{"passes":[{"textures":["_rt_imageLayerComposite_42_a"]}]}"#.data(using: .utf8)!),
            ("materials/face.tex", solidTex(255, 0, 0, w: 8, h: 2))
        ])
        let renderer = SceneRenderer()

        let material = try XCTUnwrap(renderer.loadMesh3DMaterial("materials/mesh.json",
                                                                 package: package,
                                                                 device: device,
                                                                 compositeImageTextures: [42: "materials/face.tex"]))

        XCTAssertEqual(material.texture.width, 8)
        XCTAssertEqual(material.texture.height, 2)
    }

    func test3DMeshMaterialKeepsPBRConstantsWithoutUpperClamping() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let package = try pkg([
            ("materials/mesh.json", #"{"passes":[{"textures":["white"],"constantshadervalues":{"roughness":5,"metallic":0.25,"speculartint":"0.2 0.4 0.6"}}]}"#.data(using: .utf8)!),
            ("materials/white.tex", solidTex(255, 255, 255, w: 1, h: 1)),
        ])
        let renderer = SceneRenderer()

        let material = try XCTUnwrap(renderer.loadMesh3DMaterial(
            "materials/mesh.json", package: package, device: device))

        XCTAssertEqual(material.roughness, 5)
        XCTAssertEqual(material.metallic, 0.25)
        XCTAssertEqual(material.specularTint, SIMD3(0.2, 0.4, 0.6))
    }

    func test3DMeshLightingComboZeroParsesAsUnlit() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let renderer = SceneRenderer()
        func unlit(_ materialJSON: String) throws -> Bool {
            let package = try pkg([
                ("materials/mesh.json", Data(materialJSON.utf8)),
                ("materials/white.tex", solidTex(255, 255, 255, w: 1, h: 1)),
            ])
            return try XCTUnwrap(renderer.loadMesh3DMaterial(
                "materials/mesh.json", package: package, device: device)).unlit
        }
        // combos.LIGHTING=0 → unlit(풀브라이트 albedo, generic4.frag:124-125)
        XCTAssertTrue(try unlit(#"{"passes":[{"textures":["white"],"combos":{"LIGHTING":0}}]}"#))
        // 키 대소문자 무시(2D SceneDocument:646 규약)
        XCTAssertTrue(try unlit(#"{"passes":[{"textures":["white"],"combos":{"lighting":0}}]}"#))
        // 미명시 → lit(WE 기본 LIGHTING=1)
        XCTAssertFalse(try unlit(#"{"passes":[{"textures":["white"]}]}"#))
        // 명시 1 → lit
        XCTAssertFalse(try unlit(#"{"passes":[{"textures":["white"],"combos":{"LIGHTING":1}}]}"#))
    }

    /// F274(폐기 취소 — 3706286085 RioSonicLite/SonicBODY 실측): RIMLIGHTING 콤보 게이트 + rimamount/
    /// rimexponent 유니폼 파싱(unlit 과 동일 대소문자 무시 패턴).
    func test3DMeshRimLightingComboParsesFlagAndUniforms() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let renderer = SceneRenderer()
        func material(_ materialJSON: String) throws -> SceneRenderer.Mesh3DMaterialInfo {
            let package = try pkg([
                ("materials/mesh.json", Data(materialJSON.utf8)),
                ("materials/white.tex", solidTex(255, 255, 255, w: 1, h: 1)),
            ])
            return try XCTUnwrap(renderer.loadMesh3DMaterial(
                "materials/mesh.json", package: package, device: device))
        }
        // 실물 3706286085 chr_rio_body_dif.json 값 그대로(rimamount=5, rimexponent=2.98).
        let rimOn = try material(#"{"passes":[{"textures":["white"],"combos":{"RIMLIGHTING":1},"constantshadervalues":{"rimamount":5,"rimexponent":2.98}}]}"#)
        XCTAssertTrue(rimOn.rimLighting)
        XCTAssertEqual(rimOn.rimAmount, 5)
        XCTAssertEqual(rimOn.rimExponent, 2.98, accuracy: 1e-6)
        // 키 대소문자 무시(unlit 과 동일 규약).
        let rimOnLowercase = try material(#"{"passes":[{"textures":["white"],"combos":{"rimlighting":1}}]}"#)
        XCTAssertTrue(rimOnLowercase.rimLighting)
        // 미명시 → 꺼짐 + 셰이더 기본값(g_RimAmount=2.0/g_RimExponent=4.0, generic4.frag 유니폼 선언).
        let noCombo = try material(#"{"passes":[{"textures":["white"]}]}"#)
        XCTAssertFalse(noCombo.rimLighting)
        XCTAssertEqual(noCombo.rimAmount, 2.0)
        XCTAssertEqual(noCombo.rimExponent, 4.0)
        // 명시 0 → 꺼짐.
        let rimOff = try material(#"{"passes":[{"textures":["white"],"combos":{"RIMLIGHTING":0}}]}"#)
        XCTAssertFalse(rimOff.rimLighting)
    }

    /// F274: SHADINGGRADIENT 콤보 게이트 + g_Texture4 고정 자산("gradient/gradient_toon_smooth") 로드 —
    /// 코퍼스 전건이 재질 textures[] 로 오버라이드하지 않고 셰이더 유니폼 기본값에 상시 의존(실측).
    func test3DMeshShadingGradientComboParsesFlagAndLoadsGradientTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let renderer = SceneRenderer()
        func material(_ materialJSON: String) throws -> SceneRenderer.Mesh3DMaterialInfo {
            let package = try pkg([
                ("materials/mesh.json", Data(materialJSON.utf8)),
                ("materials/white.tex", solidTex(255, 255, 255, w: 1, h: 1)),
            ])
            return try XCTUnwrap(renderer.loadMesh3DMaterial(
                "materials/mesh.json", package: package, device: device))
        }
        // 실물 3470948192 DefaultMaterial.json 값 그대로(SHADINGGRADIENT=1, RIMLIGHTING=1 도 동시 활성
        // 가능 — 콤보는 독립 게이트, common_pbr.h 도 두 #if 를 중첩 없이 병렬 배치).
        let gradientOn = try material(#"{"passes":[{"textures":["white"],"combos":{"SHADINGGRADIENT":1,"RIMLIGHTING":1}}]}"#)
        XCTAssertTrue(gradientOn.shadingGradient)
        XCTAssertTrue(gradientOn.rimLighting, "두 콤보는 독립 게이트 — 동시 활성 가능(3470948192 실물)")
        XCTAssertNotNil(gradientOn.gradientTexture, "SHADINGGRADIENT=1 이면 고정 자산 텍스처가 로드돼야 함")
        // 미명시 → 꺼짐 + 텍스처 미로드(불필요한 자산 IO 회피).
        let noCombo = try material(#"{"passes":[{"textures":["white"]}]}"#)
        XCTAssertFalse(noCombo.shadingGradient)
        XCTAssertNil(noCombo.gradientTexture)
        // 키 대소문자 무시.
        let lowercase = try material(#"{"passes":[{"textures":["white"],"combos":{"shadinggradient":1}}]}"#)
        XCTAssertTrue(lowercase.shadingGradient)
        XCTAssertNotNil(lowercase.gradientTexture)
    }

    func test3DBillboardKeepsLightingAndPBRMaterialState() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"model":"models/missing.mdl"},
           {"id":2,"image":"models/lit.json","origin":"0 0 0","size":"2 2","color":"1 1 1","alpha":1}
         ]}
        """
        let package = try pkg([
            ("scene.json", scene.data(using: .utf8)!),
            ("models/lit.json", #"{"material":"materials/lit.json"}"#.data(using: .utf8)!),
            ("materials/lit.json", #"{"passes":[{"textures":["white"],"combos":{"LIGHTING":1},"constantshadervalues":{"roughness":0.4,"metallic":0.6,"speculartint":"0.8 0.7 0.5"}}]}"#.data(using: .utf8)!),
            ("materials/white.tex", solidTex(255, 255, 255, w: 1, h: 1)),
        ])
        let doc = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        renderer.sceneScript = SceneScriptContext()
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)

        renderer.build3D(doc: doc, package: package, device: device)

        let billboard = try XCTUnwrap(renderer.billboards.first)
        XCTAssertEqual(mirrorValue(billboard, "lighting", as: Bool.self), true)
        XCTAssertEqual(mirrorValue(billboard, "roughness", as: Float.self), 0.4)
        XCTAssertEqual(mirrorValue(billboard, "metallic", as: Float.self), 0.6)
        XCTAssertEqual(mirrorValue(billboard, "specularTint", as: SIMD3<Float>.self), SIMD3(0.8, 0.7, 0.5))
    }

    /// F5: 3D 빌보드(encodeBillboard)가 합성 스케일을 열벡터 길이로 뽑아 음수 scale.x(좌우 미러링)의
    /// 부호가 소실되는 결함 회귀 — 가로 그라디언트(좌=빨강/우=파랑) 텍스처로 방향을 직접 단언한다.
    private func captureBillboardHorizontalPixels(scale: String, tag: String) throws -> (left: NSColor, right: NSColor) {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":0,"model":"models/missing.mdl"},
           {"id":1,"image":"models/grad.json","origin":"0 0 0","size":"8 8","scale":"\(scale)",
            "angles":"0 0 0","color":"1 1 1","alpha":1}
         ]}
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/grad.json", #"{"material":"materials/grad.json"}"#.data(using: .utf8)!),
            ("materials/grad.json", #"{"passes":[{"textures":["pic"],"depthtest":"disabled","depthwrite":"disabled"}]}"#.data(using: .utf8)!),
            ("materials/pic.tex", horizontalGradientTex(left: (255, 0, 0), right: (0, 0, 255))),
        ]
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_f5_\(tag)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encodePkg(files).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "f5_\(tag)", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: "f5", tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0], toDir: output).first)
        let image = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let left = try XCTUnwrap(image.colorAt(x: 16, y: 32))
        let right = try XCTUnwrap(image.colorAt(x: 48, y: 32))
        return (left, right)
    }

    func test3DBillboardNegativeScaleMirrorsHorizontally() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let normal = try captureBillboardHorizontalPixels(scale: "1 1", tag: "normal")
        XCTAssertGreaterThan(normal.left.redComponent, normal.left.blueComponent,
                             "정상 스케일: 화면 좌측은 텍스처 좌측(빨강)이어야 함")
        XCTAssertGreaterThan(normal.right.blueComponent, normal.right.redComponent,
                             "정상 스케일: 화면 우측은 텍스처 우측(파랑)이어야 함")
        let mirrored = try captureBillboardHorizontalPixels(scale: "-1 1", tag: "mirrored")
        XCTAssertGreaterThan(mirrored.left.blueComponent, mirrored.left.redComponent,
                             "scale.x<0: 화면 좌측이 파랑으로 미러링돼야 함(부호 소실되면 정상과 동일하게 빨강)")
        XCTAssertGreaterThan(mirrored.right.redComponent, mirrored.right.blueComponent,
                             "scale.x<0: 화면 우측이 빨강으로 미러링돼야 함(부호 소실되면 정상과 동일하게 파랑)")
    }

    /// F309 최소 재현: 골든 3470948192 실물 체인(비가시 노드 id=56 origin 스크립트가 shared.xx 를 세팅 →
    /// text id=181 이 shared.xx 를 읽어 shared.vvv 생산 → mesh id=115 scale 이 shared.vvv 소비)을 축약.
    /// text3DControllers 는 항상 eval3DOrder 보다 먼저 평가되므로, build3D 가 마운트 직후 1회 프라이밍하지
    /// 않으면 최초 real 호출(여기서는 build3D 직후의 단일 evaluate3DScripts 호출로 흉내)에서 id=181 이
    /// 미정의 shared.xx 를 읽어 NaN 을 낳고 id=115 의 scale 이 그 NaN 을 물려받는다(단일 프레임 캡처·라이브
    /// 첫 프레임 모두 영향).
    func test3DTextControllerPrimingSettlesSharedChainBeforeFirstRealFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":56,"origin":{"value":"0 0 0",
             "script":"export function update(value) { value.x = value.x + 1; shared.xx = value.x; return value; }"}},
           {"id":181,"text":{"value":"0",
             "script":"export function update(value) { shared.vvv = (shared.xx - 0) / 5 + 0.6; return String(shared.vvv); }"}},
           {"id":115,"model":"models/missing.mdl","scale":{"value":"1 1 1",
             "script":"export function update(value) { let k = (shared.vvv - 0.73) / 0.73; value.x = 1 - 2 * k; return value; }"}}
         ]}
        """
        let package = try pkg([("scene.json", scene.data(using: .utf8)!)])
        let doc = try SceneDocument.parse(package: package)
        let renderer = SceneRenderer()
        renderer.sceneScript = SceneScriptContext()
        renderer.projW = Float(doc.projectionWidth)
        renderer.projH = Float(doc.projectionHeight)

        // build3D 자체가 프라이밍(F309)을 내장 — 그 뒤 단 한 번의 evaluate3DScripts 호출이 encode3D 의
        // 최초 real 프레임과 동형(순서·인자 동일). 프라이밍이 없으면 이 한 번의 호출만으로 NaN 이 나온다.
        renderer.build3D(doc: doc, package: package, device: device)
        renderer.evaluate3DScripts(time: 1.0 / 60)

        let mesh = try XCTUnwrap(renderer.nodes3D.first { $0.id == 115 })
        XCTAssertTrue(mesh.scale.x.isFinite,
                      "프라이밍 없으면 text 가 첫 호출에서 undefined shared.xx 를 읽어 shared.vvv=NaN → scale.x=NaN")
        // shared.xx=1(프라이밍의 eval3DOrder 스텝에서 세팅) → shared.vvv=(1-0)/5+0.6=0.8
        // → k=(0.8-0.73)/0.73=7/73 → scale.x=1-14/73=59/73.
        XCTAssertEqual(mesh.scale.x, Float(59.0 / 73.0), accuracy: 1e-4)
    }

    /// F311 캡처 공통 헬퍼: 흰 배경 솔리드(id=1, 화면 전체 커버) 뒤에 초록 틴트 fullscreenlayer(id=2)를
    /// 얹는다. over 블렌드+alpha=1 이므로 합성이 실제로 그려지면 중심 픽셀이 흰색→초록으로 완전 치환된다
    /// (배경이 검정이면 tint 곱이 항상 검정이 되어 관측 불가하므로 흰 배경을 쓴다). objectExtra 로 두 번째
    /// 오브젝트에 visible/parent 등을 주입해 가드 케이스를 구성한다.
    /// id=0 은 로드 실패용 더미 model(models/missing.mdl) — mount() 의 3D 게이트(SceneRenderer.swift
    /// "if let cam = doc.camera3D, !doc.objects3D.isEmpty")가 objects3D(= "model" 키 보유 오브젝트) 존재를
    /// 요구해서, 빌보드만 있는 씬은 build3D 자체가 안 불리고 2D 폴백으로 새 버린다(is3D=false 로 직접 확인).
    private func captureFullscreenCompositeCenterPixel(
        secondObject: String, extraObjects: String = "", tag: String
    ) throws -> NSColor {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":0,"model":"models/missing.mdl"},
           {"id":1,"image":"models/solid.json","origin":"0 0 0","size":"20 20","color":"1 1 1","alpha":1}\(extraObjects),
           \(secondObject)
         ]}
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/solid.json", #"{"material":"materials/solid.json"}"#.data(using: .utf8)!),
            ("materials/solid.json", #"{"passes":[{"shader":"flat","depthtest":"disabled","depthwrite":"disabled"}]}"#.data(using: .utf8)!),
            ("models/fb.json", #"{"material":"materials/fb.json","fullscreen":true}"#.data(using: .utf8)!),
            ("materials/fb.json", #"{"passes":[{"shader":"passthrough","textures":["_rt_FullFrameBuffer"]}]}"#.data(using: .utf8)!),
        ]
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_f311_\(tag)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encodePkg(files).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "f311_\(tag)", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: "f311", tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0], toDir: output).first)
        let image = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        return try XCTUnwrap(image.colorAt(x: 32, y: 32))
    }

    func test3DFullscreenCompositeDrawsWhenVisible() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let color = try captureFullscreenCompositeCenterPixel(
            secondObject: #"{"id":2,"image":"models/fb.json","origin":"0 0 -0.1","size":"2 2","color":"0 1 0","alpha":1}"#,
            tag: "visible")
        // 흰 배경 위에 초록 틴트가 over(alpha=1)로 완전 치환 — 빨강 채널이 꺼져야 한다(회귀 없음 대조군).
        XCTAssertLessThan(color.redComponent, 0.3, "가시 fullscreenlayer 는 화면을 덮어써야 함")
        XCTAssertGreaterThan(color.greenComponent, 0.7)
    }

    /// F311: bb.visible=false(스크립트로 유지 — 정적 false 는 파서가 invNode 로 드롭해 billboards 에 아예
    /// 안 들어가므로 own-visible 가드를 재현하려면 스크립트가 필요)면 합성 전체(인코더 분할 포함)를 스킵해야
    /// 배경이 그대로 남는다.
    func test3DFullscreenCompositeSkipsWhenOwnVisibleFalse() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let secondObject = #"""
        {"id":2,"image":"models/fb.json","origin":"0 0 -0.1","size":"2 2","color":"0 1 0","alpha":1,
         "visible":{"value":false,"script":"export function update(value) { return false; }"}}
        """#
        let color = try captureFullscreenCompositeCenterPixel(secondObject: secondObject, tag: "ownfalse")
        XCTAssertGreaterThan(color.redComponent, 0.7, "F311: 비가시 fullscreenlayer 가 여전히 화면을 덮어씀")
        XCTAssertGreaterThan(color.greenComponent, 0.7)
    }

    /// F311: 부모 그룹(id=9)이 정적 비가시면 자식 fullscreenlayer 도 스킵해야 한다(encodeBillboard 의
    /// 부모 가시성 가드와 대칭).
    func test3DFullscreenCompositeSkipsWhenParentInvisible() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let secondObject = #"{"id":2,"image":"models/fb.json","parent":9,"origin":"0 0 -0.1","size":"2 2","color":"0 1 0","alpha":1}"#
        let color = try captureFullscreenCompositeCenterPixel(
            secondObject: secondObject,
            extraObjects: #",{"id":9,"origin":"0 0 0","visible":false}"#,
            tag: "parentfalse")
        XCTAssertGreaterThan(color.redComponent, 0.7, "F311: 부모가 비가시인 fullscreenlayer 가 여전히 화면을 덮어씀")
        XCTAssertGreaterThan(color.greenComponent, 0.7)
    }

    // MARK: F406 — colorBlendMode 픽셀 회귀 가드

    /// F406: 이 파일의 다른 블렌드/라이팅 테스트(test3DBuildKeepsSolidAndFramebufferBillboardsWithState
    /// 등)는 `layer.blendMode`/`additive` bool 같은 build-상태 보존만 검증하고 실제 GPU 블렌드 *출력*은
    /// 아무도 캡처하지 않는다 — SceneRenderer3D.mesh3DPipeline 의 additive 파이프라인(destinationRGBBlend
    /// Factor: .one, "가산") 선택 자체가 픽셀 단위로는 무검증이었다. 불투명 빨강 배경 위에 초록
    /// billboard 를 얹어 blending 모드별 실제 합성 결과가 다른지 캡처로 직접 확인한다: additive 는
    /// dst 를 유지한 채 src 를 더해 빨강+초록=노랑(양쪽 채널 다 높음), 일반(over, alpha=1)은 dst 를
    /// 완전 치환해 순수 초록(빨강 채널 낮음) — 두 결과가 실제로 달라야 파이프라인 선택이 픽셀에
    /// 반영된다는 증거다.
    private func captureBlendModeCenterPixel(blending: String) throws -> NSColor {
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":0,"model":"models/missing.mdl"},
           {"id":1,"image":"models/bg.json","origin":"0 0 0","size":"20 20","color":"1 0 0","alpha":1},
           {"id":2,"image":"models/fg.json","origin":"0 0 -0.1","size":"20 20","color":"0 1 0","alpha":1}
         ]}
        """
        let files: [(String, Data)] = [
            ("scene.json", Data(scene.utf8)),
            ("models/bg.json", #"{"material":"materials/bg.json"}"#.data(using: .utf8)!),
            ("materials/bg.json", #"{"passes":[{"shader":"flat","depthtest":"disabled","depthwrite":"disabled"}]}"#.data(using: .utf8)!),
            ("models/fg.json", #"{"material":"materials/fg.json"}"#.data(using: .utf8)!),
            ("materials/fg.json", "{\"passes\":[{\"shader\":\"flat\",\"blending\":\"\(blending)\",\"depthtest\":\"disabled\",\"depthwrite\":\"disabled\"}]}".data(using: .utf8)!),
        ]
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_blend3d_\(blending)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encodePkg(files).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "blend3d_\(blending)", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: "blend3d", tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0], toDir: output).first)
        let image = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        return try XCTUnwrap(image.colorAt(x: 32, y: 32))
    }

    func test3DBillboardAdditiveBlendModeSumsPixelsOverBackground() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let additive = try captureBlendModeCenterPixel(blending: "additive")
        XCTAssertGreaterThan(additive.redComponent, 0.6, "additive: 빨강 배경이 가산으로 남아있어야 함")
        XCTAssertGreaterThan(additive.greenComponent, 0.6, "additive: 초록 전경도 가산으로 더해져야 함")
    }

    func test3DBillboardNormalBlendModeReplacesBackground() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let normal = try captureBlendModeCenterPixel(blending: "normal")
        XCTAssertLessThan(normal.redComponent, 0.3, "normal(over) alpha=1: 배경을 완전 치환해야 함")
        XCTAssertGreaterThan(normal.greenComponent, 0.7)
    }
}
