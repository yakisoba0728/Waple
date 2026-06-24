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
        guard !running else { return }
        running = true
        Task { await startCapture() }
    }

    public func stop() {
        running = false
        stream?.stopCapture { _ in }
        stream = nil
    }

    private func startCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { feedZeros(); return }
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
            self.stream = stream
        } catch {
            feedZeros()
        }
    }

    private func feedZeros() {
        let zeros = [Float](repeating: 0, count: 128)
        DispatchQueue.main.async { [weak self] in self?.onFrame?(zeros) }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, running else { return }
        guard let samples = Self.floatSamples(from: sampleBuffer, maxCount: fftSize) else { return }
        let mags = magnitudes(from: samples)
        let bins = AudioSpectrum.spectrum(fromMagnitudes: mags, binCount: 128)
        let frame = bins + bins   // WE 포맷: 128(64L + 64R). 모노를 좌우 복제.
        let clamped = Array(frame.prefix(128))
        DispatchQueue.main.async { [weak self] in self?.onFrame?(clamped) }
    }

    /// CMSampleBuffer(PCM Float32) 첫 채널에서 최대 maxCount 샘플 추출.
    private static func floatSamples(from sampleBuffer: CMSampleBuffer, maxCount: Int) -> [Float]? {
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(&abl)
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
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        var result = [Float](repeating: 0, count: half)
        vvsqrtf(&result, mags, [Int32(half)])
        return result
    }
}
