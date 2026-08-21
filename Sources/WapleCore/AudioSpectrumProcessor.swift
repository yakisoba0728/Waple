import Foundation

/// WE 의 **소비단(consumer) 오디오 스테이지** — 오디오 스레드가 낸 원시 64L+64R 을 셰이더 유니폼
/// `g_AudioSpectrum16/32/64Left|Right` 로 바꾸는 프레임 단위 처리.
///
/// 이 단계가 있다는 것을 몰라서 우리 스펙트럼은 레벨이 3.5~5배 모자랐다. 프로듀서의 절대 게인
/// (162.56)까지 소수점으로 맞춰 놓고, **정작 그 뒤에 붙는 정규화·스무딩을 통째로 빼먹었다**.
///
/// 원본 `0x140110630`(씬 업데이트, primary)의 오디오 구간 `0x140111662–0x1401131bf` 실측.
/// 순서가 전부다:
///
/// ```
///   ① 8밴드 × 16그룹 순간 피크 (128 float 을 연속 8개씩)      0x1401116f0–0x140111bb2
///   ② peak[g] = max(peak[g], 0.333·globalPeak)               0x140111c7d, 0x140111c99
///   ③ env[0] ≤ 1e-4 이고 소리가 있으면 env[0..15] = 1.0       0x140111cd2–0x140111da3  (리시드)
///   ④ d = peak[g] − env[g]                                    0x140111dc7 이후
///      |d| ≤ 1e-4 → env[g] = peak[g]                          0x140111f18  (스냅)
///      d > 0      → env[g] += min(dt,1)⌃|d| · **1.0**         0x140111ef1  (상승)
///      d < 0      → env[g] −= min(dt,1)⌃|d| · **0.5**         0x140111ef7  (하강)
///   ⑤ div[g] = max(env[g], 0.001), 역수                       0x1401121b8, 0x1401122d2 (rcpps)
///   ⑥ state[i] += (raw[i]·(1/div[g]) − state[i]) · min(dt·20,1)      1-pole  0x14011246f
///   ⑦ out[i]   = prev[i] + clamp(state[i] − prev[i], ±min(dt·40,1))  슬루 제한 0x140112492
///   ⑧ mono[i]  = 0.5·(L[i] + R[i])                            0x1401126b6
///   ⑨ spec32[j] = max(spec64[2j], spec64[2j+1])               0x1401128e0
///   ⑩ spec16[j] = max(spec32[2j], spec32[2j+1])               0x140112b6f
/// ```
/// (`⌃` 는 "목표를 넘지 않게 자른다" — `minss xmm0, xmm2` 가 |d| 로 스텝을 제한한다.)
///
/// **⑦ 의 결과가 64밴드 버퍼에 in-place 로 다시 쓰이므로**(`0x1401124ba`), 16·32·64 세 유니폼
/// 전부가 정규화·스무딩을 거친 값이다. "씬 audio-responsive 프로퍼티 전용" 이 아니다.
///
/// **축약은 평균이 아니라 MAX 다**(`maxss` — `0x1401128e0`, `0x140112b6f`). 종전 구현은 4개
/// 평균이었는데, 순음 저역에서 최대 4배 차이가 난다(4밴드 중 하나만 뜨면 평균은 1/4).
///
/// 세 버퍼는 서로 다른 힙이고 크기도 다르다(memset 0x300/0x180/0xc0 B = 192/96/48 float —
/// `0x14011540c`, `0x140115420`, `0x140115434`). 각 버퍼는 [Left | Right | Mono] 3분면이며
/// mono 분면은 셰이더 유니폼으로 노출되지 않는다 — **씬 스크립트에는 `average` 라는 이름으로
/// 나간다**(`Output.scriptBuffers(_:)` 주석 참조). 그게 이 사분면의 유일하게 확인된 소비처다.
///
/// ### 정규화 분모는 순간 피크가 아니라 **시간 엔벨로프**다
///
/// 종전 구현은 `1/max(그룹 순간 피크, …)` 로 나눴다. 원본은 그렇지 않다. 그룹 피크 16개는
/// `[r15+0x1b0]` 의 **전용 힙(64 B = 16 float, `0x14010dc4f` 의 `alloc(0x40,16)`)** 에 프레임을
/// 넘어 살아 있고, 매 프레임 순간 피크를 향해 **비대칭 선형 슬루**로 기어간다 — 올라갈 땐 초당
/// 1.0, 내려갈 땐 초당 0.5(`0x140111ef1` / `0x140111ef7`). ⑥ 의 분모는 그 엔벨로프다
/// (`0x1401121b1` 이 `[r15+0x1b0]` 을 다시 읽어 `rcpps` 로 역수를 만든다).
///
/// 결과가 크게 다르다. 어떤 그룹이 방금 조용해져도 분모는 즉시 따라 내려가지 않아 그 그룹은
/// 한동안 **작게** 나온다(종전 구현은 바로 1.0 으로 되살아났다). 반대로 갑자기 커지면 분모가
/// 초당 1.0 으로만 쫓아가 순간적으로 1.0 을 넘겨 나온다. 즉 이 단계는 그룹별 **AGC** 이지
/// 프레임 단위 정규화가 아니다.
///
/// ③ 의 리시드가 그 AGC 의 초기값을 준다. 엔벨로프가 0 근처로 죽은 상태(무음이 길었거나 첫
/// 프레임)에서 소리가 들어오면 16개 전부를 **1.0** 으로 앉힌다 — 없으면 `max(env,0.001)` 때문에
/// 첫 프레임이 1000배로 터진다.
///
/// 남은 차이 하나: 원본은 `rcpps`(≈12비트 근사 역수, 상대오차 ≤ 3.7e-4)를 쓰고 우리는 정확한
/// 나눗셈을 쓴다. 눈에 보이는 차이가 아니라 맞추지 않았다.
///
/// ### 상한 클램프도 dB 변환도 **없다**
///
/// 2026-08-21 재대조에서 `0x140110630–0x140113bc0`(merged 7조각)을 함수 시작부터 선형으로 떠
/// 오디오 구간 `0x140111662–0x1401131bf` 의 `minss`/`minps` 를 전수로 셌다 — **13개뿐**이고
/// 전부 시간 계수 아니면 슬루 제한이다: `min(dt,1)` 1개(`0x140111e68`), 엔벨로프 스텝
/// `min(step,|d|)` **명령 8개**(8배 언롤 — 바깥 루프가 2회 돌아 16그룹, `0x140111eeb` 외 7),
/// 슬루 상한 `minps` 4개(`0x140112495`·`500`·`562`·`5c4`). 계수 셋(`min(dt·20,1)` `0x140112377` · `min(dt·40,1)`
/// `0x1401123f9` · `max(dt·(−40),−1)` `0x14011241d`)은 `comiss`/`ja`/`movaps` 분기형이다.
/// **출력값 자체를 1.0 으로 자르는 자리는 한 곳도 없다** — 엔벨로프가 상승률 1.0/초로만 쫓아오므로
/// 갑자기 커진 대역은 정상적으로 1.0 을 넘겨 나간다. 우리 구현이 클램프를 안 두는 것이 맞다.
///
/// dB(로그) 변환도 없다. 프로듀서 소비 루프 `0x1400d1bff–0x1400d1e00` 의 라이브러리 호출은
/// 정확히 셋 — `powf`(`0x1400d1c90`), `cosf`(`0x1400d1ccd`), `sqrtf` 폴백(`0x1400d1cf7`) — 이고
/// `log`/`log10` 계열은 없다. 진폭은 `sqrt(w·power)` 선형 스케일 그대로 간다.
///
/// 무신호 바닥값은 0 이다(무음 분기 `0x140112646` 의 `memset(out, 0, 0x200)`). 바닥을
/// `0.001` 로 두는 것은 **분모**뿐이고(`0x1401121b8`) 출력이 아니다.
///
/// dt 에 대해서도 한 가지: 원본의 dt 는 `[rbp+0x378]` = `rate · fadeIn · frameDelta`
/// (`0x1401114c3–0x14011150f`)다. `rate` 는 씬 프로퍼티(`0x1401152d9`, 기본 1.0), `fadeIn` 은
/// 0↔1 램프다. 둘 다 기본값이면 그냥 프레임 dt 이고, 우리는 그 기본값 경로만 쓴다.
public struct AudioSpectrumProcessor {

