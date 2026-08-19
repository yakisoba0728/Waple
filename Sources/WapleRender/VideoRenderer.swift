import AppKit
import AVFoundation
import WapleCore

public final class VideoRenderer: WallpaperRenderer {
    /// Conservative AVFoundation-native containers used directly without conversion.
    /// F230: WapleCore.VideoFormats.nativeExtensions 가 단일 소스 — 여기서 다시 선언하지 않는다.
    public static let nativeVideoExtensions: Set<String> = VideoFormats.nativeExtensions
    /// Common non-native containers routed through ffmpeg conversion when available.
    public static let unsupportedExtensions: Set<String> = ["webm", "mkv", "avi", "wmv", "flv", "ogv", "mpg", "mpeg"]

    public static func isSupportedContainer(_ url: URL) -> Bool {
        nativeVideoExtensions.contains(url.pathExtension.lowercased())
    }

    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var statusObservation: NSKeyValueObservation?
    private weak var container: NSView?
    private var occlusionObserver: NSObjectProtocol?
    private var pausedByOcclusion = false
    private var pausedManually = false
    private var mountToken: UInt64 = 0
    private var attemptedPlaybackRecovery = false
    /// F550: 현재 장착된 소스가 ffmpeg 변환 결과물인지 — 결과물 자체의 재생 실패는 재변환하지 않는다.
    private var playingConvertedOutput = false
    private let converterAvailable: () -> Bool
    private let convert: (URL, @escaping (URL?) -> Void) -> Void

    private(set) var projectId: String?
    private(set) var lastError: Error?

    public init() {
        self.converterAvailable = { FFmpegConverter.isAvailable }
        self.convert = { url, completion in FFmpegConverter.convert(url, completion: completion) }
    }

    init(converterAvailable: @escaping () -> Bool,
         convert: @escaping (URL, @escaping (URL?) -> Void) -> Void) {
        self.converterAvailable = converterAvailable
        self.convert = convert
    }

    /// teardown 미호출 경로 안전망(형제 렌더러 전원이 이미 보유: WebRenderer·SceneVideoLayer·SceneRenderer).
    /// 이게 없으면 놓친 teardown 하나가 occlusionObserver(NotificationCenter 등록)를 남기고,
    /// AVQueuePlayer 가 도달 불가능한 채로 디코드를 계속 돌린다. teardown() 은 옵셔널 해제 정리라 멱등.
    deinit {
        teardown()
    }

    public func mount(in container: NSView, project: WallpaperProject) throws {
        mountToken &+= 1
        let token = mountToken
        lastError = nil
        attemptedPlaybackRecovery = false
        projectId = project.id
        pausedByOcclusion = false
        pausedManually = false
        stopPlayback()
        self.container = container

        guard let fileName = WallpaperPathSecurity.normalizedRelativePath(project.fileName),
              let url = WallpaperPathSecurity.containedFileURL(fileName, root: project.folderURL) else {
            lastError = RendererError.assetMissing
            throw RendererError.assetMissing
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            lastError = RendererError.assetMissing
            throw RendererError.assetMissing
        }
        if VideoRenderer.isSupportedContainer(url) {
            try attachPlayer(url: url, container: container, project: project)
            return
        }
        guard FFmpegConverter.needsConversion(url) else {
            lastError = RendererError.unsupportedCodec
            throw RendererError.unsupportedCodec
        }
        // 미지원 컨테이너: ffmpeg 로 mp4 변환 후 장착(비동기 — 메인스레드 블록 금지).
        // ffmpeg 부재 시 팩토리가 WebRenderer 폴백을 고르므로 여기 도달 = 변환 가능. 방어적으로 재확인.
        guard converterAvailable() else {
            lastError = RendererError.unsupportedCodec
            throw RendererError.unsupportedCodec
        }
        self.container = container   // teardown 이 nil 로 만들면 완료 콜백이 스킵(취소 신호)
        NSLog("%@", "[Waple] converting \(url.lastPathComponent) via ffmpeg…")
        convert(url) { [weak self] mp4 in
            DispatchQueue.main.async {
                guard let self, self.mountToken == token, let container = self.container else { return }
                guard let mp4 else {
                    self.lastError = RendererError.unsupportedCodec
                    Self.postFailureNotification(RendererError.unsupportedCodec, url: url)   // F555: 변환 실패 표면화
                    NSLog("%@", "[Waple] video conversion failed, no playback: \(url.path)")
                    return
                }
                do { try self.attachPlayer(url: mp4, container: container, project: project, fromConversion: true) }
                catch {
                    self.lastError = error
                    Self.postFailureNotification(error, url: url)   // F555
                    NSLog("%@", "[Waple] converted video mount failed: \(error)")
                }
            }
        }
    }

