import Foundation

/// WE 의 **소비단(consumer) 오디오 스테이지** — 오디오 스레드가 낸 원시 64L+64R 을 셰이더 유니폼
/// `g_AudioSpectrum16/32/64Left|Right` 로 바꾸는 프레임 단위 처리.
///
/// 이 단계가 있다는 것을 몰라서 우리 스펙트럼은 레벨이 3.5~5배 모자랐다. 프로듀서의 절대 게인
/// (162.56)까지 소수점으로 맞춰 놓고, **정작 그 뒤에 붙는 정규화·스무딩을 통째로 빼먹었다**.
///
/// 원본 `0x140111085`(씬 오디오 업데이트, 매 프레임) 실측. 순서가 전부다:
///
/// ```
///   ① 8밴드 × 16그룹 피크          (128 float 을 연속 8개씩)
///   ② peak[g] = max(peak[g], 0.333·globalPeak, 0.001)     ← 하한 둘
///   ③ state[i] += (raw[i]·(1/peak[g]) − state[i]) · min(dt·20, 1)     1-pole
///   ④ out[i]   = prev[i] + clamp(state[i] − prev[i], −min(dt·40,1), +min(dt·40,1))   슬루 제한
///   ⑤ mono[i]  = 0.5·(L[i] + R[i])
///   ⑥ spec32[j] = max(spec64[2j], spec64[2j+1])
///   ⑦ spec16[j] = max(spec32[2j], spec32[2j+1])
/// ```
///
/// ④ 의 결과가 64밴드 버퍼에 **in-place** 로 다시 쓰이므로, 16·32·64 **세 유니폼 전부가**
/// 정규화·스무딩을 거친 값이다. "씬 audio-responsive 프로퍼티 전용" 이 아니다.
///
/// **축약은 평균이 아니라 MAX 다**(`maxss` — `0x1401128e0`, `0x140112b6f`). 종전 구현은 4개
/// 평균이었는데, 순음 저역에서 최대 4배 차이가 난다(4밴드 중 하나만 뜨면 평균은 1/4).
///
/// 세 버퍼는 서로 다른 힙이고 크기도 다르다(memset 192/96/48 float — `0x140115403`).
/// 각 버퍼는 [Left | Right | Mono] 3분면이며 mono 분면은 셰이더 유니폼으로 노출되지 않는다.
public struct AudioSpectrumProcessor {

    /// 밴드 수(채널당). 프로듀서가 내는 폭.
    public static let bandCount = 64
    /// 정규화 그룹 하나가 덮는 밴드 수. 128 float 을 **연속 8개씩** 16그룹으로 나눈다 —
    /// 즉 그룹 0..7 은 Left, 8..15 는 Right 다.
    public static let groupSize = 8
    /// 그룹 피크의 하한 계수. `peak[g] = max(peak[g], 0.333·globalPeak)` (`0x140111c7d`).
    public static let groupPeakFloorRatio: Float = 0.333
    /// 절대 하한 — 이게 없으면 무음 근처에서 1/peak 가 발산한다(`0x1401122b7`).
    public static let absolutePeakFloor: Float = 0.001
    /// 이 아래면 정규화·스무딩을 통째로 건너뛰고 0 을 낸다(`0x140111c8c` 의 `comiss … 1e-4`).
    public static let silenceThreshold: Float = 1e-4
    /// 1-pole 계수 `min(dt·20, 1)` (`0x140112363`).
    public static let smoothingRate: Float = 20
    /// 슬루 제한 `±min(dt·40, 1)` (`0x1401123f0`, `0x14011240f`).
    public static let slewRate: Float = 40

    /// 1-pole 상태. 프레임을 넘어 유지된다.
    private var state = [Float](repeating: 0, count: 128)
    /// 직전 프레임의 출력 — 슬루 제한의 기준점.
    private var previous = [Float](repeating: 0, count: 128)

    public init() {}

