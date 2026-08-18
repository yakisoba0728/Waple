import XCTest
@testable import Waple

final class NowPlayingSubtitleTests: XCTestCase {
    func testNoWallpaper() {
        XCTAssertEqual(NowPlayingSubtitle.text(typeRaw: nil, playlistCount: 0,
                                               intervalMinutes: 30, playlistEnabled: false),
                       "라이브러리에서 배경을 선택하세요")
    }

    func testTypeOnly() {
        XCTAssertEqual(NowPlayingSubtitle.text(typeRaw: "scene", playlistCount: 0,
                                               intervalMinutes: 30, playlistEnabled: false),
                       "장면")
    }

    func testTypeWithPlaylistOff() {
        XCTAssertEqual(NowPlayingSubtitle.text(typeRaw: "video", playlistCount: 3,
                                               intervalMinutes: 15, playlistEnabled: false),
                       "동영상 · 재생목록 3개")
    }

    func testTypeWithPlaylistOn() {
        XCTAssertEqual(NowPlayingSubtitle.text(typeRaw: "web", playlistCount: 5,
                                               intervalMinutes: 15, playlistEnabled: true),
                       "웹 · 재생목록 5개 · 15분마다 전환")
    }

    // MARK: - 하단 바 음량/배속 컨트롤 노출 (w5d-settings-ia)

    /// 배속은 동영상 전용이다 — `SceneAudioPlayer` 에 배속 개념이 없다.
    func testShowsVideoControlsOnlyForVideoType() {
        XCTAssertTrue(NowPlayingSubtitle.showsVideoControls(typeRaw: "video"))
        XCTAssertFalse(NowPlayingSubtitle.showsVideoControls(typeRaw: "scene"))
        XCTAssertFalse(NowPlayingSubtitle.showsVideoControls(typeRaw: "web"))
        XCTAssertFalse(NowPlayingSubtitle.showsVideoControls(typeRaw: nil), "적용된 배경이 없으면 노출 안 함")
    }

    /// 음량은 **씬에도** 열려 있어야 한다.
    ///
    /// 씬 BGM 이 항상 무음이던 원인이 여기였다. `SceneAudioPlayer` 는 재생을 실제로 하고
    /// 있었고(코퍼스 실측 자동재생 사운드 157개 / 119씬), 최종 음량이
    /// `오서 볼륨 × VideoSettings.volume(id:)` 인데 후자 기본값이 0(음소거)이다.
    /// 그 값을 올리는 UI 가 `.video` 로 좁혀져 있어서 **씬 사용자는 올릴 방법이 없었다** —
    /// 유일한 우회로가 `defaults write waple.video.volume.<id>` 였다.
    ///
    /// 기본값 0 자체는 유지한다("바탕화면이 예고 없이 소리 내지 않는다"). 바꾼 것은
    /// 노출 범위뿐이다. 웹은 제외 — 웹 오디오는 이 볼륨 배관을 타지 않는다.
    func testShowsVolumeControlForVideoAndScene() {
        XCTAssertTrue(NowPlayingSubtitle.showsVolumeControl(typeRaw: "video"))
        XCTAssertTrue(NowPlayingSubtitle.showsVolumeControl(typeRaw: "scene"),
                      "씬 BGM 도 VideoSettings.volume 을 타므로 올릴 창구가 있어야 한다")
        XCTAssertFalse(NowPlayingSubtitle.showsVolumeControl(typeRaw: "web"))
        XCTAssertFalse(NowPlayingSubtitle.showsVolumeControl(typeRaw: nil), "적용된 배경이 없으면 노출 안 함")
    }
}
