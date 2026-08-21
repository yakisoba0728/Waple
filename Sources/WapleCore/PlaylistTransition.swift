import Foundation

// WE(2.8.42, imagebase 0x140000000) 재생목록·벽지 전환 서브시스템의 **순수 모델**.
//
// 왜 여기 있는가
// -------------
// `Sources/Waple/AppLogic.swift` 의 `PlaylistScheduling` 은 AppKit 타깃 안이라 리눅스에서
// 빌드조차 안 된다. 전환 종류 표·타이밍 곡선·셔플백은 전부 GPU 도 창도 필요 없는 **산수**라
// 그 자리가 맞지 않는다. 이 파일은 `import Foundation` 하나만 쓰고 AppKit/Metal/simd 를
// 건드리지 않으므로 `scripts/dev/linux-core-tests.sh` 에서 초 단위로 검증된다.
//
// 근거는 전부 `docs/re/playlist-transition.md` 이고, 이 파일의 VA 인용은 그중 이번에
// **디스어셈으로 직접 재확인한 것만** 적었다(§4.1 파서 · §4.3 추첨 · §5.1 타이밍 ·
// §6.1 타이머 틱 · §6.2 daytime · §6.4 셔플백 · §6.5 sorted 커서).
//
// 여기 없는 것: 셰이더 27종의 실제 이식. Metal 이고 범위가 크다 — 난이도표는 문서 §10.

// MARK: - 전환 종류 (27종 + 특수값 3)

/// WE 벽지 전환 효과. `playlist.settings.transition` 이 갖는 값의 정본.
///
/// `-1`/`-2`/`-3` 특수값 3개와 id `0…26` 효과 27개로 **총 30종**이다. 27 이라는 숫자는
/// 세 출처가 독립적으로 확인한다 — 셰이더 분기 27개, `getTransitionOptions()` 27개,
/// 로케일 키 27개. 여기에 바이너리도 보탠다: 무작위 추첨 상수 `27.0f`(0x140492894)와
/// 상한 `26`(0x1400691c6).
///
/// `case none` 을 쓰지 않는다 — `Optional.none` 과 `.none` 표기가 겹쳐 추론이 흔들린다.
public enum PlaylistTransitionKind: Equatable, Hashable, Sendable, CaseIterable {

    // ── 특수값 3 ──────────────────────────────────────────────────────────
    /// `-1`. 전환 자체를 하지 않는다. 0x14006904a 의 `cmp r12d,-1` 에서 즉시 이탈해
    /// 떠나는 프레임을 **캡처조차 안 한다**. 파서 진입 시 초기값이기도 하다(0x14007579f).
    case noTransition
    /// `-2`. 셰이더 없이 마지막 프레임만 붙잡아 새 벽지가 뜰 때의 깜빡임을 가린다
    /// (0x1400692f8 `cmp r12d,-2` → `sub_14005aaf0`).
    case noTransitionReduceFlicker
    /// `-3`. `transitionpool` 에서 추첨한다(0x1400691a4 `cmp ecx,-3`).
    case random

    // ── 효과 27종, id 순 ─────────────────────────────────────────────────
    case fade               // 0
    case mosaic             // 1
    case diffuse            // 2
    case horizontalSlide    // 3
    case verticalSlide      // 4
    case horizontalFade     // 5
    case verticalFade       // 6
    case clouds             // 7   셰이더 주석은 "Cloud blend"
    case burntPaper         // 8
    case circular           // 9   셰이더 주석은 "Circular blend"
    case zipper             // 10
    case door               // 11
    case lines              // 12
    case zoom               // 13
    case drip               // 14  셰이더 주석은 "Drip vertical"
    case pixelate           // 15
    case bricks             // 16  유일하게 지오메트리 셰이더가 필요하다
    case paint              // 17
    case fadeToBlack        // 18
    case twister            // 19
    case blackHole          // 20
    case crt                // 21
    case radialWipe         // 22
    case glassShatter       // 23  유일하게 정점 메시가 필요하다
    case bullets            // 24
    case ice                // 25
    case boilover           // 26

    /// 효과 id `0…26`. 특수값은 `nil`.
    public var effectID: Int? {
        let v = weConfigValue
        return v >= 0 ? v : nil
    }

    /// `playlist.settings.transition` 에 저장되는 정수.
    ///
    /// 전수 `switch` 로 둔다 — 케이스를 추가하면 컴파일러가 여기서 막는다.
    public var weConfigValue: Int {
        switch self {
        case .noTransition: return -1
        case .noTransitionReduceFlicker: return -2
        case .random: return -3
        case .fade: return 0
        case .mosaic: return 1
        case .diffuse: return 2
        case .horizontalSlide: return 3
        case .verticalSlide: return 4
        case .horizontalFade: return 5
        case .verticalFade: return 6
        case .clouds: return 7
        case .burntPaper: return 8
        case .circular: return 9
        case .zipper: return 10
        case .door: return 11
        case .lines: return 12
        case .zoom: return 13
        case .drip: return 14
        case .pixelate: return 15
        case .bricks: return 16
        case .paint: return 17
        case .fadeToBlack: return 18
        case .twister: return 19
        case .blackHole: return 20
        case .crt: return 21
        case .radialWipe: return 22
        case .glassShatter: return 23
        case .bullets: return 24
        case .ice: return 25
        case .boilover: return 26
        }
    }

