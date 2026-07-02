import AppKit
import AVFoundation
import WapleCore

public final class VideoRenderer: WallpaperRenderer {
    /// AVFoundation 이 디코드하지 못하는 컨테이너 확장자.
    public static let unsupportedExtensions: Set<String> = ["webm", "mkv"]

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
        guard VideoRenderer.isSupportedContainer(url) else { throw RendererError.unsupportedCodec }

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
