import XCTest
import simd
@testable import WapleCore
@testable import WapleRender

/// 정사영 씬의 runtime camera eye와 camera 의사-오브젝트 origin.xy를 렌더러에 잇는 경계.
final class SceneCameraOriginTests: XCTestCase {

    private func kf(_ frame: Float, _ value: Float) -> PropertyKeyframe {
        PropertyKeyframe(frame: frame, value: value, frontEnabled: false, frontX: 0, frontY: 0,
                         backEnabled: false, backX: 0, backY: 0)
    }

    /// 실측 3521337568 전형: origin 애니 relative — base(-244.74,1468.74) + c0[(0,159.2),(36,244.74)]
    /// c1[(0,1.6),(36,-1468.74)] fps12 len60 single. t=0 은 인트로 오프셋, 끝 클램프는 base+최종=≈(0,0).
    private func introPanCamera() -> SceneCameraObject {
        var cam = SceneCameraObject()
        cam.origin = Vec3(x: -244.73788, y: 1468.74146, z: 500)
        cam.originAnimation = PropertyAnimation(
            tracks: [[kf(0, 159.19997), kf(36, 244.73788)],
                     [kf(0, 1.59997), kf(36, -1468.7415)]],
            fps: 12, length: 60, mode: "single", relative: true)
        return cam
    }

    // MARK: 파스 — origin {"animation"} 바인딩 → originAnimation(zoom 과 동형 재사용)

    func testOrthographicSceneCameraEyeIsPreservedWithoutEnablingPerspectiveRenderer() throws {
        let scene: [String: Any] = [
            "general": ["orthogonalprojection": ["width": 200, "height": 100]],
            "camera": [
                "eye": "20 -10 3",
                "center": "20 -10 2",
                "up": "0 1 0",
            ],
            "objects": [],
        ]
        let package = ScenePackage.assemble([
            ("scene.json", try JSONSerialization.data(withJSONObject: scene)),
        ])

        let doc = try SceneDocument.parse(package: package)

        XCTAssertTrue(doc.orthographic)
        XCTAssertNil(doc.camera3D, "정사영 씬은 원근 렌더러를 켜면 안 된다")
        let camera = try XCTUnwrap(doc.sceneCamera)
        XCTAssertEqual(camera.eye.x, 20)
        XCTAssertEqual(camera.eye.y, -10)
        XCTAssertEqual(camera.eye.z, 3)
    }

    func testParse_originAnimationBinding() throws {
        let scene: [String: Any] = [
            "general": ["orthogonalprojection": ["width": 3840, "height": 2160]],
            "objects": [[
                "camera": "default",
                "origin": ["value": "-244.73788 1468.74146 500.00000",
                           "animation": ["c0": [["frame": 0, "value": 159.19997],
                                                ["frame": 36, "value": 244.73788]],
                                         "c1": [["frame": 0, "value": 1.59997],
                                                ["frame": 36, "value": -1468.7415]],
                                         "relative": true,
                                         "options": ["fps": 12, "length": 60, "mode": "single"]]]
            ]]
        ]
        let sceneData = try JSONSerialization.data(withJSONObject: scene)
        let package = ScenePackage.assemble([("scene.json", sceneData)])
        let doc = try SceneDocument.parse(package: package)
        XCTAssertEqual(doc.cameraObjects.count, 1)
        let cam = doc.cameraObjects[0]
        XCTAssertNotNil(cam.originAnimation, "origin 애니 바인딩이 파스돼야 함")
        XCTAssertEqual(cam.originAnimation?.relative, true)
        XCTAssertEqual(cam.originAnimation?.tracks.count, 2)
        XCTAssertEqual(cam.origin.x, -244.73788, accuracy: 1e-2, "base = value 언랩")
    }

    // MARK: 평가 — 인트로 t=0 발화, single 끝 클램프로 t=6 중립 정착(A/B 게이트 비트동일)

