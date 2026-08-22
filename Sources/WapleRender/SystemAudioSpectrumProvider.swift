import Foundation
// @preconcurrency — WebRenderer.swift 상단의 근거와 동일(SDK 동시성 애너테이션이
// 델리게이트 요구사항 매칭을 깬다). SCStreamOutput 은 required 라 불일치가 컴파일
// 오류로 드러나지만, 강등해 두는 편이 진단 소음도 함께 없앤다.
@preconcurrency import ScreenCaptureKit
import AVFoundation
import Accelerate
import WapleCore

/// 창 누적기는 `WapleCore` 로 옮겼다 — 캡처 API 가 하나도 안 들어가는 순수 값 타입인데
/// macOS 전용 모듈에 있어서 리눅스 테스트가 못 봤다. 여기서는 재수출만 하므로 호출부와
/// 기존 테스트(`AudioInputPipelineTests`)는 그대로다. 같은 관례가
/// `Sources/WapleRender/AudioSpectrum.swift` 에도 있다.
public typealias AudioWindowAccumulator = WapleCore.AudioWindowAccumulator
/// 무음 게이트 순수 판정부도 같은 이유로 `WapleCore` 에 있다.
public typealias AudioCaptureGate = WapleCore.AudioCaptureGate

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
/// @unchecked Sendable: 이 타입은 애초에 멀티스레드 전제로 쓰인다 — start/stop 은 메인,
/// process 는 캡처 콜백 큐(waple.audio)다. 그래서 가변 상태 둘(`running`·`accumulator`)을 아래
/// `lock` 이 직렬화하고, 나머지는 let 이며, 소비자 콜백 `onFrame` 은 항상 메인 홉 뒤에 호출된다.
/// 컴파일러가 볼 수 없는 그 규율이 근거라 `unchecked` 다(진단 :93/:125 의 메인 홉 self 캡처).
public final class SystemAudioSpectrumProvider: NSObject, AudioSpectrumProviding, @unchecked Sendable {
    public var onFrame: (([Float]) -> Void)?

