import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics
import Metal
import QuartzCore
import Accelerate
import WapleCore

/// F5-2: 라이브 임베디드 mp4 트랙 방향 메타데이터(preferredTransform) 분류 — 90° 배수 회전 + 좌우 미러
/// 조합(디헤드럴군 8원소)만 지원한다. 헤드리스 경로(AVAssetImageGenerator.appliesPreferredTrackTransform=true,
/// SceneVideoLayer.swift 아래 generator 정의)는 이미 정합이나, 라이브 경로(AVPlayerItemVideoOutput.
/// copyPixelBuffer)는 트랙 표시 변환을 전혀 적용하지 않아 회전/미러 메타데이터를 가진 mp4 가 라이브·헤드리스
/// 간 다른 방향으로 렌더된다. 임의 회전/스큐 등 그 외 변환은 안전 무시(1회 로그) — "오역보다 폴백".
struct VideoTrackOrientation: Equatable {
    /// 시계방향 90° 단위 회전 횟수(0..3) — 미러 적용 "후" 기준.
    let quarterTurns: Int
    /// 회전 전 좌우(수평) 미러 여부.
    let mirroredX: Bool

    static let identity = VideoTrackOrientation(quarterTurns: 0, mirroredX: false)

    /// AVAssetTrack.preferredTransform → 분류. 표준 8개 디헤드럴 변환(identity/90/180/270 × 무미러/미러)
    /// 중 하나와 일치하면 그 값을, 그 외(임의 회전·스큐·비균등 스케일 등)는 nil.
    static func classify(_ t: CGAffineTransform) -> VideoTrackOrientation? {
        let eps: CGFloat = 0.01
        func near(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) < eps }
        // (quarterTurns, mirroredX, a, b, c, d) — tx/ty(평행이동)는 재래스터라이즈라 무관.
        let candidates: [(Int, Bool, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0, false,  1,  0,  0,  1), (1, false,  0,  1, -1,  0),
            (2, false, -1,  0,  0, -1), (3, false,  0, -1,  1,  0),
            (0, true,  -1,  0,  0,  1), (1, true,   0,  1,  1,  0),
            (2, true,   1,  0,  0, -1), (3, true,   0, -1, -1,  0),
        ]
        for (q, m, a, b, c, d) in candidates
        where near(t.a, a) && near(t.b, b) && near(t.c, c) && near(t.d, d) {
            return VideoTrackOrientation(quarterTurns: q, mirroredX: m)
        }
        return nil
    }
}

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
/// ## 씬 시각 `t` 와 비디오 PTS 의 관계 — WE 실측 (2026-08-21)
///
/// **WE 는 둘을 아예 잇지 않는다.** 씬 안 비디오 텍스처의 시계는 Media Engine 자신의
/// 재생 시계이고, 씬 클록은 입력으로 들어가지 않는다. 근거(wallpaper64.exe 2.8.42,
/// imagebase 0x140000000):
///
///  - 비디오 플레이어 vtable **0x1404871b8**. `+0x58` 게터(0x1400f31f0)는
///    `IMFMediaEngine +0x80`(GetCurrentTime, double)을 그대로 float 으로 내리고,
///    `+0x50` 세터(0x1400f3160)는 `IMFMediaEngine +0x88`(SetCurrentTime)로 그대로 넘긴다.
///    스크립트 `IVideoTexture.getCurrentTime/setCurrentTime`(등록부 0x140214050–0x140214799,
///    썽크 0x1401fa620 / 0x1401fa650)이 그 두 슬롯에 착지한다.
///  - 프레임을 텍스처로 옮기는 슬롯은 `+0x78`(0x1400f3480)인데 **인자가 `this` 하나뿐**이다.
///    시각도 프레임 번호도 받지 않는다 — 키드뮤텍스를 잡고 "지금 있는 프레임" 을 넘긴다.
///  - 스프라이트시트 쪽(`ITextureAnimation`)에만 `join()`("씬 전역 애니 타이머에 재합류")이
///    있고 `IVideoTexture` 에는 없다. 애초에 합류할 공용 시계가 없다는 뜻이다.
///
/// 그래서 **WE 의 비디오 레이어는 씬 시각에 대해 비결정적이다.** Waple 의 헤드리스 경로가
/// `wrap(t, duration)` 으로 t 를 PTS 에 사상하는 것은 WE 를 베낀 것이 아니라 `SnapshotPipeline`
/// 의 고정 시각 캡처를 결정적으로 만들기 위한 **의도적 이탈**이다. 라이브 경로(플레이어
/// 타임베이스)가 WE 와 동형인 쪽이고, 그래서 라이브·헤드리스 프레임이 서로 다를 수 있다 —
/// 그건 버그가 아니라 이 설계의 결과다. 골든을 깨지 않으려면 **헤드리스 경로에 벽시계를
/// 절대 넣지 마라**(`CACurrentMediaTime`·`Date` 등).
///
/// 스코프 밖(근거 없어 미구현): 비디오 오디오 트랙(무음 — 씬 sound 레이어는 SceneAudioPlayer 별도),
/// 비디오 이펙트 체인(단, 레이어에 효과가 있으면 기존 buildDisplayTextures 체인이 프레임 위에 자연 적용),
/// HDR video.
/// Swift 5.10 부터 @Sendable Task 본문에서 캡처한 var 변경이 에러(CI macos-14 기본 툴체인)라,
/// 세마포어 동기 대기 브리지의 결과 전달은 참조형 박스로 한다. signal→wait 쌍이 happens-before 를
/// 보장하므로 별도 락 없이 @unchecked Sendable 로 충분. internal: FFmpegConverter 도 공유.
final class SemaphoreResultBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

