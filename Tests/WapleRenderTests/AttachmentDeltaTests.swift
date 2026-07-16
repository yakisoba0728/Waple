import XCTest
import simd
@testable import WapleCore
@testable import WapleRender

/// P1 attachment 씬공간 델타 D = P∘(Y·A·Y)∘P⁻¹ 수학(순수 — Metal 불요).
/// 검증 성질: 베이크된 자식 월드(P∘childLocal)에 D 를 곱하면 P∘A∘childLocal.
final class AttachmentDeltaTests: XCTestCase {
    private func translation(_ x: Float, _ y: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(x, y, 0, 1)
        return m
    }

    func testIdentityFrameIsIdentityDelta() {
        let d = SceneRenderer.attachmentSceneDelta(frame: matrix_identity_float4x4,
                                                   parentOrigin: SIMD2(100, 200),
                                                   parentScale: SIMD2(2, 3), parentAngle: 0.7)!
        XCTAssertEqual(d.m.columns.0.x, 1, accuracy: 1e-5)
        XCTAssertEqual(d.m.columns.0.y, 0, accuracy: 1e-5)
        XCTAssertEqual(d.m.columns.1.y, 1, accuracy: 1e-5)
        XCTAssertEqual(d.t.x, 0, accuracy: 1e-3)
        XCTAssertEqual(d.t.y, 0, accuracy: 1e-3)
    }

    func testModelSpaceTranslationYFlipsToScene() {
        // 모델공간(y-up) +648y 이동 → 씬(y-down)에서 −648y(위로). 부모 항등.
        let d = SceneRenderer.attachmentSceneDelta(frame: translation(31.7, 648),
                                                   parentOrigin: SIMD2(1919, 872),
                                                   parentScale: SIMD2(1, 1), parentAngle: 0)!
        // 베이크된 자식 월드 = 부모 origin + childLocal(y-down). childLocal=(-69.8, 23.3):
        let baked = SIMD2<Float>(1919 - 69.8, 872 + 23.3)
        let moved = d.m * baked + d.t
        // 기대: 부모 + Y켤레(A)·childLocal = (1919+31.7-69.8, 872-648+23.3) — 실물 3538758087 주발이 머리로.
        XCTAssertEqual(moved.x, 1919 + 31.7 - 69.8, accuracy: 1e-2)
        XCTAssertEqual(moved.y, 872 - 648 + 23.3, accuracy: 1e-2)
    }

    func testParentScaleConjugation() {
        // 부모 스케일 2×: 모델공간 +10x 부착 이동은 씬에서 +20x 로 확대.
        let d = SceneRenderer.attachmentSceneDelta(frame: translation(10, 0),
                                                   parentOrigin: SIMD2(0, 0),
                                                   parentScale: SIMD2(2, 2), parentAngle: 0)!
        let moved = d.m * SIMD2<Float>(0, 0) + d.t
        XCTAssertEqual(moved.x, 20, accuracy: 1e-3)
        XCTAssertEqual(moved.y, 0, accuracy: 1e-3)
    }

    func testModelRotationBecomesOppositeSignInYDown() {
        // 모델공간(y-up) +90° 회전 본: y-down 씬 좌표계에선 −90°(화면상 같은 방향).
        var A = matrix_identity_float4x4
        A.columns.0 = SIMD4(0, 1, 0, 0)    // cos90, sin90
        A.columns.1 = SIMD4(-1, 0, 0, 0)
        let d = SceneRenderer.attachmentSceneDelta(frame: A, parentOrigin: SIMD2(0, 0),
                                                   parentScale: SIMD2(1, 1), parentAngle: 0)!
        let rot = atan2(d.m.columns.0.y, d.m.columns.0.x)
        XCTAssertEqual(rot, -Float.pi / 2, accuracy: 1e-4)
        // 회전 델타에 의한 위치: 자식(10, 0) → 씬 y-down 에서 (0, -10).
        let moved = d.m * SIMD2<Float>(10, 0) + d.t
        XCTAssertEqual(moved.x, 0, accuracy: 1e-4)
        XCTAssertEqual(moved.y, -10, accuracy: 1e-4)
    }

    func testDegenerateParentScaleNil() {
        XCTAssertNil(SceneRenderer.attachmentSceneDelta(frame: matrix_identity_float4x4,
                                                        parentOrigin: .zero,
                                                        parentScale: SIMD2(0, 1), parentAngle: 0))
    }
}