    /// X-⑩(G-E2-01~04): 1024 → 2048.
    ///
    /// 원본은 `N = int(max(rate/44100, 1) · 1920)` 이고 그 설계 의도가 **빈 폭을 항상 ≈22.97 Hz
    /// 로 고정**하는 것이다(N 은 레이트에 비례, 소비 빈 수 B 는 640 고정). 그 N 은 2의 거듭제곱이
    /// 아니고(48 kHz 에서는 2089, 소수) vDSP 는 임의 길이 실수 FFT 를 못 하므로 길이를 그대로
    /// 못 맞춘다. 대신 **빈 폭을 원본에 최대한 가깝게** 만든다 — 44.1 kHz 에서 2048 은 21.53 Hz 로
    /// 원본의 0.94배다(종전 1024 는 43.07 Hz 로 1.88배였다). 밴드 경계는 정규화 좌표로 계산하고
    /// 소비 빈 수를 원본과 같은 상한 주파수에 맞춰 잡는다(AudioSpectrum.binCount) — 맞는 것은
    /// **상한**(오차 0.06% 이내)이고 밴드 경계 자체는 격자가 달라 최대 1~2빈 밀린다.
    /// 수치와 근거는 `AudioSpectrum` 타입 주석 참조.
    private let fftSize = 2048
    /// 캡처 **요청** 샘플레이트(`SCStreamConfiguration.sampleRate`, 아래 startCapture).
    ///
    /// **원본은 레이트를 요청하지 않는다.** `IAudioClient::GetMixFormat`(`0x1400cf5ab`)이 준
    /// 공유모드 믹스 포맷을 그대로 쓰고, 거기서 `nSamplesPerSec`(`0x1400cf5e4`)와
    /// `nChannels`(`0x1400cf5d3`)를 읽어 N·B 를 정한다. 요구는 `wBitsPerSample == 32`
    /// 하나뿐인데(`0x1400cf5bb`) 그마저 어기면 로그만 남기고 진행한다. 우리가 48000 을
    /// **요청**하는 것은 SCStream API 규약 차이일 뿐이고, 진실원이 실측 포맷이라는 점은 같다.
    ///
    /// 요청일 뿐 보장이 아니다 — 실제로 들어온 버퍼의 레이트는 `Self.sampleRate(of:)` 가 포맷
    /// 기술자에서 읽고, 이 상수는 **그게 없을 때의 폴백**으로만 쓴다. 44.1 kHz 로 오는 장치에서
    /// 48000 을 가정하면 `AudioSpectrum.binCount` 가 B 를 627 로 잡는데 정답은 683 이라
    /// 밴드가 통째로 밀린다(경계 이동 실측 최대 2.00빈).
    ///
    /// 빈 폭 = 48000/2048 = 23.4375 Hz — 원본의 22.96875 Hz 대비 **1.02배**(44.1 kHz 면 21.53 Hz).
    /// **Int 로 든다.** `SCStreamConfiguration.sampleRate` 가 Int 를 받고, 스펙트럼 쪽은
    /// `Double(Int)`(절대 트랩하지 않는 확대 변환)로 쓴다 — 반대로 Double 로 들고 `Int(_:)` 로
    /// 좁히면 그 한 줄이 정수 좁힘 검사(R4)에 걸린다. 상수라 실제 위험은 없지만, 예외를 만들면
    /// 검사가 무뎌진다. 실측 레이트(`sampleRate(of:)`)도 Double 그대로 흘려 좁히지 않는다.
    static let captureSampleRateHz: Int = 48000
    static var captureSampleRate: Double { Double(captureSampleRateHz) }
    private let log2n: vDSP_Length
    // create_fftsetup 실패(극히 드묾) 시 nil — 강제 언랩 대신 무음 폴백. let 이라 lock 없이 안전.
    private let fftSetup: FFTSetup?
    // running 은 메인 스레드(start/stop)와 코어 팬아웃(waple.audio 콜백 큐)에서 동시 접근 — lock 으로 직렬화.
    private let lock = NSLock()
    private var running = false
    // 채널별 링버퍼(WapleCore.AudioWindowAccumulator) — 패킷을 누적해 FFT 창이 찰 때만 분석한다.
    // process(waple.audio 큐)/stop(메인) 양쪽에서 접근 — running 과 같은 lock 으로 보호.
    private var accumulator: AudioWindowAccumulator

    public override init() {
        log2n = vDSP_Length(round(log2(Double(fftSize))))
        let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        fftSetup = setup
        // X-⑩: 창은 FFT 길이가 아니라 **원본의 창 규약** `N − N/3` 이다(0x1400d1491-0x1400d14a0).
        // 나머지 1/3 은 패딩이고 오버랩은 없다(FFT 직후 `xor r13d, r13d` — 0x1400d1e21).
        // 원본은 그 패딩을 0 이 아니라 무음값 127 로 채우는데(0x1400d141d), 상수항이 bin 0 에만
        // 떨어지므로 소비 빈 1..B-1 에서는 우리의 0 패딩과 정확히 등가다.
        // 종전엔 창 = FFT 길이라 패딩이 0 이었다 — 응답 지연이 1.5배였고 격자 보간도 없었다.
        accumulator = AudioWindowAccumulator(windowSize: AudioSpectrum.windowLength(fftLength: fftSize))
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
        accumulator.reset()   // 미완성 창 잔여는 세션을 넘기지 않는다(엔진도 무음/실패 경로에서 캐리 리셋 — `0x1400d1f58`)
        lock.unlock()
        SharedAudioCaptureCore.shared.remove(self)   // 마지막 구독자가 나가면 코어가 스트림을 닫는다
    }

