import XCTest
import AppKit
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

/// 3D(camera3D) 씬 파티클 배선 + 원근 빌보드 렌더 경로 검증.
/// 종전엔 3D 마운트가 buildParticles 를 호출하지 않아 파티클 오브젝트가 전량 드롭됐다(B3 분석 §최중요 갭).
final class Scene3DParticleTests: XCTestCase {
    private func d(_ s: String) -> Data { s.data(using: .utf8)! }

    /// 모델(objects3D 게이트) + solid 이미지(→ billboard, is3D 성립) + 파티클 오브젝트를 가진 3D 씬을
    /// 마운트하면 파티클 시스템이 생성되고 3D 배치 필드(origin3D 등)가 채워져야 한다.
    private func mount3DParticleScene() throws -> SceneRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let scene = """
        {"camera":{"eye":"0 0 5","center":"0 0 0","up":"0 1 0"},
         "general":{"orthogonalprojection":null,"fov":50.0,"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"model":"models/missing.mdl"},
           {"id":2,"image":"models/solid.json","origin":"0 0 0","size":"2 2","color":"1 1 1","alpha":1},
           {"id":3,"name":"emitter","particle":"particles/p.json","origin":"0 0 -2","scale":"1 1 1","visible":true}
         ]}
        """
        let particle = #"""
        {"emitter":[{"name":"boxrandom","origin":"0 0 0","distancemax":"0.5 0.5 0","rate":50}],
         "initializer":[{"name":"lifetimerandom","min":3,"max":5},{"name":"sizerandom","min":20,"max":40},
           {"name":"colorrandom","min":"255 255 255","max":"255 255 255"}],
         "operator":[{"name":"movement","gravity":"0 0 0"}],
         "renderer":[{"name":"sprite"}],"maxcount":100,"starttime":0,"material":"materials/p.json"}
        """#
        let material = #"{"passes":[{"shader":"genericparticle","blending":"additive","textures":["particle/dot"]}]}"#
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_3dpart_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg([
            ("scene.json", d(scene)),
            ("particles/p.json", d(particle)),
            ("materials/p.json", d(material)),
            ("materials/particle/dot.tex", solidTex(255, 255, 255, w: 4, h: 4)),
            ("models/solid.json", d(#"{"material":"materials/solid.json"}"#)),
            ("materials/solid.json", d(#"{"passes":[{"shader":"flat"}]}"#)),
        ]).write(to: dir.appendingPathComponent("scene.pkg"))

        let project = WallpaperProject(
            id: "3dpart", type: .scene, fileName: "scene.pkg", previewName: nil, title: "3dpart",
            tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let renderer = SceneRenderer()
        try renderer.mount(in: container, project: project)
        addTeardownBlock { renderer.teardown() }
        return renderer
    }

    func testMount3DSceneBuildsParticleSystemsWith3DFields() throws {
        let renderer = try mount3DParticleScene()
        XCTAssertTrue(renderer.is3D, "solid 빌보드가 있으므로 3D 씬으로 분류돼야")
        XCTAssertTrue(renderer.hasParticles, "3D 마운트가 파티클을 배선해야")
        XCTAssertEqual(renderer.particleSystems.count, 1, "파티클 시스템 생성 실패(종전=전량 드롭)")
        XCTAssertNotNil(renderer.particle3DAdditive)
        XCTAssertNotNil(renderer.particle3DTranslucent)
        let sys = renderer.particleSystems[0]
        XCTAssertEqual(sys.origin3D, SIMD3<Float>(0, 0, -2), "3D origin 배치 실패")
        XCTAssertTrue(sys.visible3D)
        XCTAssertNil(sys.parent3D)
    }

    /// 원근 빌보드 렌더 경로(encode3D → encode3DParticles) 엔드투엔드 스모크: 크래시 없이 PNG 산출.
    func testMount3DParticleCaptureProducesPNG() throws {
        let renderer = try mount3DParticleScene()
        let outDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_3dpart_cap_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let urls = renderer.captureFrames(width: 320, height: 200, times: [0.5, 2.0], toDir: outDir)
        XCTAssertEqual(urls.count, 2)
        for u in urls {
            let size = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
            XCTAssertGreaterThan(size ?? 0, 100, "PNG too small: \(u.path)")
        }
    }

    // ── 빌보드 행렬 수학: 쿼드가 카메라 right/up 평면에 놓이고(카메라 향함) 월드 위치/크기가 정확해야. ──

    private func makeSystem(texRatio: Float) throws -> SceneRenderer.GPUParticleSystem {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        let tex = try XCTUnwrap(device.makeTexture(descriptor: td))
        let def = ParticleSystemDef(emitters: [], initializers: [], operators: [],
                                    renderer: .sprite, maxCount: 1, startTime: 0, material: nil)
        return SceneRenderer.GPUParticleSystem(
            sim: ParticleSimulator(def: def, seed: 1), def: def, seed: 1, texture: tex,
            blendAdditive: true, origin: .zero, scale: SIMD2(1, 1), texRatio: texRatio,
            order: 0, isTrail: false, childOf: nil, frames: [], mapSeqMirror: false)
    }

    private func vtx(_ verts: [Float], _ i: Int) -> SIMD3<Float> {
        SIMD3(verts[i * 9 + 0], verts[i * 9 + 1], verts[i * 9 + 2])
    }

    func testParticle3DBillboardPositionAndSize() throws {
        let renderer = SceneRenderer()
        let sys = try makeSystem(texRatio: 1)
        var p = Particle(); p.pos = SIMD3(2, 3, 0); p.size = 4; p.alpha = 1; p.color = SIMD3(1, 1, 1)
        let verts = renderer.particle3DVertices([p], sys, m: matrix_identity_float4x4,
                                                right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0))
        XCTAssertEqual(verts.count, 6 * 9, "쿼드 = 2삼각 6정점 × 9float")
        // hw=hh=0.5·size=2. TL=center-r+u=(0,5,0), TR=(4,5,0), BR=(4,1,0), BL=(0,1,0).
        XCTAssertEqual(vtx(verts, 0), SIMD3(0, 5, 0), "TL 위치")   // 삼각1 v0 = TL
        XCTAssertEqual(vtx(verts, 1), SIMD3(4, 5, 0), "TR 위치")
        XCTAssertEqual(vtx(verts, 2), SIMD3(4, 1, 0), "BR 위치")
    }

    func testParticle3DQuadFacesCameraPlane() throws {
        let renderer = SceneRenderer()
        let sys = try makeSystem(texRatio: 1)
        var p = Particle(); p.pos = SIMD3(0, 0, 0); p.size = 2; p.alpha = 1
        // 카메라가 +X 를 바라봐 right=(0,0,1)·up=(0,1,0) 인 경우: 쿼드는 ZY 평면 → 모든 코너 x == center.x.
        let verts = renderer.particle3DVertices([p], sys, m: matrix_identity_float4x4,
                                                right: SIMD3(0, 0, 1), up: SIMD3(0, 1, 0))
        for i in 0..<6 {
            XCTAssertEqual(vtx(verts, i).x, 0, accuracy: 1e-6, "카메라-페이싱 쿼드는 right/up 평면(x불변)에 놓여야")
        }
        // 세로(up) 방향으로 실제 전개됐는지 — 코너 y 가 ±1(0.5·size) 범위.
        let ys = (0..<6).map { vtx(verts, $0).y }
        XCTAssertEqual(ys.max()!, 1, accuracy: 1e-6)
        XCTAssertEqual(ys.min()!, -1, accuracy: 1e-6)
    }

    /// texRatio(세로/가로) 가 세로 반경에만 반영(WE ComputeParticlePosition: up 축 × textureRatio).
    func testParticle3DTextureRatioScalesHeightOnly() throws {
        let renderer = SceneRenderer()
        let sys = try makeSystem(texRatio: 2)  // 세로 2배
        var p = Particle(); p.pos = .zero; p.size = 2; p.alpha = 1
        let verts = renderer.particle3DVertices([p], sys, m: matrix_identity_float4x4,
                                                right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0))
        let xs = (0..<6).map { vtx(verts, $0).x }, ys = (0..<6).map { vtx(verts, $0).y }
        XCTAssertEqual(xs.max()! - xs.min()!, 2, accuracy: 1e-6, "가로 폭 = size")
        XCTAssertEqual(ys.max()! - ys.min()!, 4, accuracy: 1e-6, "세로 폭 = size·ratio")
    }
}
