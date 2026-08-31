import XCTest
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

/// F200 배치 P: 파티클 오브젝트의 parallaxDepth 가 GPUParticleSystem 까지 배선되고, pv_main 셰이더가
/// parallaxDepth 파스와, 실제 draw가 공통 object root의 origin/depth로 계산한 이동을 파티클에도
/// 적용하는지 GPU 픽셀로 실증한다. cameraOffset은 더 이상 포인터에서 만든 전역 gain이 아니라
/// root별로 이미 해소된 NDC 이동이며, vertex ABI의 depth 슬롯에는 단위값이 들어간다.
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

    // MARK: - GPU 픽셀 판독: root origin/depth 오프셋 실증

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

    /// focus=(100,100), root origin=(160,100), amount=1이면 depth=1의 이동은 +60px=NDC +0.6이다.
    /// depth=0은 고정되어야 하며, 이 계산은 파티클 leaf 필드가 아니라 objects[] root 표에서 와야 한다.
    func testParticleShiftsWithRootOffsetWeightedByParallaxDepth() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let p = dotPkg()
        let doc = try SceneDocument.parse(package: p)
        let renderer = SceneRenderer()
        renderer.projW = 200; renderer.projH = 200
        renderer.parallaxEnabled = true
        renderer.parallaxAmount = 1
        renderer.parallaxFocus = SIMD2<Float>(100, 100)
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
        func render(depth: SIMD2<Float>, enabled: Bool = true) throws -> [UInt8] {
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
            renderer.parallaxEnabled = enabled
            renderer.cameraParallaxRootByOrder[sys.order] = SceneObjectParallaxDescriptor(
                order: sys.order, id: 1, parent: nil,
                origin: Vec2(x: 160, y: 100), depth: Vec2(x: depth.x, y: depth.y)
            )
            var aspectScale = SIMD2<Float>(1, 1)
            renderer.encodeParticle(sys, snapshot: [particle], into: enc, device: device,
                                    aspectScale: &aspectScale)
            enc.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            return readRGBA(tex)
        }

        // 루트/초점/amount가 만든 +60px 병진 → col[14,18]. 원위치 col[8,12] 와 완전 분리.
        let originalCols = 8...12
        let shiftedCols = 14...18

        let pinned = try render(depth: SIMD2(0, 0))
        XCTAssertTrue(columnsOpaque(pinned, width: width, height: height, cols: originalCols),
                     "root parallaxDepth=0 은 원위치에 그려져야")
        XCTAssertFalse(columnsOpaque(pinned, width: width, height: height, cols: shiftedCols),
                      "root parallaxDepth=0 은 계산된 루트 시차만큼 이동하면 안 됨")

        let shifted = try render(depth: SIMD2(1, 1))
        XCTAssertFalse(columnsOpaque(shifted, width: width, height: height, cols: originalCols),
                      "parallaxDepth=1 은 원위치에 남아있으면 안 됨(미배선이면 여기서 fail = RED)")
        XCTAssertTrue(columnsOpaque(shifted, width: width, height: height, cols: shiftedCols),
                     "root parallaxDepth=1 은 계산된 +60px만큼 이동해야")

        // 시차 게이트가 꺼지면 authored depth와 무관하게 원위치다.
        let noMouse = try render(depth: SIMD2(1, 1), enabled: false)
        XCTAssertTrue(columnsOpaque(noMouse, width: width, height: height, cols: originalCols),
                     "cameraparallax=false이면 parallaxDepth와 무관하게 원위치")
        XCTAssertFalse(columnsOpaque(noMouse, width: width, height: height, cols: shiftedCols))
    }
}
