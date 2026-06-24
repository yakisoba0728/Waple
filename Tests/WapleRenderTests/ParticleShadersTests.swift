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
}