    private func isRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// 코어가 팬아웃한 원시 오디오 버퍼 처리(구 SCStreamOutput 콜백 본체).
    /// internal: 같은 파일의 SharedAudioCaptureCore 가 호출.
    /// WE 2.8.42 AudioProcessor 규약: 패킷을 채널별로 누적해 정확히 창 크기 `W` 에 닿을 때만
    /// FFT 한다(`0x1400d1b6b` 의 `cmp r13d, edi`). **겹침 없음은 이제 추정이 아니다** — FFT 커밋
    /// 직후 채움 카운터를 0 으로 되돌리는 `xor r13d, r13d` 를 확인했다(`0x1400d1e21`, 무음 경로는
    /// `0x1400d1f58`). 구 콜백마다-제로패드/절단은 폐기(짧은 버퍼의 제로패드가 스펙트럼을 오염시켰다).
    /// 창이 차기 전엔 onFrame 을 부르지 않는다.
    ///
    /// 원본과 한 군데 다르다: 원본은 창이 찬 뒤 남은 프레임을 **버린다**(`ReleaseBuffer` 가 소비량이
    /// 아니라 패킷 전체를 반납한다 — `0x1400d1b19`). 그래서 원본의 실효 홉은 창이 아니라 폴 간격
    /// 33 ms 이고 매 폴마다 ~4 ms 를 잃는다. 우리는 푸시 콜백이라 버릴 이유가 없어 전량 캐리한다.
    func process(sampleBuffer: CMSampleBuffer) {
        guard isRunning() else { return }
        guard let (l, r) = Self.stereoSamples(from: sampleBuffer) else { return }
        // 주파수 매핑의 진실원은 **이 버퍼의 포맷**이지 구성 요청값이 아니다. 상태로 들지 않고
        // 인자로 흘린다 — 락이 늘지 않고, 창을 채운 패킷의 레이트가 그 창의 분석에 그대로 따라간다.
        let rate = Self.sampleRate(of: sampleBuffer) ?? Self.captureSampleRate
        lock.lock()
        let windows = running ? accumulator.append(left: l, right: r) : []
        lock.unlock()
        for (wl, wr) in windows { analyzeWindow(left: wl, right: wr, sampleRate: rate) }
    }

    /// 창 1개(채널별 fftSize 샘플)를 분석해 onFrame 디스패치. 무음 게이트가 문 창은 0 스펙트럼 공급
    /// — 엔진도 무음이면 출력 128 float 을 통째로 memset 한다(`0x1400d1f5b`, 폭 `0x200`).
    /// 엔진은 그 밖에도 **패킷이 1,000 ms 동안 한 건도 안 오면** 같은 memset 을 한다
    /// (`0x1400d14ac` 의 `comiss xmm7, 1000.0`). 우리는 폴링이 아니라 푸시 콜백이라 그 타이머가
    /// 없다 — 캡처가 끊기면 마지막 스펙트럼이 남는데, 소비단(`AudioSpectrumProcessor`)의 엔벨로프
    /// 감쇠가 그 자리를 덮으므로 별도 워치독을 두지 않았다.
    private func analyzeWindow(left l: [Float], right r: [Float], sampleRate: Double) {
        guard let setup = fftSetup else { feedZeros(); return }
        guard let out = Self.analyzeWindow(l: l, r: r, fftSize: fftSize, log2n: log2n, setup: setup,
                                           threshold: AudioInputSettings.threshold,
                                           volume: AudioInputSettings.volume,
                                           sampleRate: sampleRate) else {
            feedZeros()
            return
        }
        DispatchQueue.main.async { [weak self] in self?.onFrame?(out) }
    }

