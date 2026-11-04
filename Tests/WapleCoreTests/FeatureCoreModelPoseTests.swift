import XCTest
import simd
@testable import WapleCore

final class FeatureCoreModelPoseTests: XCTestCase {
    func testExtendedSkinPackingPreservesTangentHandednessAndLightmapUV() {
        let v = Model3D.Vertex(position: SIMD3(1, 2, 3), normal: SIMD3(0, 1, 0),
                               tangent: SIMD4(1, 0, 0, -1), uv: SIMD2(0.25, 0.5),
                               boneIndices: .zero, weights: SIMD4(1, 0, 0, 0), uv1: SIMD2(0.75, 1))
        let mesh = Model3D.Mesh(material: "m", boundsMin: .zero, boundsMax: .zero,
                                skinned: true, vertices: [v], indices: [0])
        let rotation = simd_float4x4(SIMD4(0, 1, 0, 0), SIMD4(-1, 0, 0, 0),
                                     SIMD4(0, 0, 1, 0), SIMD4(10, 0, 0, 1))
        XCTAssertEqual(Model3DPose.cpuSkinnedPacked(mesh: mesh, matrices: [rotation]),
                       [8, 1, 3, -1, 0, 0, 0.25, 0.5])
        XCTAssertEqual(Model3DPose.cpuSkinnedPacked(mesh: mesh, matrices: [rotation],
                                                   includeTangents: true, includeUV1: true),
                       [8, 1, 3, -1, 0, 0, 0, 1, 0, -1, 0.25, 0.5, 0.75, 1])
    }

    func testModelLayerCascadeAndNamedAttachmentUseAnimatedBoneWorld() throws {
        var model = Model3D(meshes: [])
        model.bones = [.init(name: "root", parent: -1, bind: matrix_identity_float4x4, properties: "")]
        func animation(_ x: Float, _ y: Float) -> Model3D.Animation {
            let key = Model3D.Key(position: SIMD3(x, y, 0), angles: .zero, scale: SIMD3(repeating: 1))
            return Model3D.Animation(name: "clip", mode: "single", fps: 30, lengthFrames: 1, tracks: [[key, key]])
        }
        model.animations = [animation(10, 0), animation(0, 20)]
        var local = matrix_identity_float4x4
        local.columns.3 = SIMD4(1, 2, 0, 1)
        model.attachments = [.init(name: "hand", bone: 0, local: local)]
        let layers: [(anim: Int, additive: Bool, weight: Float, rate: Float)] =
            [(0, false, 1, 1), (1, false, 0.5, 1)]
        let matrices = Model3DPose.blendedSkinMatrices(model: model, layers: layers, time: 0)
        XCTAssertEqual(matrices[0].columns.3, SIMD4(5, 10, 0, 1))
        let attachment = try XCTUnwrap(Model3DPose.attachmentFrame(model: model, name: "hand", layers: layers, time: 0))
        XCTAssertEqual(attachment.columns.3, SIMD4(6, 12, 0, 1))
        XCTAssertEqual(Model3DPose.attachmentFrame(model: model, name: "hand", layers: [], time: 1)?.columns.3,
                       SIMD4(1, 2, 0, 1))
        XCTAssertNil(Model3DPose.attachmentFrame(model: model, name: "missing", layers: layers, time: 0))
        var override = matrix_identity_float4x4
        override.columns.3 = SIMD4(30, 40, 0, 1)
        XCTAssertEqual(Model3DPose.attachmentFrame(model: model, name: "hand", layers: [], time: 0,
                                                   localOverrides: [0: override])?.columns.3, SIMD4(31, 42, 0, 1))
    }
}
