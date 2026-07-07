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
public final class SystemAudioSpectrumProvider: NSObject, SCStreamOutput, AudioSpectrumProviding {
    public var onFrame: (([Float]) -> Void)?

    private var stream: SCStream?
    private let fftSize = 1024
    private let log2n: vDSP_Length
    // create_fftsetup 실패(극히 드묾) 시 nil — 강제 언랩 대신 무음 폴백. let 이라 lock 없이 안전.
    private let fftSetup: FFTSetup?
    private var window: [Float]
    // running/stream/generation 은 메인 스레드(start/stop), 캡처 Task, waple.audio 콜백 큐에서 동시 접근되므로 lock 으로 직렬화한다.
    private let lock = NSLock()
    private var running = false
    // 매 start/stop 마다 증가. in-flight startCapture Task 는 자기 세대가 현재일 때만 stream 을 할당(급속 stop/start 시 고아 스트림 방지).
    private var generation = 0

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
        generation += 1
        let gen = generation
        lock.unlock()
        Task { await startCapture(generation: gen) }
    }

    public func stop() {
        lock.lock()
        running = false
        generation += 1   // 진행 중인 startCapture Task 를 무효화(고아 스트림 방지)
        let s = stream
        stream = nil
        lock.unlock()
        // stopCapture 는 lock 밖에서 호출(콜백 큐와의 교착 방지).
        s?.stopCapture { _ in }
    }

    private func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
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

    private func startCapture(generation gen: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard isCurrent(gen) else { return }
            guard let display = content.displays.first else {
                NSLog("%@", "[Waple] audio capture: no displays available, feeding silence")
                feedZeros(); return
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
            // 세대 확인 + stream 할당을 한 임계 구역에서. stop()/재start() 가 await 도중 일어났다면
            // 이 Task 는 더 이상 현재 세대가 아니므로 방금 만든 stream 을 즉시 중단(고아 방지).
            let (old, assigned) = swapStreamIfCurrent(stream, generation: gen)
            old?.stopCapture { _ in }  // 이론상 nil(직전 stream 은 stop 이 정리). 방어적.
            if !assigned {
                stream.stopCapture { _ in }
                return
            }
        } catch {
            // 화면 기록 권한 거부가 흔한 원인. 폴백(무음)은 유지하되 진단 가능하도록 로깅한다.
            NSLog("%@", "[Waple] audio capture failed (screen-recording permission?), feeding silence: \(error)")
            feedZeros()
        }
    }

    private func feedZeros() {
        let zeros = [Float](repeating: 0, count: 128)
        DispatchQueue.main.async { [weak self] in self?.onFrame?(zeros) }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, isRunning() else { return }
        guard let (l, r) = Self.stereoSamples(from: sampleBuffer, maxCount: fftSize) else { return }
        // WE 포맷: 128(64L + 64R) — 채널별 FFT 로 진짜 스테레오(이전: 첫 채널 복제).
        let lBins = AudioSpectrum.spectrum(fromMagnitudes: magnitudes(from: l), binCount: 64)
        let rBins = AudioSpectrum.spectrum(fromMagnitudes: magnitudes(from: r), binCount: 64)
        let clamped = Array((lBins + rBins).prefix(128))
        DispatchQueue.main.async { [weak self] in self?.onFrame?(clamped) }
    }

    /// CMSampleBuffer(PCM Float32) 첫 채널에서 최대 maxCount 샘플 추출.
    /// non-interleaved 스테레오(버퍼 2개)도 처리하기 위해 필요한 크기를 먼저 조회해 할당한다.
    private static func floatSamples(from sampleBuffer: CMSampleBuffer, maxCount: Int) -> [Float]? {
        var sizeNeeded = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, sizeNeeded > 0 else { return nil }

        let ablMemory = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablMemory.deallocate() }
        let ablPtr = ablMemory.assumingMemoryBound(to: AudioBufferList.self)

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(ablPtr)
        guard let first = buffers.first, let data = first.mData else { return nil }
        let count = min(Int(first.mDataByteSize) / MemoryLayout<Float>.size, maxCount)
        guard count > 0 else { return nil }
        let ptr = data.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
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