    /// 재생 가능한 컨테이너(mp4 등)를 실제 장착·재생. mount 가 직접 또는 ffmpeg 변환 완료 후 호출.
    /// fromConversion: ffmpeg 변환 결과물을 장착하는 경우 true — 그 결과물 자체의 재생 실패는
    /// 재변환하지 않는다(F550, 무의미 루프 차단).
    private func attachPlayer(url: URL, container: NSView, project: WallpaperProject,
                              fromConversion: Bool = false) throws {
        stopPlayback()
        lastError = nil
        let token = mountToken
        projectId = project.id
        playingConvertedOutput = fromConversion
        let item = AVPlayerItem(url: url)
        // 코덱/손상/DRM 실패는 AVFoundation 내부에서 비동기로 발생해 mount 성공 후 검은 화면이 된다.
        // status 를 관찰해 실패를 로깅함으로써 진단 가능하게 한다.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                self?.recordPlayerItemFailure(item.error, url: url, token: token)
            }
        }
        // F565: loadValuesAsynchronously/statusOfValue/tracks 는 deprecated — load(_:) async 계열로 국소
        // 교체(로드 실패·재생 불가를 표면화 — 재생 불가 분기는 F600 참조).
        let asset = item.asset
        Task { [weak self] in
            do {
                // F600: hev1(hvcC 없는 HEVC) mp4 는 status=.readyToPlay + 오디오 트랙 존재로 보고돼
                // .failed 관찰·tracks.isEmpty 두 감지를 모두 우회한다(코퍼스 3448728208 실측:
                // isPlayable=false, 트랙 2개, status=readyToPlay). 로드한 isPlayable 을 버리지 않고
                // DeepScan.scanVideo 프로브(isPlayable && hasVideo)와 정합하게 검사해 F550 회복을 발동.
                let (isPlayable, tracks, _) = try await asset.load(.isPlayable, .tracks, .duration)
                let hasVideo = tracks.contains { $0.mediaType == .video }
                if !isPlayable || !hasVideo { self?.recoverUnplayableLoadedAsset(url: url, token: token) }
            } catch {
                self?.recordPlayerItemFailure(error, url: url, token: token)
            }
        }
        // 배속 변경 시 음정 유지(WE 동작과 유사).
        item.audioTimePitchAlgorithm = .spectral
        let queue = AVQueuePlayer()
        let looper = AVPlayerLooper(player: queue, templateItem: item)
        // 배경별 음량/배속(기본: 음소거, 1배속). defaultRate 는 루프 재시작에도 유지된다.
        let volume = VideoSettings.volume(id: project.id)
        queue.volume = volume
        queue.isMuted = volume <= 0
        queue.defaultRate = VideoSettings.rate(id: project.id)

        let layer = AVPlayerLayer(player: queue)
        switch SceneRenderSettings.fitMode {
        case .fit: layer.videoGravity = .resizeAspect
        case .fill: layer.videoGravity = .resizeAspectFill
        case .stretch: layer.videoGravity = .resize
        }
        container.wantsLayer = true
        layer.frame = container.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        container.layer?.addSublayer(layer)
        // F551: mount 시점의 창 가림 상태 반영 — occluded 상태에서 mount 되면 첫 occlusion 알림 전까지
        // 디코드·재생이 돌아갔다. 창이 없으면(headless 테스트) 기존 동작(재생) 유지.
        if Self.isOccludedAtMount(container.window) { pausedByOcclusion = true }
        if !pausedManually && !pausedByOcclusion {
            queue.play()
        }

        self.player = queue
        self.looper = looper
        self.playerLayer = layer
        self.container = container

        // 가림 시 정지(절전 — 씬 렌더러와 동일 동작). 창이 없으면(headless 테스트) no-op.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let win = self.container?.window, (note.object as? NSWindow) === win else { return }
            if win.occlusionState.contains(.visible) {
                if self.pausedByOcclusion, !self.pausedManually { self.player?.play() }
                self.pausedByOcclusion = false
            } else if self.player?.rate != 0 {
                self.pausedByOcclusion = true
                self.player?.pause()
            }
        }
    }

    private func recordPlayerItemFailure(_ error: Error?, url: URL, token: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mountToken == token else { return }
            let finalError = error ?? RendererError.unsupportedCodec
            self.lastError = finalError
            NSLog("%@", "[Waple] video playback failed for \(url.path): \(String(describing: error))")
            // F555: 회복이 시작되지 않으면(불가/소진/변환 결과물) 최종 실패 — 앱 계층 표면화 연결점.
            if !self.recoverPlaybackFailureIfPossible(url: url, token: token) {
                Self.postFailureNotification(finalError, url: url)
            }
        }
    }

    /// F600: 로드 헤더상 재생 불가(hev1 등 — status 는 readyToPlay 라 .failed 관찰이 오지 않는다)는
    /// 실제 재생 실패가 아닌 판정이므로 lastError 를 세우기 전에 F550 회복부터 시도한다.
    /// 회복 진행 중 lastError 를 세우면 소비자(RealVideosGroundTruthTests 등)가 최종 실패로 오인한다.
    /// 회복 불가(변환기 부재·소진·변환 결과물)면 최종 실패로 기록(F555 표면화 포함).
    private func recoverUnplayableLoadedAsset(url: URL, token: UInt64) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.mountToken == token else { return }
            if !self.recoverPlaybackFailureIfPossible(url: url, token: token) {
                self.recordPlayerItemFailure(nil, url: url, token: token)
            }
        }
    }

    /// ffmpeg 회복(재변환)을 시작했으면 true. F550: 변환 결과물(캐시 mp4) 자체의 재생 실패를 다시
    /// ffmpeg 로 변환하면 같은 손상을 재인코딩하는 무의미 루프(수백MB CPU 낭비 + 동일 실패 예상) —
    /// 회복은 원본 소스에 대해 1회만 시도한다.
    @discardableResult
    private func recoverPlaybackFailureIfPossible(url: URL, token: UInt64) -> Bool {
        guard !attemptedPlaybackRecovery, !playingConvertedOutput, converterAvailable(), container != nil else { return false }
        attemptedPlaybackRecovery = true
        NSLog("%@", "[Waple] attempting ffmpeg recovery for native video: \(url.lastPathComponent)")
        convert(url) { [weak self] mp4 in
            DispatchQueue.main.async {
                guard let self, self.mountToken == token, let container = self.container else { return }
                guard let mp4 else {
                    // F600: F600 경로(헤더 판정 → 회복 우선)는 여기까지 lastError 가 nil — 최종 실패를 기록.
                    self.lastError = RendererError.unsupportedCodec
                    Self.postFailureNotification(RendererError.unsupportedCodec, url: url)   // F555: 회복 실패 = 최종 실패
                    return
                }
                do {
                    let project = WallpaperProject(
                        id: self.projectId ?? url.deletingPathExtension().lastPathComponent,
                        type: .video,
                        fileName: mp4.lastPathComponent,
                        previewName: nil,
                        title: mp4.deletingPathExtension().lastPathComponent,
                        tags: [],
                        contentRating: nil,
                        workshopId: nil,
                        dependency: nil,
                        folderURL: mp4.deletingLastPathComponent()
                    )
                    try self.attachPlayer(url: mp4, container: container, project: project, fromConversion: true)
                } catch {
                    self.lastError = error
                    Self.postFailureNotification(error, url: url)   // F555
                    NSLog("%@", "[Waple] ffmpeg recovery mount failed: \(error)")
                }
            }
        }
        return true
    }

    /// 수동 정지·가림 정지의 합성(WebRenderer 의 isEffectivelyPaused 와 같은 모델).
    private var isEffectivelyPaused: Bool { pausedManually || pausedByOcclusion }

    public func pause() { pausedManually = true; player?.pause() }
    /// F840: 종전 resume() 은 무조건 play() 라 **가려진 창의 영상이 되살아났다**(가림 정지의 목적인
    /// 절전이 무효화되고, 이후 visible 복귀 시엔 pausedByOcclusion 이 여전히 true 라 상태도 어긋난다).
    /// 가림 정지 중이면 플래그만 내리고 재생은 occlusion 옵저버의 visible 복귀에 맡긴다.
    public func resume() {
        pausedManually = false
        guard !isEffectivelyPaused else { return }
        player?.play()
    }

    /// F820: 음량/배속 라이브 반영 — UserDefaults 에 이미 저장된 새 값을 실행 중인 플레이어에
    /// 직접 적용해, apply() 전체 리마운트(mkv/webm 은 ffmpeg 재변환 대기+재생 리셋) 없이 즉시 반영.
    /// 플레이어가 아직 없으면(ffmpeg 변환 대기 중) no-op — attachPlayer 가 장착 시 새 값을 읽는다.
    public func applyLiveVideoSettings() {
        guard let player, let id = projectId else { return }
        let volume = VideoSettings.volume(id: id)
        player.volume = volume
        player.isMuted = volume <= 0
        let rate = VideoSettings.rate(id: id)
        player.defaultRate = rate
        // defaultRate 는 다음 play() 부터 적용 — 재생 중이면 현재 rate 도 즉시 맞춘다.
        // 정지(수동/가림, rate==0) 중 대입은 재생 재개를 뜻하므로 건드리지 않는다.
        if player.rate != 0 { player.rate = rate }
    }

    public func teardown() {
        mountToken &+= 1
        stopPlayback()
        container = nil
        projectId = nil
    }

    private func stopPlayback() {
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        occlusionObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        player = nil
        looper = nil
        playerLayer = nil
    }

    /// F551: mount 시점 가림 판정 — 창이 있고 visible 아니면 true(재생 보류). headless(창 없음)는 false.
    static func isOccludedAtMount(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return !window.occlusionState.contains(.visible)
    }

    /// F555: 비동기 실패 표면화 최소 경로 — lastError 기록과 함께 Notification 발행(앱 계층 구독점).
    static func postFailureNotification(_ error: Error, url: URL) {
        NotificationCenter.default.post(name: .wapleVideoPlaybackFailed, object: nil,
                                        userInfo: ["error": error, "url": url])
    }
}

extension Notification.Name {
    /// F555: 비디오 배경의 비동기 실패(ffmpeg 변환 실패·재생 중 실패 후 회복 불가/소진) 직후 post.
    /// userInfo["error"]: Error, userInfo["url"]: 실패한 소스 URL. 앱 계층(배너/상태 표시)이 구독해
    /// 사용자에게 표면화하는 연결점(종전엔 lastError 쓰기만 하고 소비자가 없어 검은 화면이 무표시였다).
    public static let wapleVideoPlaybackFailed = Notification.Name("wapleVideoPlaybackFailed")
}