public final class SceneVideoLayer {
    public let mp4URL: URL

    // MARK: 라이브
    var player: AVPlayer?   // internal — 테스트가 pause/resume 상태(rate)를 관측(감사 V06 가림 대칭 검증)
    private var output: AVPlayerItemVideoOutput?
    private var textureCache: CVMetalTextureCache?
    private var endObserver: NSObjectProtocol?
    /// CVMetalTexture/CVPixelBuffer 는 GPU 가 그 프레임을 다 읽기 전에 해제되면 AVFoundation 이
    /// IOSurface 를 재활용 → GPU 가 해제 메모리를 읽어 깜빡임/쓰레기가 된다(전형적 Metal-비디오 버그).
    /// MTKView 최대 인-플라이트(기본 3)만큼 최근 프레임 refs 를 붙잡아 둔다.
    /// ponytail: 고정 3-deep 링. 티어링이 스모크에서 보이면 semaphore 완료핸들러 해제로 승급.
    private var frameHold: [(CVPixelBuffer, CVMetalTexture)] = []
    private var lastLiveTexture: MTLTexture?
    /// F5-2: startLive 가 채운다 — identity(기본값)면 기존 CVMetalTextureCache 제로카피 경로 그대로.
    private var trackOrientation: VideoTrackOrientation = .identity

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
    /// F840: 세마포어 동기 대기의 상한. 무한 대기는 Task 가 영영 완료되지 않으면(협조 스레드풀 고갈,
    /// 응답 없는 네트워크 볼륨의 mp4) 호출 스레드를 영구 블록한다 — 헤드리스 경로는 draw 스레드다.
    /// 타임아웃 시 값을 **읽지 않고**(박스는 락이 없어 늦게 도착한 쓰기와 경합) 폴백으로 간다.
    static let assetLoadTimeoutSeconds: Double = 5

    // load(.duration) 은 비동기 — 호출부(wrappedTime/headlessTexture)가 동기이고 헤드리스 디코드가
    // 어차피 블로킹이라, 구조 변경 대신 세마포어로 동기 대기한다. 로드 실패/타임아웃 시 0 — wrap 이 t 를 그대로 통과(기존과 동일).
    private lazy var duration: Double = {
        let asset = AVURLAsset(url: mp4URL)
        let sem = DispatchSemaphore(value: 0)
        let loaded = SemaphoreResultBox<CMTime?>(nil)
        Task {
            loaded.value = try? await asset.load(.duration)
            sem.signal()
        }
        guard sem.wait(timeout: .now() + SceneVideoLayer.assetLoadTimeoutSeconds) == .success else {
            WapleLog.warn("[Waple] video duration load timed out — wrap disabled: \(mp4URL.lastPathComponent)")
            return 0
        }
        return loaded.value?.seconds ?? 0
    }()

    public init(mp4URL: URL) {
        self.mp4URL = mp4URL
        VideoTextureExtractor.markActive(mp4URL)   // F560: 사용 중 캐시 mp4 를 evict 에서 보호
    }

    deinit { teardown() }   // teardown 미호출 백스톱 — endObserver(NotificationCenter 보유) 누수 방지