    /// WE UI 라벨(`getTransitionOptions()` · 로케일 키와 교차 검증된 이름).
    /// `scripts/re/playlist_transition.py` 가 세 출처 일치를 매번 재확인한다.
    public var weDisplayName: String {
        switch self {
        case .noTransition: return "None"
        case .noTransitionReduceFlicker: return "None (reduce flicker)"
        case .random: return "Random"
        case .fade: return "Fade"
        case .mosaic: return "Mosaic"
        case .diffuse: return "Diffuse"
        case .horizontalSlide: return "Horizontal slide"
        case .verticalSlide: return "Vertical slide"
        case .horizontalFade: return "Horizontal fade"
        case .verticalFade: return "Vertical fade"
        case .clouds: return "Clouds"
        case .burntPaper: return "Burnt paper"
        case .circular: return "Circular"
        case .zipper: return "Zipper"
        case .door: return "Door"
        case .lines: return "Lines"
        case .zoom: return "Zoom"
        case .drip: return "Drip"
        case .pixelate: return "Pixelate"
        case .bricks: return "Bricks"
        case .paint: return "Paint"
        case .fadeToBlack: return "Fade to black"
        case .twister: return "Twister"
        case .blackHole: return "Black hole"
        case .crt: return "CRT"
        case .radialWipe: return "Radial wipe"
        case .glassShatter: return "Glass shatter"
        case .bullets: return "Bullets"
        case .ice: return "Ice"
        case .boilover: return "Boilover"
        }
    }

    /// 효과 27종만, id 오름차순.
    public static let allEffects: [PlaylistTransitionKind] =
        allCases.filter { $0.effectID != nil }.sorted { $0.weConfigValue < $1.weConfigValue }

    /// 특수값 3종만(`-1`, `-2`, `-3` 순).
    public static let allSpecials: [PlaylistTransitionKind] =
        [.noTransition, .noTransitionReduceFlicker, .random]

    /// 정확한 왕복. 알려지지 않은 값이면 `nil` — 클램프하지 않는다.
    /// 엔진이 실제로 하는 관용 처리는 `resolving(weConfigValue:)` 쪽이다.
    public init?(weConfigValue value: Int) {
        guard let kind = Self.byConfigValue[value] else { return nil }
        self = kind
    }

