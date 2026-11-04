import XCTest
@testable import WapleRender

final class TextTileGeometryTests: XCTestCase {
    func testPerspectiveTileBoundaryStaysOnOriginalHomogeneousPlane() {
        // Plane: clip x=2u-1, clip y=1-2v, w=1+u. These independently specified
        // projected corners distinguish homogeneous subdivision from NDC interpolation.
        let vertices: [SIMD4<Float>] = [
            SIMD4(-1, 1, 0, 0), SIMD4(0.5, 0.5, 1, 0), SIMD4(-1, -1, 0, 1),
            SIMD4(0.5, 0.5, 1, 0), SIMD4(0.5, -0.5, 1, 1), SIMD4(-1, -1, 0, 1)
        ]
        let result = TextTileGeometry.crop(vertices: vertices, projectiveDepth: SIMD4(1, 0, 1, 1),
                                           rect: SIMD4(0.5, 0, 1, 1))
        XCTAssertFalse(result.vertices.isEmpty)
        XCTAssertEqual(result.vertices.count % 3, 0)
        XCTAssertEqual(result.projectiveDepth, SIMD4(0.5, 0, 1.5, 1))
        for value in result.vertices {
            XCTAssertGreaterThanOrEqual(value.z, -0.0001)
            XCTAssertLessThanOrEqual(value.z, 1.0001)
            if abs(value.z) < 0.0001 {
                XCTAssertEqual(value.x, 0, accuracy: 0.0001)
            }
            if abs(value.z - 1) < 0.0001 {
                XCTAssertEqual(value.x, 0.5, accuracy: 0.0001)
            }
        }
    }

    func testFilteringGutterRemapsTextureUVWithoutChangingScreenGeometry() {
        let vertices: [SIMD4<Float>] = [SIMD4(-1, 1, 0, 0), SIMD4(1, 1, 1, 0), SIMD4(-1, -1, 0, 1)]
        let result = TextTileGeometry.crop(vertices: vertices, projectiveDepth: SIMD4(0, 0, 1, 0),
                                           rect: SIMD4(0, 0, 1, 1), textureRect: SIMD4(0.1, 0.2, 0.9, 0.8))
        XCTAssertEqual(result.vertices[0], SIMD4(-1, 1, 0.1, 0.2))
        XCTAssertEqual(result.vertices[1].z, 0.9, accuracy: 0.0001)
        XCTAssertEqual(result.vertices[2].w, 0.8, accuracy: 0.0001)
    }
}
