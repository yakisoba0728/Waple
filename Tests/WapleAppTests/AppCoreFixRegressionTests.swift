import XCTest
@testable import Waple
import WapleCore

/// 감사 2차 라운드(fix-g7, Waple 앱 코어) 회귀 테스트 — F480~F489.
/// 순수 결정 로직만 검증한다. AppDelegate 스레드 구조 변경(F485/F486)과 라이프사이클 글루
/// (F482 폴백 게이트/F487 선소거 제거)는 단위 테스트가 비현실적이라 커버하지 않는다(사유: 화면
/// 구성·렌더러·UserDefaults 영속이 얽힌 통합 지점이라 순수 함수 추출이 오히려 왜곡을 만든다).
final class AppCoreFixRegressionTests: XCTestCase {

    // MARK: - F480(F-30): 최근 배경은 파서 id 가 아니라 엔트리 id — F194 접미 유일화 정합

    func testRecentEntryId_matchesByFolderPath_notParserId() {
        // 시나리오: workshopid/폴더명 충돌로 두 번째 배경이 "x-2" 로 유일화됨(F194).
        // 파서 id("x")로 push 하면 첫 번째 배경을 가리키는 결함 — 엔트리 id 로 역탐색해야 한다.
        let entries = [(id: "x", path: "/lib/a"), (id: "x-2", path: "/lib/b")]
        XCTAssertEqual(RecentWallpapers.entryId(matchingFolderPath: "/lib/b", entries: entries), "x-2",
                       "접미 유일화 엔트리의 마운트 폴더는 자기 엔트리 id(x-2)로 해석돼야 한다")
        XCTAssertEqual(RecentWallpapers.entryId(matchingFolderPath: "/lib/a", entries: entries), "x")
    }

    func testRecentEntryId_noMatch_returnsNil() {
        let entries = [(id: "x", path: "/lib/a")]
        XCTAssertNil(RecentWallpapers.entryId(matchingFolderPath: "/lib/elsewhere", entries: entries),
                     "라이브러리 밖 폴더면 nil — 파서 id 폴백을 섞으면 같은 불일치가 재발한다")
        XCTAssertNil(RecentWallpapers.entryId(matchingFolderPath: "/lib/a", entries: []))
    }

    // MARK: - F481(F-31): 종료 시 원본 복원은 자동 동기화 ON 일 때만

    func testShouldRestoreOnTerminate_gatedBySyncEnabled() {
        XCTAssertTrue(StillDesktopSync.shouldRestoreOnTerminate(syncEnabled: true),
                      "동기화 ON — 동기화가 덮어쓴 바탕화면은 종료 시 원복")
        XCTAssertFalse(StillDesktopSync.shouldRestoreOnTerminate(syncEnabled: false),
                       "동기화 OFF — 수동 1회 설정(명시적 사용자 액션)까지 종료 시 되돌리면 모순")
    }

    // MARK: - F483(F-33): 재생목록 1개 → 자동전환 타이머를 걸지 않는다

    func testShouldScheduleTimer_singleItem_doesNotRun() {
        XCTAssertFalse(PlaylistScheduling.shouldScheduleTimer(enabled: true, ids: ["a"]),
                       "1개뿐이면 매 간격 같은 배경 리마운트만 발생 — 수동 버튼 canAdvance 가드와 대칭")
        XCTAssertFalse(PlaylistScheduling.shouldScheduleTimer(enabled: true, ids: []))
        XCTAssertFalse(PlaylistScheduling.shouldScheduleTimer(enabled: false, ids: ["a", "b"]))
        XCTAssertTrue(PlaylistScheduling.shouldScheduleTimer(enabled: true, ids: ["a", "b"]),
                      "2개 이상 + 활성 → 타이머 가동")
    }

    // MARK: - F484(F-34): 스틸 캐시/출력 키에 크기 포함(크기 의존 소스만)