    /// `uniqueKeysWithValues` 라 id 가 겹치면 **첫 사용 시점에 트랩**한다.
    /// 위 두 `switch` 가 어긋나면 조용히 통과하지 않게 하려는 의도다.
    private static let byConfigValue: [Int: PlaylistTransitionKind] =
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.weConfigValue, $0) })

    /// 엔진이 **전환 시작 시점에** 실제로 쓰는 값.
    ///
    /// 파서는 `atoi` 결과를 그대로 저장하고(0x1400759de–0x1400759e3) 클램프는 여기서 한다:
    ///
    ///     0x14006904a  cmp r12d, -1   → 즉시 이탈(전환 없음)
    ///     0x1400692f8  cmp r12d, -2   → 깜빡임 완화 경로
    ///     0x1400691a4  cmp ecx,  -3   → 풀 추첨
    ///     0x14006924e  cmp ecx, 0x1a / jge → 26        (상한)
    ///     0x140069255  test ecx,ecx  / cmovs → 0       (하한)
    ///
    /// 그래서 `-4` 는 특수값이 아니라 **하한에 걸려 `.fade`(0)** 가 되고, `99` 는 `.boilover`(26)
    /// 가 된다. 이게 "정의되지 않은 값은 거부" 가 아니라 "클램프" 라는 점이 `init?` 과 다르다.
    public static func resolving(weConfigValue value: Int) -> PlaylistTransitionKind {
        if value == -1 { return .noTransition }
        if value == -2 { return .noTransitionReduceFlicker }
        if value == -3 { return .random }
        let clamped = min(max(value, 0), PlaylistRandomDraw.maxEffectID)
        return PlaylistTransitionKind(weConfigValue: clamped) ?? .fade
    }

    // MARK: 설정 파스 (0x140075790–0x140075a8f)

    /// `transition` 이 **bool** 일 때 저장되는 정수.
    ///
    ///     0x1400757fd  cmp byte [rax+8], 5        ; jsoncpp booleanValue
    ///     0x140075813  lea eax, [rax*2 - 2]       ; true(1) → 0,  false(0) → -2
    ///
    /// `true` 가 `.fade` 라는 게 헷갈리는 지점이다 — "전환 켬" 의 기본이 Fade 다.
    public static func weConfigValue(fromBool flag: Bool) -> Int { flag ? 0 : -2 }

    /// `transition` 이 **string** 일 때 저장되는 정수(0x140075827 `cmp byte [rax+8], 4`).
    ///
    /// - `"random"` → `-3`, 이어서 `transitionpool` 을 읽는다(0x140075882–0x14007589d).
    /// - `"none"`   → **저장을 아예 건너뛴다**(0x1400759c1–0x1400759cf 가 0x1400759f0 으로
    ///   점프해 `mov [r14], eax` 를 지나친다). 진입부 초기값 `-1`(0x14007579f) 이 그대로 남으므로
    ///   결과는 `-1` 과 같지만, **이유가 다르다** — 값을 쓰는 게 아니라 안 쓰는 것이다.
    /// - 그 외 → `atoi`(0x1400759de). 숫자가 아니면 C 관례대로 0 = Fade 다.
    public static func weConfigValue(fromString text: String) -> Int {
        if text == "random" { return -3 }
        if text == "none" { return -1 }
        return weAtoi(text)
    }

    /// CRT `atoi`(0x1402c82c0, 호출 0x1400759de)의 좁은 재현.
    ///
    /// 선행 공백 → 부호 → 숫자, 첫 비숫자에서 멈추고 그때까지의 값을 낸다. 숫자가 하나도
    /// 없으면 0 이다. **오버플로 처리는 WE 주장이 아니다** — C 에서는 미정의라 여기서는
    /// `Int32` 범위로 포화시킨다(WE 반환형이 `int` 라는 것만 근거로 삼은 안전 선택).
    public static func weAtoi(_ text: String) -> Int {
        var digits = Substring(text)
        while let head = digits.first, head == " " || head == "\t" || head == "\n"
                || head == "\r" || head == "\u{0B}" || head == "\u{0C}" {
            digits = digits.dropFirst()
        }
        var negative = false
        if let sign = digits.first, sign == "+" || sign == "-" {
            negative = (sign == "-")
            digits = digits.dropFirst()
        }
        var magnitude = 0
        let ceiling = 2_147_483_648            // |Int32.min|. 여기서 멈추면 트랩이 없다.
        for character in digits {
            guard let value = character.wholeNumberValue, character.isASCII,
                  character >= "0", character <= "9" else { break }
            if magnitude > ceiling { continue }   // 이미 포화 — 더 곱하지 않는다
            magnitude = magnitude * 10 + value
        }
        if negative {
            return -min(magnitude, ceiling)
        }
        return min(magnitude, ceiling - 1)
    }
}

// MARK: - 균등 추첨 (0x1400691ba–0x140069249, 0x140068138–0x14006819b)

/// WE 의 `rand()` 기반 인덱스 추첨을 그대로 옮긴 것.
///
/// 셰이더 효과 추첨과 셔플백 추첨이 **완전히 같은 형태**다 — `[0,1] 균등값 × n` 을
/// 0 방향으로 절단하고 `[0, n-1]` 로 클램프한다. 그래서 한 자리에 둔다.
public enum PlaylistRandomDraw {

    /// 효과 개수. 추첨 상수 `27.0f` = 0x140492894.
    public static let effectCount = 27
    /// 효과 상한. 0x1400691c6 `mov ecx, 0x1a`.
    public static let maxEffectID = 26
    /// CRT `rand()` 의 최대값이자 나눗셈 상수 `32767.0f` = 0x140492960.
    public static let weRandMax = 32767

    /// `rand()` 결과를 [0,1] 로 정규화한다.
    ///
    /// **닫힌 구간이다** — `rand()` 가 32767 을 내면 정확히 1.0 이 되고, `1.0 × 27 = 27` 은
    /// 유효 id 를 넘는다. 뒤따르는 클램프가 장식이 아니라 이 한 경우를 위해 있다.
    public static func unit(weRand: Int) -> Double {
        Double(min(max(weRand, 0), weRandMax)) / Double(weRandMax)
    }

    /// `idx = clamp(trunc(unit × count), 0, count-1)`.
    ///
    ///     0x140069235  cvttss2si eax, xmm2      ; 0 방향 절단
    ///     0x140069239  cmp ebx, eax / cmovg     ; min(count-1, ·)
    ///     0x140069242  test ebx,ebx / cmovs     ; max(0, ·)
    ///
    /// `count <= 0` 이면 0 을 낸다 — 호출부가 빈 컬렉션을 먼저 걸러야 한다.
    public static func index(unit: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let scaled = (unit * Double(count)).rounded(.towardZero)
        let raw = safeInt(scaled) ?? 0     // 신뢰 경계 밖 unit 이 와도 트랩하지 않는다
        return min(max(raw, 0), count - 1)
    }

