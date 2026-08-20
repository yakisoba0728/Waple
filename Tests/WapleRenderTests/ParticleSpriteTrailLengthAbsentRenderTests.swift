import XCTest
import Metal
import simd
@testable import WapleCore
@testable import WapleRender

/// H3(핫픽스, 웨이브 W0b): F790(spriteTrailStretch)의 speed×length 클램프는 length 부재 시
/// 종전 "곱 항등 1"(mul=1 → s=speed) 폴백으로 씬의 전형적 속도(수백 px/s)가 그대로
/// [minlength,maxlength] 로 밀려 들어가 사실상 항상 maxlength 로 포화됐다 — 신장의 speed
/// 의존성 자체가 관측 불가(spriteTrailStretch(10) == spriteTrailStretch(1000)). 실물 회귀:
/// 3489263099·3465215190 공유 rain_on_the_glass 프리셋(워크샵 2446129945, maxlength=6, length
/// 부재, sizerandom 70-150, gravity -400 로 급가속) — 씬 창밖 도시 전체가 흰 스미어에 가려짐
/// (구 베이스라인 95fad7a 는 리본 기반 구현으로 얇은 대각선 스트릭, 명백한 회귀).
///
/// 수정(루트코즈): 결과물을 사후 클램프하는 안전판이 아니라, 진단된 원인 지점
/// (RendererKind.spriteTrailStretch, Sources/WapleCore/ParticleSystem.swift) 에서 length 가
/// 부재(≤0)면 신장 산정 자체를 하지 않고 항등(1, WE 공식 문서의 "1/1/1=무신장 회전만" 케이스)을
/// 반환하도록 정정 — length 를 실제로 저작한 시스템(예: ember length=0.007)은 완전히 무영향으로
/// 둔다(population 자체가 다르다: length 부재 = 신장 미정의, length 저작 = speed 의존 신장 의도).
/// 이 파일은 그 정정이 렌더 경로(SceneRendererFrameEncoder.appendSpriteTrailQuad) 까지 end-to-end
/// 로 반영되는지 GPU 렌더+픽셀 판독으로 검증한다.
final class ParticleSpriteTrailLengthAbsentRenderTests: XCTestCase {
    private struct SpriteTrailKeys {
        var length: Float?
        var minLength: Float?
        var maxLength: Float?
    }

