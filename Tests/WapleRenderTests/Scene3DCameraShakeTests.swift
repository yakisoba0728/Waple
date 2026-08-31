import XCTest
import simd
@testable import WapleCore
@testable import WapleRender

/// 3D shake는 clip-space 병진이 아니라 eye/center를 같은 월드 델타로 이동시킨다.
final class Scene3DCameraShakeTests: XCTestCase {

    func testPerspectiveShakeMovesCameraInWorldAndRemainsDepthDependent() throws {
        let renderer = SceneRenderer()
        renderer.camera3D = SceneCamera3D(
            eye: Vec3(x: 0, y: 0, z: 5),
            center: Vec3(x: 0, y: 0, z: 0),
            up: Vec3(x: 0, y: 1, z: 0),
            fov: 60, nearZ: 0.1, farZ: 100)
        renderer.cameraShakeEnabled = true
        renderer.cameraShakeSpeed = 1
        renderer.cameraShakeAmplitude = 10
        renderer.cameraShakeRoughness = 1

        let frame = try XCTUnwrap(renderer.resolveCamera3DFrame(at: 0))
        XCTAssertEqual(frame.eye, SIMD3<Float>(1, 0, 5))
        XCTAssertEqual(frame.center, SIMD3<Float>(1, 0, 0), "eye와 center에 같은 월드 델타")

        let view = Scene3DMath.lookAt(eye: frame.eye, center: frame.center, up: frame.up)
        let proj = Scene3DMath.perspective(fovYDegrees: frame.fov, aspect: 1, nearZ: 0.1, farZ: 100)
        let viewProj = proj * view

        func ndc(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD2<Float> {
            let c = m * SIMD4<Float>(p.x, p.y, p.z, 1)
            return SIMD2(c.x / c.w, c.y / c.w)
        }

        let near = ndc(viewProj, SIMD3<Float>(0, 0, 0)).x
        let far = ndc(viewProj, SIMD3<Float>(0, 0, -3)).x
        XCTAssertEqual(near, -sqrt(3) / 5, accuracy: 1e-5)
        XCTAssertEqual(far, -sqrt(3) / 8, accuracy: 1e-5)
        XCTAssertNotEqual(near, far, "월드 카메라 이동은 깊이에 따라 다른 화면 이동을 만든다")
    }

    func testDisabledPerspectiveShakePreservesBasePose() throws {
        let renderer = SceneRenderer()
        renderer.camera3D = SceneCamera3D(
            eye: Vec3(x: 2, y: 3, z: 5), center: Vec3(x: 0, y: 0, z: 0),
            up: Vec3(x: 0, y: 1, z: 0), fov: 50, nearZ: 0.1, farZ: 100)
        let frame = try XCTUnwrap(renderer.resolveCamera3DFrame(at: 12))
        XCTAssertEqual(frame.eye, SIMD3<Float>(2, 3, 5))
        XCTAssertEqual(frame.center, .zero)
    }
}