    /// 밴드 수(채널당). 프로듀서가 내는 폭.
    public static let bandCount = 64
    /// 정규화 그룹 하나가 덮는 밴드 수. 128 float 을 **연속 8개씩** 16그룹으로 나눈다 —
    /// 즉 그룹 0..7 은 Left, 8..15 는 Right 다.
    ///
    /// 근거(2026-08-21 독립 재측정): 피크 루프 `0x1401116f0–0x140111bb2` 의 적재 주소가
    /// `[rbx + ecx*4 + K]`, `K ∈ {0x00, 0x20, 0x40, …, 0x1e0}`(16개, 스트라이드 0x20 = 8 float)
    /// 이고 그룹마다 `K+0, +4, +8, +0xc` 넷을 읽는다. 카운터는 `add ecx, 4`(`0x140111b81`) 로
    /// **4씩** 오르고 `cmp ecx, 8` / `jl`(`0x140111baf`)로 두 바퀴만 돈다 → 그룹당 4×2 = 8 float.
    public static let groupSize = 8
    /// 그룹 피크의 하한 계수. `peak[g] = max(peak[g], 0.333·globalPeak)` (`0x140111c7d`).
    public static let groupPeakFloorRatio: Float = 0.333
    /// 이 아래면 스무딩 단계를 통째로 건너뛰고 출력만 0 으로 지운다
    /// (`0x140111c8c` 의 `comiss … 1e-4` → `0x14011242f` 의 `je` → `0x140112646` 의 memset).
    public static let silenceThreshold: Float = 1e-4
    /// 엔벨로프 분모의 절대 하한 — 이게 없으면 무음 근처에서 1/env 가 발산한다(`0x1401121b8`).
    public static let peakEnvelopeFloor: Float = 0.001
    /// 목표와 이만큼 이내로 붙으면 슬루하지 않고 그대로 앉힌다(`0x140111ee0` 의 `comiss |d|, 1e-4`).
    public static let peakEnvelopeSnapEpsilon: Float = 1e-4
    /// 엔벨로프 **상승** 속도(초당). `0x140111ef1` 이 계수로 `xmm11`(=1.0)을 고른다.
    public static let peakEnvelopeRiseRate: Float = 1.0
    /// 엔벨로프 **하강** 속도(초당). `0x140111ef7` 의 `-0.5` — 상승의 절반이다.
    public static let peakEnvelopeFallRate: Float = 0.5
    /// 죽은 엔벨로프가 소리를 만났을 때 앉는 값(`0x140111cd2` 의 `mov dword [rax], 0x3f800000`).
    public static let peakEnvelopeReseed: Float = 1.0
    /// 1-pole 계수 `min(dt·20, 1)` (`0x140112363`).
    public static let smoothingRate: Float = 20
    /// 슬루 제한 `±min(dt·40, 1)` (`0x1401123f0`, `0x14011240f`).
    public static let slewRate: Float = 40

