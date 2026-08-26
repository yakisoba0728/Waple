import XCTest
import CoreGraphics
@testable import Waple
import WapleCore
import WaplePolicy

/// stage 2 의 순수 코어 — 전역 정책면 · 두 층 병합 · 창 파생 마스크.
///
/// `SceneRenderSettingsTests`(:22-32)의 suite 격리 관례를 그대로 쓴다 — 프로세스 id + UUID 로
/// 테스트마다 고유한 `UserDefaults` 를 만들어 `.standard` 를 건드리지 않는다.
///
/// **클래스에 `@MainActor` 를 붙이지 마라.** 여기 검증 대상은 전부 static 순수 함수라 필요가
/// 없고, 붙이면 `override func setUp()` 이 리눅스 swift-corelibs-xctest 에서 nonisolated 로
/// 고정돼 타입체크가 깨진다(`RENDER_TEST_EXCLUDED` 의 `VideoLiveSettingsTests` 와 같은 부류).
final class PlaybackPolicyRuntimeTests: XCTestCase {
    private var suiteName: String!
    private var store: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "waple.tests.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
        store = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        GlobalPlaybackSettings.defaults = store
    }

    override func tearDownWithError() throws {
        GlobalPlaybackSettings.defaults = .standard
        store.removePersistentDomain(forName: suiteName)
    }

    private func project(_ playback: [String: String]) -> WallpaperProject {
        WallpaperProject(id: "p", type: .scene, fileName: nil, previewName: nil,
                         title: "p", tags: [], contentRating: nil, workshopId: nil,
                         dependency: nil, folderURL: URL(fileURLWithPath: "/tmp/p"),
                         playbackProperties: playback)
    }

    // MARK: - 전역면

    /// **미설정 = WE 기본값.** 처음 실행하는 사용자가 WE 와 같은 동작을 얻는다는 계약이고,
    /// 그 값들은 설치본 `config.json` 의 `general/user` 실측과 전 축 일치한다(런타임 파일 머리말).
    func testUnsetGlobalPolicyIsExactlyWEDefault() {
        XCTAssertEqual(GlobalPlaybackSettings.current, PlaybackPolicy.weDefault)
        // 값도 명시로 못 박는다 — weDefault 가 바뀌면 이 단언이 먼저 깨져야 한다.
        let p = GlobalPlaybackSettings.current
        XCTAssertEqual(p.focus, .run)
        XCTAssertEqual(p.maximized, .pause)
        XCTAssertEqual(p.fullscreen, .pause)
        XCTAssertEqual(p.audio, .run)
        XCTAssertEqual(p.displaySleep, .stop)
        XCTAssertEqual(p.battery, .run)
        XCTAssertFalse(p.pauseVRAM)
    }

    func testSettingATriggerIsReadBack() {
        GlobalPlaybackSettings.set(.pauseAll, for: .focus)
        XCTAssertEqual(GlobalPlaybackSettings.current.focus, .pauseAll)
        // 손대지 않은 축은 여전히 WE 기본값이다.
        XCTAssertEqual(GlobalPlaybackSettings.current.displaySleep, .stop)
    }

    func testResetReturnsEveryAxisToWEDefault() {
        for trigger in PlaybackTrigger.allCases { GlobalPlaybackSettings.set(.stop, for: trigger) }
        GlobalPlaybackSettings.setPauseVRAM(true)
        GlobalPlaybackSettings.reset()
        XCTAssertEqual(GlobalPlaybackSettings.current, PlaybackPolicy.weDefault)
    }

    /// `pausevram` 은 `object(forKey:)` 로 읽어야 한다. `bool(forKey:)` 는 **미설정을 false 로
    /// 뭉개서** "미설정" 과 "명시 false" 를 구분하지 못한다. 지금은 WE 기본값이 마침 false 라
    /// 결과가 같지만, 그 구분을 못 하는 코드는 기본값이 바뀌는 날 조용히 틀린다.
    /// 이 테스트는 그 구분이 실제로 살아 있는지를 본다.
    func testPauseVRAMDistinguishesUnsetFromExplicitFalse() {
        XCTAssertNil(store.object(forKey: GlobalPlaybackSettings.vramKey), "전제: 미설정")
        XCTAssertEqual(GlobalPlaybackSettings.current.pauseVRAM, PlaybackPolicy.weDefault.pauseVRAM)

        GlobalPlaybackSettings.setPauseVRAM(false)
        XCTAssertNotNil(store.object(forKey: GlobalPlaybackSettings.vramKey), "명시 false 는 키가 존재해야 한다")
        XCTAssertFalse(GlobalPlaybackSettings.current.pauseVRAM)

        GlobalPlaybackSettings.setPauseVRAM(true)
        XCTAssertTrue(GlobalPlaybackSettings.current.pauseVRAM)
    }

    /// 키 이름은 WE 것을 그대로 쓴다(접두만 붙는다) — 나중에 WE 설치본에서 가져오기를 붙일 때
    /// 매핑표가 필요 없게 하려는 것이다. 접두를 뗀 나머지가 `weConfigKey` 와 같아야 한다.
    func testDefaultsKeysMirrorWEConfigKeyNames() {
        for trigger in PlaybackTrigger.allCases {
            let k = GlobalPlaybackSettings.key(for: trigger)
            XCTAssertTrue(k.hasPrefix(GlobalPlaybackSettings.prefix))
            XCTAssertEqual(String(k.dropFirst(GlobalPlaybackSettings.prefix.count)), trigger.weConfigKey)
        }
        XCTAssertEqual(GlobalPlaybackSettings.vramKey, GlobalPlaybackSettings.prefix + "pausevram")
    }

    // MARK: - 두 층 병합

    /// **stage 1 과의 결정적 차이.** 종전에는 벽지가 아무것도 선언하지 않으면 `.running` 으로
    /// 단축했는데, 이제는 전역 정책이 그대로 적용된다 — WE 의 `""` 주입이 뜻하는 바다.
    func testNothingDeclaredYieldsGlobalPolicyUnchanged() {
        GlobalPlaybackSettings.set(.pauseAll, for: .maximized)
        let effective = PlaybackPolicyResolver.effective(global: GlobalPlaybackSettings.current, declaring: [:])
        XCTAssertEqual(effective, GlobalPlaybackSettings.current)
        XCTAssertEqual(effective.maximized, .pauseAll, "전역 설정이 살아 있어야 한다")
    }

    func testDeclaredAxisOverridesGlobalAndOthersSurvive() {
        GlobalPlaybackSettings.set(.stop, for: .focus)
        GlobalPlaybackSettings.set(.stop, for: .audio)
        let effective = PlaybackPolicyResolver.effective(
            global: GlobalPlaybackSettings.current,
            declaring: ["playbackfocus": "run"])
        XCTAssertEqual(effective.focus, .run, "선언한 축은 덮어쓴다")
        XCTAssertEqual(effective.audio, .stop, "선언하지 않은 축은 전역 그대로")
    }

    /// 빈 문자열은 "전역을 따른다" 는 뜻이라 덮어쓰지 않는다. 파서가 이미 버리지만,
    /// 딕셔너리가 다른 경로로 들어와도 계약이 유지돼야 한다.
    func testEmptyDeclarationDoesNotOverride() {
        GlobalPlaybackSettings.set(.stop, for: .focus)
        let effective = PlaybackPolicyResolver.effective(
            global: GlobalPlaybackSettings.current,
            declaring: ["playbackfocus": ""])
        XCTAssertEqual(effective.focus, .stop)
    }

    /// 미인식 문자열은 `PlaybackAction(weConfigValue:)` 규약대로 조용히 `.run` 이다(매퍼 0x140141918).
    /// 즉 오타는 "정책 없음" 이 아니라 **run 으로 덮어쓰기** 다 — 전역과 다를 수 있으므로 못 박는다.
    func testUnknownDeclarationBecomesRunNotPassthrough() {
        GlobalPlaybackSettings.set(.stop, for: .focus)
        let effective = PlaybackPolicyResolver.effective(
            global: GlobalPlaybackSettings.current,
            declaring: ["playbackfocus": "definitely-not-an-action"])
        XCTAssertEqual(effective.focus, .run)
    }

    /// 벽지가 전 축을 선언하면 전역은 결과에 하나도 남지 않는다.
    func testFullyDeclaredWallpaperIgnoresGlobalEntirely() {
        for trigger in PlaybackTrigger.allCases { GlobalPlaybackSettings.set(.stop, for: trigger) }
        var declared: [String: String] = [:]
        for trigger in PlaybackTrigger.allCases { declared[trigger.weConfigKey] = "run" }
        let effective = PlaybackPolicyResolver.effective(global: GlobalPlaybackSettings.current, declaring: declared)
        for trigger in PlaybackTrigger.allCases {
            XCTAssertEqual(effective[trigger], .run, "\(trigger.weConfigKey)")
        }
    }

    /// 조건이 하나도 성립하지 않으면 어떤 정책이든 판정은 재생이다 — 관측자가 붙기 전
    /// (조건 전부 기본값) 무동작이라는 뜻이라, stage 2b 착지 전 무회귀의 근거가 된다.
    func testNoConditionsMeansRunningEvenUnderWEDefaults() {
        let verdict = PlaybackPolicyResolver.verdict(
            for: project([:]),
            conditions: PlaybackConditions(allMonitorsMask: 1),
            global: PlaybackPolicy.weDefault)
        XCTAssertFalse(verdict.stop)
        XCTAssertFalse(verdict.muted)
        XCTAssertEqual(verdict.pauseMask, 0)
    }

    /// 반대로 조건이 서면 WE 기본값에서 실제로 멈춘다 — 이 커밋이 무엇을 바꾸는지의 오라클이다.
    func testMaximizedPausesUnderWEDefaults() {
        let verdict = PlaybackPolicyResolver.verdict(
            for: project([:]),
            conditions: PlaybackConditions(allMonitorsMask: 1, maximizedMask: 1),
            global: PlaybackPolicy.weDefault)
        XCTAssertEqual(verdict.pauseMask, 1)
    }

    /// 그리고 벽지가 명시로 `run` 을 선언하면 그 전역 동작을 되돌린다.
    func testWallpaperCanOptOutOfGlobalMaximizedPause() {
        let verdict = PlaybackPolicyResolver.verdict(
            for: project(["playbackmaximized": "run"]),
            conditions: PlaybackConditions(allMonitorsMask: 1, maximizedMask: 1),
            global: PlaybackPolicy.weDefault)
        XCTAssertEqual(verdict.pauseMask, 0)
    }

    /// **이 라운드가 바꾸는 것의 오라클.** 아무것도 선언하지 않은 같은 벽지가, 같은 조건에서,
    /// 전역이 `.allRun`(= stage 1 의 의미)이면 무동작이고 `.weDefault`(= WE 실물 기본값)이면
    /// 멈춘다. 두 값이 **달라야** 이 변경이 실제 효과를 갖는다 — 같아지면 여기서 먼저 깨진다.
    func testGlobalSurfaceIsWhatMakesTheDifference() {
        let undeclared = project([:])
        let conditions = PlaybackConditions(allMonitorsMask: 0b1, maximizedMask: 0b1, fullscreenMask: 0b1)

        let stage1 = PlaybackPolicyResolver.verdict(for: undeclared, conditions: conditions, global: .allRun)
        let stage2 = PlaybackPolicyResolver.verdict(for: undeclared, conditions: conditions, global: .weDefault)

        XCTAssertEqual(stage1, .running, "정책이 어디에도 없으면 무동작")
        XCTAssertNotEqual(stage2, .running, "WE 기본값에서는 최대화·전체화면이 실제로 멈춘다")
        XCTAssertEqual(stage2.pauseMask, 0b1)
    }

    // MARK: - 창 파생 마스크

    private func win(_ pid: Int, _ r: CGRect, layer: Int = 0, alpha: Double = 1) -> DesktopVisibilityMonitor.WindowSnapshot {
        .init(ownerName: "app\(pid)", processId: pid, layer: layer, alpha: alpha, bounds: r)
    }

    private let screenA = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let screenB = CGRect(x: 1920, y: 0, width: 1920, height: 1080)

    func testScreenIndexPicksLargestOverlapNotFirstHit() {
        // 두 화면에 걸치되 B 쪽이 더 넓은 창.
        let straddling = CGRect(x: 1720, y: 0, width: 800, height: 1080)   // A 200 · B 600
        XCTAssertEqual(PlaybackMasks.screenIndex(of: straddling, screenFrames: [screenA, screenB]), 1)
    }

    func testScreenIndexIsNilWhenOffscreen() {
        XCTAssertNil(PlaybackMasks.screenIndex(of: CGRect(x: -500, y: -500, width: 10, height: 10),
                                               screenFrames: [screenA]))
    }

    /// 허용오차는 **양방향**이다. 화면보다 큰 창(다중 화면에 걸친 창)을 최대화로 오판하면
    /// 모든 화면이 한꺼번에 멈춘다 — 그래서 "덮는다(포함)" 가 아니라 근사 일치로 본다.
    func testCoversRejectsWindowsLargerThanTheScreen() {
        XCTAssertTrue(PlaybackMasks.covers(CGRect(x: 2, y: 2, width: 1918, height: 1078), screenA),
                      "몇 포인트 어긋남은 최대화로 본다")
        XCTAssertFalse(PlaybackMasks.covers(CGRect(x: 0, y: 0, width: 3840, height: 1080), screenA),
                       "두 화면을 덮는 창은 A 의 최대화가 아니다")
    }

    func testMaximizedAndFullscreenUseDifferentTargets() {
        let visibleA = CGRect(x: 0, y: 25, width: 1920, height: 1030)   // 메뉴바·독 제외
        let windows = [win(42, visibleA)]
        XCTAssertEqual(PlaybackMasks.maximized(windows: windows, currentProcessId: 1, visibleFrames: [visibleA]), 1)
        XCTAssertEqual(PlaybackMasks.fullscreen(windows: windows, currentProcessId: 1, screenFrames: [screenA]), 0,
                       "visibleFrame 을 덮는 창은 전체화면이 아니다")
    }

    func testOwnWindowsNeverSetAnyMask() {
        let mine = [win(1, screenA)]
        XCTAssertEqual(PlaybackMasks.maximized(windows: mine, currentProcessId: 1, visibleFrames: [screenA]), 0)
        XCTAssertEqual(PlaybackMasks.fullscreen(windows: mine, currentProcessId: 1, screenFrames: [screenA]), 0)
        XCTAssertEqual(PlaybackMasks.unfocused(windows: mine, frontmostProcessId: 1,
                                               currentProcessId: 1, screenFrames: [screenA]), 0)
    }

    /// 데스크탑 레이어·투명 창은 남의 앱이어도 화면을 점유하는 것으로 보지 않는다.
    func testDesktopLayerAndTransparentWindowsAreIgnored() {
        let desktop = [win(42, screenA, layer: -1)]
        let ghost = [win(42, screenA, alpha: 0)]
        XCTAssertEqual(PlaybackMasks.fullscreen(windows: desktop, currentProcessId: 1, screenFrames: [screenA]), 0)
        XCTAssertEqual(PlaybackMasks.fullscreen(windows: ghost, currentProcessId: 1, screenFrames: [screenA]), 0)
    }

    func testUnfocusedMarksOnlyScreensTheFrontmostAppOccupies() {
        let windows = [win(42, CGRect(x: 1920, y: 100, width: 400, height: 300)),   // B
                       win(99, CGRect(x: 0, y: 100, width: 400, height: 300))]      // A, 포커스 아님
        let mask = PlaybackMasks.unfocused(windows: windows, frontmostProcessId: 42,
                                           currentProcessId: 1, screenFrames: [screenA, screenB])
        XCTAssertEqual(mask, 0b10)
    }

    /// 화면을 점유하지 않는 포커스 앱(메뉴바 전용 등)에는 벽지를 멈출 이유가 없다.
    func testFrontmostAppWithNoWindowsYieldsZeroMask() {
        let windows = [win(99, CGRect(x: 0, y: 0, width: 400, height: 300))]
        XCTAssertEqual(PlaybackMasks.unfocused(windows: windows, frontmostProcessId: 42,
                                               currentProcessId: 1, screenFrames: [screenA]), 0)
    }

    func testAllMonitorsMaskEdges() {
        XCTAssertEqual(PlaybackMasks.allMonitors(count: 0), 0)
        XCTAssertEqual(PlaybackMasks.allMonitors(count: 1), 0b1)
        XCTAssertEqual(PlaybackMasks.allMonitors(count: 3), 0b111)
        XCTAssertEqual(PlaybackMasks.allMonitors(count: 32), UInt32.max, "32개는 전 비트")
        XCTAssertEqual(PlaybackMasks.allMonitors(count: 99), UInt32.max, "폭을 넘으면 잘린다(오버플로 아님)")
    }

    /// 33번째 이상의 화면은 마스크에 넣지 않는다 — `1 << 32` 는 `UInt32` 에서 오버플로다.
    /// 이 테스트가 없으면 33모니터 환경에서 크래시로만 드러난다.
    func testScreensBeyondBitWidthDoNotOverflow() {
        let frames = (0..<40).map { CGRect(x: CGFloat($0) * 100, y: 0, width: 100, height: 100) }
        let windows = frames.enumerated().map { win(42, $0.element) }
        XCTAssertEqual(PlaybackMasks.fullscreen(windows: windows, currentProcessId: 1, screenFrames: frames),
                       UInt32.max, "0..31 비트만 서고 32번째부터는 무시된다")
    }
}