    /// 씬 1000×200, 파티클 오브젝트 origin=중앙. renderer=spritetrail 키 조합은 `keys` 로 지정
    /// (nil 은 JSON 미저작 — 실물 코퍼스의 "부재" 를 그대로 재현).
    private func trailPkg(_ keys: SpriteTrailKeys) -> ScenePackage {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1000,"height":200}},
         "objects":[{"id":1,"particle":"particles/drop.json","origin":"500 100 0","scale":"1 1 1"}]}
        """
        var rendererFields = [String: Any]()
        rendererFields["name"] = "spritetrail"
        if let l = keys.length { rendererFields["length"] = l }
        if let mn = keys.minLength { rendererFields["minlength"] = mn }
        if let mx = keys.maxLength { rendererFields["maxlength"] = mx }
        let rendererJSON = try! JSONSerialization.data(withJSONObject: [rendererFields])
        let particle = """
        {"renderer":\(String(data: rendererJSON, encoding: .utf8)!),"maxcount":1,"starttime":0,\
        "material":"materials/dropmat.json"}
        """
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

    private func renderHalfSpan(keys: SpriteTrailKeys, sizePx: Float, speedPxPerSec: Float) throws -> Int? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let p = trailPkg(keys)
        let doc = try SceneDocument.parse(package: p)
        let renderer = SceneRenderer()
        renderer.projW = 1000; renderer.projH = 200
        let built = renderer.buildParticles(doc: doc, package: p, device: device)
        guard let sys = built.first, let pipe = renderer.particlePipeline(additive: false, device: device) else {
            XCTFail("파티클 시스템/파이프라인 빌드 실패"); return nil
        }
        renderer.translucentPipeline = pipe

        var particle = Particle()
        particle.pos = SIMD3<Float>(0, 0, 0)          // sys.origin(500,100) = 월드 중앙
        particle.size = sizePx
        particle.vel = SIMD3<Float>(-speedPxPerSec, 0, 0)  // 수평(장축이 열 방향에 정렬)
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
        return opaqueHalfSpan(rgba, width: width, height: height, center: 500)
    }

    /// rain_on_the_glass 실물 구성(length 부재, maxlength=6)을 sizePx=100, 두 속도로 렌더한다.
    ///
    /// **[2026-08-20] H3 를 되돌리고 WE 계약으로 바꾼다.** H3 는 "length 부재 = 무신장" 을
    /// 단언했는데 전제가 틀렸다 — 주입기 0x1401c0af0 이 부재에도 `length` 0.05(0x1401c0b55)를
    /// 심으므로 신장은 언제나 정의된다. 그리고 WE 가 셰이더 원문을 동봉한다
    /// (`assets/shaders/common_particles.h`):
    ///
    /// ```glsl
    /// up = localVelocity * max(g_RenderVar0.z, min(trailLength * g_RenderVar0.x, g_RenderVar0.y));
    /// // ComputeParticlePosition: positionAndSize.w * up * (uvs.y-0.5) * textureRatio
    /// ```
    /// `g_RenderVar0 = (length, maxlength, minlength)` 이고 두 축 모두 size 가 곱해지므로
    /// **반폭 = sizePx · 0.5 · clamp(speed·length, minlength, maxlength)** 다.
    ///
    /// 그래서 기대값이 손계산으로 떨어진다(sizePx 100 · length 0.05 · maxlength 6 · minlength 0):
    ///   speed  10 → clamp(0.5, 0, 6) = 0.5 → 100·0.5·0.5  =  **25px**  (속도가 낮으면 오히려 납작해진다)
    ///   speed 800 → clamp(40,  0, 6) = 6   → 100·0.5·6    = **300px**  (maxlength 포화)
    ///
    /// H3 가 관측한 흰 스미어의 실제 원인은 그 직전 폴백 `mul = 1` → `s = speed`(수백)였다.
    /// `s = speed·0.05` 는 그보다 20배 작지만, `maxlength = 6` 인 이 프리셋은 speed 120 부터
    /// 포화하므로 **실물도 300px 를 그린다** — H3 가 "회귀" 로 판정한 비교 대상은 WE 가 아니라
    /// Waple 의 옛 리본 구현이었다. 근거가 바이트(주입기)와 WE 동봉 셰이더 원문 둘이므로
    /// 그 관측 판단보다 우선한다. **골든 재검토 대상이다.**
    ///
    /// `minlength` 를 저작한 씬(rainfall.json 의 `minlength: 5`)이 바로 저속 납작해짐을 막는
    /// 장치다 — 그 키가 왜 존재하는지도 이 계약이 설명한다.
    func testLengthAbsentStretchFollowsShaderClamp() throws {
        func span(_ speed: Float) throws -> Float? {
            try renderHalfSpan(keys: SpriteTrailKeys(length: nil, minLength: nil, maxLength: 6),
                               sizePx: 100, speedPxPerSec: speed)
        }
        guard let slow = try span(10), let fast = try span(800) else { throw XCTSkip("no Metal device") }
        XCTAssertEqual(slow, 25, accuracy: 6,
                       "speed 10 → clamp(0.5,0,6)=0.5 → 100·0.5·0.5 = 25px — 실측 \(slow)px")
        XCTAssertEqual(fast, 300, accuracy: 12,
                       "speed 800 → maxlength 6 포화 → 100·0.5·6 = 300px — 실측 \(fast)px")
        // 신장이 speed 에 **의존한다**는 것 자체를 못박는다. H3 는 정확히 이 의존성을 없앴다.
        XCTAssertNotEqual(slow, fast,
                          "length 부재에도 신장은 speed 의존이다 — slow=\(slow)px fast=\(fast)px")
    }

    /// 대조군: length 가 실제로 저작된 시스템(ember 류)은 population 이 달라 이 수정의 영향을 받지
    /// 않는다 — speed 에 비례해 신장이 그대로 성립해야 한다(root-cause 수정이 length 부재만 좁혀
    /// 잡았는지 end-to-end 로 확인).
    func testLengthAuthoredStillStretchesWithSpeed() throws {
        // sizePx=40(half=20), length=0.1, maxlength=50(비클램프 영역) — speed=100 이면
        // stretch=speed*length=10(공식 그대로) → hw=20*10=200px, 원본 반폭(20px) 대비 대폭 신장.
        guard let halfSpan = try renderHalfSpan(keys: SpriteTrailKeys(length: 0.1, minLength: nil, maxLength: 50),
                                                sizePx: 40, speedPxPerSec: 100) else {
            throw XCTSkip("no Metal device")
        }
        XCTAssertGreaterThan(halfSpan, 150,
                             "length 저작 씬은 speed 신장이 그대로 성립해야 함(무영향 population) — 실측 \(halfSpan)px")
    }
}
