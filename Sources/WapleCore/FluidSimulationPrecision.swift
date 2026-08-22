import Foundation

/// 유체 시뮬레이션 버퍼의 **저장 정밀도**와 그것이 만드는 수치적 한계.
///
/// 왜 있는가
/// ---------
/// `docs/re/fluid-simulation.md` §2.13 은 셰이더 식을 float64 로 재현해 "반복 9회는 수렴이
/// 아니라 평활이다" 를 보였고, 그 절 말미에 **[미해결]** 을 하나 남겼다 —
/// *"`r16f`/`rg16f` 반올림이 §2.13 의 수치에 미치는 영향. 잔차가 작아지는 구간에서 실물이
/// 더 나쁠 것은 확실하나 얼마나인지는 재지 않았다."*
///
/// 이 파일이 그것을 재는 도구다. 실물 버퍼 포맷은 §1.2 에서 확정돼 있다 —
/// 속도 `rg1616f`, 압력/발산/컬 `r16f`, 염료 `rgba_backbuffer`(씬 HDR 비트로
/// `rgba16161616f` 또는 **`rgba8888`**; 설치본 씬 184개 중 `general.hdr` 참은 **3개**뿐이라
/// 기본 경로는 `rgba8888` 이다).
///
/// 모델의 한계(숨기지 않는다)
/// -------------------------
/// GPU 는 **fp32 로 계산하고 fp16/unorm8 로 저장한다.** 여기 함수들은 Swift `Double` 로
/// 계산하고 저장 자리만 양자화한다 — 즉 계산 자리가 실물보다 정확하다. 가수가 53비트 대
/// 23비트 대 10비트라 **저장 양자화가 지배적**이므로 결론이 갈리지 않지만, 이 파일의 수치를
/// "GPU 비트 동일" 이라고 읽으면 안 된다. `binary16Quantize` 는 `Double → Float → binary16`
/// 순서로 접어 저장 단계만은 실물과 같은 한 번의 반올림을 거치게 한다.
public enum FluidSimulationPrecision {

    // MARK: - IEEE 754 binary16 (`r16f` / `rg16f`)

    /// binary16 가수 비트 수(암묵 1 제외).
    public static let binary16SignificandBits = 10

    /// **정규 구간에서 살아남는 가장 작은 상대 증분** = `2^-11`.
    ///
    /// 반올림이 최근접(RTNE)이므로 `|Δ| < ulp(x)/2` 인 증분은 저장에서 **통째로 사라진다**.
    /// `ulp(x) = 2^(e-10)` 이고 `x ∈ [2^e, 2^(e+1))` 이므로 상대 하한이 `2^-11` 이다.
    /// Jacobi 가 정체하는 기구가 정확히 이것이다 — 반복이 쌓여 `p` 가 커질수록 한 번의
    /// 갱신량은 줄어드는데, 그 갱신이 반 ulp 아래로 떨어지면 그 뒤로는 아무 일도 안 일어난다.
    public static let binary16SmallestResolvableRelativeStep = 0x1p-11

    /// binary16 의 ulp(단위 최소 자리). 0 과 준정규 구간에서는 최소 준정규 `2^-24` 를 준다.
    public static func binary16Ulp(_ value: Double) -> Double {
        let a = abs(value)
        if !(a.isFinite) { return .nan }
        if a < 0x1p-14 { return 0x1p-24 }          // 준정규: 간격이 균일하다
        if a >= 65536 { return .infinity }         // 표현 범위 밖
        let exponent = a.exponent                  // 2^e <= a < 2^(e+1)
        return exp2(Double(exponent - binary16SignificandBits))
    }

    /// `Double → Float → binary16` 저장 후 되읽은 값. 반올림은 **최근접-짝수**(RTNE).
    /// 범위를 넘으면 `±infinity`(binary16 의 `0x7C00`)가 된다 — 클램프하지 않는다.
    public static func binary16Quantize(_ value: Double) -> Double {
        binary16Value(binary16Bits(Float(value)))
    }

