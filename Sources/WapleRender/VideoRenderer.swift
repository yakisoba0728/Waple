import AppKit
import AVFoundation
import WapleCore

/// @unchecked Sendable: 이 렌더러의 상태는 **메인 큐 한정**이다 — mount/attachPlayer/pause/resume/
/// teardown 은 메인에서 불리고, 비동기로 들어오는 세 경로(ffmpeg 변환 완료, AVPlayerItem.status KVO,
/// asset.load Task)는 전부 첫 줄에서 DispatchQueue.main.async 로 홉한 뒤에야 필드를 만진다.
/// mountToken 세대 가드가 그 위에서 늦게 도착한 콜백을 무효화한다.
///
/// **[해소 2026-08-25] 아래 금지를 걷는다 — 이 타입은 이제 `@MainActor` 다.**
/// 두 블로커를 각각 없앴고, 원문은 되돌리려는 사람을 위해 취소선으로 남긴다.
///  1. **해소**: `AppDelegate.captureSceneStill` 이 팩토리를 거치지 않고 `SceneRenderer` 를 직접
///     만든다. `RendererFactory.swift` 가 스스로 지정해 둔 선택지이고, `.sceneCapture` 가
///     `case .scene:` 에서만 나온다는 사실이 동치성을 보증한다. F486 은 그대로다.
///  2. **해소**: 아래 인스턴스를 직접 생성·구동하던 테스트 7파일에 `@MainActor` 를 달았다.
///     테스트 타깃이 Swift 5·minimal 인 것과 무관하게, 클래스 표기만으로 해결된다.
///
/// ⚠️ 정적 3종(`nativeVideoExtensions`·`unsupportedExtensions`·`isSupportedContainer`)은
/// **`nonisolated` 여야 한다.** 비격리 컨텍스트 다섯이 그것을 읽는다 — `FFmpegConverter:11` ·
/// `StillWallpaper:23` · `DeepScan:790`·`:817` · `FFmpegConverterTests:185`. 여기서 격리를 빼지
/// 않으면 그 다섯이 전부 에러가 된다. 패턴은 `WallpaperSchemeHandler:16/17/35/95`.
///
/// ~~**`@MainActor` 로 바꾸지 마라.** 표기상으로는 그쪽이 더 정확해 보이지만 두 곳이 막는다:~~
///  1. ~~`RendererFactory.makeRenderer` 가 **nonisolated 여야 한다** — AppDelegate.captureSceneStill(F486)이
///     백그라운드 큐에서 그것을 부르고, 팩토리의 switch 안에 `VideoRenderer()` 생성이 있다.
///     여기에 격리를 붙이면 그 경로가 컴파일되지 않아 F486(메인 수 초 정지 수정)이 되돌아간다.~~
///  2. ~~테스트 타깃은 아직 Swift 5·minimal 인데 비격리 XCTest 메서드에서 이 타입을 40여 곳에서
///     직접 생성·구동한다(VideoRendererLifecycleTests·MediaFixRegressionTests 등) — 소스에 @MainActor 를
///     붙이면 그 호출이 **에러**가 되어 `swift test` 가 통째로 안 선다.~~
/// 실제 실행 규율은 위 문단(메인 큐 한정 + mountToken 세대 가드)이고, 그것이 이 표기의 근거다.
@MainActor
public final class VideoRenderer: WallpaperRenderer, @unchecked Sendable {
    /// Conservative AVFoundation-native containers used directly without conversion.
    /// F230: WapleCore.VideoFormats.nativeExtensions 가 단일 소스 — 여기서 다시 선언하지 않는다.
    nonisolated public static let nativeVideoExtensions: Set<String> = VideoFormats.nativeExtensions
    /// Common non-native containers routed through ffmpeg conversion when available.
    nonisolated public static let unsupportedExtensions: Set<String> = ["webm", "mkv", "avi", "wmv", "flv", "ogv", "mpg", "mpeg"]

