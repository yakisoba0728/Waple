import XCTest
import Metal
@testable import WapleRender

final class ParticleShadersTests: XCTestCase {
    func testCompilesMSL() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let lib = try device.makeLibrary(source: ParticleShaders.source, options: nil)
        XCTAssertNotNil(lib.makeFunction(name: "pv_main"))
        XCTAssertNotNil(lib.makeFunction(name: "pf_main"))
    }

    /// F200 ABI: pv_main은 레이어(QuadShaders.v_main)와 같은 5-buffer 레이아웃을 유지한다.
    /// 현재 CPU는 root depth를 미리 적용한 offset + 단위 depth를 싣지만, 셰이더 계약을 축소하면
    /// 기존/대체 호출자가 authored depth를 싣는 경로와 ABI가 갈라진다.
    func testVertexShaderWeightsCameraOffsetByParallaxDepth() {
        XCTAssertTrue(ParticleShaders.source.contains("cameraOffset * parallaxDepth"),
                     "pv_main 이 레이어 v_main 과 동일한 cameraOffset×parallaxDepth ABI를 유지해야(F200)")
    }

    /// 파이프라인이 확장된 5-버퍼 시그니처(v,cameraOffset,parallaxDepth,aspectScale,shakeOffset)로도
    /// 정상 빌드되는지(회귀: 버퍼 인덱스 재배치가 컴파일/파이프라인 생성 자체를 깨지 않았는지).
    func testPipelineBuildsWithParallaxDepthBuffer() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let lib = try device.makeLibrary(source: ParticleShaders.source, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "pv_main")
        pd.fragmentFunction = lib.makeFunction(name: "pf_main")
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        XCTAssertNoThrow(try device.makeRenderPipelineState(descriptor: pd))
    }

    // MARK: - [2026-08-21] SPRITESHEETBLEND 크로스페이드 (docs/re/sprite-occlusion.md §11.3)

    /// **스트라이드가 두 곳에 박히지 않는다**는 것을 잠근다. 종전엔 MSL 문자열의 `vid * 8` 과
    /// `SceneRendererFrameEncoder` 의 `verts.count / 8` 이 **각자 리터럴**이라 반쪽만 고치면
    /// 화면이 통째로 깨지는데 컴파일러가 아무 말도 안 했다. 이제 둘 다 이 상수를 본다.
    func testVertexStrideIsInterpolatedFromTheSingleConstant() {
        XCTAssertEqual(ParticleShaders.vertexFloats2D, 12)
        XCTAssertEqual(ParticleShaders.vertexFloats3D, 13)
        XCTAssertTrue(ParticleShaders.source.contains("uint b = vid * \(ParticleShaders.vertexFloats2D);"),
                      "pv_main 의 스트라이드가 상수와 어긋났다")
        XCTAssertTrue(ParticleShaders.source.contains("uint b = vid * \(ParticleShaders.vertexFloats3D);"),
                      "pv3d_* 의 스트라이드가 상수와 어긋났다")
        // 리터럴 사본이 되살아나는 것을 직접 막는다.
        XCTAssertFalse(ParticleShaders.source.contains("uint b = vid * 8;"))
        XCTAssertFalse(ParticleShaders.source.contains("uint b = vid * 9;"))
    }

    /// **straight-alpha 에서 mix 하고 그 뒤에 premultiply** — WE `genericparticle.frag:73-77`.
    /// premultiply 뒤에 섞으면(= 같은 쿼드를 두 번 그리기) 다른 식이 된다(§11.2 의 반례).
    /// 세 프래그먼트가 다 섞어야 한다: `pf_main`(2D·3D 비포그 공용) · `pf3d_fog` · `pf_refract`.
    /// 하나라도 빠지면 그 경로만 크로스페이드가 사라져 화면이 갈린다.
    func testAllParticleFragmentsCrossfadeTheAlbedo() {
        let src = ParticleShaders.source
        XCTAssertTrue(src.contains("float4 t = mix(tex.sample(s, in.uv), tex.sample(s, in.uv2), in.blend);"),
                      "pf_main/pf3d_fog 가 두 프레임을 mix 해야 한다")
        XCTAssertTrue(src.contains("float4 t = mix(albedoTex.sample(s, in.uv), albedoTex.sample(s, in.uv2), in.blend);"),
                      "pf_refract 도 pv_main 을 공유하므로 같이 섞어야 한다")
        // 노멀맵은 **안** 섞는다 — WE 는 g_Texture1 을 v_TexCoord.xy 한 곳에서만 뜬다.
        XCTAssertTrue(src.contains("float4 nraw = normalTex.sample(s, in.uv);"))
        XCTAssertFalse(src.contains("normalTex.sample(s, in.uv2)"))
        // 프리멀티플라이는 mix **뒤**다(= A 를 곱하는 자리가 mix 다음).
        let mixIdx = src.range(of: "mix(tex.sample")!.lowerBound
        let premulIdx = src.range(of: "t.rgb * in.color.rgb * A * overbright")!.lowerBound
        XCTAssertLessThan(mixIdx, premulIdx, "straight 로 섞고 그 다음에 premultiply 해야 한다")
    }

    /// `nearestSource`(NoInterpolation 변형)는 `source` 의 문자열 치환이므로 크로스페이드가
    /// 자동으로 따라온다 — 두 소스가 갈리지 않는지 확인한다.
    func testNearestVariantKeepsTheCrossfade() {
        XCTAssertTrue(ParticleShaders.nearestSource.contains("in.uv2"))
        XCTAssertTrue(ParticleShaders.nearestSource.contains("filter::nearest"))
        XCTAssertFalse(ParticleShaders.nearestSource.contains("filter::linear, mip_filter::linear, address::clamp_to_edge"))
    }

    /// 세 정점 셰이더가 **꼬리 4 슬롯을 같은 뜻으로** 읽는지. 2D 12f 의 8·9·10, 3D 13f 의 9·10·11.
    func testVertexShadersReadTheCrossfadeTail() {
        let src = ParticleShaders.source
        XCTAssertTrue(src.contains("o.uv2 = float2(v[b + 8], v[b + 9]); o.blend = v[b + 10];"),
                      "2D(pv_main) 꼬리 슬롯")
        XCTAssertEqual(src.components(separatedBy: "o.uv2 = float2(v[b + 9], v[b + 10]); o.blend = v[b + 11];").count - 1, 2,
                       "3D 정점 셰이더 둘(pv3d_main·pv3d_fog_main)이 같은 꼬리를 읽어야 한다")
    }

    /// 크로스페이드 배선 뒤에도 MSL 이 실제로 컴파일되고 파이프라인이 서는지(3D 포그·굴절 포함).
    /// 리눅스는 타입체크만 하므로 이 단언의 판정자는 macOS 다.
    func testAllParticlePipelineFunctionsStillCompile() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let lib = try device.makeLibrary(source: ParticleShaders.source, options: nil)
        for name in ["pv_main", "pv3d_main", "pv3d_fog_main", "pf_main", "pf3d_fog", "pf_refract"] {
            XCTAssertNotNil(lib.makeFunction(name: name), "\(name) 가 사라졌다")
        }
        let near = try device.makeLibrary(source: ParticleShaders.nearestSource, options: nil)
        XCTAssertNotNil(near.makeFunction(name: "pf_main"))
    }
}
