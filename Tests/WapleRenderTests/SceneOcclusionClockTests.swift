import XCTest
@testable import WapleRender

/// 가림(occlusion) draw-게이트의 클록 동결·오디오 중지(F289/F290)와 정지 중 재드로의 dt 동결(F291)
/// 검증. SceneRenderer.draw(in:) 자체는 실 Metal 디바이스가 필요해 직접 호출할 수 없으므로, 그
/// 전이 로직(handleOcclusionGate)과 dt 계산(frameDelta)을 순수 함수/메서드로 추출해 여기서 검증한다
/// — draw() 는 이 두 지점만 호출하므로 실사용 경로와 동일하다(병렬 사본 아님).
final class SceneOcclusionClockTests: XCTestCase {

    // MARK: - F289/F290: handleOcclusionGate

    func testOcclusionGate_entersOcclusion_recordsStartAndStopsAudioOnce() {
        let r = SceneRenderer()
        var stopCount = 0, startCount = 0
        r.handleOcclusionGate(occluded: true, now: 100, stopAudio: { stopCount += 1 }, startAudioIfNeeded: { startCount += 1 })
        XCTAssertEqual(r.drawGateOccludedSince, 100, "가림 진입 시각 기록")
        XCTAssertEqual(stopCount, 1, "가림 진입 시 오디오 정지(F289)")
        XCTAssertEqual(startCount, 0)

        // 계속 가려진 채 여러 프레임이 더 지나가도(30fps 폴링) 재정지하지 않는다.
        r.handleOcclusionGate(occluded: true, now: 100.1, stopAudio: { stopCount += 1 }, startAudioIfNeeded: { startCount += 1 })
        r.handleOcclusionGate(occluded: true, now: 100.2, stopAudio: { stopCount += 1 }, startAudioIfNeeded: { startCount += 1 })
        XCTAssertEqual(stopCount, 1, "가림 지속 중엔 매 프레임 재정지 호출을 반복하지 않는다")
        XCTAssertEqual(r.drawGateOccludedSince, 100, "시작 시각은 최초 진입 시각으로 고정")
    }

    func testOcclusionGate_becomesVisible_compensatesClockAndRestartsAudio() {
        let r = SceneRenderer()
        r.startTime = 0
        _ = { r.handleOcclusionGate(occluded: true, now: 10, stopAudio: {}, startAudioIfNeeded: {}) }()

        var startCount = 0
        r.hasAudio = true
        r.handleOcclusionGate(occluded: false, now: 17, stopAudio: {}, startAudioIfNeeded: { startCount += 1 })

        XCTAssertNil(r.drawGateOccludedSince, "가림 해제 시 추적 종료")
        XCTAssertEqual(r.startTime, 7, accuracy: 1e-9,
                       "F290: 가림 지속시간(10→17=7초)만큼 startTime 을 앞으로 보정해 time 점프 방지")
        XCTAssertEqual(startCount, 1, "가림 해제 시 오디오 재기동(F289)")
    }

    func testOcclusionGate_neverOccluded_isNoOp() {
        let r = SceneRenderer()
        let before = r.startTime
        var stopCount = 0, startCount = 0
        r.handleOcclusionGate(occluded: false, now: 999, stopAudio: { stopCount += 1 }, startAudioIfNeeded: { startCount += 1 })
        XCTAssertNil(r.drawGateOccludedSince)
        XCTAssertEqual(r.startTime, before, "가려진 적 없으면 클록 보정 없음")
        XCTAssertEqual(stopCount, 0); XCTAssertEqual(startCount, 0)
    }

    /// 가림 중 명시 pause() 가 들어오면(예: 사용자가 수동으로도 일시정지) 추적을 이어받아 이중 보정을
    /// 막는다 — pause() 가 drawGateOccludedSince(더 이른 시각)를 scenePausedAt 으로 채택하고 게이트
    /// 트래킹을 정리하므로, 이후 resume() 의 단일 보정이 가림+명시정지 전체 구간을 커버한다.
    func testPause_duringOcclusion_adoptsEarlierOcclusionStartAndClearsGateTracking() {
        let r = SceneRenderer()
        r.startTime = 0
        r.handleOcclusionGate(occluded: true, now: 5, stopAudio: {}, startAudioIfNeeded: {})
        XCTAssertEqual(r.drawGateOccludedSince, 5)

        r.pause()   // 실제 시각 사용(now) — scenePausedAt 이 drawGateOccludedSince(5)를 채택했는지만 확인
        XCTAssertEqual(r.scenePausedAt, 5, "가림 시작 시각을 그대로 채택(더 늦은 '지금' 이 아니라)")
        XCTAssertNil(r.drawGateOccludedSince, "게이트 추적은 명시 정지가 이어받아 정리됨")
    }

    // MARK: - F291: frameDelta

    func testFrameDelta_paused_isZeroRegardlessOfGap() {
        XCTAssertEqual(SceneRenderer.frameDelta(nowT: 100, lastFrameTime: 99.9, isPaused: true), 0,
                       "정지 중 재드로는 잔여 간격과 무관하게 dt=0(F291) — 시뮬이 전진하지 않게")
        XCTAssertEqual(SceneRenderer.frameDelta(nowT: 100, lastFrameTime: 0, isPaused: true), 0)
    }

    func testFrameDelta_live_clampsToRange() {
        XCTAssertEqual(SceneRenderer.frameDelta(nowT: 100.01, lastFrameTime: 100, isPaused: false), 0.01, accuracy: 1e-5,
                       "클램프 범위(≤50ms) 안이면 실제 간격 그대로")
        XCTAssertEqual(SceneRenderer.frameDelta(nowT: 100, lastFrameTime: 0, isPaused: false), 0.05, "큰 델타(탭 전환 등)는 50ms 로 클램프")
        XCTAssertEqual(SceneRenderer.frameDelta(nowT: 100, lastFrameTime: 101, isPaused: false), 0, "음수 델타는 0 으로 클램프")
    }
}