    /// `transition == -3` 일 때 뽑히는 효과 id (0x1400691ba–0x140069249).
    ///
    /// 풀이 비면 0…26 전체에서 뽑는다(0x1400691b5 `cmp rax, r12` → 같으면 아래로).
    /// 풀이 있으면 `n = (end-begin)/4` 로 인덱스를 뽑아 **그 원소를 그대로 낸다**.
    ///
    /// **풀 경로는 0…26 클램프를 거치지 않는다.** 0x14006924c 의 `jmp 0x140069261` 이
    /// 클램프 블록(0x14006924e–0x14006925c)을 건너뛰고, 파스 쪽도 `atoi` 결과를 그대로
    /// 집합에 넣는다(0x140075934 → 0x140075946). 즉 손으로 고친 config 의 `"99"` 는
    /// `FADEEFFECT=99` 로 컴파일된다. UI 는 그런 값을 만들지 않는다.
    ///
    /// 풀은 WE 에서 `std::set<int>` 라 **오름차순**이다 — 인덱스가 의미를 가지려면
    /// 정렬 순서가 계약이다.
    public static func effectID(pool: Set<Int>, unit: Double) -> Int {
        guard !pool.isEmpty else {
            return index(unit: unit, count: effectCount)
        }
        let ordered = pool.sorted()
        return ordered[index(unit: unit, count: ordered.count)]
    }

    /// `effectID(pool:unit:)` 에 전환 시작 시점의 클램프까지 태운 결과.
    /// 풀에 범위 밖 값이 들어 있어도 Waple 쪽에서는 유효한 효과가 나오게 한다.
    public static func kind(pool: Set<Int>, unit: Double) -> PlaylistTransitionKind {
        PlaylistTransitionKind.resolving(weConfigValue: effectID(pool: pool, unit: unit))
    }
}

// MARK: - 전환 타이밍 (0x14005a351–0x14005a3d1)

/// 전환 진행도. **호스트는 순수 선형이다** — 이징 곡선은 전부 셰이더 27종 안에 있다.
///
///     progress = clamp((elapsed - 0.1) / (transitiontime × 0.001), 0, 1)
///
/// 렌더 루프에 곱셈·거듭제곱·`smoothstep` 이 없다는 것을 0x14005a351–0x14005a3d1 전 구간에서
/// 확인했다. 0.1초 리드인은 새 벽지가 첫 프레임을 띄울 시간을 벌어 준다 — 그동안
/// `progress == 0` 이라 떠나는 벽지의 캡처 프레임이 그대로 보인다.
public enum TransitionTimeline {

    /// 리드인. `0.1f` @ 0x140492654, 루프 진입 전 `xmm9` 로 적재(0x140059b76).
    public static let leadInSeconds: Float = 0.1
    /// 밀리초 → 초. `0.001f` @ 0x140492608, `xmm8` 로 적재(0x14005a2e3).
    public static let millisToSeconds: Float = 0.001

    /// 정본 계산. WE 가 `float` 로 계산하므로 여기도 `Float` 다 — `Double` 로 올리면
    /// 경계에서 결과가 갈린다.
    ///
    /// 클램프는 `comiss` 두 번이라 **NaN 이 1.0 으로 간다**:
    ///
    ///     0x14005a3b6  comiss xmm14(1.0), xmm6(p)
    ///     0x14005a3ba  jbe 0x14005a3cd            ; 1.0 <= p  또는 unordered(NaN) → p = 1.0
    ///     0x14005a3bc  comiss xmm15(0.0), xmm6(p)
    ///     0x14005a3c0  jbe 0x14005a3c7            ; 0.0 <= p → 유지
    ///     0x14005a3c2  xorps xmm6, xmm6           ; 그 외 → p = 0.0
    ///
    /// 그래서 `transitionTimeMillis == 0` 은 크래시가 아니라 **1프레임 전환**이다:
    /// `elapsed > 0.1` 이면 `+inf` → 1.0, `elapsed == 0.1` 이면 `0/0 = NaN` → 1.0,
    /// `elapsed < 0.1` 이면 `-inf` → 0.0.
    public static func progress(elapsed: Float, transitionTimeMillis: Int) -> Float {
        let denominator = Float(transitionTimeMillis) * millisToSeconds
        let raw = (elapsed - leadInSeconds) / denominator
        if raw.isNaN || raw >= 1.0 { return 1.0 }
        if raw < 0.0 { return 0.0 }
        return raw
    }

    /// `TimeInterval` 편의 오버로드. 계산 자체는 위 `Float` 경로를 그대로 탄다.
    public static func progress(elapsedSeconds: TimeInterval, transitionTimeMillis: Int) -> Double {
        Double(progress(elapsed: Float(elapsedSeconds), transitionTimeMillis: transitionTimeMillis))
    }

    /// 오버레이가 살아 있는 총 시간(초). 루프는 `progress >= 1.0` 에서 창을 파괴한다
    /// (0x14005a79b–0x14005a7d3).
    public static func totalSeconds(transitionTimeMillis: Int) -> Float {
        leadInSeconds + Float(transitionTimeMillis) * millisToSeconds
    }