    /// 한 프레임 결과. 각 배열은 [Left | Right | Mono] 3분면이다.
    public struct Output: Equatable {
        public let spec64: [Float]   // 192 = 64×3
        public let spec32: [Float]   // 96  = 32×3
        public let spec16: [Float]   // 48  = 16×3
        public var left16: [Float] { Array(spec16[0..<16]) }
        public var right16: [Float] { Array(spec16[16..<32]) }
        public var left64: [Float] { Array(spec64[0..<64]) }
        public var right64: [Float] { Array(spec64[64..<128]) }
    }

    /// - raw: 128 float(64L + 64R). 길이가 모자라면 0 으로 채우고, 넘치면 앞 128 만 쓴다.
    /// - dt: 직전 프레임과의 간격(초). 0 이면 스무딩이 멈추므로(계수 0) 상태가 그대로 유지된다.
    public mutating func process(raw: [Float], dt: Float) -> Output {
        var input = [Float](repeating: 0, count: 128)
        for i in 0..<Swift.min(128, raw.count) where raw[i].isFinite { input[i] = raw[i] }

        // ① 그룹 피크 + 전체 피크
        let groups = 128 / Self.groupSize
        var peak = [Float](repeating: 0, count: groups)
        var globalPeak: Float = 0
        for g in 0..<groups {
            var p: Float = 0
            for k in 0..<Self.groupSize { p = Swift.max(p, input[g * Self.groupSize + k]) }
            peak[g] = p
            globalPeak = Swift.max(globalPeak, p)
        }

        // 무음: 정규화가 의미 없고 1/peak 가 발산한다. **출력만 0 으로 지우고 상태는 그대로 둔다** —
        // 원본이 그렇다(`0x140112646` 이 출력 버퍼 0x200 B 만 memset 하고 스무딩 단계를 건너뛴다.
        // `state`/`prev` 는 별도 버퍼 `[r15+0x1A8]`/`[r15+0x1A0]` 이고 그 경로에서 안 만진다).
        // 그래서 소리가 돌아오면 처음부터가 아니라 **끊긴 자리에서 이어서** 올라간다.
        // 여기서 상태까지 0 으로 되돌리면 무음이 끼일 때마다 어택이 다시 시작돼 원본보다 굼뜨다.
        guard globalPeak >= Self.silenceThreshold else {
            return Self.reduce([Float](repeating: 0, count: 128))
        }

        // ② 하한 둘
        let ratioFloor = globalPeak * Self.groupPeakFloorRatio
        for g in 0..<groups { peak[g] = Swift.max(Swift.max(peak[g], ratioFloor), Self.absolutePeakFloor) }

        // ③④ 1-pole + 슬루 제한
        let alpha = Swift.min(Swift.max(dt, 0) * Self.smoothingRate, 1)
        let slew = Swift.min(Swift.max(dt, 0) * Self.slewRate, 1)
        var out = [Float](repeating: 0, count: 128)
        for i in 0..<128 {
            let normalized = input[i] / peak[i / Self.groupSize]
            state[i] += (normalized - state[i]) * alpha
            let delta = Swift.min(Swift.max(state[i] - previous[i], -slew), slew)
            out[i] = previous[i] + delta
        }
        previous = out
        return Self.reduce(out)
    }

    /// ⑤⑥⑦ — mono 분면 채우기 + MAX 축약 두 단.
    /// 순수 함수라 테스트가 스무딩 없이 축약만 검증할 수 있다.
    static func reduce(_ stereo128: [Float]) -> Output {
        precondition(stereo128.count == 128)
        var spec64 = [Float](repeating: 0, count: 192)
        for i in 0..<128 { spec64[i] = stereo128[i] }
        for i in 0..<64 { spec64[128 + i] = 0.5 * (spec64[i] + spec64[64 + i]) }

        var spec32 = [Float](repeating: 0, count: 96)
        for j in 0..<96 { spec32[j] = Swift.max(spec64[2 * j], spec64[2 * j + 1]) }

        var spec16 = [Float](repeating: 0, count: 48)
        for j in 0..<48 { spec16[j] = Swift.max(spec32[2 * j], spec32[2 * j + 1]) }

        return Output(spec64: spec64, spec32: spec32, spec16: spec16)
    }
}
