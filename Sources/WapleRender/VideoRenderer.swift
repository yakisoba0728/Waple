import AppKit
import AVFoundation
import WapleCore

public final class VideoRenderer: WallpaperRenderer {
    /// Conservative AVFoundation-native containers used directly without conversion.
    public static let nativeVideoExtensions: Set<String> = ["mp4", "m4v", "mov"]
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
                    NSLog("%@", "[Waple] video conversion failed, no playback: \(url.path)")
                    return
                }
                do { try self.attachPlayer(url: mp4, container: container, project: project) }
                catch {
                    self.lastError = error
                    NSLog("%@", "[Waple] converted video mount failed: \(error)")
                }
            }
        }
    }

    /// 재생 가능한 컨테이너(mp4 등)를 실제 장착·재생. mount 가 직접 또는 ffmpeg 변환 완료 후 호출.
    private func attachPlayer(url: URL, container: NSView, project: WallpaperProject) throws {
        stopPlayback()
        lastError = nil
        let token = mountToken
        projectId = project.id
        let item = AVPlayerItem(url: url)
        // 코덱/손상/DRM 실패는 AVFoundation 내부에서 비동기로 발생해 mount 성공 후 검은 화면이 된다.
        // status 를 관찰해 실패를 로깅함으로써 진단 가능하게 한다.
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                self?.recordPlayerItemFailure(item.error, url: url, token: token)
            }
        }
        item.asset.loadValuesAsynchronously(forKeys: ["playable"]) { [weak self] in
            var error: NSError?
            let status = item.asset.statusOfValue(forKey: "playable", error: &error)
            if status == .failed || !item.asset.isPlayable {
                self?.recordPlayerItemFailure(item.error ?? error, url: url, token: token)
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
            self.lastError = error ?? RendererError.unsupportedCodec
            NSLog("%@", "[Waple] video playback failed for \(url.path): \(String(describing: error))")
            self.recoverPlaybackFailureIfPossible(url: url, token: token)
        }
    }

    private func recoverPlaybackFailureIfPossible(url: URL, token: UInt64) {
        guard !attemptedPlaybackRecovery, converterAvailable(), container != nil else { return }
        attemptedPlaybackRecovery = true
        NSLog("%@", "[Waple] attempting ffmpeg recovery for native video: \(url.lastPathComponent)")
        convert(url) { [weak self] mp4 in
            DispatchQueue.main.async {
                guard let self, self.mountToken == token, let container = self.container else { return }
                guard let mp4 else { return }
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
                    try self.attachPlayer(url: mp4, container: container, project: project)
                } catch {
                    self.lastError = error
                    NSLog("%@", "[Waple] ffmpeg recovery mount failed: \(error)")
                }
            }
        }
    }

    public func pause() { pausedManually = true; player?.pause() }
    public func resume() { pausedManually = false; player?.play() }

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
}