    /// 렌더 루프의 프레임 상한. 0x14005a790 `mov ecx, 0xf` → `Sleep(15)`.
    public static let frameSleepMilliseconds = 15
}

// MARK: - 재생 순서 · 모드

/// `playlist.settings.order` (0x140075b8b–0x140075bf2).
public enum PlaylistOrder: Int, Sendable, CaseIterable {
    case random = 0
    case sorted = 1

    /// `"sorted"` 만 1 이고 **그 밖의 모든 문자열이 0** 이다(0x140075bd9 의 단일 비교).
    /// 오타든 빈 문자열이든 전부 셔플이 된다.
    public init(weConfigString text: String) {
        self = (text == "sorted") ? .sorted : .random
    }

    public var weConfigString: String {
        switch self {
        case .random: return "random"
        case .sorted: return "sorted"
        }
    }
}

/// `playlist.settings.mode` (0x140075c41–0x140075d41).
public enum PlaylistMode: Int, Sendable, CaseIterable {
    case logon = 0
    case timer = 1
    case daytime = 2
    case dayOfWeek = 3
    case never = 4

    /// **`"timer"` 라는 문자열은 바이너리에 없다.** 기본값 1 이 곧 timer 라서
    /// (0x140075c3d `mov …, 1`) 어떤 문자열도 매치되지 않으면 자동으로 timer 다.
    public init(weConfigString text: String) {
        switch text {
        case "logon": self = .logon
        case "daytime": self = .daytime
        case "dayofweek": self = .dayOfWeek
        case "never": self = .never
        default: self = .timer
        }
    }

    /// 디스크에 쓰이는 문자열. `timer` 만 `nil` — 쓸 문자열이 없어 키를 생략한다.
    public var weConfigString: String? {
        switch self {
        case .logon: return "logon"
        case .timer: return nil
        case .daytime: return "daytime"
        case .dayOfWeek: return "dayofweek"
        case .never: return "never"
        }
    }

    /// 이 모드에서 `delay` 가 0 으로 덮이는가(0x140075d41 `mov [r14+0x30], r13d`).
    ///
    /// `logon` 은 이 지점을 건너뛴다(0x140075cb1 `jmp 0x140075d45`). 그래서 logon 은
    /// `delay` 가 살아 있으면 **타이머 전환도 같이 돈다** — 문서 §3.1 의 관찰 그대로다.
    public var clearsDelayOnParse: Bool {
        self == .daytime || self == .dayOfWeek || self == .never
    }

    /// 타이머 틱이 이 모드에서 도는가.
    ///
    ///     0x140076d41  mov eax, [rbx+0x70]   ; mode
    ///     0x140076d44  sub eax, 2
    ///     0x140076d47  cmp eax, 1
    ///     0x140076d4a  jbe 0x140076d92       ; mode ∈ {2,3} → 시각 기반, 타이머 안 씀
    ///
    /// `never` 는 여기서 걸러지지 않는다 — `delay = 0` 이 0.01분 가드에 걸려 멎는다.
    public var usesTimerTick: Bool {
        self != .daytime && self != .dayOfWeek
    }
}

// MARK: - 항목

/// `playlist.items[]` 의 원소. WE 는 0x48바이트 구조체로 저장한다(0x140075ae7 `add rbx, 0x48`).
///
/// 디스크에서는 문자열이거나 오브젝트다 — `daytimeend` 도 `preset` 도 없으면 UI 직렬화기가
/// **문자열로 축약**한다.
public struct PlaylistItem: Equatable, Sendable {
    /// 항목 구조체 `+0x00`, `std::string`(32B).
    public var file: String
    /// 항목 구조체 `+0x20`, `float`(0x14007629a). 하루를 [0,1] 로 정규화한 **끝나는 시각**.
    /// 키가 없으면 `nil` — daytime 선택에서 매치되지 않는다.
    public var daytimeEnd: Float?
    /// 항목 구조체 `+0x28`, `std::string`(32B).
    public var preset: String

    public init(file: String, daytimeEnd: Float? = nil, preset: String = "") {
        self.file = file
        self.daytimeEnd = daytimeEnd
        self.preset = preset
    }

    /// 항목 구조체 크기. 0x140075ae7 · 0x140068177(`lea rbx,[rbx+rbx*8]` ×9 후 `*8`) ·
    /// 0x140067b43 세 곳이 같은 값을 확인한다.
    public static let weStructStride = 0x48
}

// MARK: - 설정

/// `playlist.settings` 전체. 기본값은 **엔진 파서 기준**이다(UI 기본값과 다른 항목은 아래 주석).
public struct PlaylistSettings: Equatable, Sendable {