    /// binary32 → binary16 비트 변환(RTNE). NaN 은 quiet NaN 으로 접는다.
    ///
    /// 이 함수의 정수 변환은 전부 **비트 필드 자르기**가 목적이라 `truncatingIfNeeded:` 를 쓴다.
    /// 마스크(`& 0x8000` · `& 0xFF` · 10비트 가수)가 이미 폭을 보장하므로 트랩할 값이 들어올 수
    /// 없고, `scripts/spec/check_int_narrowing.py` 의 R4 인구조사에도 잡히면 안 되는 자리다.
    public static func binary16Bits(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let one: UInt32 = 1
        let sign = UInt16(truncatingIfNeeded: (bits >> 16) & 0x8000)
        let biased = Int(truncatingIfNeeded: (bits >> 23) & 0xFF)
        let mantissa = bits & 0x007F_FFFF
        if biased == 0xFF {                                  // inf / NaN
            return mantissa == 0 ? (sign | 0x7C00) : (sign | 0x7E00)
        }
        var exponent = biased - 127 + 15
        if exponent >= 0x1F { return sign | 0x7C00 }         // 오버플로 → inf
        if exponent <= 0 {                                   // 준정규 또는 0
            if exponent < -10 { return sign }                // 최소 준정규의 절반 미만 → 0
            let withImplicitOne = mantissa | 0x0080_0000
            let shift = UInt32(truncatingIfNeeded: 14 - exponent)   // 1 ... 24
            var result = withImplicitOne >> shift
            let half = one << (shift - 1)
            let remainder = withImplicitOne & ((one << shift) - 1)
            if remainder > half || (remainder == half && (result & 1) == 1) { result += 1 }
            // 준정규 가수는 10비트 안이고, 0x400 로 올라가면 그것이 곧 최소 정규수의 비트다.
            return sign | UInt16(truncatingIfNeeded: result)
        }
        var significand = mantissa >> 13
        let remainder = mantissa & 0x1FFF
        if remainder > 0x1000 || (remainder == 0x1000 && (significand & 1) == 1) { significand += 1 }
        if significand == 0x400 {                            // 자리올림이 지수로 넘어갔다
            significand = 0
            exponent += 1
            if exponent >= 0x1F { return sign | 0x7C00 }
        }
        return sign | UInt16(truncatingIfNeeded: exponent << 10)
            | UInt16(truncatingIfNeeded: significand)
    }

    /// binary16 비트를 `Double` 로.
    public static func binary16Value(_ bits: UInt16) -> Double {
        let sign: Double = (bits & 0x8000) != 0 ? -1 : 1
        let exponent = Int(truncatingIfNeeded: (bits >> 10) & 0x1F)
        let significand = Double(bits & 0x03FF)
        if exponent == 0 { return sign * significand * 0x1p-24 }
        if exponent == 0x1F { return significand == 0 ? sign * .infinity : .nan }
        return sign * (1 + significand / 1024) * exp2(Double(exponent - 15))
    }

    // MARK: - unorm8 (`rgba8888` — 비 HDR 씬의 염료 버퍼)

    /// `float → unorm8` 저장. `saturate` 후 `×255`, **최근접-짝수** 반올림.
    ///
    /// `exactly:` 를 거치는 이유는 NaN 하나다 — Swift 의 `min`/`max` 는 NaN 을 삼키지 않고
    /// 그대로 흘려보내므로 `UInt8(Double.nan)` 이 트랩할 수 있다. 반올림 뒤 값은 정수이고
    /// [0, 255] 안이라 정상 입력에서는 `exactly:` 가 절대 nil 이 아니다.
    public static func unorm8Store(_ value: Double) -> UInt8 {
        let clamped = min(max(value, 0), 1) * 255
        return UInt8(exactly: clamped.rounded(.toNearestOrEven)) ?? 0
    }

    /// `unorm8 → float` 로드.
    public static func unorm8Load(_ level: UInt8) -> Double { Double(level) / 255 }

    // MARK: - rg16f 속도 감쇠의 고정점 (신규 2026-08-21 · 4차 실측)

