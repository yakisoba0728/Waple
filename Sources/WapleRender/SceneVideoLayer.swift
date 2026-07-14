import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import Metal
import QuartzCore

/// 씬 내부 video-텍스처 레이어의 프레임 공급자.
///
/// 종전엔 씬에 video 레이어가 하나라도 있으면 mount 가 씬을 통째로 VideoRenderer 로 스왑했다
/// (→ 형제 레이어 전부 소실). 대신 이 클래스가 video 프레임을 MTLTexture 로 내고,
/// buildDisplayTextures 가 해당 레이어의 표시 텍스처로 합성한다 — 레이어 rect/blend/opacity 는
/// 기존 GPULayer 경로가 그대로 존중한다.
///
/// 두 모드(호출부가 isLive 로 선택):
///  - 라이브(온스크린, container.window != nil): AVPlayer + AVPlayerItemVideoOutput + CVMetalTextureCache.
///    프레임 페이싱은 씬 draw 루프가 pull 한다(자체 CADisplayLink 없음). 플레이어 자체 타임베이스로 진행.
///  - 헤드리스(캡처/테스트): AVAssetImageGenerator 로 씬 시간 t 의 프레임을 결정적 디코드(스냅샷 2× 결정성).
///
/// 스코프 밖(근거 없어 미구현): 비디오 오디오 트랙(무음 — 씬 sound 레이어는 SceneAudioPlayer 별도),
/// 비디오 이펙트 체인(단, 레이어에 효과가 있으면 기존 buildDisplayTextures 체인이 프레임 위에 자연 적용),
/// HDR video.
public final class SceneVideoLayer {
    public let mp4URL: URL

    // MARK: 라이브
    private var player: AVPlayer?
    private var output: AVPlayerItemVideoOutput?
    private var textureCache: CVMetalTextureCache?
    private var endObserver: NSObjectProtocol?
    /// CVMetalTexture/CVPixelBuffer 는 GPU 가 그 프레임을 다 읽기 전에 해제되면 AVFoundation 이
    /// IOSurface 를 재활용 → GPU 가 해제 메모리를 읽어 깜빡임/쓰레기가 된다(전형적 Metal-비디오 버그).
    /// MTKView 최대 인-플라이트(기본 3)만큼 최근 프레임 refs 를 붙잡아 둔다.
    /// ponytail: 고정 3-deep 링. 티어링이 스모크에서 보이면 semaphore 완료핸들러 해제로 승급.
    private var frameHold: [(CVPixelBuffer, CVMetalTexture)] = []
    private var lastLiveTexture: MTLTexture?

    // MARK: 헤드리스
    private lazy var generator: AVAssetImageGenerator = {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: mp4URL))
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = .zero   // 정확 디코드 → 스냅샷 셀프체크 2× 결정성
        g.requestedTimeToleranceAfter = .zero
        // 헤드리스 캡처는 ≤1080p — 4K/8K 원본을 풀해상도(33MB+)로 디코드하면 다중 마운트 시 메모리 압박으로
        // 텍스처 할당이 비결정 실패(→ 폴백 프레임 편차)한다. 1080p 로 바운드(레이어는 어차피 쿼드로 다운샘플).
        g.maximumSize = CGSize(width: 1920, height: 1920)
        return g
    }()
    private lazy var duration: Double = AVURLAsset(url: mp4URL).duration.seconds

    public init(mp4URL: URL) { self.mp4URL = mp4URL }

    deinit { teardown() }   // teardown 미호출 백스톱 — endObserver(NotificationCenter 보유) 누수 방지

    /// startLive 가 성공했으면 true — 호출부가 라이브/헤드리스 프레임 경로를 선택한다.
    public var isLive: Bool { player != nil }

    // MARK: 라이브

    /// 라이브 재생 시작(온스크린 마운트에서만 호출). 실패해도 헤드리스 폴백엔 영향 없음(isLive=false 유지).
    public func startLive(device: MTLDevice) {
        guard player == nil else { return }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return }
        textureCache = cache
        let item = AVPlayerItem(url: mp4URL)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(out)
        output = out
        let p = AVPlayer(playerItem: item)
        p.isMuted = true                 // 스코프 밖: 비디오 오디오 트랙.
        p.actionAtItemEnd = .none
        // 루프: AVPlayerLooper 는 매 루프 아이템을 교체 → 부착한 output 이 새 아이템을 못 따라간다.
        // 단일 아이템 + 종료 시 seek(0) 수동 루프(output-기반 재생의 표준 패턴).
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak p] _ in p?.seek(to: .zero); p?.play() }
        player = p
        p.play()
    }

    /// 라이브 현재 프레임 텍스처(씬 draw 루프가 매 프레임 pull). 새 프레임이 없으면 직전 프레임 재사용.
    public func liveTexture(device: MTLDevice) -> MTLTexture? {
        guard let output, let textureCache else { return lastLiveTexture }
        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard itemTime.isValid, output.hasNewPixelBuffer(forItemTime: itemTime),
              let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return lastLiveTexture
        }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard st == kCVReturnSuccess, let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else {
            return lastLiveTexture
        }
        frameHold.append((pb, cvTex))                       // 최근 프레임 refs 보유(GPU 인-플라이트 보호)
        if frameHold.count > 3 { frameHold.removeFirst() }
        lastLiveTexture = tex
        return tex
    }

    public func pause() { player?.pause() }
    public func resume() { player?.play() }

    public func teardown() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        output = nil
        frameHold.removeAll()
        lastLiveTexture = nil
        textureCache = nil
    }

    // MARK: 헤드리스 (결정적)

    /// 씬 시간 t 를 duration 으로 wrap(루프)해 정확 디코드 → rgba8 텍스처. 다른 애니 레이어와
    /// 동일 scene-time 프레임을 낸다(clamp 아님 — 루프 재생 정합). 디코드 실패(LZ4-mp4 등
    /// AVFoundation 미해독)면 nil → 호출부가 placeholder 폴백(형제 레이어 보존).
    public func headlessTexture(at t: Float, device: MTLDevice) -> MTLTexture? {
        let cg: CGImage
        do {
            cg = try generator.copyCGImage(
                at: CMTime(seconds: wrappedTime(Double(t)), preferredTimescale: 600), actualTime: nil)
        } catch {
            guard let zero = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
            cg = zero
        }
        return Self.rgbaTexture(from: cg, device: device)
    }

    func wrappedTime(_ t: Double) -> Double { Self.wrap(t, duration: duration) }

    /// t 를 [0, duration) 로 wrap(루프 재생). duration 미상(비유한/0 이하)이면 max(0,t)(디코드 폴백에 위임).
    static func wrap(_ t: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return max(0, t) }
        let m = t.truncatingRemainder(dividingBy: duration)
        return m < 0 ? m + duration : m
    }

    /// CGImage → rgba8Unorm 텍스처(makeTexture 규약과 동일 R,G,B,A 순 → 샘플러 색 정합).
    static func rgbaTexture(from cg: CGImage, device: MTLDevice) -> MTLTexture? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        let bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        bytes.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bpr)
        }
        return tex
    }
}
