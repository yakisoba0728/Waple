import AppKit
import AVFoundation
import WapleCore

public final class VideoRenderer: WallpaperRenderer {
    /// AVFoundation 이 디코드하지 못하는 컨테이너 확장자. ffmpeg 변환 대상(FFmpegConverter.convertExtensions).
    public static let unsupportedExtensions: Set<String> = ["webm", "mkv", "avi"]

    public static func isSupportedContainer(_ url: URL) -> Bool {
        !unsupportedExtensions.contains(url.pathExtension.lowercased())
    }

    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var statusObservation: NSKeyValueObservation?
    private weak var container: NSView?
    private var occlusionObserver: NSObjectProtocol?
    private var pausedByOcclusion = false
    private var pausedManually = false

    public init() {}

    public func mount(in container: NSView, project: WallpaperProject) throws {
        guard let fileName = project.fileName else { throw RendererError.assetMissing }
        let url = project.folderURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw RendererError.assetMissing }
        if VideoRenderer.isSupportedContainer(url) {
            try attachPlayer(url: url, container: container, project: project)
            return
        }
        // 미지원 컨테이너(mkv/avi/webm): ffmpeg 로 mp4 변환 후 장착(비동기 — 메인스레드 블록 금지).
        // ffmpeg 부재 시 팩토리가 WebRenderer 폴백을 고르므로 여기 도달 = 변환 가능. 방어적으로 재확인.
        guard FFmpegConverter.isAvailable else { throw RendererError.unsupportedCodec }
        self.container = container   // teardown 이 nil 로 만들면 완료 콜백이 스킵(취소 신호)
        NSLog("%@", "[Waple] converting \(url.lastPathComponent) via ffmpeg…")
        FFmpegConverter.convert(url) { [weak self] mp4 in
            guard let self, let container = self.container else { return }
            guard let mp4 else {
                NSLog("%@", "[Waple] video conversion failed, no playback: \(url.path)")
                return
            }
            do { try self.attachPlayer(url: mp4, container: container, project: project) }
            catch { NSLog("%@", "[Waple] converted video mount failed: \(error)") }
        }
    }

    /// 재생 가능한 컨테이너(mp4 등)를 실제 장착·재생. mount 가 직접 또는 ffmpeg 변환 완료 후 호출.
    private func attachPlayer(url: URL, container: NSView, project: WallpaperProject) throws {
        let item = AVPlayerItem(url: url)
        // 코덱/손상/DRM 실패는 AVFoundation 내부에서 비동기로 발생해 mount 성공 후 검은 화면이 된다.
        // status 를 관찰해 실패를 로깅함으로써 진단 가능하게 한다.
        statusObservation = item.observe(\.status, options: [.new]) { item, _ in
            if item.status == .failed {
                NSLog("%@", "[Waple] video playback failed for \(url.path): \(String(describing: item.error))")
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
        queue.play()

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

    public func pause() { pausedManually = true; player?.pause() }
    public func resume() { pausedManually = false; player?.play() }

    public func teardown() {
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        occlusionObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        player = nil
        looper = nil
        playerLayer = nil
        container = nil
    }
}
