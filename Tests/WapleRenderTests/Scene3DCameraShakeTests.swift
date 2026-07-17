import XCTest
import simd
@testable import WapleRender

/// camerashake 3D 확장(코퍼스 3D 2씬: 3706286085 소닉 / 3477054430).
/// 2D 는 shakeOffset 을 NDC 에 직접 가산(v_main/pv_main). 3D 는 동형으로 clip-space 병진행렬을
/// viewProj 에 좌승 → 원근분할 후 전 정점이 depth 무관하게 동일 NDC 만큼 병진(전역 카메라 지터).
/// shadow(광원공간 VP)는 viewProj 미사용 → 월드 지오메트리 불변, 화면만 흔들림.
final class Scene3DCameraShakeTests: XCTestCase {

    // MARK: clipTranslation(shake)·viewProj 는 투영 NDC 를 shake 만큼 병진하되 depth 에 무관
    func testClipShakeTranslatesNDCDepthIndependent() {
        let view = Scene3DMath.lookAt(eye: SIMD3(0, 0, 5), center: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))
        let proj = Scene3DMath.perspective(fovYDegrees: 60, aspect: 1.6, nearZ: 0.1, farZ: 100)
        let viewProj = proj * view
        let shake = SIMD2<Float>(0.02, -0.013)
        let shaken = Scene3DMath.clipTranslation(shake) * viewProj

        func ndc(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD2<Float> {
            let c = m * SIMD4<Float>(p.x, p.y, p.z, 1)
            return SIMD2(c.x / c.w, c.y / c.w)
        }
        // 서로 다른 깊이의 두 점 — 병진량이 동일해야(원근 무관 전역 지터).
        for p in [SIMD3<Float>(0.3, -0.2, 0), SIMD3<Float>(-0.5, 0.4, -3.0)] {
            let d = ndc(shaken, p) - ndc(viewProj, p)
            XCTAssertEqual(d.x, shake.x, accuracy: 1e-5, "NDC.x 병진 = shake.x (depth 무관)")
            XCTAssertEqual(d.y, shake.y, accuracy: 1e-5, "NDC.y 병진 = shake.y (depth 무관)")
        }
    }

    // MARK: shake .zero 는 항등(비활성 3D 씬 = 비트동일 가드)
    func testZeroShakeIsIdentity() {
        let m = Scene3DMath.clipTranslation(.zero)
        let id = matrix_identity_float4x4
        for c in 0..<4 {
            XCTAssertEqual(m[c], id[c], "clipTranslation(.zero) == identity → viewProj 불변")
        }
    }
}
