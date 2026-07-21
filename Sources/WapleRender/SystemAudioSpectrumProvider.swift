import Foundation
import ScreenCaptureKit
import AVFoundation
import Accelerate

protocol AudioSpectrumProviding: AnyObject {
    var onFrame: (([Float]) -> Void)? { get set }
    func start()
    func stop()
}

/// 시스템 출력 오디오를 SCStream 으로 캡처해 FFT 스펙트럼(128 bin)을 onFrame 으로 전달.
/// 권한 거부/실패 시 0 배열을 공급(배경은 계속 렌더). 메인 스레드 콜백.
/// F536(F-51): 실제 SCStream 은 프로세스 전역 공유 코어(SharedAudioCaptureCore, 파일 말미)가 1개만
/// 보유 — 멀티모니터(화멻다 SceneRenderer/WebRenderer 인스턴스)의 중복 캡처를 디듑한다. 캡처 대상은
/// 화면 무관 전역 시스템 오디오라 공유가 정확하며, 각 인스턴스는 원시 버퍼를 넘겨받아 자체 FFT 를 돌린다.
public final class SystemAudioSpectrumProvider: NSObject, AudioSpectrumProviding {
    public var onFrame: (([Float]) -> Void)?

    private let fftSize = 1024
    private let log2n: vDSP_Length
    // create_fftsetup 실패(극히 드묾) 시 nil — 강제 언랩 대신 무음 폴백. let 이라 lock 없이 안전.
    private let fftSetup: FFTSetup?
    private var window: [Float]
    // running 은 메인 스레드(start/stop)와 코어 팬아웃(waple.audio 콜백 큐)에서 동시 접근 — lock 으로 직렬화.
    private let lock = NSLock()
    private var running = false

    public override init() {
        log2n = vDSP_Length(round(log2(Double(fftSize))))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        fftSetup = setup
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        super.init()
        if setup == nil {
            NSLog("%@", "[Waple] FFT setup 생성 실패 — 오디오 스펙트럼은 무음으로 폴백")
        }
    }

    deinit { if let fftSetup { vDSP_destroy_fftsetup(fftSetup) } }

    public func start() {
        // FFT setup 이 없으면 캡처를 띄우지 않고 무음만 공급(배경은 계속 렌더).
        guard fftSetup != nil else { feedZeros(); return }
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        SharedAudioCaptureCore.shared.add(self)   // F536: 실제 캡처는 공유 코어가 참조 카운트로 관리
    }

    public func stop() {
        lock.lock()
        if !running { lock.unlock(); return }
        running = false
        lock.unlock()
        SharedAudioCaptureCore.shared.remove(self)   // 마지막 구독자가 나가면 코어가 스트림을 닫는다
    }

    private func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// 코어가 팬아웃한 원시 오디오 버퍼 처리(구 SCStreamOutput 콜백 본체 — FFT/다운샘플 무수정).
    /// internal: 같은 파일의 SharedAudioCaptureCore 가 호출.
    func process(sampleBuffer: CMSampleBuffer) {
        guard isRunning() else { return }
        guard let (l, r) = Self.stereoSamples(from: sampleBuffer, maxCount: fftSize) else { return }
        // WE 포맷: 128(64L + 64R) — 채널별 FFT 로 진짜 스테레오(이전: 첫 채널 복제).
        let lBins = AudioSpectrum.spectrum(fromMagnitudes: magnitudes(from: l), binCount: 64)
        let rBins = AudioSpectrum.spectrum(fromMagnitudes: magnitudes(from: r), binCount: 64)
        let clamped = Array((lBins + rBins).prefix(128))
        DispatchQueue.main.async { [weak self] in self?.onFrame?(clamped) }
    }

    /// 무음 공급(권한 거부/캡처 실패 폴백). 코어가 실패를 구독자 전원에 브로드캐스트할 때도 호출한다.
    /// internal: 같은 파일의 SharedAudioCaptureCore 가 호출.
    func feedZeros() {
        let zeros = [Float](repeating: 0, count: 128)
        DispatchQueue.main.async { [weak self] in self?.onFrame?(zeros) }
    }

