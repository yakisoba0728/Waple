import XCTest
import simd
@testable import WapleCore

final class PuppetPoseTests: XCTestCase {
    /// 본 2개(root→child), 정점 3개(w=root/child/반반) 모델. 바인드 = 평행이동만.
    private func model(tracks: [[PuppetModel.Key]], fps: Float = 10, length: Int = 2,
                       mode: String = "loop") -> PuppetModel {
        var m = PuppetModel(
            material: "m",
            vertices: [
                .init(position: SIMD3(0, 0, 0), boneIndices: SIMD4(0, 0, 0, 0), weights: SIMD4(1, 0, 0, 0), uv: SIMD2(0, 0)),
                .init(position: SIMD3(10, 0, 0), boneIndices: SIMD4(1, 0, 0, 0), weights: SIMD4(1, 0, 0, 0), uv: SIMD2(1, 0)),
                .init(position: SIMD3(5, 5, 0), boneIndices: SIMD4(0, 1, 0, 0), weights: SIMD4(0.5, 0.5, 0, 0), uv: SIMD2(0, 1)),
            ],
            indices: [0, 1, 2])
        m.bones = [
            .init(name: "root", parent: -1, bind: matrix_identity_float4x4),
            .init(name: "child", parent: 0,
                  bind: simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(10, 0, 0, 1))),
        ]
        m.animations = [.init(name: "a", mode: mode, fps: fps, lengthFrames: length, tracks: tracks)]
        return m
    }

    private func key(_ x: Float, _ y: Float, rz: Float = 0, s: Float = 1) -> PuppetModel.Key {
        .init(position: SIMD3(x, y, 0), angles: SIMD3(0, 0, rz), scale: SIMD3(s, s, s))
    }

    func testBindPoseIsIdentity() {
        // 트랙 첫 키 == 바인드 → t=0 스킨은 항등 → 정점 불변.
        let m = model(tracks: [[key(0, 0), key(0, 0), key(0, 0)], [key(10, 0), key(10, 0), key(10, 0)]])
        let mats = PuppetPose.skinMatrices(model: m, animation: 0, time: 0)
        let pos = PuppetPose.skinnedPositions(model: m, matrices: mats)
        XCTAssertEqual(pos[0].x, 0, accuracy: 1e-4)
        XCTAssertEqual(pos[1].x, 10, accuracy: 1e-4)
        XCTAssertEqual(pos[2].y, 5, accuracy: 1e-4)
    }

    func testRootTranslationInterpolatesAndPropagates() {
        // root 가 끝 프레임에 +100x: t=0.1s(프레임1/2) → +50. child 정점도 함께 이동(계층 전파).
        let m = model(tracks: [[key(0, 0), key(50, 0), key(100, 0)], []])
        let mats = PuppetPose.skinMatrices(model: m, animation: 0, time: 0.1)
        let pos = PuppetPose.skinnedPositions(model: m, matrices: mats)
        XCTAssertEqual(pos[0].x, 50, accuracy: 1e-3, "root 정점 +50")
        XCTAssertEqual(pos[1].x, 60, accuracy: 1e-3, "child(정적 트랙) 정점도 전파로 +50")
        XCTAssertEqual(pos[2].x, 55, accuracy: 1e-3, "반반 가중치")
    }

    func testMirrorModePingPongs() {
        // mirror: 길이 지나면 역방향. length=2, fps=10 → 주기 0.2s. t=0.3 → 프레임 1(되돌아옴).
        let m = model(tracks: [[key(0, 0), key(50, 0), key(100, 0)], []], mode: "mirror")
        let mats = PuppetPose.skinMatrices(model: m, animation: 0, time: 0.3)
        let pos = PuppetPose.skinnedPositions(model: m, matrices: mats)
        XCTAssertEqual(pos[0].x, 50, accuracy: 1e-3)
    }

    func testOutOfBoundsBoneParentTreatedAsRoot() {
        // 부모 인덱스가 본 개수 밖(비정상/손상 데이터)이어도 크래시하지 않고 루트(항등)로 처리 —
        // 3D 형제 Model3DPose 와 동일 규약(p < i 게이트). 종전엔 bindWorld[Int(b.parent)] /
        // world[Int(b.parent)] 가 무한계 인덱싱이라 배열 범위 밖 트랩(앱 전체 크래시).
        var m = PuppetModel(
            material: "m",
            vertices: [.init(position: SIMD3(1, 2, 0), boneIndices: SIMD4(1, 0, 0, 0),
                             weights: SIMD4(1, 0, 0, 0), uv: SIMD2(0, 0))],
            indices: [0])
        m.bones = [
            .init(name: "root", parent: -1, bind: matrix_identity_float4x4),
            .init(name: "bad", parent: 99, bind: matrix_identity_float4x4),  // 범위 밖 부모
        ]
        m.animations = [.init(name: "a", mode: "single", fps: 30, lengthFrames: 1, tracks: [])]
        let mats = PuppetPose.skinMatrices(model: m, animation: 0, time: 0)  // 수정 전: 트랩
        XCTAssertEqual(mats.count, 2)
        XCTAssertEqual(mats[1], matrix_identity_float4x4, "범위 밖 부모 본은 루트(항등)로 처리")
    }

    func testChildRotationAboutOwnOrigin() {
        // child 만 z 90° 회전(위치 키는 바인드 유지) → child 정점(바인드에서 본과 동일 위치)은 제자리,
        // 본에서 +x 로 떨어진 점이 있다면 회전. 여기선 정점1이 정확히 child 원점에 있으므로 불변이 핵심.
        let m = model(tracks: [[], [key(10, 0, rz: .pi / 2), key(10, 0, rz: .pi / 2), key(10, 0, rz: .pi / 2)]])
        let mats = PuppetPose.skinMatrices(model: m, animation: 0, time: 0)
        let pos = PuppetPose.skinnedPositions(model: m, matrices: mats)
        XCTAssertEqual(pos[1].x, 10, accuracy: 1e-3, "본 원점 위 정점은 회전 불변")
        XCTAssertEqual(pos[1].y, 0, accuracy: 1e-3)
        // 반반 정점(5,5): root 성분은 불변, child 성분은 child 원점(10,0) 기준 (5,5)-(10,0)=(-5,5) 회전→(-5,-5)+((10,0)=(5,-5)
        XCTAssertEqual(pos[2].x, 5, accuracy: 1e-3)
        XCTAssertEqual(pos[2].y, 0, accuracy: 1e-3, "0.5*(5) + 0.5*(-5)")
    }
}
