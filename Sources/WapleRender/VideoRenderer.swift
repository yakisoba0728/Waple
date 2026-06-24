import AppKit
import AVFoundation
import WapleCore

public final class VideoRenderer: WallpaperRenderer {
    /// AVFoundation 이 디코드하지 못하는 컨테이너 확장자.
    public static let unsupportedExtensions: Set<String> = ["webm", "mkv"]

    public static func isSupportedContainer(_ url: URL) -> Bool {
        !unsupportedExtensions.contains(url.pathExtension.lowercased())
    }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var statusObservation: NSKeyValueObservation?

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
        let queue = AVQueuePlayer()
        let looper = AVPlayerLooper(player: queue, templateItem: item)
        queue.isMuted = true

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
    }

    public func pause() { player?.pause() }
    public func resume() { player?.play() }

    public func teardown() {
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        player = nil
        looper = nil
        playerLayer = nil
    }
}
