import XCTest
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

/// M(④): 3D 파티클 씬 포그(genericparticle.frag FOG 콤보 기본 1, 3706286085 실증) — pf3d_fog 셰이더가
/// 실제로 알베도를 감쇠시키는지 GPU 렌더 + 픽셀 판독으로 실증한다(ParticleParallaxDepthRenderTests 와
/// 동일한 저수준 직접 인코딩 패턴 — mount/시뮬레이션 타이밍에 기대지 않는 결정론적 단일 파티클).
final class Scene3DParticleFogTests: XCTestCase {
    private func dotPkg(fogCombo: String = "") -> ScenePackage {
        let scene = """
        {"general":{"orthogonalprojection":{"width":200,"height":200}},
         "objects":[{"id":1,"particle":"particles/dot.json","origin":"100 100 0","scale":"1 1 1"}]}
        """
        let particle = #"{"renderer":[{"name":"sprite"}],"maxcount":1,"starttime":0,"material":"materials/dotmat.json"}"#
        let material = #"{"passes":[{"textures":["dot"]\#(fogCombo)}]}"#
        return ScenePackage.assemble([
            (name: "scene.json", data: Data(scene.utf8)),
            (name: "particles/dot.json", data: Data(particle.utf8)),
            (name: "materials/dotmat.json", data: Data(material.utf8)),
            (name: "materials/dot.tex", data: solidTex(255, 255, 255)),
        ])
    }

    // MARK: - 파스 단(combos.FOG → ParticleMaterial.foggy → GPUParticleSystem.foggy)

    func testFogComboZeroParsesToNonFoggy() throws {
        let mat = ParticleMaterial.parse(["passes": [["textures": ["dot"], "combos": ["FOG": 0]]]])
        XCTAssertFalse(mat.foggy, "combos.FOG:0 은 foggy=false 로 파스돼야 함")
    }

    func testFogComboAbsentDefaultsToFoggy() throws {
        let mat = ParticleMaterial.parse(["passes": [["textures": ["dot"]]]])
        XCTAssertTrue(mat.foggy, "FOG 콤보 미지정은 WE 기본값(1)대로 foggy=true 여야 함")
    }

    func testFoggyFlagFlowsIntoGPUParticleSystem() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pkgOn = dotPkg(fogCombo: #","combos":{"FOG":0}"#)
        let docOn = try SceneDocument.parse(package: pkgOn)
        let builtOff = SceneRenderer().buildParticles(doc: docOn, package: pkgOn, device: device)
        XCTAssertEqual(builtOff.first?.foggy, false)

        let pkgDefault = dotPkg()
        let docDefault = try SceneDocument.parse(package: pkgDefault)
        let builtDefault = SceneRenderer().buildParticles(doc: docDefault, package: pkgDefault, device: device)
        XCTAssertEqual(builtDefault.first?.foggy, true)
    }

    // MARK: - 파이프라인 컴파일(swift build 는 MSL 을 컴파일하지 않음 — 런타임 링크 확인 필수)

