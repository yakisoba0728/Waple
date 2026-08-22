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

    /// I1/#2: 같은 렌더러로 captureFrames 를 두 번 호출해도(라이브 재사용) 각 호출이 프레시 sim+clock=0 에서
    /// 리플레이하므로 동일 t 는 바이트 동일. 수정 전엔 1차 캡처가 clock 을 전진시켜 2차가 현재 프레임을 잡았다.
    func testCaptureFramesReproducibleAcrossCalls() throws {
        let renderer = try mount3DParticleScene()
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_3dpart_repro_\(UUID().uuidString)", isDirectory: true)
        let d1 = base.appendingPathComponent("a"), d2 = base.appendingPathComponent("b")
        for d in [d1, d2] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let u1 = try XCTUnwrap(renderer.captureFrames(width: 160, height: 100, times: [2.0], toDir: d1).first)
        let u2 = try XCTUnwrap(renderer.captureFrames(width: 160, height: 100, times: [2.0], toDir: d2).first)
        XCTAssertEqual(try Data(contentsOf: u1), try Data(contentsOf: u2),
                       "captureFrames 재호출은 프레시 리플레이라 동일 t=2s 결과가 바이트 동일해야(I1: defer 복원/리셋)")
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
        SIMD3(verts[i * ParticleShaders.vertexFloats3D + 0],
              verts[i * ParticleShaders.vertexFloats3D + 1],
              verts[i * ParticleShaders.vertexFloats3D + 2])
    }

    func testParticle3DBillboardPositionAndSize() throws {
        let renderer = SceneRenderer()
        let sys = try makeSystem(texRatio: 1)
        var p = Particle(); p.pos = SIMD3(2, 3, 0); p.size = 4; p.alpha = 1; p.color = SIMD3(1, 1, 1)
        let verts = renderer.particle3DVertices([p], sys, m: matrix_identity_float4x4,
                                                right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0))
        // [2026-08-21] 9 → 13 float: 크로스페이드 배선(ParticleShaders.vertexFloats3D).
        XCTAssertEqual(verts.count, 6 * ParticleShaders.vertexFloats3D, "쿼드 = 2삼각 6정점 × 13float")
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

    // ── 시뮬 시간 구동(감사 C1/I1): 라이브 = 클램프 dt 이어가기(유한 스텝), 캡처 = 프레시 결정적 리플레이. ──

    /// 방출 파티클 시스템 하나를 renderer.particleSystems 에 직접 배치(Metal 텍스처만 필요, 마운트 불요).
    private func makeEmittingRenderer() throws -> SceneRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        let tex = try XCTUnwrap(device.makeTexture(descriptor: td))
        let def = ParticleSystemDef(
            emitters: [.box(origin: Vec3(x: 0, y: 0, z: 0), distanceMax: Vec3(x: 0.5, y: 0.5, z: 0), rate: 50, burst: 0)],
            initializers: [.lifetimeRandom(min: 3, max: 5), .sizeRandom(min: 20, max: 40)],
            operators: [], renderer: .sprite, maxCount: 100, startTime: 0, material: nil)
        let sys = SceneRenderer.GPUParticleSystem(
            sim: ParticleSimulator(def: def, seed: 1), def: def, seed: 1, texture: tex,
            blendAdditive: true, origin: .zero, scale: SIMD2(1, 1), texRatio: 1,
            order: 0, isTrail: false, childOf: nil, frames: [], mapSeqMirror: false)
        let renderer = SceneRenderer()
        renderer.particleSystems = [sys]
        return renderer
    }

    /// C1: 라이브 프레임은 클램프 dt 로 구동돼 큰 time(가림/절전 갭) 뒤에도 유한 스텝만 밟아야 한다.
    /// 수정 전(stepParticleSnapshots 가 liveDelta 무시, time-clock 구동)엔 300s → 9000 스텝 = 메인스레드 행.
    func testLiveFrameStepsBoundedAfterOcclusionGap() throws {
        let r = try makeEmittingRenderer()
        r.particle3DClock = 0
        _ = r.stepParticleSnapshots(time: 300, liveDelta: 1.0 / 60.0)   // draw() 가 넘기는 클램프 dt
        XCTAssertLessThanOrEqual(r.particle3DLastStepCount, 2,
                                 "라이브는 프레임당 유한 스텝(클램프 dt)이어야 — time-clock 캐치업 루프 금지")
        XCTAssertGreaterThanOrEqual(r.particle3DLastStepCount, 1, "dt>0 이면 최소 1스텝 진행")
    }

    /// I1/#2: 캡처(liveDelta=nil)는 프레시 sim + clock=0 에서 0→t 결정적 리플레이 — 같은 t 두 번 = 동일 스냅샷.
    func testCaptureReplayDeterministic() throws {
        let a = try makeEmittingRenderer(); a.particle3DClock = 0
        let b = try makeEmittingRenderer(); b.particle3DClock = 0
        let s1 = a.stepParticleSnapshots(time: 2.0, liveDelta: nil).flatMap { $0 }
        let s2 = b.stepParticleSnapshots(time: 2.0, liveDelta: nil).flatMap { $0 }
        XCTAssertFalse(s1.isEmpty, "방출 시스템이라 t=2s 에 파티클이 있어야(결정성 검증 유의미)")
        XCTAssertEqual(s1.count, s2.count, "프레시 sim 은 결정적 — 파티클 수 동일")
        XCTAssertEqual(s1.map { $0.pos.x }, s2.map { $0.pos.x }, "프레시 sim 은 결정적 — 위치 동일")
        XCTAssertEqual(s1.map { $0.age }, s2.map { $0.age }, "프레시 sim 은 결정적 — age 동일")
    }
}