    /// binary16 의 **최소 준정규**. 감쇠가 여기까지 내려오면 실질 0이다.
    public static let binary16SmallestSubnormal = 0x1p-24

    /// `v ← v / decay` 한 걸음이 binary16 **저장에서 살아남는가**.
    ///
    /// `false` 면 그 자리가 고정점이다 — 그 뒤로는 몇 프레임을 돌려도 값이 안 움직인다.
    public static func binary16DecayStepSurvives(magnitude: Double, decay: Double) -> Bool {
        let stored = binary16Quantize(magnitude)
        return binary16Quantize(stored / decay) != stored
    }

    /// **`viscosityfactor` 가 어디부터 rg16f 속도장의 감쇠를 완전히 멈추는가.**
    ///
    /// 속도 패스의 감쇠는 `v ← v / (1 + ν·m·dt)`(§2.8)이고 상대 감소분은 `≈ ν·m·dt` 다.
    /// binary16 은 상대 반 ulp 미만의 증분을 저장에서 버리는데(§`binary16SmallestResolvableRelativeStep`)
    /// 그 상대 반 ulp 는 가수 위치에 따라 `2^-12`(binade 위쪽) … `2^-11`(binade 아래쪽) 사이를
    /// 오간다. 그래서 문턱이 **하나의 값이 아니라 띠**다:
    ///
    /// * `ν < alwaysStallsBelow` — binade 안쪽 값에서는 감쇠가 **한 걸음도** 못 간다.
    /// * `ν > neverStallsAbove` — 어느 값에서든 감쇠가 진행된다.
    /// * 그 사이 — 값이 binade 안 어디에 있느냐로 갈린다.
    ///
    /// **이 띠는 근사 안내선이지 판정기가 아니다.** 두 가지가 어긋나게 만든다 —
    /// ① **binade 경계 바로 아래에서는 간격이 반으로 줄어** 위 문턱을 못 넘는 증분도 한 걸음
    ///    내려간다(60 fps · `ν = 0.1` 에서 `300.0` 은 즉시 멈추지만 `256.0` 은 548프레임
    ///    내려가 `187.5` 에서 멈춘다). ② RTNE **동점**은 짝수 쪽으로 접혀 제자리에 남는다
    ///    (`187.5` 가 정확히 그 경우다 — 감소분이 반 ulp 와 같다).
    /// 실제 고정점은 반드시 `binary16VelocityDecayFixedPoint` 로 **돌려서** 구해라.
    ///
    /// 실물 기본값 `viscosityfactor = 1.0`(preview 2.29)은 60 fps 에서 띠보다 **한 자릿수 위**라
    /// 출하 설정에서는 이 정체가 일어나지 않는다. 슬라이더 범위가 `[0, 20]` 이므로 워크샵
    /// 저작으로는 도달한다. `viscosityfactor = 0` 은 `decay == 1` 이라 정밀도와 무관하게 감쇠가 없다.
    public static func binary16DecayStallBand(materialDissipation: Double,
                                              dt: Double) -> (alwaysStallsBelow: Double,
                                                              neverStallsAbove: Double) {
        let perUnit = materialDissipation * dt
        guard perUnit > 0 else { return (.infinity, .infinity) }
        return (0x1p-12 / perUnit, binary16SmallestResolvableRelativeStep / perUnit)
    }

