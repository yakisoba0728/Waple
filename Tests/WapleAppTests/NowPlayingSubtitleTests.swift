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

    func testShowsVideoControlsOnlyForVideoType() {
        XCTAssertTrue(NowPlayingSubtitle.showsVideoControls(typeRaw: "video"))
        XCTAssertFalse(NowPlayingSubtitle.showsVideoControls(typeRaw: "scene"))
        XCTAssertFalse(NowPlayingSubtitle.showsVideoControls(typeRaw: "web"))
        XCTAssertFalse(NowPlayingSubtitle.showsVideoControls(typeRaw: nil), "적용된 배경이 없으면 노출 안 함")
    }
}
