import XCTest
import simd
@testable import WapleCore
@testable import WapleRender

/// camera 의사-오브젝트(P0-2 파스) → 2D 뷰-투영 배선(zoom).
/// WE 시맨틱(클린룸 L19 봉인 + 코퍼스 실측): 2D 씬 투영은 orthogonalprojection dict 가 지배 —
/// fov 는 투영 선택자가 아니고(160/168 씬 50 상수), camera 오브젝트의 zoom 만 뷰 스케일로 실효.
/// 실측 zoom 애니 9씬은 전수 single 모드로 최종 키프레임 1.0 정착(인트로 줌).
final class SceneCameraZoomTests: XCTestCase {

    private func kf(_ frame: Float, _ value: Float) -> PropertyKeyframe {
        PropertyKeyframe(frame: frame, value: value, frontEnabled: false, frontX: 0, frontY: 0,
                         backEnabled: false, backX: 0, backY: 0)
    }

    /// 실측 3521337568 전형: zoom c0=[(0,3),(36,1)] fps12 len60 single — t=0 은 3×, 끝 클램프 1×.
    private func introZoomCamera() -> SceneCameraObject {
        var cam = SceneCameraObject()
        cam.zoom = 3
        cam.zoomAnimation = PropertyAnimation(tracks: [[kf(0, 3), kf(36, 1)]],
                                              fps: 12, length: 60, mode: "single", relative: false)
        return cam
    }

    // MARK: 뷰-투영 반영(수학)

    func testCameraZoom_staticZoomApplied() {
        let r = SceneRenderer()
        var cam = SceneCameraObject()
        cam.zoom = 0.75   // 실측 3479521040(정적 줌아웃)
        r.applyCameraObjects([cam])
        XCTAssertEqual(r.cameraZoom(at: 0), 0.75)
        XCTAssertEqual(r.cameraZoom(at: 6), 0.75, "정적 zoom 은 시간 무관")
    }

    func testCameraZoom_keyframeAnimationEvaluatesAndClampsToRest() {
        let r = SceneRenderer()
        r.applyCameraObjects([introZoomCamera()])
        XCTAssertEqual(r.cameraZoom(at: 0), 3, accuracy: 1e-5, "인트로 시작 3×")
        // frame 18 = 두 키프레임 중간, 핸들 disabled = 선형 동치 → 2.0
        XCTAssertEqual(r.cameraZoom(at: 1.5), 2, accuracy: 1e-3)
        XCTAssertEqual(r.cameraZoom(at: 6), 1, accuracy: 1e-5, "single 끝 클램프 = 정착 1×")
    }

    func testCameraZoom_firstCameraWins() {
        // 실측 3629379075: 가시 카메라 2대 공존 — 첫 번째 소비(정적 비가시는 파스가 이미 드롭).
        var a = SceneCameraObject(); a.zoom = 2
        var b = SceneCameraObject(); b.zoom = 5
        let r = SceneRenderer()
        r.applyCameraObjects([a, b])
        XCTAssertEqual(r.cameraZoom(at: 0), 2)
    }

    // MARK: camera 부재 시 현행 투영 불변(무회귀 가드)

    func testCameraZoom_noCameraIsNeutralAndRemountResets() {
        let r = SceneRenderer()
        XCTAssertEqual(r.cameraZoom(at: 0), 1, "초기 상태 중립")
        r.applyCameraObjects([introZoomCamera()])   // 카메라 씬 마운트
        r.applyCameraObjects([])                    // 카메라 없는 씬 재마운트(렌더러 재사용)
        XCTAssertEqual(r.cameraZoom(at: 0), 1, "중립 — draw 는 1 에서 aspectScale 곱 자체를 스킵(비트 불변)")
        XCTAssertNil(r.cameraZoomAnim)
        XCTAssertEqual(r.currentCameraZoom, 1)
    }

    // MARK: 클릭/호버 역매핑(sceneCoords) 정합

    func testSceneCoords_zoomInversesViewScale() {
        let size = CGSize(width: 800, height: 600)
        // 화면 중심은 줌 불변.
        let c = SceneRenderer.sceneCoords(viewPoint: CGPoint(x: 400, y: 300), viewSize: size,
                                          projW: 1920, projH: 1080, fitMode: .stretch, zoom: 2)
        XCTAssertEqual(c?.x ?? -1, 960, accuracy: 0.01)
        XCTAssertEqual(c?.y ?? -1, 540, accuracy: 0.01)
        // 2× 줌: 뷰 우상단(AppKit 하단원점 (800,600)) → 씬 중심과 코너의 중간.
        let p = SceneRenderer.sceneCoords(viewPoint: CGPoint(x: 800, y: 600), viewSize: size,
                                          projW: 1920, projH: 1080, fitMode: .stretch, zoom: 2)
        XCTAssertEqual(p?.x ?? -1, 1440, accuracy: 0.01)   // 960 + 960/2
        XCTAssertEqual(p?.y ?? -1, 270, accuracy: 0.01)    // 540 − 540/2 (WE 상단원점)
        // 줌아웃 0.5×: 뷰 코너는 씬 밖(레터박스 유사) → nil.
        XCTAssertNil(SceneRenderer.sceneCoords(viewPoint: CGPoint(x: 800, y: 600), viewSize: size,
                                               projW: 1920, projH: 1080, fitMode: .stretch, zoom: 0.5))
        // 기본 인자(zoom=1) = 종전 공식 그대로(무회귀).
        let base = SceneRenderer.sceneCoords(viewPoint: CGPoint(x: 400, y: 300), viewSize: size,
                                             projW: 1920, projH: 1080, fitMode: .stretch)
        XCTAssertEqual(base?.x ?? -1, 960, accuracy: 0.01)
        XCTAssertEqual(base?.y ?? -1, 540, accuracy: 0.01)
    }
}