    /// `delay` 기본값. 0x140075b14 의 즉치 `0x42700000` = 60.0f (분).
    public static let defaultDelayMinutes: Float = 60.0
    /// 타이머 틱의 하한. `0.01f` @ 0x140492620, 비교 0x140076d51. 0.01분 = 0.6초.
    public static let minimumDelayMinutes: Float = 0.01
    /// `transitiontime` **엔진** 기본값. 0x140075a2f `mov dword [r14+4], 0x1f4` = 500ms.
    public static let defaultTransitionTimeMillis = 500
    /// UI 가 새 재생목록에 심는 기본값. 실측 `browsetransition` 도 이 값이다.
    /// 문서 §5.3 대로 WE 자신이 세 값(500/1000/1500)을 쓴다 — 실사용에 맞는 것은 이쪽이다.
    public static let uiDefaultTransitionTimeMillis = 1500
    /// UI 슬라이더 범위와 스텝(`configureTransitionSlider`).
    public static let transitionTimeSliderRange = 0...3000
    public static let transitionTimeSliderStep = 50

    /// 전환 간격(분). `int`/`uint`/`real` 만 받는다 — 0x140075b56 `cmp ecx,2; jbe`.
    /// 그 밖의 타입(문자열·bool·배열)이면 기본값이 아니라 **0.0** 이 된다.
    public var delayMinutes: Float
    public var order: PlaylistOrder
    public var mode: PlaylistMode
    /// `+0x3c` bit0. 동영상이 끝날 때 전환한다(그동안 타이머 전환은 보류된다).
    public var videoSequence: Bool
    /// `+0x3c` bit1. 일시정지 중에도 타이머를 굴린다.
    public var updateOnPause: Bool
    /// `+0x3c` bit3. **`mode == timer` 일 때만 읽는다**(0x140075e02 `cmp dword [r14+0x38],1`).
    public var beginFirst: Bool
    /// `+0x3c` bit4. **`beginFirst` 가 켜졌을 때만 읽는다**(0x140075e4c `test byte [r14+0x3c],8`).
    public var playIntro: Bool
    /// `transition` 의 **원시** 저장값. 클램프 전이라 `-4` 나 `99` 도 그대로 담긴다.
    public var transitionConfigValue: Int
    public var transitionTimeMillis: Int
    /// `transitionpool`. WE 는 `std::set<int>` 라 중복이 없고 오름차순이다.
    /// UI 는 풀이 전체와 같아지면 키를 지운다 — 그래서 **빈 풀 = 전체 허용**이다.
    public var transitionPool: Set<Int>

    public init(
        delayMinutes: Float = PlaylistSettings.defaultDelayMinutes,
        order: PlaylistOrder = .random,
        mode: PlaylistMode = .timer,
        videoSequence: Bool = false,
        updateOnPause: Bool = false,
        beginFirst: Bool = false,
        playIntro: Bool = false,
        transitionConfigValue: Int = -1,
        transitionTimeMillis: Int = PlaylistSettings.defaultTransitionTimeMillis,
        transitionPool: Set<Int> = []
    ) {
        self.delayMinutes = delayMinutes
        self.order = order
        self.mode = mode
        self.videoSequence = videoSequence
        self.updateOnPause = updateOnPause
        self.beginFirst = beginFirst
        self.playIntro = playIntro
        self.transitionConfigValue = transitionConfigValue
        self.transitionTimeMillis = transitionTimeMillis
        self.transitionPool = transitionPool
    }

    /// 전환 시작 시점에 확정되는 종류. 원시값이 범위를 벗어나도 여기서 클램프된다.
    public var transition: PlaylistTransitionKind {
        PlaylistTransitionKind.resolving(weConfigValue: transitionConfigValue)
    }

    /// 파서가 **읽는 도중에** 거는 상호 의존을 적용한 결과.
    ///
    /// 세 규칙 전부 순서 의존이라 별도 단계로 두면 안 된다 — 파서는 위에서 아래로 한 번에 읽는다.
    ///   1. `mode ∈ {daytime, dayofweek, never}` → `delay = 0` (0x140075d41)
    ///   2. `mode != timer` → `beginfirst` 를 아예 안 읽는다 → false 유지 (0x140075e02)
    ///   3. `!beginfirst` → `playintro` 를 아예 안 읽는다 → false 유지 (0x140075e4c)
    public func normalized() -> PlaylistSettings {
        var out = self
        if mode.clearsDelayOnParse { out.delayMinutes = 0 }
        if mode != .timer { out.beginFirst = false }
        if !out.beginFirst { out.playIntro = false }
        return out
    }