    /// 스테레오 채널별 샘플: non-interleaved(버퍼 2개) → 각 버퍼, interleaved(1버퍼 2채널) → 짝/홀 분리,
    /// 모노 → (mono, mono). 반환 (L, R).
    private static func stereoSamples(from sampleBuffer: CMSampleBuffer, maxCount: Int) -> ([Float], [Float])? {
        var sizeNeeded = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        ) == noErr, sizeNeeded > 0 else { return nil }
        let ablMemory = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablMemory.deallocate() }
        let ablPtr = ablMemory.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer
        ) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        func floats(_ b: AudioBuffer) -> [Float] {
            guard let d = b.mData else { return [] }
            let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            return Array(UnsafeBufferPointer(start: d.assumingMemoryBound(to: Float.self), count: n))
        }
        if buffers.count >= 2 {  // non-interleaved 스테레오
            let l = floats(buffers[0]), r = floats(buffers[1])
            guard !l.isEmpty else { return nil }
            return (Array(l.prefix(maxCount)), Array((r.isEmpty ? l : r).prefix(maxCount)))
        }
        guard let first = buffers.first else { return nil }
        let all = floats(first)
        guard !all.isEmpty else { return nil }
        if first.mNumberChannels >= 2 {  // interleaved 스테레오
            var l: [Float] = []; var r: [Float] = []
            l.reserveCapacity(min(all.count / 2, maxCount)); r.reserveCapacity(min(all.count / 2, maxCount))
            var i = 0
            while i + 1 < all.count, l.count < maxCount {
                l.append(all[i]); r.append(all[i + 1]); i += 2
            }
            return (l, r)
        }
        let m = Array(all.prefix(maxCount))
        return (m, m)
    }

    private func magnitudes(from samples: [Float]) -> [Float] {
        guard let setup = fftSetup else { return [Float](repeating: 0, count: fftSize / 2) }
        return Self.magnitudes(from: samples, fftSize: fftSize, window: window, log2n: log2n, setup: setup)
    }

    /// 실수 FFT 진폭(순수 — 커버리지 가능한 계산부). 반환 길이 = fftSize/2.
    /// window/log2n/setup 은 fftSize 와 정합해야 함(fftSize 는 2의 거듭제곱). samples 는 fftSize 로
    /// 제로패딩(짧으면)·절단(길면)된다.
    static func magnitudes(from samples: [Float], fftSize: Int, window: [Float],
                           log2n: vDSP_Length, setup: FFTSetup) -> [Float] {
        var input = samples
        if input.count < fftSize { input += [Float](repeating: 0, count: fftSize - input.count) }
        else if input.count > fftSize { input = Array(input.prefix(fftSize)) }
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // packed-real FFT: split.imagp[0] 에는 Nyquist(fs/2) 항이 들어가 있다.
                // 0 으로 만들지 않으면 mags[0] = DC² + Nyquist² 가 되어 최저 주파수(베이스) bin 이
                // 최고 주파수와 섞여 오염된다. bin 0 = |DC| 가 되도록 Nyquist 항을 제거한다.
                split.imagp[0] = 0
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        var result = [Float](repeating: 0, count: half)
        vvsqrtf(&result, mags, [Int32(half)])
        return result
    }

    /// 테스트/일회성용 편의: 자체 Hann 창 + FFT setup 을 생성·해제하며 진폭 계산. setup 생성 실패 → nil.
    static func magnitudes(from samples: [Float], fftSize: Int) -> [Float]? {
        let log2n = vDSP_Length(round(log2(Double(fftSize))))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        return magnitudes(from: samples, fftSize: fftSize, window: window, log2n: log2n, setup: setup)
    }
}

/// F536(F-51): 프로세스 전역 단일 SCStream 캡처 코어. 구독자(SystemAudioSpectrumProvider)가 1명 이상이면
/// 캡처를 유지하고 원시 sampleBuffer 를 전원에게 팬아웃, 0명이 되면 스트림을 닫는다(참조 카운트).
/// 세대(generation) 관리는 구 per-instance 구현과 동형 — 급속 stop/start 시 고아 스트림 방지.
private final class SharedAudioCaptureCore: NSObject, SCStreamOutput {
    static let shared = SharedAudioCaptureCore()

    /// 약한 구독자 상자 — provider 가 stop 없이 해제돼도 코어가 영구 유지되지 않게 한다.
    private final class WeakBox {
        weak var provider: SystemAudioSpectrumProvider?
        init(_ p: SystemAudioSpectrumProvider) { provider = p }
    }

    private let lock = NSLock()
    private var subscribers: [ObjectIdentifier: WeakBox] = [:]
    private var stream: SCStream?
    private var running = false
    // 매 캡처 세션마다 증가. in-flight startCapture Task 는 자기 세대가 현재일 때만 stream 을 할당.
    private var generation = 0

