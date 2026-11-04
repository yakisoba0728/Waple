import AppKit
import WapleCore

/// RGBA8 픽셀 버퍼 → PNG 인코드. 헤드리스 렌더 검증(오프스크린 텍스처 readback → PNG → Read)용.
/// 라이브 데스크탑을 건드리지 않으므로 가림 여부와 무관하게 시각 검증이 가능하다.
public enum OffscreenCapture {
    // Shared by the CLI and real-project GT. Changing these requires an intentional baseline review.
    public static let sceneWidth = 256
    public static let sceneHeight = 144
    public static let sceneTime: Float = 6
    public static let sceneEpochMillis: Double = 1_704_110_400_000
    public static let sceneRandomSeed: UInt64 = 0xC0FFEE_1038
    public static let scenePointerUV = SIMD2<Float>(0.5, 0.5)

    private struct StoppedNowPlaying: NowPlayingProvider {
        func fetch() -> NowPlayingInfo? { nil }
    }

    /// One canonical headless mount/capture, with caller settings restored even when mounting fails.
    @MainActor
    public static func scene(project: WallpaperProject, width: Int = sceneWidth,
                             height: Int = sceneHeight, times: [Float] = [sceneTime],
                             toDir: URL) throws -> [URL] {
        let oldFit = SceneRenderSettings.fitMode
        let oldEpoch = TextScriptEngine.captureDateEpochMillis
        let oldSeed = TextScriptEngine.captureRandomSeed
        SceneRenderSettings.fitMode = .fill
        TextScriptEngine.captureDateEpochMillis = sceneEpochMillis
        TextScriptEngine.captureRandomSeed = sceneRandomSeed
        defer {
            SceneRenderSettings.fitMode = oldFit
            TextScriptEngine.captureDateEpochMillis = oldEpoch
            TextScriptEngine.captureRandomSeed = oldSeed
        }
        let renderer = SceneRenderer()
        defer { renderer.teardown() }
        renderer.nowPlayingProvider = StoppedNowPlaying()
        renderer.capturePointerUV = scenePointerUV
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: width, height: height)), project: project)
        renderer.pause()
        renderer.setSpectrum(.silent)
        return renderer.captureFrames(width: width, height: height, times: times, toDir: toDir)
    }

    /// width×height RGBA8(행당 width*4 바이트, 상단 행 우선) → PNG Data. 실패 시 nil.
    public static func png(rgba: [UInt8], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32
        ), let dst = rep.bitmapData else { return nil }
        rgba.withUnsafeBytes { src in
            dst.update(from: src.bindMemory(to: UInt8.self).baseAddress!, count: width * height * 4)
        }
        return rep.representation(using: .png, properties: [:])
    }
}
