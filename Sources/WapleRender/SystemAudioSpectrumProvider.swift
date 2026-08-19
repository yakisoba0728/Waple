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
    // running 은 메인 스레드(start/stop)와 코어 팬아웃(waple.audio 콜백 큐)에서 동시 접근 — lock 으로 직렬화.
    private let lock = NSLock()
    private var running = false
    // 채널별 링버퍼(파일 말미 AudioWindowAccumulator) — 패킷을 누적해 FFT 창이 찰 때만 분석한다.
    // process(waple.audio 큐)/stop(메인) 양쪽에서 접근 — running 과 같은 lock 으로 보호.
    private var accumulator: AudioWindowAccumulator

    public override init() {
        log2n = vDSP_Length(round(log2(Double(fftSize))))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        fftSetup = setup
        accumulator = AudioWindowAccumulator(windowSize: fftSize)
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
        accumulator.reset()   // 미완성 창 잔여는 세션을 넘기지 않는다(엔진도 재구성 시 캐리 리셋 — FUN_1400d0380:184-185)
        lock.unlock()
        SharedAudioCaptureCore.shared.remove(self)   // 마지막 구독자가 나가면 코어가 스트림을 닫는다
    }

    private func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// 코어가 팬아웃한 원시 오디오 버퍼 처리(구 SCStreamOutput 콜백 본체).
    /// internal: 같은 파일의 SharedAudioCaptureCore 가 호출.
    /// WE 2.8.42 AudioProcessor 규약: 패킷을 채널별로 누적(carry uVar14=local_3a0 — FUN_1400d0380:260-274·:425)
    /// 해 정확히 창 크기에 도달할 때만 FFT(:449 `(uint)uVar14 == uVar18`). hop = 창 크기(겹침 없음)는 추정 —
    /// 디컴파일에 오버랩 흔적이 없고 창 소비 후 캐리가 리셋된다(:184-185). 구 콜백마다-제로패드/절단은 폐기
    /// (짧은 버퍼의 제로패드가 스펙트럼을 오염시켰다). 창이 차기 전엔 onFrame 을 부르지 않는다.
    func process(sampleBuffer: CMSampleBuffer) {
        guard isRunning() else { return }
        guard let (l, r) = Self.stereoSamples(from: sampleBuffer) else { return }
        lock.lock()
        let windows = running ? accumulator.append(left: l, right: r) : []
        lock.unlock()
        for (wl, wr) in windows { analyzeWindow(left: wl, right: wr) }
    }

    /// 창 1개(채널별 fftSize 샘플)를 분석해 onFrame 디스패치. 무음 게이트 통과 창은 0 스펙트럼 공급
    /// (엔진도 무음 시 0 커밋 — FUN_1400d0380:419-424 플래그, :444-445 `func_0x000140421870(*param_1,0,0x200)`).
    private func analyzeWindow(left l: [Float], right r: [Float]) {
        guard let setup = fftSetup else { feedZeros(); return }
        guard let out = Self.analyzeWindow(l: l, r: r, fftSize: fftSize, log2n: log2n, setup: setup,
                                           threshold: AudioInputSettings.threshold,
                                           volume: AudioInputSettings.volume) else {
            feedZeros()
            return
        }
        DispatchQueue.main.async { [weak self] in self?.onFrame?(out) }
    }

    /// 창 분석 순수 계산부(커버리지 가능): 게이트 → 채널별 FFT → 64+64 비닝 → volume 스칼라.
    /// 반환 nil = 무음 게이트가 창을 무음 처리. volume 은 결과 스펙트럼 전체에 곱한다(audioinputvolume)
    /// — 1.0 곱은 IEEE 상 정확히 항등이라 기본값 무회귀. WE 포맷: 128(64L + 64R) 채널별 FFT.
    static func analyzeWindow(l: [Float], r: [Float], fftSize: Int,
                              log2n: vDSP_Length, setup: FFTSetup,
                              threshold: Float, volume: Float) -> [Float]? {
        guard !isSilenced(peak: windowPeak(l, r), threshold: threshold) else { return nil }
        let lBins = AudioSpectrum.spectrum(fromMagnitudes: magnitudes(from: l, fftSize: fftSize, log2n: log2n, setup: setup), binCount: 64)
        let rBins = AudioSpectrum.spectrum(fromMagnitudes: magnitudes(from: r, fftSize: fftSize, log2n: log2n, setup: setup), binCount: 64)
        return Array((lBins + rBins).prefix(128)).map { $0 * volume }
    }

    /// 창 피크(채널 합산). 엔진은 raw 샘플의 부호 있는 최댓값을 0 바닥으로 잰다
    /// (FUN_1400d0380:378-417 — fVar24=0.0 시작, 부호 있는 max). 절댓값이 아님에 주의.
    static func windowPeak(_ l: [Float], _ r: [Float]) -> Float {
        max(0, max(l.max() ?? 0, r.max() ?? 0))
    }

    /// 무음 게이트 판정(순수). 엔진 활성 조건 threshold > FLT_EPSILON(FUN_1400d0380:376 —
    /// `fVar27(FLT_EPSILON) < *(param_1+2)`), 활성 시 창 피크 < threshold 이면 무음(:419-424).
    /// 기본 threshold 0 이면 항상 비활성(무회귀).
    static func isSilenced(peak: Float, threshold: Float) -> Bool {
        threshold > Float.ulpOfOne && peak < threshold
    }

    /// 무음 공급(권한 거부/캡처 실패 폴백). 코어가 실패를 구독자 전원에 브로드캐스트할 때도 호출한다.
    /// internal: 같은 파일의 SharedAudioCaptureCore 가 호출.
    func feedZeros() {
        let zeros = [Float](repeating: 0, count: 128)
        DispatchQueue.main.async { [weak self] in self?.onFrame?(zeros) }
    }

    /// 스테레오 채널별 샘플: non-interleaved(버퍼 2개) → 각 버퍼, interleaved(1버퍼 2채널) → 짝/홀 분리,
    /// 모노 → (mono, mono). 반환 (L, R). 절단 없이 패킷 전체 — 창 맞춤은 누적 버퍼(AudioWindowAccumulator)가 담당.
    private static func stereoSamples(from sampleBuffer: CMSampleBuffer) -> ([Float], [Float])? {
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
            return (l, r.isEmpty ? l : r)
        }
        guard let first = buffers.first else { return nil }
        let all = floats(first)
        guard !all.isEmpty else { return nil }
        if first.mNumberChannels >= 2 {  // interleaved 스테레오
            var l: [Float] = []; var r: [Float] = []
            l.reserveCapacity(all.count / 2); r.reserveCapacity(all.count / 2)
            var i = 0
            while i + 1 < all.count {
                l.append(all[i]); r.append(all[i + 1]); i += 2
            }
            return (l, r)
        }
        return (all, all)
    }

    private func magnitudes(from samples: [Float]) -> [Float] {
        guard let setup = fftSetup else { return [Float](repeating: 0, count: fftSize / 2) }
        return Self.magnitudes(from: samples, fftSize: fftSize, log2n: log2n, setup: setup)
    }

    /// 실수 FFT 진폭(순수 — 커버리지 가능한 계산부). 반환 길이 = fftSize/2.
    /// log2n/setup 은 fftSize 와 정합해야 함(fftSize 는 2의 거듭제곱). samples 는 fftSize 로
    /// 제로패딩(짧으면)·절단(길면)된다 — 라이브 경로는 누적 버퍼가 정확히 fftSize 창만 넘기므로
    /// 이 패딩/절단은 테스트 등 일회성 호출자용 방어다.
    /// WE 2.8.42 는 캡처 샘플에 윈도우(테이퍼)를 적용하지 않는다(디컴파일 FUN_1400d0380:285-308) —
    /// 구 Hann 창 제거로 진폭이 약 2배(Hann coherent gain 0.5 상쇄)가 되는 것은 의도된 방향.
    static func magnitudes(from samples: [Float], fftSize: Int,
                           log2n: vDSP_Length, setup: FFTSetup) -> [Float] {
        var input = samples
        if input.count < fftSize { input += [Float](repeating: 0, count: fftSize - input.count) }
        else if input.count > fftSize { input = Array(input.prefix(fftSize)) }

        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                input.withUnsafeBufferPointer { wp in
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

    /// 테스트/일회성용 편의: FFT setup 을 생성·해제하며 진폭 계산(윈도우 없음 — 위 static 과 동일 경로).
    /// setup 생성 실패 → nil.
    static func magnitudes(from samples: [Float], fftSize: Int) -> [Float]? {
        let log2n = vDSP_Length(round(log2(Double(fftSize))))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        return magnitudes(from: samples, fftSize: fftSize, log2n: log2n, setup: setup)
    }
}

/// 채널별 링버퍼 — 콜백 패킷을 누적해 정확히 windowSize 개가 채워질 때만 창을 방출한다
/// (hop = 창 크기, 겹침 없음). WE 2.8.42 AudioProcessor 도 패킷을 캐리(uVar14=local_3a0)에 누적해
/// 창 도달 시에만 FFT 한다(FUN_1400d0380:260-274 누적·:425 캐리 갱신·:449 `(uint)uVar14 == uVar18` 창 판정).
/// hop=창 크기는 추정 — 디컴파일에 오버랩 흔적이 없고 창 소비 후 캐리가 리셋된다(:184-185).
/// 제로패드 없음 — 창 미만 잔여는 다음 패킷에 이어진다.
struct AudioWindowAccumulator {
    let windowSize: Int
    private var bufL: [Float] = []
    private var bufR: [Float] = []

    init(windowSize: Int) {
        self.windowSize = windowSize
        bufL.reserveCapacity(windowSize * 2)
        bufR.reserveCapacity(windowSize * 2)
    }

    /// 아직 창을 이루지 못한 잔여 샘플 수(진단/테스트용).
    var pendingCount: Int { bufL.count }

    /// 패킷(L/R 동일 길이)을 누적하고, 채워진 완전 창을 선두부터 모두 방출(0개 이상, 순서 보존).
    mutating func append(left l: [Float], right r: [Float]) -> [(left: [Float], right: [Float])] {
        bufL.append(contentsOf: l)
        bufR.append(contentsOf: r)
        // F840: 길이 어긋남 정렬. 종전에는 잔여 길이가 갈리면 짧은 쪽이 영원히 창을 못 채워
        // 긴 쪽이 무한 증가한다(캡처 세션 내내 누적 = OOM). 어긋난 시점에서 이미 L/R 동일 길이
        // 계약이 깨진 것이므로 긴 쪽의 꼬리(최신 샘플)를 버려 다시 맞춘다 — 앞쪽 정렬은 보존된다.
        if bufL.count != bufR.count {
            let aligned = min(bufL.count, bufR.count)
            bufL.removeLast(bufL.count - aligned)
            bufR.removeLast(bufR.count - aligned)
        }
        var out: [(left: [Float], right: [Float])] = []
        // F840: 종전 조건은 bufL 만 봤는데 removeFirst(windowSize) 는 bufR 에도 걸린다 —
        // stereoSamples 가 r.isEmpty 만 특수 처리하므로 **길이가 다른** 스테레오 패킷
        // (non-interleaved 버퍼 두 개의 mDataByteSize 가 갈리는 경우)이 오면 트랩이었다.
        while bufL.count >= windowSize && bufR.count >= windowSize {
            out.append((Array(bufL.prefix(windowSize)), Array(bufR.prefix(windowSize))))
            bufL.removeFirst(windowSize)
            bufR.removeFirst(windowSize)
        }
        return out
    }

    /// 미완성 창 잔여 폐기(캡처 세션 경계 — 엔진 재구성 시 캐리 리셋 FUN_1400d0380:184-185 대응).
    mutating func reset() {
        bufL.removeAll(keepingCapacity: true)
        bufR.removeAll(keepingCapacity: true)
    }
}

/// 앱 레벨 오디오 입력 설정(UserDefaults 백 — scene.json 파스가 아님. WE 도 앱/설정 레벨 어휘:
/// audioinputvolume/audioinputthreshold, strings/json-keys.txt:424-425). 설정 UI 배선은 범위 밖.
/// 키 관례는 `waple.fitMode`/`waple.maxFPS` 등 기존 설정 키(`kr.yaki.waple` 도메인)를 따른다.
public enum AudioInputSettings {
    static let thresholdKey = "waple.audioInputThreshold"
    static let volumeKey = "waple.audioInputVolume"

    /// 무음 게이트 임계값 — 창 피크 < threshold 이면 그 창은 0 스펙트럼(FUN_1400d0380:376-424).
    /// 기본 0 = 비활성(무회귀; 엔진 활성 조건 threshold > FLT_EPSILON 의 판정은 isSilenced 가 담당).
    public static var threshold: Float {
        get { UserDefaults.standard.object(forKey: thresholdKey) == nil ? 0 : UserDefaults.standard.float(forKey: thresholdKey) }
        set { UserDefaults.standard.set(newValue, forKey: thresholdKey) }
    }

    /// 입력 볼륨 — 분석 결과 스펙트럼에 곱하는 스칼라(audioinputvolume). 기본 1 = 무회귀.
    public static var volume: Float {
        get { UserDefaults.standard.object(forKey: volumeKey) == nil ? 1 : UserDefaults.standard.float(forKey: volumeKey) }
        set { UserDefaults.standard.set(newValue, forKey: volumeKey) }
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
