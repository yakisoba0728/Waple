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

    public init() {}

    public func mount(in container: NSView, project: WallpaperProject) throws {
        guard let fileName = project.fileName else { throw RendererError.assetMissing }
        let url = project.folderURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw RendererError.assetMissing }
        guard VideoRenderer.isSupportedContainer(url) else { throw RendererError.unsupportedCodec }

        let item = AVPlayerItem(url: url)
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
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        player = nil
        looper = nil
        playerLayer = nil
    }
}