    nonisolated public static func isSupportedContainer(_ url: URL) -> Bool {
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
    /// 재생정책 음소거(stage 3①). **사용자 음량과 별개의 층**이라 값을 덮어쓰지 않는다 —
    /// 끄면 `VideoSettings.volume(id:)` 가 그대로 돌아온다.
    private var policyMuted = false
    private var mountToken: UInt64 = 0
    private var attemptedPlaybackRecovery = false
    /// F550: 현재 장착된 소스가 ffmpeg 변환 결과물인지 — 결과물 자체의 재생 실패는 재변환하지 않는다.
    private var playingConvertedOutput = false
    private let converterAvailable: () -> Bool
    /// [2026-08-25] 완료 콜백이 `@Sendable` — 주입부와 `FFmpegConverter.convert` 의 시그니처를 맞춘다.
    private let convert: (URL, @escaping @Sendable (URL?) -> Void) -> Void

    private(set) var projectId: String?
    private(set) var lastError: Error?

    public init() {
        self.converterAvailable = { FFmpegConverter.isAvailable }
        self.convert = { url, completion in FFmpegConverter.convert(url, completion: completion) }
    }

    init(converterAvailable: @escaping () -> Bool,
         convert: @escaping (URL, @escaping @Sendable (URL?) -> Void) -> Void) {
        self.converterAvailable = converterAvailable
        self.convert = convert
    }

    /// teardown 미호출 경로 안전망(형제 렌더러 전원이 이미 보유: WebRenderer·SceneVideoLayer·SceneRenderer).
    /// 이게 없으면 놓친 teardown 하나가 occlusionObserver(NotificationCenter 등록)를 남기고,
    /// AVQueuePlayer 가 도달 불가능한 채로 디코드를 계속 돌린다. teardown() 은 옵셔널 해제 정리라 멱등.
    /// [2026-08-25] `deinit` 은 액터 격리를 가질 수 없다 — `AppDelegate:32-34` 규약대로
    /// `MainActor.assumeIsolated` 로 "실행되는 곳이 메인" 을 런타임 단언한다.
    /// 이 렌더러는 `RendererFactory`(@MainActor)가 만들고 `AppDelegate`(@MainActor)가 소유하며,
    /// 파일 머리말이 적은 대로 상태가 **메인 큐 한정**이다. 마지막 참조는 메인에서 놓인다.
    deinit {
        MainActor.assumeIsolated { teardown() }
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
            // weak 캡처를 여기서 강참조로 승격한다: weak 캡처는 가변 저장소라, 이어지는 메인 홉
            // 클로저가 그것을 다시 참조하면 "concurrently-executing code 의 captured var" 진단이
            // 난다(Swift 6 에선 에러). 승격 뒤 캡처되는 것은 불변 let 이다. 수명 영향은 메인 홉 한 번
            // 동안의 유지뿐이고, 취소 신호는 종전대로 mountToken/container 로 메인에서 판정한다.
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.mountToken == token, let container = self.container else { return }
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
        // [2026-08-25] `AVPlayerItem(url:)` 대신 `AVURLAsset` 을 지역에 들고 그것으로 만든다.
        // 결과는 같다(전자가 내부에서 하는 일이 이것이다). 바뀌는 것은 아래에서 `item.asset` 을
        // 읽지 않아도 된다는 것뿐이다 — `item.asset` 의 정적 타입은 `AVAsset` 이고 그 타입은
        // Sendable 이 아니라 `Task` 경계를 넘길 때 진단이 난다. 판례: `SceneVideoLayer.swift:124-125`
        // 의 `duration` lazy 가 이미 같은 형태로 `AVURLAsset` 을 직접 만든다.
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // 코덱/손상/DRM 실패는 AVFoundation 내부에서 비동기로 발생해 mount 성공 후 검은 화면이 된다.
        // status 를 관찰해 실패를 로깅함으로써 진단 가능하게 한다.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                self?.recordPlayerItemFailure(item.error, url: url, token: token)
            }
        }
        // F565: loadValuesAsynchronously/statusOfValue/tracks 는 deprecated — load(_:) async 계열로 국소
        // 교체(로드 실패·재생 불가를 표면화 — 재생 불가 분기는 F600 참조).
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
        // stage 3①: 마운트도 정책 음소거를 거친다. 안 거치면 정책이 음소거를 요구하는 동안
        // 배경을 바꾸거나 모니터를 착탈할 때마다 **새 렌더러가 소리부터 내고** 다음 정책
        // 틱(≤1초)에 꺼진다 — 사용자에게는 1초짜리 소음이다.
        queue.isMuted = Self.effectiveMute(volume: volume, policyMuted: policyMuted)
        queue.defaultRate = VideoSettings.rate(id: project.id)