    /// 타이머 틱이 지금 다음 벽지로 넘어가야 하는가(0x140076d32–0x140076d85).
    ///
    /// 다섯 관문이 전부 통과해야 한다. `isPaused` 관문이 Waple 과 갈리는 자리다 —
    /// Waple 의 `shouldAdvanceNow(isPaused:)` 는 `updateOnPause` 를 **false 로 고정**한
    /// 것과 같다.
    public func shouldTimerAdvance(
        elapsedSeconds: Float,
        isPaused: Bool,
        currentIsVideo: Bool
    ) -> Bool {
        // 0x140076d3b  test byte [rbx+0x74], 2 / je → 정지 중엔 updateonpause 가 있어야 진행
        if isPaused && !updateOnPause { return false }
        // 0x140076d4a  jbe → mode ∈ {2,3} 은 시각 기반이라 타이머를 안 쓴다
        guard mode.usesTimerTick else { return false }
        // 0x140076d51  comiss xmm7(0.01), delay / ja → delay < 0.01분이면 아무것도 안 한다
        guard delayMinutes >= Self.minimumDelayMinutes else { return false }
        // 0x140076d63  divss xmm8(60.0) / 0x140076d68 comiss delay, elapsed_min / ja
        guard elapsedSeconds / 60.0 >= delayMinutes else { return false }
        // 0x140076d7c  cmp eax,4(동영상) / 0x140076d81 test byte [rbx+0x74],1
        if currentIsVideo && videoSequence { return false }
        return true
    }
}

// MARK: - 셔플백 (0x140068010–0x1400681a0)

/// **소진형** 셔플. WE 의 `order = random` 은 단순 난수가 아니다.
///
/// 백이 비면 전체 항목으로 다시 채우고, 뽑은 항목은 백에서 지운다. 그래서 **한 바퀴가 다
/// 돌기 전에는 같은 항목이 두 번 나오지 않는다.** Waple 의 `shuffleNext` 는 직전 1개만
/// 회피하므로 3곡짜리 목록에서 A,B,A,B 가 나올 수 있다 — 그게 이 타입이 존재하는 이유다.
///
/// **첫 백만 n 개이고 이후 백은 n-1 개다.** 리필 직후 현재 재생 항목을 빼기 때문이다.
/// 직관적으로 "매 바퀴 전원" 을 기대하기 쉬운데 그렇지 않다 — 어떤 항목은 한 바퀴를 통째로
/// 건너뛰고 그다음 바퀴에 반드시 나온다(그 항목이 빠진 백의 마지막이 될 수 없으므로).
/// 결과적으로 3곡에서 임의의 5연속 추첨 안에 3종이 전부 든다.
///
/// `Sendable` 을 선언하지 않는다: 내부 `SplitMix64` 가 `Sendable` 을 채택하지 않은 public
/// 타입이라 조건부 적합이 서지 않는다. 값 타입이라 복사 후 각자 굴리면 되고, 실제 사용은
/// 액터/큐 하나에 갇힌 상태 조각이다.
public struct ShuffleBag<Element: Equatable> {

    /// 리필 원본. 항목 목록이 바뀌면 백을 새로 만든다(WE 도 설정 재적용 때 그렇게 한다).
    public let source: [Element]
    /// `playintro`. 켜져 있으면 **첫 항목을 빼고** 채운다(0x140068039 `je` → 0x14006803b `add r9, 0x48`).
    /// "첫 벽지는 부팅 직후 1회만" 이라는 뜻이다.
    public let playIntro: Bool
    /// 남은 항목. 관찰용으로 열어 둔다 — 불변식 테스트가 이걸 본다.
    public private(set) var remaining: [Element]

    private var rng: SplitMix64

    /// - Parameter seed: 결정적 재현의 근거. 같은 시드 + 같은 호출 순서 = 같은 수열이다.
    public init(items: [Element], seed: UInt64, playIntro: Bool = false) {
        self.source = items
        self.playIntro = playIntro
        self.remaining = []
        self.rng = SplitMix64(seed: seed)
    }

    /// 백이 비어 다음 `next` 가 리필을 하게 되는가.
    public var needsRefill: Bool { remaining.isEmpty }

    /// 다음 항목을 뽑는다. 백이 비었으면 먼저 채운다.
    ///
    /// - Parameter current: 지금 재생 중인 항목. **리필 직후에만** 백에서 제거된다
    ///   (0x1400680a0–0x140068114) — 한 바퀴가 끝나고 다시 채웠을 때 같은 벽지가 연달아
    ///   나오는 것을 막는 장치다. 리필이 없었으면 아무 일도 안 한다.
    ///
    /// 제거 조건은 0x140068054–0x140068065 다: `playintro` 면 항목수 > 2, 아니면 > 1.
    /// 리필 직후 백 크기가 `playintro ? n-1 : n` 이므로 **어느 쪽이든 "백 크기 > 1"** 로
    /// 같은 말이다. 하나뿐인 백에서 현재 항목까지 빼면 뽑을 게 없어지기 때문이다.
    public mutating func next(current: Element? = nil) -> Element? {
        guard !source.isEmpty else { return nil }

        if remaining.isEmpty {
            // 0x140068018  cmp [r14+0x50], r8 / jne → 백이 비었을 때만 리필한다
            remaining = playIntro ? Array(source.dropFirst()) : source
            if remaining.count > 1,
               let current,
               let hit = remaining.firstIndex(of: current) {
                remaining.remove(at: hit)
            }
        }

        // 0x140068121  cmp rax, rdi / je 0x14006839a → 그래도 비면 포기한다
        // (항목 1개 + playintro 조합이 여기 걸린다)
        guard !remaining.isEmpty else { return nil }

        let pick = PlaylistRandomDraw.index(unit: Double(rng.nextFloat()), count: remaining.count)
        return remaining.remove(at: pick)   // 0x140068183 복사 → 0x14006819b 삭제
    }

