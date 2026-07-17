import XCTest
import simd
@testable import WapleCore
@testable import WapleRender

/// camerashake 전역 카메라 지터 적용(D 재감사 #16 — 코퍼스 활성 13/168씬, 2D 11 / 3D 2).
/// WE 확정 수식 부재(클린룸: 문서 결론은 "전역 지터" 만 확정) → 코퍼스 값분포 기반 결정적 근사.
/// 가드: t 결정성(Date/random 미사용) + 미보유 씬 무영향(frameShakeOffset .zero → 셰이더 +0 = 비트동일).
final class CameraShakeTests: XCTestCase {

    // MARK: 결정적 오프셋 — 같은 t → 같은 값(비트동일), 다른 t → 다른 값(정지 아님)
    func testShakeOffsetIsDeterministicInTime() {
        let a = SceneRenderer.cameraShakeOffset(time: 6.0, amplitude: 0.5, roughness: 1, speed: 1)
        let b = SceneRenderer.cameraShakeOffset(time: 6.0, amplitude: 0.5, roughness: 1, speed: 1)
        XCTAssertEqual(a.x, b.x)
        XCTAssertEqual(a.y, b.y)
        let c = SceneRenderer.cameraShakeOffset(time: 6.1, amplitude: 0.5, roughness: 1, speed: 1)
        XCTAssertTrue(a.x != c.x || a.y != c.y, "다른 t 는 다른 오프셋(움직여야 함)")
    }

    // MARK: 진폭 선형 스케일 + 유계(roughness 커도 발산 금지)
    func testShakeScalesWithAmplitudeAndStaysBounded() {
        let half = SceneRenderer.cameraShakeOffset(time: 6.0, amplitude: 0.5, roughness: 1, speed: 1)
        let full = SceneRenderer.cameraShakeOffset(time: 6.0, amplitude: 1.0, roughness: 1, speed: 1)
        XCTAssertEqual(full.x, half.x * 2, accuracy: 1e-5, "진폭 선형")
        XCTAssertEqual(full.y, half.y * 2, accuracy: 1e-5)
        // roughness 최대(코퍼스 1.1)·속도 최대(7)로 t 스윕해도 피크는 ≈amplitude×scale(0.03) 유계.
        for i in 0..<400 {
            let t = Float(i) * 0.05
            let o = SceneRenderer.cameraShakeOffset(time: t, amplitude: 1.0, roughness: 1.1, speed: 7)
            XCTAssertLessThan(abs(o.x), 0.05)
            XCTAssertLessThan(abs(o.y), 0.05)
        }
    }

    // MARK: roughness=0 은 매끈 저주파, roughness>0 은 고주파 오버톤 가산(지글거림)
    func testRoughnessAddsHighFrequencyContent() {
        // 인접 t 미소구간의 2차차분(굴곡) 합은 roughness 클수록 커야 함(고주파 = 큰 곡률).
        func curvature(_ rough: Float) -> Float {
            var acc: Float = 0
            var prev2: Float = 0, prev1: Float = 0
            for i in 0..<200 {
                let t = Float(i) * 0.02
                let x = SceneRenderer.cameraShakeOffset(time: t, amplitude: 1, roughness: rough, speed: 2).x
                if i >= 2 { acc += abs(x - 2 * prev1 + prev2) }
                prev2 = prev1; prev1 = x
            }
            return acc
        }
        XCTAssertGreaterThan(curvature(1.1), curvature(0) * 1.5, "roughness 는 고주파 굴곡을 더한다")
    }

    // MARK: 미보유 씬 무영향(비트동일 가드) — 기본 비활성 → 프레임 오프셋 .zero
    func testDisabledSceneHasZeroFrameOffset() {
        let r = SceneRenderer()
        XCTAssertEqual(r.shakeOffset(at: 6).x, 0)
        XCTAssertEqual(r.shakeOffset(at: 6).y, 0)
        XCTAssertEqual(r.shakeOffset(at: 123.4).x, 0, "비활성은 t 무관 .zero")
    }

    // MARK: 활성 씬 t 의존 오프셋 발화 + 렌더러 상태 결정성
    func testEnabledSceneEmitsDeterministicOffset() {
        let r = SceneRenderer()
        r.cameraShakeEnabled = true
        r.cameraShakeAmplitude = 0.5
        r.cameraShakeRoughness = 1
        r.cameraShakeSpeed = 1
        let o = r.shakeOffset(at: 6)
        XCTAssertTrue(o.x != 0 || o.y != 0, "활성 씬은 t=6 에서 오프셋 발화")
        let o2 = r.shakeOffset(at: 6)
        XCTAssertEqual(o.x, o2.x)
        XCTAssertEqual(o.y, o2.y)
        // 인스턴스 디스패치 = 정적 함수와 동일.
        let s = SceneRenderer.cameraShakeOffset(time: 6, amplitude: 0.5, roughness: 1, speed: 1)
        XCTAssertEqual(o.x, s.x, accuracy: 1e-6)
        XCTAssertEqual(o.y, s.y, accuracy: 1e-6)
    }
}