        let layer = AVPlayerLayer(player: queue)
        switch SceneRenderSettings.fitMode {
        case .fit: layer.videoGravity = .resizeAspect
        case .fill: layer.videoGravity = .resizeAspectFill
        case .stretch: layer.videoGravity = .resize
        }
        // 레터박스/필러박스 색. WE 는 목적지 사각형을 **항상 창 전체**로 두고 남는 자리를
        // 경계색으로 칠하는데, 그 색은 하드코딩된 **불투명 검정**이다 — `TransferVideoFrame`
        // 직전의 MFARGB 구성 0x1400f34f3 `mov word [rsp+0x51], 0` · 0x1400f34fa
        // `mov byte [rsp+0x50], 0` · 0x1400f34ff `mov byte [rsp+0x53], 0xff`
        // (BGRA = 00 00 00 FF). `clearcolor`/`schemecolor` 를 쓰지 않는다.
        // 종전 Waple 은 AVPlayerLayer 에 배경을 안 줘서 상위 뷰 색이 비쳤다
        // (`docs/re/media-playback.md` §9.2 G3). 웹 폴백은 이미 `background:#000` 이라
        // 이 한 줄로 두 경로의 레터박스가 같아진다.
        layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
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
            // `Notification` 은 Sendable 이 아니라 블록 안으로 들고 들어가지 않는다 — 필요한 것은
            // 발신 창 하나뿐이다(WebRenderer 의 같은 자리와 동형).
            let sender = note.object as? NSWindow
            // queue: .main 으로 등록했으므로 이 블록은 메인에서 돈다 — `AppDelegate:32-34` 규약대로
            // 그 사실을 런타임 단언으로 적는다.
            MainActor.assumeIsolated {
                guard let self, let win = self.container?.window, sender === win else { return }
                if win.occlusionState.contains(.visible) {
                    if self.pausedByOcclusion, !self.pausedManually { self.player?.play() }
                    self.pausedByOcclusion = false
                } else if self.player?.rate != 0 {
                    self.pausedByOcclusion = true
                    self.player?.pause()
                }
            }
        }
    }

    /// [2026-08-25] `nonisolated` — **이 함수는 스스로 메인으로 홉한다**(첫 줄이
    /// `DispatchQueue.main.async`). 그래서 어느 스레드에서 불러도 안전하고, 실제로 호출부는
    /// `AVPlayerItem.status` KVO 라 **메인 보장이 없다**. 여기에 `MainActor.assumeIsolated` 를
    /// 쓰면 안 된다 — 그건 "메인에서 돈다" 는 단언인데 KVO 는 그걸 보장하지 않으므로 트랩이 된다.
    /// 격리를 벗기는 것이 맞는 자리다.
    nonisolated private func recordPlayerItemFailure(_ error: Error?, url: URL, token: UInt64) {
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
            guard let self else { return }   // 승격 근거는 mount 의 같은 패턴 주석 참조
            DispatchQueue.main.async {
                guard self.mountToken == token, let container = self.container else { return }
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
        player.isMuted = Self.effectiveMute(volume: volume, policyMuted: policyMuted)
        let rate = VideoSettings.rate(id: id)
        player.defaultRate = rate
        // defaultRate 는 다음 play() 부터 적용 — 재생 중이면 현재 rate 도 즉시 맞춘다.
        // 정지(수동/가림, rate==0) 중 대입은 재생 재개를 뜻하므로 건드리지 않는다.
        if player.rate != 0 { player.rate = rate }
    }

    // MARK: - 재생정책 음량면 (stage 3①·③)

    /// 사용자 음량과 정책 음소거의 합성 — **순수**라 살아 있는 `AVPlayer` 없이 오라클을 쓸 수 있다.
    ///
    /// `volume <= 0` 을 따로 보는 이유: `AVPlayer.volume = 0` 만으로도 소리는 안 나지만,
    /// `isMuted` 를 같이 세워야 "지금 소리가 나는가" 를 한 값으로 읽을 수 있다. 종전 두 자리
    /// (`attachPlayer`·`applyLiveVideoSettings`)가 이 규칙을 각자 복사하고 있었고, 정책 음소거를
    /// 얹으면서 그 복사가 셋이 되기 전에 한 자리로 모은다.
    static func effectiveMute(volume: Float, policyMuted: Bool) -> Bool {
        policyMuted || volume <= 0
    }

    /// 정책 음소거. 렌더 루프는 건드리지 않는다 — 음소거는 정지가 아니다(프로토콜 주석).
    public func setPolicyMuted(_ muted: Bool) {
        policyMuted = muted
        guard let player, let id = projectId else { return }
        player.isMuted = Self.effectiveMute(volume: VideoSettings.volume(id: id), policyMuted: muted)
    }

    /// 오디오 축의 뺄셈 항. 순간 상태(`rate`)가 아니라 **의도**를 답한다 — `rate` 는 루프
    /// 이음매·seek 중에 0 을 스쳐서 1초 폴링이 그 틈을 "조용하다" 로 읽으면 정책이 진동한다.
    public var isPlayingAudio: Bool {
        guard player != nil, let id = projectId else { return false }
        return !isEffectivelyPaused
            && !Self.effectiveMute(volume: VideoSettings.volume(id: id), policyMuted: policyMuted)
    }

    public func teardown() {
        mountToken &+= 1
        stopPlayback()
        container = nil
        projectId = nil
        // `policyMuted` 는 **남긴다.** 정책은 렌더러가 아니라 앱 전역의 상태라, teardown 후
        // 같은 인스턴스를 다시 mount 하는 경로(`SceneRenderer.mount` 와 같은 재사용 규약)에서
        // 리셋하면 음소거가 조용히 풀린다. 호출부는 렌더러 세트가 바뀔 때 다시 밀어 넣는다.
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
