import XCTest
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

/// H3(핫픽스, 웨이브 W0b): F790(spriteTrailStretch)의 speed×length 클램프는 length 부재(항등=1) +
/// 큰 가속/속도의 씬에서 순식간에 maxlength 에 포화된다 — 스트레치의 speed 의존성이 관측 불가해지고
/// (advisor 검증: spriteTrailStretch(10) == spriteTrailStretch(1000) for maxLength 6), 그 항등 배율이
/// sizePx(파티클 자체 지름, 수십~수백px)에 그대로 곱해져 장축이 화면 폭의 상당 부분을 덮는 불투명
/// 블록이 된다. 실물 회귀: 3489263099·3465215190 공유 rain_on_the_glass 프리셋(워크샵 2446129945,
/// maxlength=6, length 부재, sizerandom 70-150, gravity -400 로 급가속) — 씬 창밖 도시 전체가 흰
/// 스미어에 가려짐(구 베이스라인 95fad7a 는 리본 기반 구현으로 얇은 대각선 스트릭, 명백한 회귀).
///
/// 수정: SceneRendererFrameEncoder.particleVertices 의 appendSpriteTrailQuad 에 stretchGuard 안전판
/// 추가 — spriteTrailStretch 공식/기본값 자체는 보존(코퍼스 123건 재검 없이 재유도하지 않음 — Wave2
/// 범위), 결과물(장축 반폭)만 "원본 반폭 이상 보장 + 씬 폭 대비 관대한 상한(1.5%)"으로 단조감소 클램프.
/// 이미 작은 stretch(정상 범위)는 상한 미도달로 무영향 — 기존 검증 씬에 새 회귀를 만들 수 없다.
final class ParticleSpriteTrailStretchGuardTests: XCTestCase {
    /// 씬 1000×200, 파티클 오브젝트 origin=중앙. renderer=spritetrail(maxlength=6, length/minlength 부재)
    /// — rain_on_the_glass 실물 구성과 동형(길이 키만 부재, maxlength 만 명시).
    private func trailPkg(maxLength: Float = 6) -> ScenePackage {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1000,"height":200}},
         "objects":[{"id":1,"particle":"particles/drop.json","origin":"500 100 0","scale":"1 1 1"}]}
        """
        let particle = #"{"renderer":[{"name":"spritetrail","maxlength":\#(maxLength)}],"maxcount":1,"starttime":0,"material":"materials/dropmat.json"}"#
        let material = #"{"passes":[{"textures":["drop"]}]}"#
        return ScenePackage.assemble([
            (name: "scene.json", data: Data(scene.utf8)),
            (name: "particles/drop.json", data: Data(particle.utf8)),
            (name: "materials/dropmat.json", data: Data(material.utf8)),
            (name: "materials/drop.tex", data: solidTex(255, 255, 255)),
        ])
    }

    private func readRGBA(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }

    /// 열 c(픽셀 x)에 불투명 텍셀(alpha>0)이 하나라도 있으면 true(bgra8Unorm — alpha 는 4번째 바이트).
    private func columnOpaque(_ rgba: [UInt8], width: Int, height: Int, col: Int) -> Bool {
        guard col >= 0, col < width else { return false }
        for row in 0..<height {
            if rgba[(row * width + col) * 4 + 3] > 0 { return true }
        }
        return false
    }

    /// 좌우 대칭으로 불투명 열의 최대 반경(중심으로부터 열 개수) — 장축 스팬 측정.
    private func opaqueHalfSpan(_ rgba: [UInt8], width: Int, height: Int, center: Int) -> Int {
        var maxR = 0
        for c in 0..<width where columnOpaque(rgba, width: width, height: height, col: c) {
            maxR = max(maxR, abs(c - center))
        }
        return maxR
    }

    /// 결함 실증 + 수정 검증: 반지름 sizePx=100(가상 raindrop), 수평 고속(-800px/s) 이동, maxlength=6.
    /// 가드 없으면(원본 F790 공식만) 장축 반폭 = sizePx*0.5*min(speed,maxLength) = 100*0.5*6 = 300px
    /// (프레임 폭 1000 의 60% — 창밖 전체를 가리는 실물 회귀와 동형 스케일). 가드 적용 시 sizePx*0.5(=50,
    /// 원본 반폭)를 밑변으로 보장하되 씬 폭 1.5%(=15px) 상한과의 max 이므로 50 근방까지만 허용 —
    /// 최소 3배 이상 축소되어야 한다(회귀 이전 얇은 스트릭 스케일 복귀).
    func testDegenerateStretchIsBoundedNotSaturatedFullFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let p = trailPkg(maxLength: 6)
        let doc = try SceneDocument.parse(package: p)
        let renderer = SceneRenderer()
        renderer.projW = 1000; renderer.projH = 200
        let built = renderer.buildParticles(doc: doc, package: p, device: device)
        guard var sys = built.first, case .spriteTrail(let maxLen, _, _) = sys.def.renderer, maxLen == 6,
              let pipe = renderer.particlePipeline(additive: false, device: device) else {
            XCTFail("파티클 시스템/파이프라인 빌드 실패 또는 spritetrail 파스 실패")
            return
        }
        renderer.translucentPipeline = pipe

        var particle = Particle()
        particle.pos = SIMD3<Float>(0, 0, 0)          // sys.origin(500,100) = 월드 중앙
        particle.size = 100
        particle.vel = SIMD3<Float>(-800, 0, 0)        // 수평 고속(장축이 열 방향에 정렬 — F790 angleOverride)
        particle.alpha = 1
        particle.color = SIMD3<Float>(1, 1, 1)

        let width = 1000, height = 200
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        let enc = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: rpd))
        var camOffset = SIMD2<Float>(0, 0)
        var aspectScale = SIMD2<Float>(1, 1)
        renderer.encodeParticle(sys, snapshot: [particle], into: enc, device: device,
                                camOffset: &camOffset, aspectScale: &aspectScale)
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        let rgba = readRGBA(tex)

        XCTAssertTrue(columnOpaque(rgba, width: width, height: height, col: 500),
                     "중심 열은 항상 불투명(파티클 자체가 그려지지 않으면 판정 무의미)")

        let halfSpan = opaqueHalfSpan(rgba, width: width, height: height, center: 500)
        // 무가드 이론값 300px(프레임의 60%) — 가드는 이를 원본 반폭(50px) 근방으로 억제해야 한다.
        // 여유를 두어 150px(프레임의 15%, 무가드의 절반 미만) 미만을 요구 — 3489263099 실물 회귀 스케일
        // (창 폭의 30%+ 스미어) 재발을 잡는 표적 임계.
        XCTAssertLessThan(halfSpan, 150,
                          "spritetrail 장축이 씬 폭의 15%(150px)를 넘으면 F790 포화 회귀 재발 — 실측 \(halfSpan)px")
        // 하한 가드: 원본 반폭(50px) 밑으로 짓눌러 스트릭 자체를 없애면 안 됨(무신장 폴백과 구분).
        XCTAssertGreaterThanOrEqual(halfSpan, 40,
                                    "가드가 과하게 짓눌러 원본 크기(반폭 50px) 미만이면 스트릭이 사실상 사라짐 — 실측 \(halfSpan)px")
    }

    /// 무회귀 가드: maxlength 가 이미 작아 stretch≤1(회전만, 예: Cherry_Blossoms_2 maxlength=1) 인
    /// 경우 stretchGuard 는 stretch>1 조건에서 조기 반환해 원본 공식과 완전히 동일해야 한다(단조감소만 —
    /// 이미 작은 값은 무변형).
    func testAlreadySmallStretchIsUnaffected() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let p = trailPkg(maxLength: 1)   // Cherry_Blossoms_2 실물과 동형(maxlength=1, length 부재)
        let doc = try SceneDocument.parse(package: p)
        let renderer = SceneRenderer()
        renderer.projW = 1000; renderer.projH = 200
        let built = renderer.buildParticles(doc: doc, package: p, device: device)
        guard var sys = built.first, let pipe = renderer.particlePipeline(additive: false, device: device) else {
            XCTFail("빌드 실패"); return
        }
        renderer.translucentPipeline = pipe

        var particle = Particle()
        particle.pos = SIMD3<Float>(0, 0, 0)
        particle.size = 40
        particle.vel = SIMD3<Float>(-800, 0, 0)   // 고속이어도 maxlength=1 이 이미 무신장(회전만) 규정
        particle.alpha = 1
        particle.color = SIMD3<Float>(1, 1, 1)

        let width = 1000, height = 200
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]; desc.storageMode = .shared
        let tex = try XCTUnwrap(device.makeTexture(descriptor: desc))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        let enc = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: rpd))
        var camOffset = SIMD2<Float>(0, 0)
        var aspectScale = SIMD2<Float>(1, 1)
        renderer.encodeParticle(sys, snapshot: [particle], into: enc, device: device,
                                camOffset: &camOffset, aspectScale: &aspectScale)
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        let rgba = readRGBA(tex)

        let halfSpan = opaqueHalfSpan(rgba, width: width, height: height, center: 500)
        // stretch=min(800,1)=1 → hw=sizePx*0.5*1=20px(반폭). 가드 상한(원본 반폭 20 vs 씬폭 1.5%=15 중 큰
        // 쪽=20)과 정확히 일치 — 클램프가 걸리지 않아야(<=20 근방, 여유 25).
        XCTAssertLessThanOrEqual(halfSpan, 25,
                                 "maxlength=1(이미 무신장) 케이스는 가드가 개입하면 안 됨 — 실측 \(halfSpan)px")
    }
}
