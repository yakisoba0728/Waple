import XCTest
import simd
@testable import WapleCore
@testable import WapleRender

/// WapleCore의 바이너리 대조 exact shake를 2D renderer eye/view/parallax 경계에 잇는 테스트.
final class CameraShakeTests: XCTestCase {

    func testDisabledSceneHasZeroEyeDelta() {
        let r = SceneRenderer()
        XCTAssertEqual(r.cameraShakeEyeDelta2D(at: 6), .zero)
        XCTAssertEqual(r.cameraShakeEyeDelta2D(at: 123.4), .zero)
    }

    func testOrthographicShakeUsesExactPixelFormula() {
        let r = SceneRenderer()
        r.projH = 100
        r.cameraShakeEnabled = true
        r.cameraShakeAmplitude = 10
        r.cameraShakeRoughness = 1
        r.cameraShakeSpeed = 1
        // t=0: phi=0, scale=H*0.1*(amplitude*0.1)=10 → (10,0).
        let eye = r.cameraShakeEyeDelta2D(at: 0)
        XCTAssertEqual(eye.x, 10, accuracy: 1e-6)
        XCTAssertEqual(eye.y, 0, accuracy: 1e-6)
    }

    func testSameFinalEyeFeedsViewAndParallax() {
        let r = SceneRenderer()
        r.projW = 100
        r.projH = 100
        r.parallaxEnabled = true
        r.parallaxMouseInfluence = 0
        r.parallaxDelay = 0
        r.cameraShakeEnabled = true
        r.cameraShakeAmplitude = 10
        r.cameraShakeRoughness = 1
        r.cameraShakeSpeed = 1

        let eye = r.resolvedCameraEye2D(at: 0)
        _ = r.advanceCameraParallax(dt: 0, eye: eye)
        let view = SceneRenderer.cameraEyeNDCOffset(eye: eye, projW: r.projW, projH: r.projH)

        XCTAssertEqual(eye.x, 10, accuracy: 1e-6)
        XCTAssertEqual(view.x, -0.2, accuracy: 1e-6)
        XCTAssertEqual(r.parallaxFocus.x, 60, accuracy: 1e-6)
        XCTAssertEqual(r.parallaxFocus.y, 50, accuracy: 1e-6)
        XCTAssertEqual(r.parallaxPosition.x, 0.6, accuracy: 1e-6)
        XCTAssertEqual(r.parallaxPosition.y, 0.5, accuracy: 1e-6)
    }
}