    func testStillOutputURL_includesSizeForSceneCapture() {
        let dir = URL(fileURLWithPath: "/s")
        let sized = StillWallpaper.outputURL(projectId: "abc 123!", size: CGSize(width: 2560, height: 1440), stillDir: dir)
        XCTAssertEqual(sized.lastPathComponent, "abc-123-2560x1440.png",
                       "씬 캡처는 크기별로 다른 파일 — 모니터 해상도가 달라도 스틸 공유 오염 없음")
        // 무크기(비디오 프레임/preview)는 기존 경로 규약 유지(DesktopIntegrationTests 와 동일 기대).
        let plain = StillWallpaper.outputURL(projectId: "abc 123!", stillDir: dir)
        XCTAssertEqual(plain.lastPathComponent, "abc-123.png")
    }

    func testStillCacheKey_sizeDependentOnlyForSceneCapture() {
        let size = CGSize(width: 1920, height: 1080)
        XCTAssertTrue(StillWallpaper.isSizeDependent(.sceneCapture))
        XCTAssertFalse(StillWallpaper.isSizeDependent(.videoFrame(URL(fileURLWithPath: "/v.mp4"))))
        XCTAssertFalse(StillWallpaper.isSizeDependent(.previewImage(URL(fileURLWithPath: "/p.jpg"))))
        XCTAssertEqual(StillWallpaper.cacheKey(projectId: "p", size: size, sizeDependent: true), "p#1920x1080")
        XCTAssertEqual(StillWallpaper.cacheKey(projectId: "p", size: size, sizeDependent: false), "p",
                       "크기 무관 소스는 id 키 유지 — 다른 크기 모니터끼리 정상 공유")
        XCTAssertNotEqual(
            StillWallpaper.cacheKey(projectId: "p", size: CGSize(width: 1920, height: 1080), sizeDependent: true),
            StillWallpaper.cacheKey(projectId: "p", size: CGSize(width: 3440, height: 1440), sizeDependent: true),
            "같은 씬이라도 화면 크기가 다르면 캐시가 갈려야 한다")
    }

    // MARK: - F488(F-94): intervalSeconds 오버플로 트랩 방지(상한 클램프)

    func testIntervalSeconds_hugeMinutes_clampedNotTrapped() {
        XCTAssertEqual(PlaylistScheduling.intervalSeconds(minutes: .max), 31_536_000,
                       "Int.max 분도 곱셈 오버플로 트랩 없이 1년(525_600분)으로 클램프")
        XCTAssertEqual(PlaylistScheduling.intervalSeconds(minutes: 525_600), 31_536_000, "경계값 통과")
        XCTAssertEqual(PlaylistScheduling.intervalSeconds(minutes: 525_601), 31_536_000, "경계+1 클램프")
        // 기존 동작 무회귀(하한/정상값은 AppLogicTests.testIntervalSeconds 가 고정)
        XCTAssertEqual(PlaylistScheduling.intervalSeconds(minutes: -3), 60)
    }

    // MARK: - F489(F-96): enable→disable 사이 사용자 직접 변경 시 옛 백업 복원 방지

    func testShouldDiscardBackup_onlyWhenSelectionCleared() {
        XCTAssertTrue(ScreenSaverLogic.shouldDiscardBackup(current: nil),
                      "'없음' 해제 후 재활성 — 옛 백업은 스테일이라 폐기")
        XCTAssertFalse(ScreenSaverLogic.shouldDiscardBackup(current: ["moduleName": "Flurry"]),
                       "다른 saver 는 shouldBackup 이 새로 덮어쓴다")
        XCTAssertFalse(ScreenSaverLogic.shouldDiscardBackup(
            current: ["moduleName": ScreenSaverLogic.saverName]),
            "Waple 재활성 — 최초 백업 보존")
    }

    func testShouldRestoreBackup_onlyWhenWapleStillSelected() {
        XCTAssertTrue(ScreenSaverLogic.shouldRestoreBackup(
            current: ScreenSaverLogic.moduleDict(installedPath: "/x/Waple.saver")),
            "현재 선택이 Waple — 정상 원복 경로")
        XCTAssertFalse(ScreenSaverLogic.shouldRestoreBackup(current: ["moduleName": "Flurry", "path": "/y", "type": 0]),
                       "사용자가 다른 saver 로 직접 변경 — 옛 백업으로 덮어쓰지 않음")
        XCTAssertFalse(ScreenSaverLogic.shouldRestoreBackup(current: nil),
                       "사용자가 '없음'으로 해제 — 제거 상태 존중")
    }
}
