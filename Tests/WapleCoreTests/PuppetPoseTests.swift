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

    // MARK: - 다층 animationlayers 캐스케이드 블렌드

    /// 1본(root, bind=항등) + 원점 정점 → skinned pos = root 로컬 평행이동값(클립 위치). 클립별 스펙 주입.
    private func multiModel(_ clips: [(name: String, keys: [PuppetModel.Key])],
                            fps: Float = 10, length: Int = 1, mode: String = "single") -> PuppetModel {
        var m = PuppetModel(
            material: "m",
            vertices: [.init(position: SIMD3(0, 0, 0), boneIndices: SIMD4(0, 0, 0, 0),
                             weights: SIMD4(1, 0, 0, 0), uv: SIMD2(0, 0))],
            indices: [0])
        m.bones = [.init(name: "root", parent: -1, bind: matrix_identity_float4x4)]
        m.animations = clips.map { .init(name: $0.name, mode: mode, fps: fps, lengthFrames: length, tracks: [$0.keys]) }
        return m
    }
    private func skinnedX(_ m: PuppetModel, _ layers: [(anim: Int, additive: Bool, weight: Float, rate: Float)],
                          _ time: Float = 0) -> SIMD3<Float> {
        PuppetPose.skinnedPositions(model: m, matrices: PuppetPose.blendedSkinMatrices(model: m, layers: layers, time: time)).first ?? .zero
    }

    /// 단일 절대 레이어 weight=1 → skinMatrices(animation:) 와 동일(= 단층 무회귀).
    func testSingleAbsoluteLayerMatchesSingleClip() {
        let m = multiModel([("a", [key(100, 0), key(100, 0)])])
        let single = PuppetPose.skinnedPositions(model: m, matrices: PuppetPose.skinMatrices(model: m, animation: 0, time: 0)).first!
        let blended = skinnedX(m, [(anim: 0, additive: false, weight: 1, rate: 1)])
        XCTAssertEqual(blended.x, single.x, accuracy: 1e-4)
        XCTAssertEqual(blended.x, 100, accuracy: 1e-4)
    }

    /// 2 절대 레이어 캐스케이드: 두 번째 weight 0 → 첫 클립, 1 → 둘째 클립, 0.5 → 중간(보간).
    func testTwoAbsoluteCascadeExtremesAndMidpoint() {
        let m = multiModel([("a", [key(100, 0), key(100, 0)]), ("b", [key(0, 100), key(0, 100)])])
        func blend(_ w: Float) -> SIMD3<Float> {
            skinnedX(m, [(anim: 0, additive: false, weight: 1, rate: 1),
                         (anim: 1, additive: false, weight: w, rate: 1)])
        }
        // weight 0 극값 = 첫 레이어 단독(clip a)
        XCTAssertEqual(blend(0).x, 100, accuracy: 1e-4); XCTAssertEqual(blend(0).y, 0, accuracy: 1e-4)
        // weight 1 극값 = 둘째 레이어(clip b) 오버라이드
        XCTAssertEqual(blend(1).x, 0, accuracy: 1e-4); XCTAssertEqual(blend(1).y, 100, accuracy: 1e-4)
        // 중간값 = 선형 보간
        XCTAssertEqual(blend(0.5).x, 50, accuracy: 1e-4); XCTAssertEqual(blend(0.5).y, 50, accuracy: 1e-4)
        XCTAssertEqual(blend(0.25).x, 75, accuracy: 1e-4); XCTAssertEqual(blend(0.25).y, 25, accuracy: 1e-4)
    }

    /// 가산 레이어: 절대 베이스 위에 (클립 - 클립프레임0) 델타를 weight 배로 가산.
    func testAdditiveLayerAddsWeightedDelta() {
        // 베이스 a=(100,0) 상수. 가산 b: frame0=(0,0), frame1=(0,50) → 델타=(0,50).
        let m = multiModel([("a", [key(100, 0), key(100, 0)]), ("b", [key(0, 0), key(0, 50)])],
                           fps: 10, length: 1, mode: "single")
        let base: [(anim: Int, additive: Bool, weight: Float, rate: Float)] = [(0, false, 1, 1)]
        // time=1.0 → b 프레임 1(=키1). weight 0 → 델타 없음(베이스), weight 1 → +델타, 0.5 → 절반.
        XCTAssertEqual(skinnedX(m, base + [(1, true, 0, 1)], 1.0).y, 0, accuracy: 1e-4)
        XCTAssertEqual(skinnedX(m, base + [(1, true, 1, 1)], 1.0).y, 50, accuracy: 1e-4)
        XCTAssertEqual(skinnedX(m, base + [(1, true, 0.5, 1)], 1.0).y, 25, accuracy: 1e-4)
        // x 는 베이스 유지(가산은 y 평행이동만).
        XCTAssertEqual(skinnedX(m, base + [(1, true, 1, 1)], 1.0).x, 100, accuracy: 1e-4)
    }

    /// clipIndex: 이름 서브스트링 매칭, 실패 시 fallback 위치.
    func testClipIndexResolution() {
        let m = multiModel([("idle_bone", []), ("wave_bone", [])])
        XCTAssertEqual(PuppetPose.clipIndex(model: m, name: "wave", fallback: 0), 1)
        XCTAssertEqual(PuppetPose.clipIndex(model: m, name: "idle", fallback: 1), 0)
        XCTAssertEqual(PuppetPose.clipIndex(model: m, name: "nomatch", fallback: 1), 1)  // fallback 위치
    }
}