    /// 속도 크기가 감쇠를 멈추는 자리. `nil` 이면 최소 준정규까지(= 실질 0) 내려간다.
    ///
    /// `lowPass`(§2.8)는 `‖v‖ ≤ u_Lifetime` 에서만 붙어 분모를 `+0.5` 로 키우므로,
    /// 그 대역 안으로 들어오면 프레임당 33 % 로 급감해 정체를 못 만든다. 즉 이 함수가
    /// 0 아닌 고정점을 돌려주는 것은 **`u_Lifetime` 위**에서 멈춘 경우뿐이다.
    ///
    /// - Parameters:
    ///   - startMagnitude: 시작 속도 크기(텍셀/초).
    ///   - viscosity: `u_Viscosity`(`viscosityfactor`, 기본 1.0 · preview 2.29).
    ///   - materialDissipation: `m_Dissipation` — 속도 머티리얼 상수 **0.2**.
    ///   - lifetime: `u_Lifetime`(기본 0.1 · preview 0.32).
    ///   - frameTime: 생 `g_Frametime`. `dt` 는 여기서 `min(1/20, ·)` 로 접힌다.
    public static func binary16VelocityDecayFixedPoint(startMagnitude: Double,
                                                       viscosity: Double,
                                                       materialDissipation: Double,
                                                       lifetime: Double,
                                                       frameTime: Double,
                                                       frameLimit: Int = 200_000)
        -> (magnitude: Double, frames: Int)? {
        let dt = FluidSimulation.simulationTimeStep(frameTime: frameTime)
        let decay = FluidSimulation.advectionDecay(decayFactor: viscosity,
                                                   materialDissipation: materialDissipation,
                                                   dt: dt)
        var magnitude = binary16Quantize(startMagnitude)
        var frames = 0
        while frames < frameLimit {
            let lowPass = FluidSimulation.advectionLowPass(sampleMagnitude: magnitude,
                                                           lifetime: lifetime)
            let next = binary16Quantize(magnitude / (decay + lowPass))
            if next == magnitude {
                return magnitude <= binary16SmallestSubnormal ? nil : (magnitude, frames)
            }
            magnitude = next
            frames += 1
            if magnitude == 0 { return nil }
        }
        return (magnitude, frames)
    }

    // MARK: - LDR 염료 감쇠의 고정점 (신규 2026-08-21)

    /// **속도가 0 인 자리에서 염료가 몇 레벨에서 감쇠를 멈추는가.**
    ///
    /// 흐름이 멎으면 이류의 역추적 좌표가 자기 자신이 되어 염료 패스는
    /// `dye ← dye / (decay + lowPass)` 한 줄로 줄어든다(§2.9). `rgba8888` 저장은 그 나눗셈을
    /// 매 프레임 8비트로 접으므로, 감소분이 **반 레벨 미만**이 되는 순간 값이 얼어붙는다.
    ///
    /// 결과가 `nil` 이면 0 까지 내려간다(고정점 없음).
    ///
    /// - Parameters:
    ///   - startLevel: 시작 레벨(0…255).
    ///   - dissipationFactor: `u_Dissipation`(염료 패스의 `dissipationfactor`, 기본 1.0).
    ///   - materialDissipation: `m_Dissipation` — 염료 머티리얼 상수 **0.4**.
    ///   - lifetime: `u_Lifetime`(셰이더 기본 0.1, preview 저작 0.32).
    ///   - frameTime: 생 `g_Frametime`. `dt` 는 여기서 `min(1/20, ·)` 로 접힌다.
    ///
    /// `length(result.rgb)` 는 `RENDERING == 0` 의 밀도 주입이 `CAST4(amt)` 라 rgb 가 같다는
    /// 사실을 써서 `레벨/255 · √3` 으로 계산한다.
    public static func ldrDyeDecayFixedPoint(startLevel: UInt8,
                                             dissipationFactor: Double,
                                             materialDissipation: Double,
                                             lifetime: Double,
                                             frameTime: Double,
                                             frameLimit: Int = 100_000) -> (level: UInt8, frames: Int)? {
        let dt = FluidSimulation.simulationTimeStep(frameTime: frameTime)
        let decay = FluidSimulation.advectionDecay(decayFactor: dissipationFactor,
                                                   materialDissipation: materialDissipation,
                                                   dt: dt)
        var level = startLevel
        var frames = 0
        while frames < frameLimit {
            let value = unorm8Load(level)
            let magnitude = value * 3.0.squareRoot()
            let lowPass = FluidSimulation.advectionLowPass(sampleMagnitude: magnitude,
                                                           lifetime: lifetime)
            let next = unorm8Store(value / (decay + lowPass))
            if next == level { return level == 0 ? nil : (level, frames) }
            level = next
            frames += 1
            if level == 0 { return nil }
        }
        return (level, frames)
    }
}
