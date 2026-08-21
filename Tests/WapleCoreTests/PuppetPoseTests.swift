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

    /// `rz` 는 **파일 첫 각 슬롯**(키 +0x0c)에 들어간다 — WE 는 그 슬롯을 Z(yaw)로 읽는다
    /// (MDL 로더 오일러→쿼터니언 0x140264188–0x1402642ae). 종전엔 이 헬퍼가 세 번째 슬롯(+0x14)에
    /// 넣고 있었고, 그 슬롯은 실제로 X(roll)라 2D 퍼펫이 화면 밖으로 접혔다.
    private func key(_ x: Float, _ y: Float, rz: Float = 0, s: Float = 1) -> PuppetModel.Key {
        .init(position: SIMD3(x, y, 0), angles: SIMD3(rz, 0, 0), scale: SIMD3(s, s, s))
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
        // z==0 판별 — 종전 규약(각 3축을 (x,y,z)로 읽음)이면 이 회전은 **X축** 회전이 되어
        // 정점이 xy 평면 밖으로 나간다(z=2.5). 그때도 위 두 단언은 우연히 통과했다.
        XCTAssertEqual(pos[2].z, 0, accuracy: 1e-3, "z 회전은 평면 안 — X 축으로 새면 안 됨")
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

    // MARK: - C④ 캐스케이드 위상 dt 적분(스크립트 구동 rate)

    /// integratedCascadeFrame: 첫 호출(previousPhase nil)은 기존 time×rate 순간위상과 동일하게 시딩되고,
    /// 이후 호출은 rate 가 프레임마다 급변해도 phase 가 dt×rate×fps 만큼만 연속 전진한다(불연속 점프 없음).
    /// 감사 C④ 재현: rate 가 1 → 1000 으로 급변해도(오디오 반응 스크립트의 전형적 패턴) 위상은
    /// time×rate 재계산(순간 수만 프레임 점프)이 아니라 dt 폭만큼만 이동해야 한다.
    func testIntegratedCascadePhaseIsContinuousUnderVaryingRate() {
        let m = model(tracks: [[key(0, 0), key(0, 0)], []], fps: 10, length: 1000, mode: "loop")
        // 첫 프레임: previousPhase nil → time×rate×fps 로 시딩(정적 rate 경로와 동일 시작점).
        let r0 = PuppetPose.integratedCascadeFrame(model: m, anim: 0, rate: 1, time: 1.0, dt: 0,
                                                    previousPhase: nil)
        XCTAssertEqual(r0.phase, 10, accuracy: 1e-4, "시딩 위상 = time×rate×fps = 1.0×1×10")

        // rate 가 다음 프레임에 1000 으로 급변(오디오 반응 시나리오) — dt=0.1s 만 지남.
        let r1 = PuppetPose.integratedCascadeFrame(model: m, anim: 0, rate: 1000, time: 1.1, dt: 0.1,
                                                    previousPhase: r0.phase)
        let expectedDelta: Float = 0.1 * 1000 * 10   // dt × rate × fps
        XCTAssertEqual(r1.phase - r0.phase, expectedDelta, accuracy: 1e-2,
                       "위상은 dt×rate×fps 만큼만 연속 전진 — time×rate 재계산이면 1.1×1000×10=11000 이 나와야 하는데 그게 아님을 확인")
        // 구버전(time×rate 순간위상) 값과 뚜렷이 달라야 함 — 결함 재현 가드.
        let naiveJump = Float(1.1) * 1000 * 10
        XCTAssertNotEqual(r1.phase, naiveJump, "적분 위상이 순간위상 재계산과 같으면 안 됨(회귀)")
        XCTAssertLessThan(abs(r1.phase - r0.phase), abs(naiveJump - r0.phase),
                          "적분 위상 변화폭이 순간위상 재계산의 점프보다 훨씬 작아야(연속성)")
    }

    /// worldMatrices/blendedSkinMatrices 의 overrideFrames 배선: override 를 주면 그 레이어는 override
    /// 프레임을, nil 이면 기존 time×rate 계산을 쓴다(선택적 오버라이드 — 무회귀 가드).
    func testOverrideFramesSelectivelyReplacesPerLayerFrame() {
        // 클립 a: 프레임 0→x=0, 프레임 1→x=100(단일 트랙). fps=1, length=1, single.
        let m = multiModel([("a", [key(0, 0), key(100, 0)])], fps: 1, length: 1, mode: "single")
        // override 없음(nil) → time=0 이므로 frame=0 → x=0.
        let noOverride = skinnedX(m, [(anim: 0, additive: false, weight: 1, rate: 1)], 0)
        XCTAssertEqual(noOverride.x, 0, accuracy: 1e-4)
        // override 로 프레임 1 강제 지정 → time=0 이어도 x=100(오버라이드가 우선).
        let withOverride = PuppetPose.skinnedPositions(
            model: m,
            matrices: PuppetPose.blendedSkinMatrices(model: m, layers: [(anim: 0, additive: false, weight: 1, rate: 1)],
                                                      time: 0, overrideFrames: [1.0])).first!
        XCTAssertEqual(withOverride.x, 100, accuracy: 1e-4, "override 프레임이 time×rate 계산을 대체해야")
    }

    /// clipIndex: 이름 서브스트링 매칭, 실패 시 fallback 위치.
    func testClipIndexResolution() {
        let m = multiModel([("idle_bone", []), ("wave_bone", [])])
        XCTAssertEqual(PuppetPose.clipIndex(model: m, name: "wave", fallback: 0), 1)
        XCTAssertEqual(PuppetPose.clipIndex(model: m, name: "idle", fallback: 1), 0)
        XCTAssertEqual(PuppetPose.clipIndex(model: m, name: "nomatch", fallback: 1), 1)  // fallback 위치
    }

    /// C③: clipId 가 있고 매칭되면 이름 휴리스틱보다 우선한다 — 저작 도구가 클립을 제네릭 이름("动画 1/2")
    /// 으로 남기고 레이어 이름("wave" 등)에만 의미를 부여하는 실물 사례(3384019940/3517818807/3486806915
    /// 코퍼스 교차검증) 재현: 이름으로는 "wave"가 clip1("动画 2")에 매칭될 것 같지만, 실제로는 id가
    /// clip0("动画 1")을 가리키면 id가 이긴다.
    func testClipIndexPrefersClipIdOverNameHeuristic() {
        var m = multiModel([("动画 1", []), ("动画 2", [])])
        m.animations[0].id = 100
        m.animations[1].id = 200
        // 이름 매칭만이면 "wave"는 두 제네릭 이름 어디에도 안 붙어 fallback(1) 로 떨어진다.
        XCTAssertEqual(PuppetPose.clipIndex(model: m, name: "wave", fallback: 1), 1)
        // clipId=100 을 주면 이름/제네릭과 무관하게 clip0 을 정확히 골라야(fallback 은 무시됨).
        XCTAssertEqual(PuppetPose.clipIndex(model: m, name: "wave", fallback: 1, clipId: 100), 0)
        XCTAssertEqual(PuppetPose.clipIndex(model: m, name: "wave", fallback: 0, clipId: 200), 1)
        // 매칭 안 되는 clipId → 이름 휴리스틱/fallback 으로 정상 폴백(무회귀).
        XCTAssertEqual(PuppetPose.clipIndex(model: m, name: "nomatch", fallback: 1, clipId: 999), 1)
    }
}