    /// 창 분석 순수 계산부(커버리지 가능): 게이트 → 채널별 FFT → 64+64 비닝 → volume 스칼라.
    /// 반환 nil = 무음 게이트가 창을 무음 처리. volume 은 결과 스펙트럼 전체에 곱한다
    /// — 1.0 곱은 IEEE 상 정확히 항등이라 기본값 무회귀. WE 포맷: 128(64L + 64R) 채널별 FFT.
    ///
    /// **`threshold`/`volume` 은 설정값이 아니라 이미 변환된 값이다** — 각각 AP `+0x10` · `+0x0C`
    /// 에 해당한다(`설정×0.001` · `설정×0.02`). 호출부가 `AudioInputSettings.threshold`/`.volume`
    /// 로 변환해 넘긴다. WE 설정 정수를 그대로 넣으면 볼륨 50배 · 임계 1000배다.
    static func analyzeWindow(l: [Float], r: [Float], fftSize: Int,
                              log2n: vDSP_Length, setup: FFTSetup,
                              threshold: Float, volume: Float,
                              sampleRate: Double = AudioSpectrum.referenceRate) -> [Float]? {
        guard !isSilenced(peak: windowPeak(l, r), threshold: threshold) else { return nil }
        // X-⑩: `AudioSpectrum.spectrum` 은 **1/N 정규화 진폭**(|DFT|/N)을 받는다. vDSP 의
        // packed-real 출력은 수학적 DFT 의 2배라 나눗수가 2N 이다. 이 규약을 안 맞추면
        // 원본에서 유도한 절대 게인 162.56 이 의미를 잃는다.
        let norm = 1 / (2 * Float(max(1, fftSize)))
        let bins = AudioSpectrum.binCount(fftLength: fftSize, sampleRate: sampleRate)
        func bands(_ ch: [Float]) -> [Float] {
            let raw = magnitudes(from: ch, fftSize: fftSize, log2n: log2n, setup: setup)
            return AudioSpectrum.spectrum(normalizedMagnitudes: raw.map { $0 * norm }, binCount: bins)
        }
        return Array((bands(l) + bands(r)).prefix(128)).map { $0 * volume }
    }

    /// 창 피크. **채널 0(왼쪽)만** 본다 — 원본이 stride 를 `nChannels · 4` 로 잡고
    /// 프레임마다 첫 채널 하나만 훑기 때문이다(`0x1400d1a36` stride · `0x1400d1a95` `maxss`).
    /// 부호 있는 최댓값을 0 바닥으로 재고 절댓값이 아니다.
    ///
    /// **종전엔 L·R 둘 다 봤다.** 그러면 하드 우측 팬 신호에서 판정이 갈린다(원본은 무음,
    /// 우리는 통과). 기본 threshold 가 0(비활성)이라 실사용 회귀는 없지만 파리티는 파리티다.
    /// 판정 자체는 `WapleCore.AudioCaptureGate` 에 있고(리눅스 테스트 가능) 여기는 위임이다.
    static func windowPeak(_ l: [Float], _ r: [Float]) -> Float {
        _ = r   // 원본이 채널 0 만 재므로 오른쪽은 게이트에 안 들어간다(위 주석).
        return AudioCaptureGate.windowPeak(l)
    }

    /// 무음 게이트 판정(순수). 엔진 활성 조건 `threshold > FLT_EPSILON`(`0x1400d1a1b`),
    /// 활성 시 창 피크 < threshold 이면 무음(`0x1400d1ad6`). 기본 threshold 0 이면 항상 비활성.
    /// 본체는 `WapleCore.AudioCaptureGate` — 여기는 호출부 호환용 위임이다.
    static func isSilenced(peak: Float, threshold: Float) -> Bool {
        AudioCaptureGate.isSilenced(peak: peak, threshold: threshold)
    }

    /// 무음 공급(권한 거부/캡처 실패 폴백). 코어가 실패를 구독자 전원에 브로드캐스트할 때도 호출한다.
    /// internal: 같은 파일의 SharedAudioCaptureCore 가 호출.
    func feedZeros() {
        let zeros = [Float](repeating: 0, count: 128)
        DispatchQueue.main.async { [weak self] in self?.onFrame?(zeros) }
    }

