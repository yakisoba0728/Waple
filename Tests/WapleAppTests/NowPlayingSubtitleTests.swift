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
}
