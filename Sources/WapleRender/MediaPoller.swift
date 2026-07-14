import AppKit

/// 지금 재생 중 폴러(웹/씬 공용): 5초 간격(AppleScript 비용과 체감 실시간성의 균형)으로 fetch,
/// 변화 감지 후 종류별 콜백 배달(메인 스레드). 트랙(제목|아티스트|앨범) 변경 시에만 아트워크를
/// 가져오고(비용), 실패하면 onThumbnail 자체를 생략(graceful — WE 도 썸네일 없으면 이벤트 없음).
public final class MediaPoller {
    public var onPlayback: ((NowPlayingInfo) -> Void)?      // state 변화 시
    public var onProperties: ((NowPlayingInfo) -> Void)?    // 제목/아티스트/앨범 변화 시
    public var onTimeline: ((NowPlayingInfo) -> Void)?      // 재생 중 매 틱
    public var onThumbnail: ((NowPlayingInfo, Data) -> Void)?  // 트랙 변화 + 아트워크 성공 시(원본 바이트)
    /// 배달 완료 횟수(테스트 동기화용 — 폴 1회 처리 시마다 +1).
    public private(set) var deliveryCount = 0

    private let provider: NowPlayingProvider
    private var timer: Timer?
    var isRunningForTesting: Bool { timer != nil }
    private var last: NowPlayingInfo?
    private var lastTrackKey: String?
    private let pollLock = NSLock()
    private var pollInFlight = false

    public init(provider: NowPlayingProvider) { self.provider = provider }
    deinit { stop() }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.fire()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        pollLock.lock()
        guard !pollInFlight else {
            pollLock.unlock()
            return
        }
        pollInFlight = true
        pollLock.unlock()

        let prevKey = lastTrackKey
        // AppleScript 는 블로킹 — 백그라운드에서 fetch(+아트워크) 후 메인에서 배달.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = self?.provider.fetch() ?? NowPlayingInfo(state: .stopped)
            let key = "\(info.title)|\(info.artist)|\(info.album)"
            var artwork: Data?
            if info.state != .stopped, key != prevKey {
                artwork = (self?.provider as? ArtworkProviding)?.fetchArtwork()
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.deliver(info, artwork: artwork, trackKey: key)
                self.finishPoll()
            }
        }
    }

    private func finishPoll() {
        pollLock.lock()
        pollInFlight = false
        pollLock.unlock()
    }

    // internal(테스트 가능): 상태전이·dedupe 로직을 폴 타이밍 없이 직접 검증한다.
    func deliver(_ info: NowPlayingInfo, artwork: Data?, trackKey: String) {
        if last?.state != info.state { onPlayback?(info) }
        if last?.title != info.title || last?.artist != info.artist || last?.album != info.album {
            onProperties?(info)
        }
        if let artwork { onThumbnail?(info, artwork) }
        if info.state == .playing { onTimeline?(info) }
        last = info
        lastTrackKey = trackKey  // 아트워크 실패도 기록 — 같은 트랙 재시도로 5초마다 osascript 낭비 방지
        deliveryCount += 1
    }
}