    func testFogPipelinesCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let renderer = SceneRenderer()
        XCTAssertNotNil(renderer.particle3DFogPipeline(additive: false, device: device))
        XCTAssertNotNil(renderer.particle3DFogPipeline(additive: true, device: device))
    }

    // MARK: - GPU 픽셀 판독: pf3d_fog 가 실제로 알베도를 감쇠시키는지 실증

    private func readCenterAlpha(_ texture: MTLTexture) -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        let cx = texture.width / 2, cy = texture.height / 2
        return bytes[(cy * texture.width + cx) * 4 + 3]   // bgra8Unorm: alpha = 4번째 바이트
    }

    /// 월드원점 파티클을 identity viewProj 로 화면중앙에 렌더 — plain(pf_main) 대비 pf3d_fog 가
    /// (a) 포그 완전활성(factor≡1) 이면 알파를 0 으로 죽이고 (b) 포그 비활성(w=0)이면 plain 과 동일해야 한다.
    func testPf3dFogAttenuatesAlphaWhenActiveAndMatchesPlainWhenInactive() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let pkg = dotPkg()
        let doc = try SceneDocument.parse(package: pkg)
        let renderer = SceneRenderer()
        let built = renderer.buildParticles(doc: doc, package: pkg, device: device)
        guard let sys = built.first,
              let plainPipe = renderer.particle3DPipeline(additive: false, device: device),
              let fogPipe = renderer.particle3DFogPipeline(additive: false, device: device)
        else { XCTFail("파티클 시스템/파이프라인 빌드 실패"); return }

        var particle = Particle()
        particle.pos = SIMD3<Float>(0, 0, 0)
        particle.size = 60
        particle.alpha = 1
        particle.color = SIMD3<Float>(1, 1, 1)
        // sys.foggy 는 이 저수준 렌더와 무관(파이프라인 선택은 테스트가 직접 지정) — sys 는 texture/verts 소스로만 사용.
        let verts = renderer.particle3DVertices([particle], sys, m: matrix_identity_float4x4,
                                                right: SIMD3<Float>(1, 0, 0), up: SIMD3<Float>(0, 1, 0))

        let width = 20, height = 20
        func render(pipe: MTLRenderPipelineState, fog: SceneRenderer.Particle3DFogUniform?) throws -> MTLTexture {
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
            enc.setRenderPipelineState(pipe)
            guard let vbuf = device.makeBuffer(bytes: verts, length: MemoryLayout<Float>.stride * verts.count) else {
                XCTFail("vbuf"); enc.endEncoding(); return tex
            }
            enc.setVertexBuffer(vbuf, offset: 0, index: 0)
            var vp = matrix_identity_float4x4
            enc.setVertexBytes(&vp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            enc.setFragmentTexture(sys.texture, index: 0)
            if var f = fog {
                enc.setFragmentBytes(&f, length: MemoryLayout<SceneRenderer.Particle3DFogUniform>.stride, index: 0)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count / 9)
            enc.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            return tex
        }

        let plainAlpha = readCenterAlpha(try render(pipe: plainPipe, fog: nil))
        XCTAssertGreaterThan(plainAlpha, 200, "대조군(pf_main)은 불투명해야 함 — 실측 \(plainAlpha)")

        // 포그 완전활성: fogDistanceColor.w>0.5(활성) + params=(start0,range=0.001,startDensity1,Δ0) →
        // factor = saturate(max(1,0)) = 1 상수 → alpha *= 1-1² = 0(완전 소거).
        let fullFog = SceneRenderer.Particle3DFogUniform(
            eye: SIMD4(0, 0, 5, 1),
            fogDistanceColor: SIMD4(0, 0, 0, 1),
            fogDistanceParams: SIMD4(0, 0.001, 1, 0),
            fogHeightColor: SIMD4(0, 0, 0, 0),
            fogHeightParams: SIMD4(0, 1, 0, 0))
        let foggedAlpha = readCenterAlpha(try render(pipe: fogPipe, fog: fullFog))
        XCTAssertEqual(foggedAlpha, 0, "완전 활성 포그는 알파를 0 으로 소거해야 함 — 실측 \(foggedAlpha)")

        // 포그 비활성(양 채널 w=0): 분기 전부 no-op → plain 과 동일해야 함.
        let noFog = SceneRenderer.Particle3DFogUniform(
            eye: SIMD4(0, 0, 5, 1),
            fogDistanceColor: SIMD4(0, 0, 0, 0),
            fogDistanceParams: SIMD4(0, 1, 0, 0),
            fogHeightColor: SIMD4(0, 0, 0, 0),
            fogHeightParams: SIMD4(0, 1, 0, 0))
        let inactiveAlpha = readCenterAlpha(try render(pipe: fogPipe, fog: noFog))
        XCTAssertEqual(inactiveAlpha, plainAlpha, "비활성 포그 유니폼은 plain 파이프라인과 동일해야 함")
    }
}