    func add(_ p: SystemAudioSpectrumProvider) {
        lock.lock()
        subscribers[ObjectIdentifier(p)] = WeakBox(p)
        if running { lock.unlock(); return }   // 캡처 이미 활성(다른 구독자) — 등록만
        running = true
        generation += 1
        let gen = generation
        lock.unlock()
        Task { await startCapture(generation: gen) }
    }

    func remove(_ p: SystemAudioSpectrumProvider) {
        lock.lock()
        subscribers[ObjectIdentifier(p)] = nil
        subscribers = subscribers.filter { $0.value.provider != nil }   // stop 없이 해제된 구독자 정리
        let s = subscribers.isEmpty ? stopCaptureIfRunningLocked() : nil   // 다른 구독자 잔존 — 캡처 유지
        lock.unlock()
        // F544(F-115): async 권고 형태. stopCapture 는 lock 밖에서 호출(콜백 큐와의 교착 방지).
        Task { try? await s?.stopCapture() }
    }

    /// lock 보유 상태에서 캡처 중단(진행 중 startCapture 무효화 포함). stop 해야 할 stream 반환 —
    /// 실제 stopCapture 는 호출자가 lock 밖에서 수행(교착 방지).
    private func stopCaptureIfRunningLocked() -> SCStream? {
        guard running else { return nil }
        running = false
        generation += 1   // 진행 중인 startCapture Task 를 무효화(고아 스트림 방지)
        let s = stream
        stream = nil
        return s
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running && gen == generation
    }

    /// gen 이 현재 세대이고 running 이면 stream 을 교체하고 (이전 stream, true) 반환.
    /// 아니면 (nil, false). 이전/거부된 stream 의 stopCapture 는 호출자가 lock 밖에서 수행.
    private func swapStreamIfCurrent(_ s: SCStream, generation gen: Int) -> (old: SCStream?, assigned: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard running, gen == generation else { return (nil, false) }
        let old = stream
        stream = s
        return (old, true)
    }

    /// 생존 구독자 스냅샷(죽은 약한 참조는 함께 정리).
    private func liveSubscribers() -> [SystemAudioSpectrumProvider] {
        lock.lock(); defer { lock.unlock() }
        let live = subscribers.values.compactMap { $0.provider }
        if live.count < subscribers.count { subscribers = subscribers.filter { $0.value.provider != nil } }
        return live
    }

    private func startCapture(generation gen: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard isCurrent(gen) else { return }
            guard let display = content.displays.first else {
                NSLog("%@", "[Waple] audio capture: no displays available, feeding silence")
                liveSubscribers().forEach { $0.feedZeros() }
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            // 최소 비디오 캡처 비용(오디오만 쓰지만 SCStream 은 비디오 구성 요구)
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "waple.audio"))
            try await stream.startCapture()
            // 세대 확인 + stream 할당을 한 임계 구역에서. 전원 stop() 이 await 도중 일어났다면 이 Task 는
            // 더 이상 현재 세대가 아니므로 방금 만든 stream 을 즉시 중단(고아 방지).
            let (old, assigned) = swapStreamIfCurrent(stream, generation: gen)
            if let old { try? await old.stopCapture() }  // F544: 이론상 nil(직전 stream 은 remove 가 정리). 방어적.
            if !assigned {
                try? await stream.stopCapture()   // F544(F-115): async 권고 형태
                return
            }
        } catch {
            // 화면 기록 권한 거부가 흔한 원인. 폴백(무음)은 유지하되 진단 가능하도록 로깅한다.
            NSLog("%@", "[Waple] audio capture failed (screen-recording permission?), feeding silence: \(error)")
            liveSubscribers().forEach { $0.feedZeros() }
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        let live = liveSubscribers()
        if live.isEmpty {
            // 구독자가 stop 없이 전원 해제됨 — 고아 캡처 자체 종료(구형에서 provider deinit 이 stream 을
            // 해제하던 것과 동등한 생명주기). 정상 경로(teardown 의 stop)에선 도달하지 않는 방어.
            lock.lock()
            let s = stopCaptureIfRunningLocked()
            lock.unlock()
            Task { try? await s?.stopCapture() }
            return
        }
        for p in live { p.process(sampleBuffer: sampleBuffer) }
    }
}
