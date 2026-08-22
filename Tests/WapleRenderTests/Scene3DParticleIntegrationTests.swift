import XCTest
import AppKit
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

/// fix-i1 통합 그룹 회귀 테스트 — F730(S-22 sequence/sequencemultiplier) / F731(S-23 flags worldspace) /
/// F732(S-26 orientation upright/fixed) / F733(S-5 잔여 3D 빌보드 이펙트 _rt_ 바인드).
/// ①~③은 particle3DVertices 기하 단언(수정 전 red → 수정 후 green), ④는 3D 씬 마운트+캡처 엔드투엔드.
final class Scene3DParticleIntegrationTests: XCTestCase {
    private func d(_ s: String) -> Data { s.data(using: .utf8)! }

    // MARK: 공용 스캐폴드

    /// frames 포함 가능한 최소 스프라이트 시스템(Scene3DParticleTests.makeSystem 과 동형 + frames/def 변형).
    private func makeSystem(texRatio: Float = 1,
                            frames: [TexImage.TexFrame] = [],
                            texW: Int = 1, texH: Int = 1,
                            mutateDef: (inout ParticleSystemDef) -> Void = { _ in }) throws -> SceneRenderer.GPUParticleSystem {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                          width: texW, height: texH, mipmapped: false)
        let tex = try XCTUnwrap(device.makeTexture(descriptor: td))
        var def = ParticleSystemDef(emitters: [], initializers: [], operators: [],
                                    renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
        mutateDef(&def)
        return SceneRenderer.GPUParticleSystem(
            sim: ParticleSimulator(def: def, seed: 1), def: def, seed: 1, texture: tex,
            blendAdditive: true, origin: .zero, scale: SIMD2(1, 1), texRatio: texRatio,
            order: 0, isTrail: false, childOf: nil, frames: frames, mapSeqMirror: false)
    }

    /// 2프레임 가로 아틀라스(2×1): 프레임0 = 좌반(u0=0), 프레임1 = 우반(u0=0.5). frametime 은 크게(10s) —
    /// nil 모드 폴터(Int(age/ft)%fc)와 sequence 모드(t×fc×rate)가 같은 age 에서 다른 프레임을 고르게 한다.
    private func twoFrames() -> [TexImage.TexFrame] {
        [TexImage.TexFrame(imageId: 0, time: 10, x: 0, y: 0, width: 1, height: 1),
         TexImage.TexFrame(imageId: 0, time: 10, x: 1, y: 0, width: 1, height: 1)]
    }

    private func vtx(_ verts: [Float], _ i: Int) -> SIMD3<Float> {
        SIMD3(verts[i * ParticleShaders.vertexFloats3D + 0],
              verts[i * ParticleShaders.vertexFloats3D + 1],
              verts[i * ParticleShaders.vertexFloats3D + 2])
    }
    /// 정점 i 의 텍스처 u 좌표(레이아웃: xyz uv rgba — 9 float 스트라이드).
    private func tu(_ verts: [Float], _ i: Int) -> Float { verts[i * ParticleShaders.vertexFloats3D + 3] }

    // MARK: F730(S-22) — animationmode=sequence + sequencemultiplier 소비

