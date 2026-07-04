import XCTest
@testable import WapleRender

/// MediaPoller 단위 테스트(이전 커버리지 0). 상태전이/dedupe 는 deliver 직접 호출로 결정적 검증하고,
/// 가짜 프로바이더 경로(fetch→아트워크→배달)는 비동기 expectation 으로 확인한다.
final class MediaPollerTests: XCTestCase {
    private struct FixedProvider: NowPlayingProvider {
        var info: NowPlayingInfo?
        func fetch() -> NowPlayingInfo? { info }
    }
    private struct ArtProvider: NowPlayingProvider, ArtworkProviding {
        let info: NowPlayingInfo
        let art: Data?
        func fetch() -> NowPlayingInfo? { info }
        func fetchArtwork() -> Data? { art }
    }

    func testStateTransitionAndPropertyDedupe() {
        let poller = MediaPoller(provider: FixedProvider(info: nil))
        var playback = 0, props = 0, timeline = 0, thumb = 0
        poller.onPlayback = { _ in playback += 1 }
        poller.onProperties = { _ in props += 1 }
        poller.onTimeline = { _ in timeline += 1 }
        poller.onThumbnail = { _, _ in thumb += 1 }

        let playing = NowPlayingInfo(state: .playing, title: "A", artist: "B", album: "C")
        // 1) nil→playing: 상태·속성 변화 + 재생 중 timeline
        poller.deliver(playing, artwork: nil, trackKey: "A|B|C")
        XCTAssertEqual([playback, props, timeline], [1, 1, 1])
        XCTAssertEqual(poller.deliveryCount, 1)

        // 2) 동일 트랙·상태 재배달: playback/props dedupe, timeline 은 재생 중이라 매 틱
        poller.deliver(playing, artwork: nil, trackKey: "A|B|C")
        XCTAssertEqual([playback, props], [1, 1], "변화 없음 → dedupe")
        XCTAssertEqual(timeline, 2, "재생 중 매 틱 timeline")
        XCTAssertEqual(poller.deliveryCount, 2)

        // 3) paused 로 상태 변화: playback+1, 속성 동일 dedupe, timeline 정지
        let paused = NowPlayingInfo(state: .paused, title: "A", artist: "B", album: "C")
        poller.deliver(paused, artwork: nil, trackKey: "A|B|C")
        XCTAssertEqual(playback, 2)
        XCTAssertEqual(props, 1)
        XCTAssertEqual(timeline, 2, "정지 상태 → timeline 없음")

        // 4) 아트워크 동반 → onThumbnail
        poller.deliver(paused, artwork: Data([1, 2, 3]), trackKey: "A|B|C")
        XCTAssertEqual(thumb, 1)
    }

    func testPropertyChangeFiresOnEachTrackChange() {
        let poller = MediaPoller(provider: FixedProvider(info: nil))
        var props = 0
        poller.onProperties = { _ in props += 1 }
        poller.deliver(NowPlayingInfo(state: .playing, title: "A"), artwork: nil, trackKey: "A||")
        poller.deliver(NowPlayingInfo(state: .playing, title: "B"), artwork: nil, trackKey: "B||")
        XCTAssertEqual(props, 2, "제목 변화마다 onProperties")
    }

    /// 가짜 프로바이더로 실제 poll 경로(start→fire→fetch→아트워크→메인 배달)를 비동기 확인.
    func testStartPollsProviderAndDeliversWithArtwork() {
        let provider = ArtProvider(info: NowPlayingInfo(state: .playing, title: "Song", artist: "Art", album: "Alb"),
                                   art: Data([9, 9]))
        let poller = MediaPoller(provider: provider)
        let gotProps = expectation(description: "properties")
        let gotThumb = expectation(description: "thumbnail")
        poller.onProperties = { info in
            XCTAssertEqual(info.title, "Song")
            gotProps.fulfill()
        }
        poller.onThumbnail = { _, data in
            XCTAssertEqual(data, Data([9, 9]))
            gotThumb.fulfill()
        }
        poller.start()  // fire() 로 즉시 1회 poll — 반복 간격 5s 라 wait(3s) 중 재발 없음
        wait(for: [gotProps, gotThumb], timeout: 3)
        poller.stop()
    }
}