    /// startLive 가 성공했으면 true — 호출부가 라이브/헤드리스 프레임 경로를 선택한다.
    public var isLive: Bool { player != nil }

    /// 감사 V06: startLive 실패 기록. true 면 호출부가 라이브/헤드리스 대신 정적 폴 백(staticFallbackTexture)
    /// 경로를 선택한다 — isLive=false 유지 상태로 라이브 draw 가 매 프레임 헤드리스 동기 디코드(copyCGImage
    /// + 최초 duration 세마포어 블로킹)를 도는 것을 막기 위함. internal(set): 테스트가 실패 상태를 재현
    /// (CVMetalTextureCacheCreate 실패는 환경 의존이라 직접 유발 불가).
    public internal(set) var liveStartFailed = false

    // MARK: 라이브

    /// 라이브 재생 시작(온스크린 마운트에서만 호출). 실패해도 헤드리스 폴백엔 영향 없음(isLive=false 유지).
    /// 실패 시 liveStartFailed 를 기록해 호출부가 정적 폴 백으로 전환하게 한다(재시도 없음 — 호출부의
    /// videoLayersLive 플래그가 startLive 재호출을 이미 막는다).
    public func startLive(device: MTLDevice) {
        guard player == nil else { return }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else {
            liveStartFailed = true   // 감사 V06: 실패 기록 — 라이브 draw 의 매 프레임 동기 디코드 방지
            return
        }
        textureCache = cache
        // [2026-08-25] `item.asset`(정적 타입 `AVAsset`, 비-Sendable) 대신 지역 `AVURLAsset` 을 쓴다 —
        // 같은 파일 `:124-125` 의 `duration` lazy 가 이미 그 형태다. 결과는 동일하다.
        let liveAsset = AVURLAsset(url: mp4URL)
        let item = AVPlayerItem(asset: liveAsset)
        let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(out)
        output = out
        resolveTrackOrientation(asset: liveAsset)   // F5-2: liveTexture 가 참조할 방향 보정값 확정
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
        // F5-2: 트랙 표시 변환(90°배수+미러)이 있으면 CPU 측(vImage) 보정 후 새 텍스처로 낸다 —
        // 아래 CVMetalTextureCache 제로카피 경로는 트랙 변환을 반영하지 않는다.
        if trackOrientation != .identity {
            if let tex = Self.orientedTexture(pixelBuffer: pb, orientation: trackOrientation, device: device) {
                lastLiveTexture = tex
                return tex
            }
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

    /// F5-2: AVURLAsset(비동기 트랙 로드) → preferredTransform 분류. 구체 Sendable 타입을
    /// 유지해 Task 안으로 전달하고, 헤드리스 duration lazy var 와 동일하게
    /// 세마포어로 동기 대기(mount 1회 startLive 비용 — 매 프레임 호출 아님).
    private func resolveTrackOrientation(asset: AVURLAsset) {
        let sem = DispatchSemaphore(value: 0)
        let transform = SemaphoreResultBox<CGAffineTransform>(.identity)
        Task {
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let t = try? await track.load(.preferredTransform) {
                transform.value = t
            }
            sem.signal()
        }
        // F840: 무한 대기 금지(위 assetLoadTimeoutSeconds 주석 참조) — 여기는 startLive(마운트) 스레드다.
        guard sem.wait(timeout: .now() + SceneVideoLayer.assetLoadTimeoutSeconds) == .success else {
            WapleLog.warn("[Waple] video track transform load timed out — orientation correction skipped")
            trackOrientation = .identity
            return
        }
        guard !transform.value.isIdentity else { trackOrientation = .identity; return }
        if let o = VideoTrackOrientation.classify(transform.value) {
            trackOrientation = o
        } else {
            trackOrientation = .identity
            WapleLog.warn("[Waple] video live track transform unsupported (not 90°-multiple/mirror) — " +
                          "orientation correction skipped: \(transform.value)")
        }
    }

    /// F5-2: BGRA CVPixelBuffer 에 90°배수 회전+미러(vImage, 실시간 가능 성능)를 적용해 새 텍스처로 낸다.
    /// 회전 시(90°/270°) 폭/높이가 스왑된다. 실패 시 nil(호출부는 직전 프레임 유지로 폴백).
    private static func orientedTexture(pixelBuffer pb: CVPixelBuffer, orientation: VideoTrackOrientation,
                                        device: MTLDevice) -> MTLTexture? {
        guard orientation != .identity else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let srcRowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0, srcRowBytes >= w * 4 else { return nil }
        var srcBuf = vImage_Buffer(data: base, height: vImagePixelCount(h),
                                   width: vImagePixelCount(w), rowBytes: srcRowBytes)

        // 미러(회전 "전" 적용) — 필요 시 원본 크기 중간 스크래치.
        let mirrorScratch = orientation.mirroredX
            ? UnsafeMutableRawPointer.allocate(byteCount: h * srcRowBytes, alignment: 16) : nil
        defer { mirrorScratch?.deallocate() }
        var stageBuf = srcBuf
        if let scratch = mirrorScratch {
            var dst = vImage_Buffer(data: scratch, height: vImagePixelCount(h),
                                    width: vImagePixelCount(w), rowBytes: srcRowBytes)
            guard vImageHorizontalReflect_ARGB8888(&srcBuf, &dst, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            else { return nil }
            stageBuf = dst
        }

        let rotated = orientation.quarterTurns % 2 != 0
        let dstW = rotated ? h : w
        let dstH = rotated ? w : h
        let dstRowBytes = dstW * 4
        var outData = [UInt8](repeating: 0, count: dstH * dstRowBytes)
        let rotConst: UInt8
        switch orientation.quarterTurns {
        case 1: rotConst = UInt8(kRotate90DegreesClockwise)
        case 2: rotConst = UInt8(kRotate180DegreesClockwise)
        case 3: rotConst = UInt8(kRotate270DegreesClockwise)
        default: rotConst = UInt8(kRotate0DegreesClockwise)   // 미러만(회전 0) — 유효 상수, 단순 복사로 동작
        }
        let ok: Bool = outData.withUnsafeMutableBytes { ptr in
            guard let dstBase = ptr.baseAddress else { return false }
            var dstBuf = vImage_Buffer(data: dstBase, height: vImagePixelCount(dstH),
                                       width: vImagePixelCount(dstW), rowBytes: dstRowBytes)
            var backColor: Pixel_8888 = (0, 0, 0, 0)
            return vImageRotate90_ARGB8888(&stageBuf, &dstBuf, rotConst, &backColor,
                                           vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard ok else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: dstW, height: dstH,
                                                             mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        outData.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, dstW, dstH), mipmapLevel: 0,
                       withBytes: $0.baseAddress!, bytesPerRow: dstRowBytes)
        }
        return tex
    }

    public func pause() { player?.pause() }
    public func resume() { player?.play() }

    // MARK: 라이브 실패 정적 폴 백 (감사 V06)

    /// startLive 실패(liveStartFailed) 레이어의 정적 프레임 — t=0 을 **1회만** 디코드해 고정(재시도 없음).
    /// 실패 레이어를 라이브 draw 가 매 프레임 headlessTexture 로 동기 디코드(copyCGImage + 최초 duration
    /// 세마포어)하는 것을 막는다. 디코드 실패 시 nil 고정 → 호출부 placeholder 폴터(headlessTexture 와 동일 규약).
    public func staticFallbackTexture(device: MTLDevice) -> MTLTexture? {
        if !didDecodeStaticFallback {
            didDecodeStaticFallback = true
            cachedStaticFallback = headlessTexture(at: 0, device: device)
        }
        return cachedStaticFallback
    }
    private var didDecodeStaticFallback = false
    private var cachedStaticFallback: MTLTexture?

    public func teardown() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        output = nil
        frameHold.removeAll()
        lastLiveTexture = nil
        textureCache = nil
        cachedStaticFallback = nil   // 감사 V06: 정적 폴 백 텍스처 해제
        // F560: 활성 등록 해제(멱등 — teardown 은 명시 호출 + deinit 백스톱으로 2회 올 수 있다).
        if holdsActiveMark { holdsActiveMark = false; VideoTextureExtractor.unmarkActive(mp4URL) }
    }

    /// F560: teardown 2회 호출(명시 + deinit)에도 unmarkActive 가 1회만 나가도록.
    private var holdsActiveMark = true

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
        // F840: `&bytes` 는 inout 포인터가 호출 밖으로 새어나가는 UB — CGContext 가 그 버퍼를
        // 계속 붙잡고 draw 까지 간다. 형제 경로(TexDecoder.draw·TextRasterizer.render)와 동일하게
        // 컨텍스트 생성·드로잉을 withUnsafeMutableBytes 안에서 끝낸다.
        let ok = bytes.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        bytes.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bpr)
        }
        return tex
    }
}