    /// sequence(×1): 수명 절반 경과 → 시트 절반(fc=2 → 프레임1). 수정 전엔 frametime 폴터라
    /// ft=10s 에 대해 Int(1/10)%2=0(프레임0)으로 정지 — red.
    func testSequenceModeAdvancesFramesOverLifetime_F730() throws {
        let renderer = SceneRenderer()
        let sys = try makeSystem(frames: twoFrames(), texW: 2, texH: 1) { $0.animationMode = .sequence }
        var p = Particle(); p.pos = .zero; p.size = 2; p.alpha = 1; p.age = 1; p.lifetime = 2
        let verts = renderer.particle3DVertices([p], sys, m: matrix_identity_float4x4,
                                                right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0))
        XCTAssertEqual(verts.count, 6 * ParticleShaders.vertexFloats3D)
        XCTAssertEqual(tu(verts, 0), 0.5, accuracy: 1e-6,
                       "sequence ×1: age/lifetime=0.5 → t×fc=1 → 프레임1(u0=0.5)이어야")
    }

    /// sequencemultiplier=2: 같은 age(t=0.25)에서 seq=0.25×2×2=1 → 프레임1. ×1 이면 seq=0.5 → 프레임0.
    /// 수정 전(폴터만)은 multiplier 무시로 둘 다 프레임0 — red.
    func testSequenceMultiplierScalesPlayback_F730() throws {
        let renderer = SceneRenderer()
        let x1 = try makeSystem(frames: twoFrames(), texW: 2, texH: 1) {
            $0.animationMode = .sequence; $0.sequenceMultiplier = 1 }
        let x2 = try makeSystem(frames: twoFrames(), texW: 2, texH: 1) {
            $0.animationMode = .sequence; $0.sequenceMultiplier = 2 }
        var p = Particle(); p.pos = .zero; p.size = 2; p.alpha = 1; p.age = 0.5; p.lifetime = 2
        let v1 = renderer.particle3DVertices([p], x1, m: matrix_identity_float4x4,
                                             right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0))
        let v2 = renderer.particle3DVertices([p], x2, m: matrix_identity_float4x4,
                                             right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0))
        XCTAssertEqual(tu(v1, 0), 0, accuracy: 1e-6, "×1: t×fc×1=0.5 → 프레임0")
        XCTAssertEqual(tu(v2, 0), 0.5, accuracy: 1e-6, "×2: t×fc×2=1.0 → 프레임1(배속 소비)")
    }

    /// animationmode 부재(nil)는 종전 frametime 폴터 그대로(무회귀): ft=10s, age=1 → Int(0.1)=0 → 프레임0.
    func testNilAnimationModeKeepsFrametimeFallback_F730() throws {
        let renderer = SceneRenderer()
        let sys = try makeSystem(frames: twoFrames(), texW: 2, texH: 1)
        var p = Particle(); p.pos = .zero; p.size = 2; p.alpha = 1; p.age = 1; p.lifetime = 2
        let verts = renderer.particle3DVertices([p], sys, m: matrix_identity_float4x4,
                                                right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0))
        XCTAssertEqual(tu(verts, 0), 0, accuracy: 1e-6, "nil 모드 = frametime 폴터(프레임0) 유지")
    }

    // MARK: F731(S-23) — flags bit1(worldspace) 소비

    /// worldspace(bit1): 파티클 pos 가 월드 직결 — 오브젝트 변환 m(이동+2×스케일) 우회.
    /// 수정 전엔 m 적용으로 center=(102,54,31)·반경 4 — red.
    func testWorldspaceFlagBypassesModelMatrix_F731() throws {
        let renderer = SceneRenderer()
        let sys = try makeSystem { $0.flags = 1 }
        var p = Particle(); p.pos = SIMD3(1, 2, 3); p.size = 4; p.alpha = 1
        let m = Scene3DMath.modelMatrix(origin: SIMD3(100, 50, 25), angles: .zero, scale: SIMD3(2, 2, 2))
        let verts = renderer.particle3DVertices([p], sys, m: m, right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0))
        // hw = 0.5·size·colScale(=1) = 2 → TL = center-(2,0,0)+(0,2,0) = (-1,4,3).
        XCTAssertEqual(vtx(verts, 0), SIMD3(-1, 4, 3), "worldspace: m 우회 + 월드 단위 크기")
    }

    /// flags=0(기본)은 종전과 동일하게 m 적용(무회귀 가드 — worldspace 대조항목).
    func testNoFlagsKeepsModelMatrixTransform_F731() throws {
        let renderer = SceneRenderer()
        let sys = try makeSystem()
        var p = Particle(); p.pos = SIMD3(1, 2, 3); p.size = 4; p.alpha = 1
        let m = Scene3DMath.modelMatrix(origin: SIMD3(100, 50, 25), angles: .zero, scale: SIMD3(2, 2, 2))
        let verts = renderer.particle3DVertices([p], sys, m: m, right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0))
        // center = m·pos = (102,54,31), hw = 0.5·4·2 = 4 → TL = (98,58,31).
        XCTAssertEqual(vtx(verts, 0), SIMD3(98, 58, 31), "기본 경로: m·pos + colScale=2 유지")
    }

    // MARK: F732(S-26) — orientation upright/fixed 소비

    /// upright: 카메라 가 기울어도 쿼드 up 은 월드 Y 고정 — 모든 코너 x == center.x(수직 평면).
    /// screen(수정 전 폴터)은 카메라 축을 따라가 x 가 벌어진다 — red.
    func testUprightOrientationLocksYAxis_F732() throws {
        let renderer = SceneRenderer()
        let up45 = SIMD3<Float>(-sqrt(0.5), sqrt(0.5), 0)   // fwd=(√½,√½,0) 45° 기운 카메라
        let right = SIMD3<Float>(0, 0, 1)
        var p = Particle(); p.pos = .zero; p.size = 2; p.alpha = 1
        let upright = try makeSystem { $0.orientation = .upright }
        let vUp = renderer.particle3DVertices([p], upright, m: matrix_identity_float4x4,
                                              right: right, up: up45)
        for i in 0..<6 {
            XCTAssertEqual(vtx(vUp, i).x, 0, accuracy: 1e-6, "upright: 쿼드는 x=0 수직 평면")
        }
        let ys = (0..<6).map { vtx(vUp, $0).y }, zs = (0..<6).map { vtx(vUp, $0).z }
        XCTAssertEqual(ys.max()! - ys.min()!, 2, accuracy: 1e-6, "세로 전개 = size")
        XCTAssertEqual(zs.max()! - zs.min()!, 2, accuracy: 1e-6, "가로 전개 = size")
        // 대조: screen 모드는 기울어진 up 축을 따라 코너 x 가 ±√½ 로 벌어진다.
        let screen = try makeSystem()
        let vScr = renderer.particle3DVertices([p], screen, m: matrix_identity_float4x4,
                                               right: right, up: up45)
        let xs = (0..<6).map { vtx(vScr, $0).x }
        XCTAssertGreaterThan(xs.max()! - xs.min()!, 0.5, "screen: 카메라 기울기가 x 에 노출(대조)")
    }

    /// fixed(axis=+Z): 카메라 yaw 45°(fwd=(√½,0,-√½))에서 쿼드는 축에 고정 — 모든 코너 x == center.x.
    /// screen 은 코너 x = ±√½ — red.
    func testFixedOrientationAlignsQuadToAxis_F732() throws {
        let renderer = SceneRenderer()
        let right = SIMD3<Float>(sqrt(0.5), 0, sqrt(0.5))
        let up = SIMD3<Float>(0, 1, 0)
        var p = Particle(); p.pos = .zero; p.size = 2; p.alpha = 1
        let fixed = try makeSystem { $0.orientation = .fixed(axis: Vec3(x: 0, y: 0, z: 1)) }
        let vFix = renderer.particle3DVertices([p], fixed, m: matrix_identity_float4x4,
                                               right: right, up: up)
        for i in 0..<6 {
            XCTAssertEqual(vtx(vFix, i).x, 0, accuracy: 1e-6, "fixed(+Z): 쿼드는 x=0 평면(축 고정)")
        }
        let zs = (0..<6).map { vtx(vFix, $0).z }
        XCTAssertEqual(zs.max()! - zs.min()!, 2, accuracy: 1e-6, "축(+Z) 방향 전개 = size")
    }

    /// 퇴화(축 ∥ 시선): cross ≈ 0 → screen 폴터 — 출력이 screen 모드와 동일해야(NaN 방지).
    func testFixedOrientationDegenerateAxisFallsBackToScreen_F732() throws {
        let renderer = SceneRenderer()
        let right = SIMD3<Float>(1, 0, 0), up = SIMD3<Float>(0, 1, 0)   // fwd = (0,0,-1)
        var p = Particle(); p.pos = .zero; p.size = 2; p.alpha = 1
        let fixed = try makeSystem { $0.orientation = .fixed(axis: Vec3(x: 0, y: 0, z: -1)) }
        let screen = try makeSystem()
        let vFix = renderer.particle3DVertices([p], fixed, m: matrix_identity_float4x4,
                                               right: right, up: up)
        let vScr = renderer.particle3DVertices([p], screen, m: matrix_identity_float4x4,
                                               right: right, up: up)
        XCTAssertEqual(vFix.count, vScr.count)
        for (a, b) in zip(vFix, vScr) { XCTAssertEqual(a, b, accuracy: 1e-6, "퇴화 축 = screen 폴터 동치") }
    }

    // MARK: F733(S-5 잔여) — 3D 빌보드 이펙트의 _rt_imageLayerComposite_* 샘플러 바인드

    /// 3D(camera) 씬: 빌보드 id=1(흰색) 의 이펙트 frag 이 g_Texture1(=_rt_imageLayerComposite_7_a,
    /// 숨김 레이어 id=7 의 빨간 텍스처)을 그대로 출력. 수정 전엔 기본 인자 [:] 로 치환 없이 흰색 1×1 폴터
    /// 바인드 → 흰 화면(red 채널만 1). 수정 후엔 참조 레이어 베이스 텍스처로 치환 → 빨간 화면.
    /// (2D 대응: SceneRendererSceneFixRegressionTests.testImageLayerCompositeSamplerBound_F650/F720)
    func testBillboardEffectBindsImageLayerCompositeSampler_F733() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() {
            gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix);
            v_TexCoord = a_TexCoord;
        }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        uniform sampler2D g_Texture1;
        void main() { gl_FragColor = texSample2D(g_Texture1, v_TexCoord); }
        """
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":9,"model":"models/missing.mdl"},
           {"id":1,"image":"models/w.json","origin":"0 0 0","size":"64 64",
            "effects":[{"file":"effects/comp/effect.json","passes":[{"textures":[null,"_rt_imageLayerComposite_7_a"]}]}]},
           {"id":7,"image":"models/r.json","origin":"0 0 0","size":"64 64","visible":false}
         ]}
        """
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_i1_f733_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", d(scene)),
            ("models/w.json", d(#"{"material":"materials/w.json"}"#)),
            ("materials/w.json", d(#"{"passes":[{"textures":["w"]}]}"#)),
            ("materials/w.tex", solidTex(255, 255, 255)),
            ("models/r.json", d(#"{"material":"materials/r.json"}"#)),
            ("materials/r.json", d(#"{"passes":[{"textures":["r"]}]}"#)),
            ("materials/r.tex", solidTex(255, 0, 0)),
            ("effects/comp/effect.json", d(#"{"passes":[{}]}"#)),
            ("shaders/effects/comp.vert", d(vert)),
            ("shaders/effects/comp.frag", d(frag)),
        ]).write(to: root.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "i1_f733", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: "f733", tags: [], contentRating: nil, workshopId: nil, dependency: nil,
            folderURL: root)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        defer { renderer.teardown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(renderer.is3D, "camera 키 + 모델 게이트(objects3D) + 이미지 레이어 → 3D 씬 분류")
        let out = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(renderer.captureFrames(width: 64, height: 64, times: [0.1], toDir: out).first)
        let img = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        var r = 0.0, g = 0.0
        for y in 0..<img.pixelsHigh {
            for x in 0..<img.pixelsWide {
                guard let c = img.colorAt(x: x, y: y) else { continue }
                r += c.redComponent; g += c.greenComponent
            }
        }
        let n = Double(img.pixelsWide * img.pixelsHigh)
        NSLog("%@", "[Waple] F733 3D composite-sampler avg r=\(r / n) g=\(g / n)")
        XCTAssertGreaterThan(r / n, 0.5, "_rt_imageLayerComposite_7_a 가 빨간 레이어 텍스처로 바인드돼야")
        XCTAssertLessThan(g / n, 0.3, "흰색 1×1 폴터가 아니라 참조 레이어(순빨강)가 출력돼야")
    }
}