    /// 그룹별 피크 엔벨로프 16개(`[r15+0x1b0]`). 프레임을 넘어 유지되고, **무음 프레임에도**
    /// 계속 감쇠한다(원본은 `0x140111ed0` 의 엔벨로프 루프를 무음 분기보다 **앞에서** 돈다).
    /// 테스트가 분모를 직접 고정할 수 있게 모듈 안에서만 읽히게 열어 둔다.
    internal private(set) var peakEnvelope = [Float](repeating: 0, count: 16)
    /// 1-pole 상태(`[r15+0x1a8]`). 프레임을 넘어 유지된다.
    private var state = [Float](repeating: 0, count: 128)
    /// 직전 프레임의 출력(`[r15+0x1a0]`) — 슬루 제한의 기준점.
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

        /// 셰이더 유니폼 `g_AudioSpectrum32Left/Right`(유니폼 id 0x64 / 0x65 — 등록표
        /// `0x140003e2f`/`0x140003e4f` 의 `mov dword [rsp+…], imm` 이 각 이름 `lea` **바로 앞**에
        /// 온다. 순진하게 "이름 뒤의 imm" 으로 읽으면 한 칸 밀린다 — 브리프 함정 16).
        ///
        /// **이 접근자가 없어서 호출부가 자기 축약을 다시 짰다.** `SceneRenderer.setSpectrum64` 는
        /// `left64` 만 받아 `(a+b)/2` 로 32밴드를 만드는데, 실물은 `maxss` 다
        /// (`0x1401128e0: f30f5f048b  maxss xmm0, [rbx+rcx*4]` — 원시 바이트 직접 대조).
        /// 아래 `spec32` 는 `reduce` 가 이미 MAX 로 접어 둔 값이므로, 잘라 쓰기만 하면 된다.
        /// 순음 저역처럼 인접 두 밴드 중 하나만 뜨는 신호에서 평균은 MAX 의 **절반**이다.
        public var left32: [Float] { Array(spec32[0..<32]) }
        public var right32: [Float] { Array(spec32[32..<64]) }