    /// 이 버퍼가 **실제로** 들고 온 샘플레이트(CMSampleBuffer → ASBD `mSampleRate`).
    /// 포맷 기술자가 없거나 값이 비유한/비양수면 nil — 호출자가 요청값(`captureSampleRateHz`)으로 폴백한다.
    ///
    /// **창 길이는 다시 계산하지 않아도 된다.** `AudioSpectrum.windowLength(fftLength:)` 는 fftSize
    /// 하나만 보므로(2048 → 1365) 레이트와 무관하고, 따라서 `accumulator` 를 다시 만들 이유가 없다.
    /// 레이트에 의존하는 것은 소비 빈 수 B 뿐인데(48 kHz→627, 44.1 kHz→683), 그건 static
    /// `analyzeWindow` 가 창마다 `AudioSpectrum.binCount(fftLength:sampleRate:)` 로 다시 잡고
    /// 밴드 표·틸트 표도 `AudioSpectrum.spectrum` 이 그 B 에서 매번 다시 만든다 — 캐시가 없으므로
    /// 무효화할 것이 없다. (창의 물리 길이는 28.5 ms↔31.0 ms 로 달라지는데, 원본도 레이트마다 N 을
    /// 비례시켜 29 ms 를 유지하므로 방향이 같다.)
    static func sampleRate(of sampleBuffer: CMSampleBuffer) -> Double? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format) else { return nil }
        let rate = asbd.pointee.mSampleRate
        guard rate.isFinite, rate > 0 else { return nil }
        return rate
    }

    /// 스테레오 채널별 샘플: non-interleaved(버퍼 2개) → 각 버퍼, interleaved(1버퍼 2채널) → 짝/홀 분리,
    /// 모노 → (mono, mono). 반환 (L, R). 절단 없이 패킷 전체 — 창 맞춤은 누적 버퍼(AudioWindowAccumulator)가 담당.
    /// 원본은 모노 입력이면 **오른쪽 밴드를 0 으로 둔다**(`0x1400d1e92` 의 `cmovge` 가 소스 오프셋을
    /// 0 으로 잡아 우 배열이 memset 상태로 남는다). 우리는 좌를 복제한다 — 소비단이 L/R 을 평균하므로
    /// 원본 쪽이 오히려 모노에서 −6 dB 다. 의도적 이탈이고 `docs/re/audio-capture.md` §4 #9 에 적었다.
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
    /// WE 2.8.42 는 캡처 샘플에 윈도우(테이퍼)를 적용하지 않는다. 적재 루프의 샘플당 연산은
    /// `mulss`(127)·`addss`(127)·`divss` 셋뿐이고 **계수 테이블 인덱싱이 한 번도 없다**
    /// (`0x1400d15d4`-`0x1400d15f1`) — `.rdata` 에 해닝/블랙먼 계수를 역산할 대상 자체가 없다.
    /// 유일한 "창" 은 길이 자르기 `W = int(N − N/3)`(`0x1400d1491`-`0x1400d14a0`)다.
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

