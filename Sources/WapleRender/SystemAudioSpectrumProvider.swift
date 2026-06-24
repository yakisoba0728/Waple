import Foundation
import ScreenCaptureKit
import AVFoundation
import Accelerate

/// 시스템 출력 오디오를 SCStream 으로 캡처해 FFT 스펙트럼(128 bin)을 onFrame 으로 전달.
/// 권한 거부/실패 시 0 배열을 공급(배경은 계속 렌더). 메인 스레드 콜백.
public final class SystemAudioSpectrumProvider: NSObject, SCStreamOutput {
    public var onFrame: (([Float]) -> Void)?

    private var stream: SCStream?
    private let fftSize = 1024
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    // running/stream 은 메인 스레드(start/stop), 캡처 Task, waple.audio 콜백 큐에서 동시 접근되므로 lock 으로 직렬화한다.
    private let lock = NSLock()
    private var running = false

    public override init() {
        log2n = vDSP_Length(round(log2(Double(fftSize))))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        super.init()
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    public func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        lock.unlock()
        Task { await startCapture() }
    }

    public func stop() {
        lock.lock()
        running = false
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

    /// running 이면 stream 을 할당하고 true 반환, 아니면 할당 없이 false 반환(동기 임계 구역).
    private func assignStreamIfRunning(_ s: SCStream) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard running else { return false }
        stream = s
        return true
    }

    private func startCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard isRunning() else { return }
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
            // stop() 이 await 도중 실행됐다면 self.stream 이 아직 nil 이라 stopCapture 가
            // no-op 였다. running 확인과 self.stream 할당을 한 임계 구역(동기 헬퍼)에서 처리해 TOCTOU 를 닫는다.
            if !assignStreamIfRunning(stream) {
                // 캡처가 주인 없이 계속 도는 것을 막기 위해 즉시 중단한다.
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
        guard let samples = Self.floatSamples(from: sampleBuffer, maxCount: fftSize) else { return }
        let mags = magnitudes(from: samples)
        let bins = AudioSpectrum.spectrum(fromMagnitudes: mags, binCount: 64)
        let frame = bins + bins   // WE 포맷: 128(64L + 64R). 64bin 스펙트럼을 좌우 복제.
        let clamped = Array(frame.prefix(128))
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

    private func magnitudes(from samples: [Float]) -> [Float] {
        var input = samples
        if input.count < fftSize { input += [Float](repeating: 0, count: fftSize - input.count) }
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
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
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
}
