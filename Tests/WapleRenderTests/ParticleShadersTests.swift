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

    /// F200 배치 P: pv_main 이 레이어(QuadShaders.v_main)와 동형으로 cameraOffset 을 parallaxDepth 로
    /// 가중해야 한다 — 수정 전엔 곱셈 없이 (pos + cameraOffset + shakeOffset) 만 있어 이 assert 가 RED.
    func testVertexShaderWeightsCameraOffsetByParallaxDepth() {
        XCTAssertTrue(ParticleShaders.source.contains("cameraOffset * parallaxDepth"),
                     "pv_main 이 레이어 v_main 과 동일하게 cameraOffset×parallaxDepth 를 소비해야(F200)")
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
}