/// 앱 레벨 오디오 입력 설정(UserDefaults 백 — scene.json 파스가 아님. WE 도 앱/설정 레벨 어휘:
/// `user.audioinputvolume` / `user.audioinputthreshold`, `config.json`). 설정 UI 배선은 범위 밖.
/// 키 관례는 `waple.fitMode`/`waple.maxFPS` 등 기존 설정 키(`kr.yaki.waple` 도메인)를 따른다.
///
/// **[2026-08-21] 저장 단위를 WE 설정 단위로 맞췄다.** 종전에는 `volume` 이 **곱수**(기본 1),
/// `threshold` 가 **임계 그대로**였다. 그런데 WE 가 실제로 저장하는 것은 슬라이더 정수/실수이고,
/// 곱수·임계는 로더가 상수를 곱해 만든다(전부 `wallpaper64.exe`, imagebase `0x140000000`):
///
/// ```
///   0x14006c72c  lea   rdx, 0x140476f00      ; "audioinputvolume"
///   0x14006c741  call  0x140085ee0           ; asInt
///   0x14006c75e  mulss xmm0, [0x14049262c]   ; × 0.019999999552965164f
///   0x14006c766  movss [0x1404e55b4], xmm0   ; = AP+0x0C  (읽는 자리: 0x1400d1d3f)
///
///   0x14006c750  lea   rdx, 0x140476f18      ; "audioinputthreshold"
///   0x14006c776  call  0x140086220           ; asFloat
///   0x14006c77b  mulss xmm0, [0x140492608]   ; × 0.001f
///   0x14006c794  movss [0x1404e55b8], xmm0   ; = AP+0x10  (읽는 자리: 0x1400d1a15)
/// ```
///
/// 두 사슬 어디에도 `minss`/`maxss`/`comiss` 가 없다 — **클램프가 없다**(확정). 그래서 여기서도
/// 클램프하지 않는다. 슬라이더 도메인은 UI 쪽 값일 뿐 저장 경로의 계약이 아니다
/// (`ui/dist/scripts/scripts.js`: 볼륨 `floor:0, ceil:200`, 임계 `floor:0, ceil:10, step:.1`).
///
/// 변환은 `WapleCore.AudioSpectrum` 에 있다(리눅스 테스트가 값을 잠근다 —
/// `AudioInputSettingsParityTests`). 여기는 **저장·조회**만 한다.
///
/// 곱해지는 **위치**는 실물과 다르다(실물은 비정규화 진폭에, 우리는 밴드 출력에) — 곱셈이
/// 결합적이라 관측 결과는 같다. 근거는 `docs/re/audio-capture.md` §9.2.
public enum AudioInputSettings {
    /// **옛 키 — 읽지도 쓰지도 않는다(툼스톤).** 여기에는 종전 의미의 값, 즉 볼륨은 **곱수**
    /// (기본 1)가, 임계는 **임계 그대로**가 들어 있다. 이름을 유지한 채 의미만 WE 설정 단위로
    /// 바꾸면 이미 저장한 사용자가 볼륨 **50배** · 임계 **1000배**를 맞는다. 그래서 새 키를 쓴다.
    ///
    /// **일회 변환을 하지 않는 이유(판단 근거).**
    ///  ① **역상이 도메인 밖으로 나간다.** 옛 임계 0.25 를 설정 단위로 되돌리면 `0.25/0.001 = 250`
    ///     인데 슬라이더 상한은 10 이다. 25배 밖의 값을 "사용자가 고른 설정" 인 척 심게 된다.
    ///  ② **볼륨은 정수로 양자화된다.** 새 저장 단위는 `asInt` 가 끝낸 정수라(위 `0x14006c741`),
    ///     옛 곱수 1.5 → 75 는 되돌아오지만 임의의 곱수는 라운드트립하지 않는다.
    ///  ③ **게터가 쓰기를 하게 된다.** 일회 변환은 첫 조회 시점에 UserDefaults 를 갱신해야 하는데,
    ///     이 프로퍼티들은 캡처 콜백 경로(`analyzeWindow`)에서 창마다 읽힌다. 읽기 전용 계약을
    ///     깨는 대가가 크다.
    ///  ④ **도달이 0 이다.** 이 두 키를 쓰는 설정 UI 가 아직 없고(위 "설정 UI 배선은 범위 밖"),
    ///     기본 상태에서 오디오를 켜는 동봉 자산도 0건이다(`docs/re/audio-capture.md` §6.1).
    ///     즉 실사용자 중 옛 키에 비기본값이 들어 있는 사람은 없다고 본다 — **추정**이지만,
    ///     틀리더라도 결과는 "그 사람이 기본값으로 돌아간다" 이지 50배가 아니다.
    ///
    /// 값을 **지우지도 않는다** — 남겨 두면 되돌릴 수 있고, 읽지 않으므로 해가 없다.
    static let legacyThresholdKey = "waple.audioInputThreshold"
    static let legacyVolumeKey = "waple.audioInputVolume"

