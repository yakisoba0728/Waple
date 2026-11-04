import AppKit

/// 지금 재생 중 폴러(웹/씬 공용): 5초 간격(AppleScript 비용과 체감 실시간성의 균형)으로 fetch,
/// 변화 감지 후 종류별 콜백 배달(메인 스레드). 트랙/세션 변경 시 아트워크를 가져오고,
/// transient miss는 제한 재시도, 성공 후에는1분마다변화를확인한다. 아트워크가 없으면
/// onThumbnail은 생략한다(WE도 썸네일 없으면 이벤트 없음).
/// @unchecked Sendable: 이 타입의 상태는 **메인 큐 한정**이다 — start/stop/deliver 와 콜백 4종은
/// 메인에서만 불리고(Timer 는 메인 런루프, 백그라운드 fetch 는 반드시 DispatchQueue.main.async 로
/// 복귀), 유일한 예외인 `pollInFlight` 는 `pollLock` 이 지킨다. 백그라운드로 나가는 것은 AppleScript
/// fetch 뿐이고 그 사이 인스턴스 상태는 건드리지 않는다(아래 poll 참조). 컴파일러가 볼 수 없는 이
/// 규율이 근거라 `unchecked` 다 — deliver/콜백을 메인 밖에서 부르는 코드를 넣으면 이 표기가 거짓이 된다.
public final class MediaPoller: @unchecked Sendable {
    public var onStatus: ((Bool) -> Void)?                   // integration enabled, independent of transport
    public var onPlayback: ((NowPlayingInfo) -> Void)?      // state 변화 시
    public var onProperties: ((NowPlayingInfo) -> Void)?    // 제목/아티스트/앨범 변화 시
    public var onTimeline: ((NowPlayingInfo) -> Void)?      // 재생 중 매 틱
    public var onThumbnail: ((NowPlayingInfo, Data) -> Void)?  // 트랙 변화 + 아트워크 성공 시(원본 바이트)
    /// 배달 완료 횟수(테스트 동기화용 — 폴 1회 처리 시마다 +1).
    public private(set) var deliveryCount = 0

    private let provider: NowPlayingProvider
    private var timer: Timer?
    var isRunningForTesting: Bool { timer != nil }
    var hasPendingPollForTesting: Bool {
        pollLock.lock()
        defer { pollLock.unlock() }
        return pollInFlight
    }
    private var last: NowPlayingInfo?
    private var lastStatus: Bool?
    private var lastTrackKey: String?
    private var lastArtwork: Data?
    private var artworkAttempts = 0
    private var pollsSinceArtworkAttempt = 0
    public private(set) var isIntegrationEnabled = true

    /// Disabling integration is distinct from an enabled player that has no current track.
    public func setIntegrationEnabled(_ enabled: Bool) {
        guard isIntegrationEnabled != enabled else { return }
        isIntegrationEnabled = enabled
        generation &+= 1
        if timer != nil {
            publishStatus(enabled)
            if enabled { poll() }
        }
    }
    private let pollLock = NSLock()
    private var pollInFlight = false
    private var generation: UInt64 = 0

    public init(provider: NowPlayingProvider) { self.provider = provider }
    deinit { stop() }

    public func start() {
        guard timer == nil else { return }
        generation &+= 1
        // `.common` 런루프 모드 — `scheduledTimer` 는 `.default` 에만 등록돼 메뉴 트래킹·라이브
        // 리사이즈 중 멈춘다. `AppDelegate.swift:701,756` 이 이미 이 규약을 쓰고 :755 주석이
        // 이유를 적어 뒀는데 이 자리로 전파되지 않았다.
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        publishStatus(isIntegrationEnabled)
        t.fire()
    }

    public func stop() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
        // stop is also used for renderer suspension; it does not disable integration.
    }

    private func publishStatus(_ enabled: Bool) {
        guard lastStatus != enabled else { return }
        lastStatus = enabled
        onStatus?(enabled)
    }

    func poll() {
        guard isIntegrationEnabled else { return }
        pollLock.lock()
        guard !pollInFlight else {
            pollLock.unlock()
            return
        }
        pollInFlight = true
        pollLock.unlock()

        let prevKey = lastTrackKey
        let attempts = artworkAttempts
        let pollsSinceAttempt = pollsSinceArtworkAttempt
        let pollGeneration = generation
        // AppleScript 는 블로킹 — 백그라운드에서 fetch(+아트워크) 후 메인에서 배달.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // 여기서 강참조로 승격한다. 종전엔 weak 캡처를 **메인 홉 클로저가 다시 참조**했는데,
            // weak 캡처는 가변 저장소라 그 재참조가 Swift 6 에서 에러다(진단 :57 "captured var 'self'").
            // 승격 후 캡처되는 것은 불변 let 이라 진단이 사라진다. 완료 배달은 아래 세대 검사로
            // stop/재시작 이전 결과를 버린다 — 같은 WKWebView의 새 문서는 nil이 아니기 때문이다.
            guard let self else { return }
            let info = self.provider.fetch() ?? NowPlayingInfo(state: .stopped)
            let key = info.artworkKey
            // 가변 var 대신 분기 초기화 let — @Sendable 클로저의 가변 캡처를 피한다(값은 종전과 동일).
            let artwork: Data?
            // Retry transient misses at most3 successive polls, then once a minute.
            // Successful artwork is also refreshed once a minute for same-track changes.
            let requestedArtwork = info.state != .stopped &&
                (key != prevKey || attempts < 3 || pollsSinceAttempt >= 11)
            if requestedArtwork, let sessionProvider = self.provider as? SessionArtworkProviding {
                artwork = sessionProvider.fetchArtwork(for: info)
            } else if requestedArtwork {
                artwork = (self.provider as? ArtworkProviding)?.fetchArtwork()
            } else { artwork = nil }
            DispatchQueue.main.async {
                self.finishPoll()
                guard self.timer != nil else { return }
                guard self.generation == pollGeneration else {
                    self.poll() // 재시작의 첫 폴이 이전 fetch에 막혔다면 새 세대로 즉시 조회한다.
                    return
                }
                self.deliver(info, artwork: artwork, trackKey: key, artworkRequested: requestedArtwork)
            }
        }
    }

    private func finishPoll() {
        pollLock.lock()
        pollInFlight = false
        pollLock.unlock()
    }

    // internal(테스트 가능): 상태전이·dedupe 로직을 폴 타이밍 없이 직접 검증한다.
    func deliver(_ info: NowPlayingInfo, artwork: Data?, trackKey: String, artworkRequested: Bool = false) {
        if last?.state != info.state { onPlayback?(info) }
        if last?.propertiesKey != info.propertiesKey { onProperties?(info) }
        let changedTrack = trackKey != lastTrackKey
        if changedTrack { lastArtwork = nil; artworkAttempts = 0; pollsSinceArtworkAttempt = 0 }
        if artworkRequested { artworkAttempts += 1; pollsSinceArtworkAttempt = 0 }
        else { pollsSinceArtworkAttempt += 1 }
        if let artwork {
            if artwork != lastArtwork { onThumbnail?(info, artwork) }
            lastArtwork = artwork
            artworkAttempts = max(3, artworkAttempts) // successful image: next refresh is periodic
        }
        let changedTimeline = last?.position != info.position || last?.duration != info.duration
        if info.state == .playing || (changedTimeline && (info.state == .paused || last != nil)) { onTimeline?(info) }
        last = info
        lastTrackKey = trackKey
        deliveryCount += 1
    }
}