    func testCameraOrigin_introFiresAndSettlesToNeutral() {
        let r = SceneRenderer()
        r.applyCameraObjects([introPanCamera()])
        // t=0: base + anim(0) = (-244.74+159.20, 1468.74+1.60) = (-85.54, 1470.34) — 인트로 오프셋 발화.
        let o0 = r.cameraOrigin(at: 0)
        XCTAssertEqual(o0.x, -85.53791, accuracy: 1e-2)
        XCTAssertEqual(o0.y, 1470.34143, accuracy: 1e-2)
        // t=6: frame 72>len60>lastKF36 클램프 → base + 최종 = (0, ≈0) — 정착 중립.
        let o6 = r.cameraOrigin(at: 6)
        XCTAssertEqual(o6.x, 0, accuracy: 1e-3, "single 정착 x 중립")
        XCTAssertEqual(o6.y, 0, accuracy: 1e-2, "single 정착 y 중립")
    }

    // MARK: 스크립트 origin(19씬) — 미평가라 stale base 무시(중립) → 팬 미발화(회귀 가드)

    func testCameraOrigin_scriptBindingIsNeutral() {
        var cam = SceneCameraObject()
        cam.origin = Vec3(x: 2434.38477, y: 725.25134, z: 500)  // 직렬화 stale base(실측 19씬)
        cam.scripts["origin"] = "export function update(value){ return value; }"
        let r = SceneRenderer()
        r.applyCameraObjects([cam])
        let o = r.cameraOrigin(at: 6)
        XCTAssertEqual(o.x, 0, "스크립트 origin 은 미평가 → base 무시 중립(팬 미발화)")
        XCTAssertEqual(o.y, 0)
    }

    // MARK: eye 오프셋 수학 — 카메라 +x/+y 이동은 콘텐츠를 정확히 −x/−y로 이동

    func testCameraEyeNDCOffsetHasExactSignAndNoDeadzone() {
        // 중립(0,0) → .zero(비트동일 가드).
        let z = SceneRenderer.cameraEyeNDCOffset(eye: SIMD2(0, 0), projW: 3840, projH: 2160)
        XCTAssertEqual(z.x, 0); XCTAssertEqual(z.y, 0)
        // 바이너리에는 2px 데드존이 없다. 1px도 양축 모두 반대 방향으로 정확히 이동한다.
        let d = SceneRenderer.cameraEyeNDCOffset(eye: SIMD2(1, 1), projW: 3840, projH: 2160)
        XCTAssertEqual(d.x, -2 / 3840, accuracy: 1e-7)
        XCTAssertEqual(d.y, -2 / 2160, accuracy: 1e-7)
        let p = SceneRenderer.cameraEyeNDCOffset(eye: SIMD2(-85.53791, 1470.34143), projW: 3840, projH: 2160)
        XCTAssertEqual(p.x, 2 * 85.53791 / 3840, accuracy: 1e-5)
        XCTAssertEqual(p.y, -2 * 1470.34143 / 2160, accuracy: 1e-5)
    }

    // MARK: 카메라 부재/정적 중립 씬 무영향(비트동일 가드) + 재마운트 리셋

    func testNoCameraAndStaticNeutralAreZeroAndRemountResets() {
        let r = SceneRenderer()
        XCTAssertEqual(r.cameraOrigin(at: 6).x, 0, "초기 중립")
        // 정적 중립 origin(0,0,500) — 실측 3479521040/3563096027(팬 미발화).
        var stat = SceneCameraObject(); stat.origin = Vec3(x: 0, y: 0, z: 500)
        r.applyCameraObjects([stat])
        XCTAssertEqual(r.cameraOrigin(at: 6).x, 0)
        XCTAssertEqual(r.cameraOrigin(at: 6).y, 0)
        // 애니 씬 마운트 후 카메라 없는 씬 재마운트(렌더러 재사용) → 중립 리셋.
        r.applyCameraObjects([introPanCamera()])
        r.applyCameraObjects([])
        XCTAssertNil(r.cameraOriginAnim)
        XCTAssertEqual(r.cameraOrigin(at: 0).x, 0, "재마운트 리셋 — 팬 미발화")
        XCTAssertEqual(r.cameraOrigin(at: 0).y, 0)
    }
}