    /// WE `user.audioinputvolume` 와 같은 단위(정수). 기본 50 = 곱수 1.0.
    static let volumeSettingKey = "waple.audioInputVolumeSetting"
    /// WE `user.audioinputthreshold` 와 같은 단위(실수). 기본 0 = 게이트 비활성.
    static let thresholdSettingKey = "waple.audioInputThresholdSetting"

    /// 저장 단위 그대로의 볼륨 설정. 미저장이면 배포 `config.json` 기본값 50.
    public static var volumeSetting: Int {
        get {
            UserDefaults.standard.object(forKey: volumeSettingKey) == nil
                ? AudioSpectrum.defaultInputVolumeSetting
                : UserDefaults.standard.integer(forKey: volumeSettingKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: volumeSettingKey) }
    }

    /// 저장 단위 그대로의 임계 설정. 미저장이면 배포 `config.json` 기본값 0.
    public static var thresholdSetting: Float {
        get {
            UserDefaults.standard.object(forKey: thresholdSettingKey) == nil
                ? AudioSpectrum.defaultInputThresholdSetting
                : UserDefaults.standard.float(forKey: thresholdSettingKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: thresholdSettingKey) }
    }

    /// 분석 결과 스펙트럼에 곱하는 스칼라 = `설정 × 0.02`(`0x14006c75e`).
    /// 기본 설정 50 에서 정확히 1.0 이라(50×0.02f 의 오차 2.2e-8 < 반ULP 3.0e-8) 종전 기본값과
    /// **비트 동일**하다 — 이 변경은 기본 설치에서 무회귀다.
    public static var volume: Float { AudioSpectrum.inputVolumeGain(setting: volumeSetting) }

    /// 무음 게이트 임계 = `설정 × 0.001`(`0x14006c77b`). 창 피크 < threshold 이면 그 창은 0 스펙트럼
    /// (`0x1400d1a1b`-`0x1400d1ad9`). 기본 0 = 비활성이라 종전 기본값과 같다.
    public static var threshold: Float { AudioSpectrum.inputThreshold(setting: thresholdSetting) }
}

/// F536(F-51): 프로세스 전역 단일 SCStream 캡처 코어. 구독자(SystemAudioSpectrumProvider)가 1명 이상이면
/// 캡처를 유지하고 원시 sampleBuffer 를 전원에게 팬아웃, 0명이 되면 스트림을 닫는다(참조 카운트).
/// 세대(generation) 관리는 구 per-instance 구현과 동형 — 급속 stop/start 시 고아 스트림 방지.
/// @unchecked Sendable: 가변 상태(subscribers/stream/running/generation) **전부**가 아래 `lock`
/// 임계 구역 안에서만 읽고 쓰인다 — add/remove/isCurrent/swapStreamIfCurrent/liveSubscribers/
/// stopCaptureIfRunningLocked 가 접근점의 전부다(교착 회피를 위해 stopCapture 만 락 밖, F544).
/// 이 코어는 애초에 여러 스레드(SCStream 콜백 큐 · 구독자 start/stop · startCapture Task)에서
/// 불리도록 설계됐고 락이 그 계약이다 — 컴파일러가 못 보는 그 계약을 표기로 알린다.
private final class SharedAudioCaptureCore: NSObject, SCStreamOutput, @unchecked Sendable {
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
            // 타입 이름을 명시한다 — 이 줄은 `SharedAudioCaptureCore` 안이라 `Self` 가 다른 타입이다.
            config.sampleRate = SystemAudioSpectrumProvider.captureSampleRateHz   // 빈 폭 산출과 단일 소스
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

    /// SCStreamOutput 의 유일한 요구사항도 **optional @objc** 다 — 후킹이 풀리면 sampleBuffer 가 한 번도
    /// 안 들어와 스펙트럼이 영구 무음이 되고(폴백 경로와 구분 불가) 실패가 조용하다. 셀렉터 고정 근거는
    /// WebRenderer.swift 의 didFinish 주석 참조.
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