        /// mono 사분면. 유니폼으로는 노출되지 않는다(등록표에 오디오는 0x62…0x67 여섯 개뿐이고
        /// 그 중 mono 는 없다 — `0x140003df7`–`0x140003e9e` 전수 확인). 진단·테스트용.
        public var mono64: [Float] { Array(spec64[128..<192]) }
        public var mono32: [Float] { Array(spec32[64..<96]) }
        public var mono16: [Float] { Array(spec16[32..<48]) }

        /// 씬 스크립트가 `engine.registerAudioBuffers(res)` 로 받는 세 배열.
        ///
        /// **실물은 이 자리에서 아무것도 접지 않는다.** `scenescript64.dll` 의
        /// `registerAudioBuffers`(`0x181655170–0x18165580f`, merged 9조각)는 해상도 하나만 받아
        /// **미리 할당해 둔 9개 버퍼**(3해상도 × 3배열, `0x181655360–0x1816553ca` 루프) 중 한 벌을
        /// 골라 JS 객체 프로퍼티로 꽂을 뿐이다. 즉 스크립트가 보는 값은 이 소비단이 이미
        /// 정규화·스무딩·MAX 축약까지 끝낸 `spec16/32/64` 그대로다.
        ///
        /// 세 프로퍼티 이름도 실물에서 그대로 떴다 — 엔진 객체의 인터닝된 이름 슬롯
        /// `[engine+0x2b8]`=`"left"`(`0x18164895b`), `[+0x2c0]`=`"right"`(`0x18164899a`),
        /// `[+0x2c8]`=`"average"`(`0x1816489d9`) 이고, `registerAudioBuffers` 가 그 셋을 각각
        /// 버퍼 슬롯 `+0x630`/`+0x638`/`+0x640` 에 물린다(`0x181655642`, `0x181655679`,
        /// `0x1816556a0`). 슬롯 인덱스는 `3·(res>>5)` 라 16→`0x630`, 32→`0x648`, 64→`0x660`
        /// 이다(`0x1816553e2` 의 `shr r15d, 5`, `0x1816553f6` 의 `lea eax,[r15+r15*2]`).
        ///
        /// **셋째 배열이 `average` 라는 것이 mono 사분면의 두 번째 독립 증거다.** 소비단이
        /// `0.5·(L+R)` 로 만드는 그 사분면(`0x1401126b6`)이 셰이더 유니폼으로는 안 나가지만
        /// (등록표에 오디오는 0x62…0x67 여섯 개뿐) 스크립트에는 `average` 로 나간다.
        ///
        /// **접는 순서 주의.** `average32/16` 은 `average64` 를 MAX 로 접은 것이지, 접힌 L/R 을
        /// 다시 평균한 것이 아니다. 32→16 언롤 사슬이 `[rax+0x160]`·`[rax+0x168]`,
        /// `[rax+0x170]`·`[rax+0x178]`(= 96 float 버퍼의 셋째 사분면)까지 도는 것이 그 증거다
        /// (`0x14011315e`, `0x1401131aa`). 두 순서는 갈린다 — L=[1,0], R=[0,1] 이면
        /// 실물은 `max(0.5, 0.5) = 0.5`, 뒤바꾼 순서는 `0.5·(1+1) = 1.0` 이다.
        public func scriptBuffers(_ resolution: ScriptResolution)
            -> (left: [Float], right: [Float], average: [Float]) {
            switch resolution {
            case .bands16: return (left16, right16, mono16)
            case .bands32: return (left32, right32, mono32)
            case .bands64: return (left64, right64, mono64)
            }
        }
    }

    /// `engine.registerAudioBuffers(resolution)` 이 받는 해상도.
    ///
    /// 실물은 셋 중 하나가 아니면 **던진다** — 폴백하지 않는다
    /// (`"Resolution must be either 16, 32 or 64."` @`0x1819a3b38` — `0x181655297` 의 `lea r8`).
    /// 전역 스코프 밖에서 부르는 것도 예외다
    /// (`"registerAudioBuffers can only be called from global scope."` @`0x1819a3af8`).
    ///
    /// 상수 `engine.AUDIO_RESOLUTION_16/32/64` = 0x10/0x20/0x40 도 같은 등록 함수가 심는다
    /// (`0x181649c05`/`0x181649c65`/`0x181649cc5` 의 `mov r8d, imm`).
    public enum ScriptResolution: Int, CaseIterable, Sendable {
        case bands16 = 16
        case bands32 = 32
        case bands64 = 64

        /// 인자를 생략했을 때 실물이 쓰는 값. `0x181655221: mov r15d, 0x10` 이 argc 검사
        /// (`0x181655216: cmp dword [rcx], 0` → `jle`)보다 **앞에** 있어서, 인자가 없으면 16 이다.
        /// **64 가 아니다** — 무인자 호출은 16밴드 한 벌을 받는다.
        public static let fallback = ScriptResolution.bands16

        /// 실물의 검사를 그대로 옮긴 것(`0x18165527e–0x181655291`):
        ///
        /// ```
        ///   mov  eax, 0xfffffff0
        ///   add  eax, r15d          ; eax = res − 16
        ///   test eax, 0xffffffcf    ; 4·5비트 말고 다른 비트가 서면 → 오류
        ///   jne  <throw>
        ///   cmp  r15d, 0x30         ; 48 은 마스크를 통과하므로 따로 걷어낸다
        ///   jne  <ok>
        /// ```
        ///
        /// **두 게이트가 다 필요하다.** 마스크만으로는 `res-16 ∈ {0,0x10,0x20,0x30}`,
        /// 즉 `{16, 32, 48, 64}` 가 통과한다 — 48 은 그 다음 `cmp` 가 따로 걷어낸다.
        /// 그래서 아래도 `rawValue:` 로 우회하지 않고 두 게이트를 그대로 태운다(하나만 빼도
        /// 48 이나 17 이 `.bands64` 로 새어 나가고, 테스트가 그 둘을 잡는다).
        ///
        /// 산술은 **int32** 다(`r15d`) — 그래서 32비트로 자른 뒤 검사한다.
        /// 유효하지 않으면 `nil`; 호출부가 실물처럼 오류를 내면 된다(폴백이 아니다).
        public static func validate(_ raw: Int) -> ScriptResolution? {
            let r32 = Int32(truncatingIfNeeded: raw)
            guard UInt32(bitPattern: r32 &- 16) & 0xffff_ffcf == 0 else { return nil }
            guard r32 != 0x30 else { return nil }
            // 두 게이트를 통과한 것은 16 · 32 · 64 뿐이다(마스크가 남긴 넷에서 48 을 뺀 셋).
            return r32 == 16 ? .bands16 : (r32 == 32 ? .bands32 : .bands64)
        }
    }

    /// - raw: 128 float(64L + 64R). 길이가 모자라면 0 으로 채우고, 넘치면 앞 128 만 쓴다.
    /// - dt: 직전 프레임과의 간격(초). 0 이면 엔벨로프도 스무딩도 멈춘다(계수 0).
    public mutating func process(raw: [Float], dt: Float) -> Output {
        var input = [Float](repeating: 0, count: 128)
        for i in 0..<Swift.min(128, raw.count) where raw[i].isFinite { input[i] = raw[i] }
        let dt = Swift.max(dt, 0)

        // ① 그룹 순간 피크 + 전체 피크. 전체 피크는 0 아래로 안 내려간다(`0x140111bc4`).
        let groups = 128 / Self.groupSize
        var peak = [Float](repeating: 0, count: groups)
        var globalPeak: Float = 0
        for g in 0..<groups {
            var p: Float = 0
            for k in 0..<Self.groupSize { p = Swift.max(p, input[g * Self.groupSize + k]) }
            peak[g] = p
            globalPeak = Swift.max(globalPeak, p)
        }

        // ② 비율 하한. **절대 하한 0.001 은 여기 없다** — 그건 ⑤ 의 엔벨로프에만 걸린다.
        let ratioFloor = globalPeak * Self.groupPeakFloorRatio
        for g in 0..<groups { peak[g] = Swift.max(peak[g], ratioFloor) }

        let audible = globalPeak >= Self.silenceThreshold

        // ③ 리시드. 조건은 `env[0]` **하나만** 본다(`0x140111ca1` 의 `comiss xmm6, [rax]`) —
        // 16개가 늘 함께 움직이므로 대표 하나로 충분하다는 판단이다.
        if audible && peakEnvelope[0] <= Self.silenceThreshold {
            for g in 0..<groups { peakEnvelope[g] = Self.peakEnvelopeReseed }
        }

        // ④ 비대칭 선형 슬루. 무음 분기보다 **앞**이라 소리가 없어도 계속 내려간다 —
        // 그래서 무음이 충분히 길면 엔벨로프가 0 에 닿고, 다음 소리에 ③ 이 다시 문다.
        let envStep = Swift.min(dt, 1)
        for g in 0..<groups {
            let d = peak[g] - peakEnvelope[g]
            if abs(d) <= Self.peakEnvelopeSnapEpsilon {
                peakEnvelope[g] = peak[g]
            } else if d > 0 {
                peakEnvelope[g] += Swift.min(envStep, d) * Self.peakEnvelopeRiseRate
            } else {
                peakEnvelope[g] -= Swift.min(envStep, -d) * Self.peakEnvelopeFallRate
            }
        }

        // 무음: **출력만 0 으로 지우고 state/prev 는 그대로 둔다** — 원본이 그렇다
        // (`0x140112646` 이 출력 버퍼 0x200 B 만 memset 하고 `0x1401125e2` 의 prev 복사도 건너뛴다.
        // `state`/`prev` 는 별도 버퍼 `[r15+0x1a8]`/`[r15+0x1a0]` 이고 그 경로에서 안 만진다).
        // 그래서 소리가 돌아오면 처음부터가 아니라 **끊긴 자리에서 이어서** 올라간다.
        guard audible else {
            return Self.reduce([Float](repeating: 0, count: 128))
        }

        // ⑤⑥⑦ 엔벨로프 역수 + 1-pole + 슬루 제한
        let alpha = Swift.min(dt * Self.smoothingRate, 1)
        let slew = Swift.min(dt * Self.slewRate, 1)
        var out = [Float](repeating: 0, count: 128)
        for i in 0..<128 {
            let divisor = Swift.max(peakEnvelope[i / Self.groupSize], Self.peakEnvelopeFloor)
            let normalized = input[i] / divisor
            state[i] += (normalized - state[i]) * alpha
            let delta = Swift.min(Swift.max(state[i] - previous[i], -slew), slew)
            out[i] = previous[i] + delta
        }
        previous = out
        return Self.reduce(out)
    }

    /// ⑧⑨⑩ — mono 분면 채우기 + MAX 축약 두 단.
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