    /// 백을 강제로 비운다. 다음 `next` 가 리필한다.
    public mutating func drain() { remaining.removeAll(keepingCapacity: true) }
}

// MARK: - sorted 커서 (0x14006826f–0x1400682d0)

/// `order = sorted` 의 인덱스 커서.
public struct PlaylistSortedCursor: Equatable, Sendable {

    /// WE 의 `+0x78`. 다음에 쓸 인덱스다.
    public private(set) var cursor: Int

    public init(cursor: Int = 0) { self.cursor = cursor }

    /// `beginfirst` 경로가 커서를 0 으로 되돌린다(0x140067ee6 `mov dword [r14+0x78], r13d`).
    public mutating func reset() { cursor = 0 }

    /// 다음 인덱스.
    ///
    ///     0x140068275  movsxd rax, [r14+0x78]
    ///     0x140068288  div  rcx              ; % 항목수
    ///     0x14006828b  mov  [r14+0x78], edx
    ///     0x14006828f  test r13b, r13b       ; playintro?
    ///     0x140068294  test edx, edx         ; 커서가 0 으로 되감겼나
    ///     0x1400682aa  mov  [r14+0x78], 1    ; → 1 로 건너뛴다(인트로 재생 안 함)
    ///     0x1400682d0  inc  dword [r14+0x78]
    ///
    /// `count > 1` 가드는 **Waple 이 더한 것**이다. WE 는 항목 1개 + `playintro` 에서
    /// 인덱스 1 을 내놓는다(UI 가 그 조합을 못 만들게 막는 것으로 보이나 확인하지 못했다).
    public mutating func next(count: Int, playIntro: Bool) -> Int? {
        guard count > 0 else { return nil }
        var index = ((cursor % count) + count) % count
        if playIntro && index == 0 && count > 1 { index = 1 }
        cursor = index + 1
        return index
    }
}

// MARK: - 시각 기반 선택

/// `mode = daytime` (0x140067adc–0x140067b61).
public enum PlaylistDaytime {

    /// 하루를 [0,1) 로 정규화한다. `1440.0f` @ 0x140492948.
    ///
    ///     0x140067b17  imul ecx, [rax+8], 0x3c   ; tm_hour * 60
    ///     0x140067b23  add  ecx, [rax+4]         ; + tm_min
    ///     0x140067b2d  divss xmm1, 1440.0
    ///
    /// **초는 안 본다** — 분 해상도다.
    public static func normalizedTimeOfDay(hour: Int, minute: Int) -> Float {
        Float(hour * 60 + minute) / 1440.0
    }

    /// `daytimeend` 가 지금보다 **큰 첫 항목**의 인덱스(0x140067b52 `comiss` / `ja`).
    ///
    /// 하나도 없으면 `nil` 이다 — 0x140067b61 이 `jmp 0x140067c70` 으로 빠져나간다.
    /// `daytimeEnd` 가 없는 항목(UI 는 마지막 항목의 키를 저장 시 지운다)은 매치되지 않는다.
    public static func index(items: [PlaylistItem], normalizedNow: Float) -> Int? {
        items.firstIndex { ($0.daytimeEnd ?? -1) > normalizedNow }
    }
}

/// `mode = dayofweek` (0x140067bc7–0x140067c2e).
public enum PlaylistDayOfWeek {

    /// `index = (weekday - firstDayOfWeek + 6) mod 7`.
    ///
    /// - Parameter weekday: `SYSTEMTIME.wDayOfWeek` 규약 — **일요일 = 0**.
    /// - Parameter firstDayOfWeek: `LOCALE_IFIRSTDAYOFWEEK` 규약 — **월요일 = 0 … 일요일 = 6**.
    ///   WE 는 6 으로 상한을 건다(0x14003dd1e–0x14003dd25).
    ///
    /// 기본 로케일(월요일 시작, `firstDayOfWeek = 0`)에서 월요일(`weekday = 1`) → 슬롯 0,
    /// 일요일(`weekday = 0`) → 슬롯 6 이다. 두 열거의 원점이 달라 `+6` 이 붙는다.
    public static func index(weekday: Int, firstDayOfWeek: Int) -> Int {
        let first = min(max(firstDayOfWeek, 0), 6)
        let day = min(max(weekday, 0), 6)
        return ((day - first + 6) % 7 + 7) % 7
    }

    /// UI 가 항목 7개를 넘기지 못하게 막는다.
    public static let slotCount = 7
}
