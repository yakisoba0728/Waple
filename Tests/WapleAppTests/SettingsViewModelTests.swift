import XCTest
@testable import Waple
import WapleLibrary
import WaplePolicy
import WapleRender

/// SettingsViewModel 배선 검증 — AppDelegate 주입 클로저 7종 + refresh() 스토어 재읽기.
/// SwiftUI 뷰는 제외. PlaylistStore 는 임시 디렉터리로 실제 생성하고,
/// SceneRenderSettings(UserDefaults 전역) 를 건드는 테스트는 원값을 저장했다가 복원한다.
final class SettingsViewModelTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)   // tearDown 에서 정리($TMPDIR 리터 방지)
        return d
    }

    private func makeVM(dir: URL) -> SettingsViewModel {
        SettingsViewModel(playlist: PlaylistStore(baseDirectory: dir))
    }

    /// 전역 렌더 설정을 바꾸는 테스트용 스냅샷/복원(테스트 간 오염 방지).
    /// SceneRenderSettings 는 UserDefaults.standard 전역 영속이라 이 방어는 직렬 실행 전제다(테스트
    /// 병렬 실행 시 스냅샷/복원이 인터리브해 상호 오염 가능 — 기본 직렬 실행에서는 안전).
    private func snapshotRenderSettings() -> (FitMode, SceneFPSCap) {
        (SceneRenderSettings.fitMode, SceneRenderSettings.maxFPS)
    }
    private func restoreRenderSettings(_ s: (FitMode, SceneFPSCap)) {
        SceneRenderSettings.fitMode = s.0
        SceneRenderSettings.maxFPS = s.1
    }

    // MARK: - 콜백 배선 (AppDelegate 주입 클로저)

    func testSetFit_updatesStoreAndFiresApply() {
        let saved = snapshotRenderSettings(); defer { restoreRenderSettings(saved) }
        let vm = makeVM(dir: tempDir())
        var applyCount = 0
        vm.onApplySelection = { applyCount += 1 }

        vm.setFit(.fill)

        XCTAssertEqual(vm.fitMode, .fill, "@Published 미러 즉시 갱신")
        XCTAssertEqual(SceneRenderSettings.fitMode, .fill, "전역 스토어 영속(트레이 메뉴와 같은 키)")
        XCTAssertEqual(applyCount, 1, "onApplySelection — 재적용(리마운트) 트리거")
    }

    func testSetMaxFPS_updatesStoreAndFiresApply() {
        let saved = snapshotRenderSettings(); defer { restoreRenderSettings(saved) }
        let vm = makeVM(dir: tempDir())
        var applyCount = 0
        vm.onApplySelection = { applyCount += 1 }

        vm.setMaxFPS(.fps60)

        XCTAssertEqual(vm.maxFPS, .fps60)
        XCTAssertEqual(SceneRenderSettings.maxFPS, .fps60)
        XCTAssertEqual(applyCount, 1, "FPS 상한도 mount 시점에만 읽히므로 fit 과 동일하게 재적용을 태운다")
    }

    func testSetOcclusion_updatesRawAndFiresCallback() {
        let vm = makeVM(dir: tempDir())
        var received: Double?
        vm.onSetOcclusion = { received = $0 }

        vm.setOcclusion(0.5)

        XCTAssertEqual(vm.occlusionRaw, 0.5, "Picker 선택값 미러")
        XCTAssertEqual(received, 0.5, "decode·영속·타이머 재구성은 AppDelegate 위임")
    }

    func testSetPlaylistEnabled_updatesStoreAndFiresCallback() {
        let dir = tempDir()
        let vm = makeVM(dir: dir)
        var changedCount = 0
        vm.onPlaylistChanged = { changedCount += 1 }

        vm.setPlaylistEnabled(true)

        XCTAssertTrue(vm.playlistEnabled)
        XCTAssertEqual(changedCount, 1, "onPlaylistChanged — 재생목록 타이머 재구성 트리거")
    }

    func testSetPlaylistInterval_updatesStoreAndFiresCallback() {
        let dir = tempDir()
        let vm = makeVM(dir: dir)
        var changedCount = 0
        vm.onPlaylistChanged = { changedCount += 1 }

        vm.setPlaylistInterval(60)

        XCTAssertEqual(vm.playlistInterval, 60)
        XCTAssertEqual(changedCount, 1)
    }

    func testSetPlaylistShuffle_updatesStoreAndFiresCallback() {
        let dir = tempDir()
        let vm = makeVM(dir: dir)
        var changedCount = 0
        vm.onPlaylistChanged = { changedCount += 1 }

        vm.setPlaylistShuffle(true)

        XCTAssertTrue(vm.playlistShuffle)
        XCTAssertEqual(changedCount, 1)
    }

    func testSetPlaylistEnabled_persistsToStore() {
        let dir = tempDir()
        makeVM(dir: dir).setPlaylistEnabled(true)
        makeVM(dir: dir).setPlaylistShuffle(true)
        // 새 스토어로 재로드 → 영속 확인.
        let reloaded = PlaylistStore(baseDirectory: dir)
        XCTAssertTrue(reloaded.enabled)
        XCTAssertTrue(reloaded.shuffle)
    }

    func testSetStillSync_updatesMirrorAndFiresCallback() {
        let vm = makeVM(dir: tempDir())
        var received: Bool?
        vm.onSetStillSync = { received = $0 }

        vm.setStillSync(true)

        XCTAssertTrue(vm.stillSync)
        XCTAssertEqual(received, true)
    }

    func testToggleSaver_appliesCallbackResult() {
        let vm = makeVM(dir: tempDir())
        vm.onToggleSaver = { true }
        vm.saverSelected = false
        vm.toggleSaver()
        XCTAssertTrue(vm.saverSelected, "토글 성공 결과(Bool)가 체크 상태에 반영")

        vm.onToggleSaver = { false }
        vm.toggleSaver()
        XCTAssertFalse(vm.saverSelected)
    }

    func testToggleSaver_withoutClosureKeepsState() {
        let vm = makeVM(dir: tempDir())
        vm.saverSelected = true
        vm.toggleSaver()
        XCTAssertTrue(vm.saverSelected, "클로저 미주입(프리뷰) — 기존 상태 유지")
    }

    func testChooseBaseAssets_firesCallbackAndRereadsPath() {
        let vm = makeVM(dir: tempDir())
        var fired = 0
        vm.onChooseBaseAssets = { fired += 1 }

        vm.chooseBaseAssets()

        XCTAssertEqual(fired, 1, "NSOpenPanel 은 AppDelegate 위임")
        XCTAssertEqual(vm.baseAssetsPath,
                       BaseAssetsSettings.baseAssetsDirectory?.path ?? "(자동 탐지)",
                       "패널 반환 후 경로 재표시")
    }

    func testMakeStillNow_firesCallback() {
        let vm = makeVM(dir: tempDir())
        var fired = 0
        vm.onSetStillWallpaper = { fired += 1 }

        vm.makeStillNow()

        XCTAssertEqual(fired, 1, "현재 프레임 정지 배경화면 설정은 AppDelegate 위임")
    }

    /// 헤더 주석의 약속: 클로저 기본값은 no-op — 프리뷰/테스트 안전.
    func testSettersAreSafeWithoutInjectedClosures() {
        let saved = snapshotRenderSettings(); defer { restoreRenderSettings(saved) }
        let vm = makeVM(dir: tempDir())

        vm.setFit(.fit)
        vm.setMaxFPS(.fps30)
        vm.setOcclusion(0)
        vm.setPlaylistEnabled(true)
        vm.setPlaylistInterval(5)
        vm.setPlaylistShuffle(true)
        vm.setStillSync(true)
        vm.toggleSaver()
        vm.chooseBaseAssets()
        vm.makeStillNow()

        XCTAssertEqual(vm.fitMode, .fit)
        XCTAssertTrue(vm.playlistEnabled)
        XCTAssertTrue(vm.stillSync, "미러는 클로저 없이도 동작 — 크래시 없이 여기까지 도달해야 함")
    }

    // MARK: - refresh() 스토어 재읽기

    func testRefresh_rereadsRenderSettings() {
        let saved = snapshotRenderSettings(); defer { restoreRenderSettings(saved) }
        let vm = makeVM(dir: tempDir())

        // 트레이/적용 경로가 그 사이 바꾼 상황을 시뮬레이션(전역 스토어 직접 기록).
        SceneRenderSettings.fitMode = .stretch
        SceneRenderSettings.maxFPS = .fps60
        vm.refresh()

        XCTAssertEqual(vm.fitMode, .stretch, "창을 열 때마다 스토어에서 다시 읽는다")
        XCTAssertEqual(vm.maxFPS, .fps60)
    }

    func testRefresh_rereadsPlaylistStore() {
        let dir = tempDir()
        let store = PlaylistStore(baseDirectory: dir)
        let vm = SettingsViewModel(playlist: store)

        // NowPlayingBar 팝오버 등 같은 스토어를 공유하는 경로가 바꾼 상황.
        store.enabled = true
        store.intervalMinutes = 60
        store.shuffle = true
        vm.refresh()

        XCTAssertTrue(vm.playlistEnabled)
        XCTAssertEqual(vm.playlistInterval, 60)
        XCTAssertTrue(vm.playlistShuffle)
    }

    func testRefresh_mapsOcclusionStateToRaw() {
        let vm = makeVM(dir: tempDir())

        vm.occlusionState = { (true, 0.5) }
        vm.refresh()
        XCTAssertEqual(vm.occlusionRaw, 0.5, "enabled+threshold → Picker raw 역산(50% 옵션)")

        vm.occlusionState = { (false, 0.8) }
        vm.refresh()
        XCTAssertEqual(vm.occlusionRaw, -1, "비활성 → '사용 안 함'(-1)")
    }

    func testRefresh_rereadsStillSyncAndSystemFlags() {
        let vm = makeVM(dir: tempDir())
        vm.stillSyncEnabled = { true }
        vm.statusMessage = "이전 오류"

        vm.refresh()

        XCTAssertTrue(vm.stillSync, "주입 측정자 기준으로 재표시")
        XCTAssertNil(vm.statusMessage, "재열기 때 이전 상태 메시지 소거")
        XCTAssertEqual(vm.loginEnabled, LoginItemController.isEnabled, "실제 SMAppService status 재조회")
        XCTAssertEqual(vm.saverSelected, ScreenSaverController.isSelected, "실제 시스템 saver 선택 상태 재조회")
        XCTAssertEqual(vm.baseAssetsPath,
                       BaseAssetsSettings.baseAssetsDirectory?.path ?? "(자동 탐지)")
    }

    // MARK: - WE 재생정책 (stage 3④)
    //
    // `GlobalPlaybackSettings` 는 `UserDefaults` 전역이라 `.standard` 를 그대로 쓰면 테스트가
    // 개발자의 실제 설정을 바꾼다. `PlaybackPolicyRuntimeTests`(:19-29) 의 스위트 격리 관례를
    // 그대로 쓰되, 여기서는 클래스 전체가 아니라 이 블록의 테스트만 필요하므로 헬퍼로 감싼다.
    private func withIsolatedPlaybackDefaults(_ body: () -> Void) {
        let suite = "waple.tests.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite) else {
            return XCTFail("격리 스위트를 못 만들었다 — .standard 를 오염시키느니 실패시킨다")
        }
        GlobalPlaybackSettings.defaults = store
        defer {
            GlobalPlaybackSettings.defaults = .standard
            store.removePersistentDomain(forName: suite)
        }
        body()
    }

    /// 축 하나를 바꾸면 **저장·미러·재적용** 셋이 같이 일어난다. 재적용이 빠지면 사용자는
    /// 설정을 만진 뒤 최대 1초 동안 "안 먹었다" 를 본다(폴링이 그때 고친다).
    func testSetPlaybackAction_persistsMirrorsAndFiresReapply() {
        withIsolatedPlaybackDefaults {
            let vm = makeVM(dir: tempDir())
            var applied = 0
            vm.onPlaybackPolicyChanged = { applied += 1 }

            vm.setPlaybackAction(.pauseAll, for: .focus)

            XCTAssertEqual(GlobalPlaybackSettings.current.focus, .pauseAll, "WE 키·값으로 영속")
            XCTAssertEqual(vm.playbackPolicy.focus, .pauseAll, "@Published 미러 즉시 갱신")
            XCTAssertEqual(applied, 1, "즉시 재적용 — 폴링을 기다리지 않는다")
            XCTAssertEqual(GlobalPlaybackSettings.current.maximized, .pause,
                           "손대지 않은 축은 WE 기본값 그대로")
        }
    }

    /// **되돌리기는 "끄기" 가 아니다.** 미설정이 곧 WE 기본값이라, 되돌리면 최대화·전체화면
    /// 정지가 다시 켜진다. 이걸 "전 축 run" 으로 착각한 구현은 사용자가 되돌리기를 누른 뒤
    /// 정책이 통째로 사라지게 만든다.
    func testResetPlaybackPolicy_returnsToWEDefaultsNotAllRun() {
        withIsolatedPlaybackDefaults {
            let vm = makeVM(dir: tempDir())
            var applied = 0
            vm.onPlaybackPolicyChanged = { applied += 1 }
            vm.setPlaybackAction(.run, for: .maximized)
            vm.setPlaybackAction(.run, for: .displaySleep)

            vm.resetPlaybackPolicy()

            XCTAssertEqual(vm.playbackPolicy, .weDefault)
            XCTAssertNotEqual(vm.playbackPolicy, .allRun, "되돌리기는 정책을 끄는 것이 아니다")
            XCTAssertEqual(GlobalPlaybackSettings.current, .weDefault)
            XCTAssertEqual(applied, 3, "되돌리기도 재적용을 태운다")
        }
    }

    /// 창을 열 때마다 스토어에서 다시 읽는다 — 다른 경로(가져오기·트레이)가 그 사이 바꿨을 수 있다.
    func testRefresh_rereadsPlaybackPolicyFromStore() {
        withIsolatedPlaybackDefaults {
            let vm = makeVM(dir: tempDir())
            XCTAssertEqual(vm.playbackPolicy, .weDefault)

            GlobalPlaybackSettings.set(.mute, for: .audio)
            vm.refresh()

            XCTAssertEqual(vm.playbackPolicy.audio, .mute, "뷰모델 밖에서 바뀐 값을 다시 읽는다")
        }
    }

    /// 축별 선택지는 **WE 의 UI 빌더 표** 그대로다(`k(e,t,a)` — 첫 인자가 축마다 갈린다).
    /// 여기서 다시 정하지 않는다는 것이 요점이라, 뷰모델이 그 표를 우회하면 이 단언이 깨진다.
    func testPlaybackOptions_followTheAxisTableNotAFlatList() {
        let vm = makeVM(dir: tempDir())

        vm.multiMonitor = { false }
        XCTAssertEqual(vm.playbackOptions(for: .focus), [.run, .mute, .pause],
                       "focus 는 stop 분기가 없다")
        XCTAssertEqual(vm.playbackOptions(for: .displaySleep), [.run, .pause, .stop],
                       "sleep 은 mute 를 제시하지 않는다")

        vm.multiMonitor = { true }
        XCTAssertEqual(vm.playbackOptions(for: .focus), [.run, .mute, .pause, .pauseAll],
                       "창 상태 축만 멀티모니터에서 pauseall 을 얻는다")
        XCTAssertEqual(vm.playbackOptions(for: .displaySleep), [.run, .pause, .stop],
                       "sleep·battery·audio 는 모니터가 몇 대든 pauseall 이 없다")
    }
}
