import XCTest
import Metal
@testable import WapleRender

/// 3D 메시 MSL 이 mv_main/mf_main 으로 실제 컴파일되고 뎁스 붙은 파이프라인이 생성되는지(런타임).
final class Mesh3DShadersTests: XCTestCase {
    func testMeshShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let lib = try device.makeLibrary(source: Mesh3DShaders.source, options: nil)
        XCTAssertNotNil(lib.makeFunction(name: "mv_main"))
        XCTAssertNotNil(lib.makeFunction(name: "mv_skin"))
        XCTAssertNotNil(lib.makeFunction(name: "mf_main"))
    }

    func testMeshShaderCarriesWorldSpacePBRInputs() {
        XCTAssertTrue(Mesh3DShaders.source.contains("worldPos"))
        XCTAssertTrue(Mesh3DShaders.source.contains("worldNormal"))
        XCTAssertTrue(Mesh3DShaders.source.contains("Distribution_GGX"))
        XCTAssertTrue(Mesh3DShaders.source.contains("cameraEye"))
        XCTAssertTrue(Mesh3DShaders.source.contains("roughness"))
        XCTAssertTrue(Mesh3DShaders.source.contains("metallic"))
    }

    func testMeshPipelineWithDepthAttachment() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let lib = try device.makeLibrary(source: Mesh3DShaders.source, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "mv_main")
        pd.fragmentFunction = lib.makeFunction(name: "mf_main")
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        pd.depthAttachmentPixelFormat = .depth32Float
        XCTAssertNoThrow(try device.makeRenderPipelineState(descriptor: pd))

        pd.vertexFunction = lib.makeFunction(name: "mv_skin")
        XCTAssertNoThrow(try device.makeRenderPipelineState(descriptor: pd))
    }
}
