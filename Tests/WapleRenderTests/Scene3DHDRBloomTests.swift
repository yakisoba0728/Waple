import XCTest
import Metal
@testable import WapleRender

/// 3D-HDR bloom(코퍼스 hdr∩bloom 3D 4씬: 3662790108/3589454154/3509243656/3470948192 골든).
/// 종전 hdrActive 의 `!is3D` 게이트가 3D HDR 씬을 HDRBloomPass(2D용 기존)에 미도달시켜
/// 유일 HDR 골든(3470948192, 3D)의 지상검증이 원리적으로 불가했다.
final class Scene3DHDRBloomTests: XCTestCase {

    // MARK: 게이트 — 3D HDR 씬도 HDR bloom 경로 활성(red: `sceneIsHDR && !is3D` 로 false)
    func test3DHDRSceneActivatesHDRPath() {
        let r = SceneRenderer()
        r.sceneIsHDR = true
        r.is3D = true
        XCTAssertTrue(r.hdrActive, "3D HDR 씬도 HDR bloom/클램프 경로 도달해야 골든 대조 가능")
    }

    // MARK: 비-HDR 3D / 2D HDR 회귀 없음(격리 가드)
    func testNonHDR3DAndHDR2DUnchanged() {
        let r = SceneRenderer()
        r.sceneIsHDR = false; r.is3D = true
        XCTAssertFalse(r.hdrActive, "비-HDR 3D 는 여전히 LDR 경로")
        r.sceneIsHDR = true; r.is3D = false
        XCTAssertTrue(r.hdrActive, "2D HDR 무회귀")
    }

    // MARK: 3D 메시/파티클 파이프라인이 HDR 씬에서 float(rgba16Float) 타깃으로 빌드(포맷불일치 크래시 방지)
    func test3DPipelinesBuildForFloatHDRTarget() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let r = SceneRenderer()
        r.sceneIsHDR = true                                   // accPixelFormat → rgba16Float
        XCTAssertEqual(r.accPixelFormat, .rgba16Float)
        let lib = try device.makeLibrary(source: Mesh3DShaders.source, options: nil)
        // mesh(billboard 공용) + 3D 파티클 파이프라인이 float 타깃으로 컴파일되어야 encode3D 가 acc(float)로 그린다.
        XCTAssertNotNil(r.mesh3DPipeline(lib: lib, vertex: "mv_main", additive: false, device: device),
                        "HDR 3D mesh 파이프라인이 float 타깃으로 빌드")
        XCTAssertNotNil(r.mesh3DPipeline(lib: lib, vertex: "mv_skin", additive: true, device: device))
        XCTAssertNotNil(r.particle3DPipeline(additive: true, device: device),
                        "HDR 3D 파티클 파이프라인이 float 타깃으로 빌드")
    }
}
