import XCTest
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

/// F200 배치 P: 파티클 오브젝트의 parallaxDepth 가 GPUParticleSystem 까지 배선되고, pv_main 셰이더가
/// 실제로 cameraOffset×parallaxDepth 를 소비해 정점을 오프셋하는지(레이어 QuadShaders.v_main 과 동형
/// 규약) GPU 렌더 + 픽셀 판독으로 실증한다. 수정 전 상태(검증자 확정 결함): ParticleShaders.swift 의
/// pv_main 이 곱셈 없이 (pos + cameraOffset + shakeOffset) 만 쓰고 GPUParticleSystem 에 필드 자체가
/// 없어 파스값(SceneParticle.parallaxDepth)이 렌더에 전혀 소비되지 않았다 — 이 파일의 세 테스트가
/// 그 상태에서 컴파일 실패/assert 실패(RED)한다.
final class ParticleParallaxDepthRenderTests: XCTestCase {
    /// 씬 100×100, 파티클 오브젝트 origin=중앙(50,50) + parallaxDepth=0.6(비-기본값, 비-영값).
    private func dotPkg(parallaxDepth: String? = "0.6 0.6 0") -> ScenePackage {
        let depthField = parallaxDepth.map { #","parallaxDepth":"\#($0)""# } ?? ""
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200}},
         "objects":[{"id":1,"particle":"particles/dot.json","origin":"100 100 0","scale":"1 1 1"\(depthField)}]}
        """
        let particle = #"{"renderer":[{"name":"sprite"}],"maxcount":1,"starttime":0,"material":"materials/dotmat.json"}"#
        let material = #"{"passes":[{"textures":["dot"]}]}"#
        return ScenePackage.assemble([
            (name: "scene.json", data: Data(scene.utf8)),
            (name: "particles/dot.json", data: Data(particle.utf8)),
            (name: "materials/dotmat.json", data: Data(material.utf8)),
            (name: "materials/dot.tex", data: solidTex(255, 255, 255)),
        ])
    }

    // MARK: - 구성 단(파스 → GPUParticleSystem)

    /// 파스(SceneParticle.parallaxDepth) → buildParticles → GPUParticleSystem.parallaxDepth 배선.
    func testParallaxDepthFlowsFromParseIntoGPUParticleSystem() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let p = dotPkg()
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.particles.first?.parallaxDepth, Vec2(x: 0.6, y: 0.6), "파스 회귀(1차 배치 C)")
        let built = SceneRenderer().buildParticles(doc: doc, package: p, device: device)
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built[0].parallaxDepth, SIMD2<Float>(0.6, 0.6),
                       "buildParticles 가 SceneParticle.parallaxDepth 를 GPUParticleSystem 에 배선해야(F200)")
    }

    /// 미지정 파티클은 기본(1,1) — 레이어(GPULayer.parallaxDepth)와 동형 무회귀 가드.
    func testParallaxDepthDefaultsToOneInGPUParticleSystem() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let p = dotPkg(parallaxDepth: nil)
        let doc = try SceneDocument.parse(package: p)
        XCTAssertEqual(doc.particles.first?.parallaxDepth, Vec2(x: 1, y: 1))
        let built = SceneRenderer().buildParticles(doc: doc, package: p, device: device)
        XCTAssertEqual(built.first?.parallaxDepth, SIMD2<Float>(1, 1))
    }

    // MARK: - GPU 픽셀 판독: cameraOffset×parallaxDepth 오프셋 실증

    private func readRGBA(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }

    /// 지정 열 범위 중 하나라도 불투명 텍셀(alpha>0)이 있으면 true(bgra8Unorm — alpha 는 4번째 바이트).
    private func columnsOpaque(_ rgba: [UInt8], width: Int, height: Int, cols: ClosedRange<Int>) -> Bool {
        for col in cols where col >= 0 && col < width {
            for row in 0..<height {
                let idx = (row * width + col) * 4 + 3
                if rgba[idx] > 0 { return true }
            }
        }
        return false
    }

    /// 정점 오프셋 실증: 동일 cameraOffset 하에서 parallaxDepth=0 은 원위치에 정지(무가중), parallaxDepth=1
    /// 은 cameraOffset 만큼 완전히 이동해야 한다 — 레이어(QuadShaders.v_main)와 동일한 depth-가중 병진을
    /// 파티클(pv_main)도 따르는지 실제 GPU 렌더 + 픽셀 판독으로 확인(F200 배치 P, 코드가 아닌 실측 근거).
    func testParticleShiftsWithCameraOffsetWeightedByParallaxDepth() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let p = dotPkg()
        let doc = try SceneDocument.parse(package: p)
        let renderer = SceneRenderer()
        renderer.projW = 200; renderer.projH = 200
        let built = renderer.buildParticles(doc: doc, package: p, device: device)
        guard var sys = built.first, let pipe = renderer.particlePipeline(additive: false, device: device) else {
            XCTFail("파티클 시스템/파이프라인 빌드 실패")
            return
        }
        // encodeParticle 은 인자로 받은 파이프라인이 아니라 sys.blendAdditive 로 내부에서
        // additivePipeline/translucentPipeline(renderer 인스턴스 프로퍼티) 를 재조회한다 — 여기 세팅
        // 안 하면 nil 이라 guard 에서 조용히 draw 스킵(빈 텍스처, 무크래시라 원인 추적이 어려움).
        renderer.translucentPipeline = pipe
        // 씬 중앙(100,100) = NDC(0,0), size=40(half-width 20px = NDC 0.2) — 원위치 NDC x∈[-0.2,0.2].
        var particle = Particle()
        particle.pos = SIMD3<Float>(0, 0, 0)
        particle.size = 40
        particle.alpha = 1
        particle.color = SIMD3<Float>(1, 1, 1)

        let width = 20, height = 20  // pixel_x = (ndc+1)*10 — 원위치 NDC[-0.2,0.2] → col[8,12], 여유 포함 판정은 7...12
        func render(depth: SIMD2<Float>, camOffset off: SIMD2<Float>) throws -> [UInt8] {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .shared
            let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))
            let queue = try XCTUnwrap(device.makeCommandQueue())
            let cb = try XCTUnwrap(queue.makeCommandBuffer())
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = tex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rpd.colorAttachments[0].storeAction = .store
            let enc = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: rpd))
            sys.parallaxDepth = depth
            var camOffset = off
            var aspectScale = SIMD2<Float>(1, 1)
            renderer.encodeParticle(sys, snapshot: [particle], into: enc, device: device,
                                    camOffset: &camOffset, aspectScale: &aspectScale)
            enc.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            return readRGBA(tex)
        }

        // camOffset NDC 0.6 병진 → 이동 목적지 NDC[0.4,0.8] → col[14,18]. 원위치 col[8,12] 와 완전 분리.
        let camOffset = SIMD2<Float>(0.6, 0)
        let originalCols = 8...12
        let shiftedCols = 14...18

        let pinned = try render(depth: SIMD2(0, 0), camOffset: camOffset)
        XCTAssertTrue(columnsOpaque(pinned, width: width, height: height, cols: originalCols),
                     "parallaxDepth=0 은 cameraOffset 과 무관하게 원위치에 그려져야(무가중)")
        XCTAssertFalse(columnsOpaque(pinned, width: width, height: height, cols: shiftedCols),
                      "parallaxDepth=0 은 cameraOffset 만큼 이동하면 안 됨")

        let shifted = try render(depth: SIMD2(1, 1), camOffset: camOffset)
        XCTAssertFalse(columnsOpaque(shifted, width: width, height: height, cols: originalCols),
                      "parallaxDepth=1 은 원위치에 남아있으면 안 됨(미배선이면 여기서 fail = RED)")
        XCTAssertTrue(columnsOpaque(shifted, width: width, height: height, cols: shiftedCols),
                     "parallaxDepth=1 은 cameraOffset 만큼 완전히 이동해야")

        // 무회귀 가드: cameraOffset=0(헤드리스 captureFrames 항상 이 값 — draw() 참조)이면 depth 값과
        // 무관하게 원위치 그대로(코드 근거는 draw()/captureFrames 의 camOffset 초기값 자체가 항상 .zero).
        let noMouse = try render(depth: SIMD2(1, 1), camOffset: SIMD2(0, 0))
        XCTAssertTrue(columnsOpaque(noMouse, width: width, height: height, cols: originalCols),
                     "cameraOffset=0 이면 parallaxDepth 와 무관하게 원위치(무회귀)")
        XCTAssertFalse(columnsOpaque(noMouse, width: width, height: height, cols: shiftedCols))
    }
}
