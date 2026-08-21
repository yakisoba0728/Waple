import Foundation

/// `remapvalue` / `remapinitialvalue` 의 **값 산출 산술** — WE `wallpaper64.exe`
/// (imagebase `0x140000000`) 실측을 그대로 옮긴 순수 함수 모음.
///
/// 왜 `WapleCore` 에 있는가
/// -----------------------
/// 이 산술은 RNG·시계·GPU 를 하나도 안 쓴다. 리눅스 코어 테스트로 오라클 대조가 가능하고,
/// 소비처(`ParticleSimulator.remapEval`)는 파티클 상태와 얽혀 있어 그 안에서는 잠글 수 없다.
/// 전문 근거는 `docs/re/remap-operation.md` §10.
///
/// 산출식(성분 하나 기준). `op = r14 + 0x10` 은 VM 레코드 헤더 0x10 을 건너뛴 파서 기준 주소다.
/// ```
///   span    = inputrangemax − inputrangemin                    ; 파스 시각 0x1401ceaf0
///   span    = (span == 0) ? 0x34000000 : span                   ; = 2^-23   0x1401cedf3
///   rcp     = rcpps(span)                                       ; 12비트 근사 0x1401cee47
///   outSpan = outputrangemax − outputrangemin                   ; 파스 시각 0x1401cedbb
///
///   t   = (raw − inputrangemin) · rcp                           ; 0x1402450fa · 0x1402450fd
///   if (flags & 1) t = clamp01(t)                               ; 0x14024510a → 0x140245117
///   v   = wave(t, transforminputscale)                          ; 점프 테이블 0x14024bc9c
///   out = outSpan · v + outputrangemin                          ; 0x140245783 · 0x140245788
///   if (flags & 2) out = clamp01(out)                           ; 0x140245799 → 0x1402457a0
/// ```
///
/// 못박아 둘 것 넷(전부 실측):
///  * **역방향 범위에 특수 처리가 없다.** `min > max` 면 폭이 음수가 되어 감소 함수가 될 뿐이다.
///    `abs`·min/max 스왑·부호 검사가 어느 쪽에도 없다.
///  * **퇴화 입력 범위(min == max)만** `2^-23` 로 치환된다. 출력 폭에는 나눗셈이 없어 치환도 없다.
///    즉치 `0x34000000` 을 쓰는 자리는 이미지 전체에 둘뿐이다(`0x1401cae45` 이니셜라이저 ·
///    `0x1401cedf3` 오퍼레이터).
///  * **`flags` 는 bit0·bit1 만 살아 있다.** 두 핸들러 모두 `[r14+0x2c]` 를 정확히 두 번 읽고
///    (`0x140244986`·`0x140244996` / `0x140246fc9`·`0x140246fd9`) 그 두 비트만 뽑는다.
///    부재 기본값은 **int 1** 이다(공유 주입 꼬리 `0x1401d8040`: 타입 `0x1401d8071`, 값 `0x1401d809d`).
///  * **`transformfunction: none` 은 `transforminputscale` 을 곱하지 않는다.** `dec`+`cmp 5`+`ja`
///    (`0x140245137`–`0x14024513c`)가 0 과 센티넬을 `0x140245928` 로 보내고, 거기서 곧장 출력
///    매핑으로 뛴다 — 변환 암에 들어가야 스케일이 곱해진다.
///
/// **[의도적 이탈] 역수.** 실물은 `rcpps`(최대 상대오차 ≈ 1.5·2⁻¹²)를 Newton 보정 없이 쓴다.
/// 여기서는 정확한 나눗셈을 쓴다 — 헤드리스 결정성이 우선이고, 근사 테이블은 CPU 모델 의존이라
/// 재현 자체가 옳지 않다. 폭이 1.0 인 기본 범위에서는 둘 다 정확히 1.0 이라 무회귀다.
public enum RemapValueMath {
    /// 입력 폭이 정확히 0 일 때 엔진이 끼워 넣는 값(`0x34000000` = 2⁻²³).
    public static let degenerateInputSpan: Float = 0x1p-23

    /// 파스 시각에 굽는 입력 폭. **정확히 0 일 때만** 치환한다(NaN 은 그대로 — `ucomiss`
    /// 뒤의 `jp`(`0x1401cede4`)가 unordered 를 먼저 걸러낸다).
    public static func inputSpan(min lo: Float, max hi: Float) -> Float {
        let span = hi - lo
        return span == 0 ? degenerateInputSpan : span
    }

    /// `t = (raw − min) / span`. 역방향(`min > max`)이면 감소 함수가 된다 — 그것이 실물이다.
    public static func normalize(_ raw: Float, min lo: Float, max hi: Float) -> Float {
        (raw - lo) * (1 / inputSpan(min: lo, max: hi))
    }

    /// `minps 1.0` → `maxps 0` 순서 그대로. NaN 은 `minps` 가 두 번째 피연산자를 내므로 1.0 이 된다.
    public static func clamp01(_ v: Float) -> Float {
        let capped = v.isNaN ? Float(1) : Swift.min(v, 1)
        return Swift.max(0, capped)
    }

    // MARK: - 파형 넷 (docs/re/remap-operation.md §10.4)

    /// `sine` — 암 `0x140245150`. `0.5·sin(π·s·t − π/2) + 0.5` = `0.5 − 0.5·cos(π·s·t)`.
    /// **주기는 `t` 기준 `2/s` 다.** 계수 π 는 `0x1404836d0`, π/2 는 `0x1404836c0`,
    /// 마지막 `0.5` 는 `0x140483740`(`0x140245245`·`0x140245249`).
    public static func sine(_ t: Float, inputScale s: Float) -> Float {
        0.5 - 0.5 * cosf(Float.pi * s * t)
    }

    /// `square` — 암 `0x14024544a`. `roundEven(u − trunc(u)) + (u < 0 ? 1 : 0)`.
    /// `roundps …, 8`(`0x14024546b`)이 **최근접짝수**라 `frac(u)` 가 정확히 0.5 면 결과가 **0** 이다.
    /// 부호 보정은 곱한 뒤의 `u` 로 본다(`cmpltps` `0x140245462`).
    public static func square(_ t: Float, inputScale s: Float) -> Float {
        let u = t * s
        let f = u - u.rounded(.towardZero)
        return f.rounded(.toNearestOrEven) + (u < 0 ? 1 : 0)
    }

    /// `saw` — 암 `0x1402454ea`. `frac(u)`. **부호 보정이 `u` 가 아니라 곱하기 전의 `t` 를 본다**
    /// (`cmpltps xmm7, xmm10` `0x1402454f9` 시점의 `xmm7` 은 아직 `t` 다). `s < 0` 에서 square 와 갈린다.
    public static func saw(_ t: Float, inputScale s: Float) -> Float {
        let u = t * s
        return (u - u.rounded(.towardZero)) + (t < 0 ? 1 : 0)
    }

    /// `triangle` — 암 `0x140245578`. `1 − |2·frac(|u|) − 1|`.
    /// 절댓값 마스크 `0x140483790`(`0x140245593`·`0x1402455ab`), 2.0 은 `0x1404837b0`.
    public static func triangle(_ t: Float, inputScale s: Float) -> Float {
        let a = abs(t * s)
        let f = a - a.rounded(.towardZero)
        return 1 - abs(2 * f - 1)
    }

    /// `simplexnoise`/`fbmnoise` 의 마지막 접기 — `0.5·n + 0.5`
    /// (`mulps xmm0, xmm15` `0x140245682` · `addps xmm0, xmm15` `0x140245686`, `xmm15 = 0.5` @`0x14023fd64`).
    public static func unitFromSignedNoise(_ n: Float) -> Float { 0.5 * n + 0.5 }

    // MARK: - 출력 매핑

    /// `out = (max − min)·v + min`. 폭이 파스 시각의 **순수 뺄셈**이라 `min > max` 면 감소한다
    /// (동봉 프리뷰 씬이 실제로 `"1 0 0"` → `"0 0 1"` 이다).
    public static func outputMap(_ v: Float, min lo: Float, max hi: Float) -> Float {
        (hi - lo) * v + lo
    }

    // MARK: - 파이프라인 전체

    /// 값 산출 전 구간. `wave` 가 `nil` 이면 `transformfunction: none` 이고, 그때는
    /// **`inputScale` 을 곱하지 않고 `v = t`** 다(`0x140245928`).
    ///
    /// `wave` 는 `(t, inputScale) -> [0,1]` 이다 — `sine`/`square`/`saw`/`triangle` 은 이 타입에
    /// 그대로 맞고, 노이즈 둘은 호출부가 자기 노이즈를 감싸 `unitFromSignedNoise` 로 접어 넘긴다.
    ///
    /// `operation`(적용 산술)은 **여기 없다.** 실물도 값 산출 구간에서 `[r14+0x10]` 을 한 번도
    /// 읽지 않는다 — `docs/re/remap-operation.md` §0.1.
    public static func evaluate(raw: Float,
                                inputMin: Float, inputMax: Float,
                                outputMin: Float, outputMax: Float,
                                flags: Int,
                                inputScale: Float,
                                wave: ((Float, Float) -> Float)?) -> Float {
        var t = normalize(raw, min: inputMin, max: inputMax)
        if flags & 1 != 0 { t = clamp01(t) }
        let v = wave.map { $0(t, inputScale) } ?? t
        var out = outputMap(v, min: outputMin, max: outputMax)
        if flags & 2 != 0 { out = clamp01(out) }
        return out
    }

    /// 부재 기본값 — 주입기 실측.
    ///  * `flags` 1 (공유 꼬리 `0x1401d8040`, 값 `0x1401d809d`)
    ///  * `transforminputscale` 2.0 (`0x1401bffe1`, 상수 `0x1404927a8`)
    ///  * `transformoctaves` 3 (`0x1401bfff8`)
    ///  * `inputrangemin` 0 (`0x1401bfc8c`) · `inputrangemax` 1 (`0x1401bfd76`)
    ///  * `outputrangemin` 0 (`0x1401bfe64`) · `outputrangemax` 1 (`0x1401bff52`)
    public enum InjectedDefault {
        public static let flags: Int = 1
        public static let transformInputScale: Float = 2
        public static let transformOctaves: Int = 3
        public static let inputRangeMin: Float = 0
        public static let inputRangeMax: Float = 1
        public static let outputRangeMin: Float = 0
        public static let outputRangeMax: Float = 1
    }
}
