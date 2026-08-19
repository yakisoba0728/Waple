import Foundation

/// 씬 픽셀 스냅샷 회귀의 순수 코어: 매니페스트 스키마 + diff 메트릭 + 임계 판정 + 해시.
/// GPU/AppKit 무의존(Foundation only) — 유닛 테스트가 GPU 없이 바이트 배열만으로 검증한다.

// MARK: - 매니페스트

/// 프레임을 산출한 씬 1종의 기록.
public struct SnapshotEntry: Codable, Equatable {
    public var id: String
    public var width: Int
    public var height: Int
    public var hash: String        // 썸네일 RGBA8 의 FNV-1a(64) hex
    public var meanLuma: Double     // 0..1
    public var deterministic: Bool  // 같은 빌드 2회 캡처가 자기-일관(self-diff ≤ 임계)인가
    public var selfMaxDiff: Int      // 두 캡처 간 최대 채널차(0..255). 셀프체크 안 했으면 -1
    public var note: String?         // 비결정 사유 등

    public init(id: String, width: Int, height: Int, hash: String, meanLuma: Double,
                deterministic: Bool, selfMaxDiff: Int, note: String? = nil) {
        self.id = id; self.width = width; self.height = height; self.hash = hash
        self.meanLuma = meanLuma; self.deterministic = deterministic
        self.selfMaxDiff = selfMaxDiff; self.note = note
    }
}

/// 캡처 1회의 산출물 매니페스트. `entries` 는 프레임을 낸 씬,
/// `empties` 는 마운트는 됐으나 픽셀이 없는 씬(비디오-백드 → AVFoundation 위임 등, 범위 밖),
/// `failures` 는 마운트 자체가 스로우한 씬.
public struct SnapshotManifest: Codable, Equatable {
    public var gitSHA: String
    public var label: String
    public var thumbWidth: Int
    public var thumbHeight: Int
    public var captureTime: Float   // 주입한 고정 시각 t
    public var createdAt: String
    public var entries: [SnapshotEntry]
    public var empties: [String]
    public var failures: [String]
    /// F145: 캡처 당시 라이브로 존중되던 렌더 출력 변형 WAPLE_* 디버그 게이트 이름 목록(정렬됨,
    /// 없으면 빈 배열). 구 매니페스트(이 필드 도입 전)는 nil 로 디코드 — "기록 안 됨"과 "0개 활성"을
    /// 구분한다. runCompare 가 현재 활성 게이트와 대조해 베이스라인 오염 가능성을 경고하는 데 쓴다.
    public var activeDebugGates: [String]?

    public init(gitSHA: String, label: String, thumbWidth: Int, thumbHeight: Int,
                captureTime: Float, createdAt: String, entries: [SnapshotEntry],
                empties: [String], failures: [String], activeDebugGates: [String]? = nil) {
        self.gitSHA = gitSHA; self.label = label
        self.thumbWidth = thumbWidth; self.thumbHeight = thumbHeight
        self.captureTime = captureTime; self.createdAt = createdAt
        self.entries = entries; self.empties = empties; self.failures = failures
        self.activeDebugGates = activeDebugGates
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> SnapshotManifest {
        try JSONDecoder().decode(SnapshotManifest.self, from: data)
    }
}

// MARK: - diff 메트릭

/// 두 RGBA8 버퍼의 차이. 채널차는 0..255.
public struct DiffMetrics: Equatable {
    public let meanAbsDiff: Double   // 전 채널 |Δ| 평균
    public let maxAbsDiff: Int       // 단일 채널 최대 |Δ|
    public let fracExceeding: Double // perPixelThreshold 초과 픽셀 비율(0..1)

    public init(meanAbsDiff: Double, maxAbsDiff: Int, fracExceeding: Double) {
        self.meanAbsDiff = meanAbsDiff; self.maxAbsDiff = maxAbsDiff; self.fracExceeding = fracExceeding
    }
}

/// RGBA8 픽셀 배열 두 개의 diff. 길이가 다르면 짧은 쪽 기준. 픽셀당 4채널(RGBA) 가정.
/// fracExceeding: 한 픽셀의 4채널 중 최대차가 perPixelThreshold 를 넘으면 그 픽셀을 "변경"으로 계수.
public func diffRGBA(_ a: [UInt8], _ b: [UInt8], perPixelThreshold: Int = 16) -> DiffMetrics {
    let n = min(a.count, b.count) / 4 * 4
    guard n > 0 else { return DiffMetrics(meanAbsDiff: 0, maxAbsDiff: 0, fracExceeding: 0) }
    var sum = 0, maxD = 0, exceed = 0
    var i = 0
    while i < n {
        var pixelMax = 0
        for c in 0..<4 {
            let d = abs(Int(a[i + c]) - Int(b[i + c]))
            sum += d
            if d > pixelMax { pixelMax = d }
        }
        if pixelMax > maxD { maxD = pixelMax }
        if pixelMax > perPixelThreshold { exceed += 1 }
        i += 4
    }
    let pixels = n / 4
    return DiffMetrics(meanAbsDiff: Double(sum) / Double(n),
                       maxAbsDiff: maxD,
                       fracExceeding: Double(exceed) / Double(pixels))
}

// MARK: - 임계 판정

/// diff 가 이 이하이면 PASS. meanAbsDiff 와 fracExceeding 동시 만족.
/// Sendable: 저장 프로퍼티가 Double 둘뿐인 값 타입 — 아래 strict/lax/selfConsistent 상수를 어느
/// 스레드에서 읽어도 안전하다(엄격 동시성이 `static let` 의 타입에 Sendable 을 요구한다).
public struct DiffThreshold: Equatable, Sendable {
    public var meanAbsDiff: Double
    public var fracExceeding: Double
    public init(meanAbsDiff: Double, fracExceeding: Double) {
        self.meanAbsDiff = meanAbsDiff; self.fracExceeding = fracExceeding
    }
    /// 결정 씬 회귀 게이트: 사실상 픽셀 동일만 통과(경미한 인코딩 노이즈 허용).
    public static let strict = DiffThreshold(meanAbsDiff: 1.5, fracExceeding: 0.004)
    /// 비결정 버킷: 관대(자기-diff 수준의 변동은 통과, 큰 시각 변화만 잡음).
    public static let lax = DiffThreshold(meanAbsDiff: 14.0, fracExceeding: 0.20)
    /// 자기-일관 판정: 같은 빌드 2회가 이 이하이면 결정 씬.
    public static let selfConsistent = DiffThreshold(meanAbsDiff: 0.5, fracExceeding: 0.002)
}

public func passes(_ m: DiffMetrics, _ t: DiffThreshold) -> Bool {
    m.meanAbsDiff <= t.meanAbsDiff && m.fracExceeding <= t.fracExceeding
}

// MARK: - 캡처 시각 파싱

/// "6.0,12,,abc, 30" 같은 콤마구분 캡처 시각(초) 문자열을 파싱. nil/공백/전부 무효면 fallback.
/// 입력 순서를 보존(정렬 안 함) — 호출자가 필요하면 별도로 정렬. F2-puppet①: 애니메이션 시간의존
/// 누적 결함(퍼펫 등)을 다중 시각 캡처로 재현하기 위한 WAPLE_CAPTURE_TIME 오버라이드 파싱 코어.
public func parseCaptureTimes(_ raw: String?, fallback: [Float]) -> [Float] {
    guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return fallback }
    let vals = raw.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
    return vals.isEmpty ? fallback : vals
}

// MARK: - 해시 / luma

/// FNV-1a 64비트 hex — 썸네일 동일성 빠른 판정/로깅용(게이트는 픽셀 diff 가 담당).
public func fnv1a(_ bytes: [UInt8]) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in bytes { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01b3 }
    return String(h, radix: 16)
}

/// RGBA8 평균 luma(0..1).
public func meanLuma(rgba: [UInt8]) -> Double {
    let n = rgba.count / 4 * 4
    guard n > 0 else { return 0 }
    var sum = 0.0
    var i = 0
    while i < n {
        sum += 0.299 * Double(rgba[i]) + 0.587 * Double(rgba[i + 1]) + 0.114 * Double(rgba[i + 2])
        i += 4
    }
    return sum / Double(n / 4) / 255.0
}

// MARK: - 골든 판정

/// 골든 비교 한 씬의 판정 결과.
///
/// **이 로직이 여기 있는 이유는 모듈 경계 때문이다.** 원래는
/// `Sources/WapleCompat/SnapshotCompare.swift` 의 `runCompare` **안 지역 상수**였는데,
/// `WapleCompat` 은 `.executableTarget` 이라 어떤 테스트 타깃도 의존할 수 없다
/// (`grep -rn "import WapleCompat" Tests/` = 0건). 그래서 `SnapshotTests` 는 수식을
/// 리터럴로 **베껴 자기 산수를 단언**했고 — 프로덕션 로직을 통째로 지워도 통과했다.
/// 라이브러리 타깃인 여기로 올려서 테스트가 프로덕션 심볼을 직접 부른다.
public struct GoldenVerdict: Equatable {
    /// 픽셀이 완전 동일(maxAbsDiff == 0) — diff 를 볼 것도 없이 통과.
    public let identical: Bool
    /// 기준선 밝기로 정규화한 상대 편차. 절대 임계(strict 1.5/255)가 어두운 씬에서
    /// 무력한 것을 보완한다(spec/golden/gate-analysis.json).
    public let relDiff: Double
    /// 아주 어두운 씬의 "구조가 사라졌는가". 절대·상대가 둘 다 둔한 구간을 맡는다.
    public let structureLoss: Bool
    public let pass: Bool
}

/// 상대 편차 허용치. 이보다 크면 FAIL.
public let goldenRelativeTolerance: Double = 0.05

/// 상대비 분모의 밝기 하한(= luma 5/255). 이보다 어두우면 상대비가 발산해 오탐이 되므로,
/// 그 구간은 `structureLoss` 가 맡는다.
public let goldenDarkLumaFloor: Double = 0.02

/// 한 씬의 골든 통과 여부. `WapleCompat` 의 비교기와 `WapleSnapshotTests` 가 **같은 코드**를 쓴다.
///
/// - Parameters:
///   - m: 기준선 대 현재 캡처의 픽셀 diff.
///   - baselineMeanLuma: 기준선 썸네일의 평균 휘도(0…1).
///   - deterministic: 같은 빌드 2회 캡처가 자기-일관인 씬인가(비결정 씬은 관대 임계).
public func goldenVerdict(_ m: DiffMetrics,
                          baselineMeanLuma: Double,
                          deterministic: Bool) -> GoldenVerdict {
    // ① 해시 동일이면 픽셀이 완전히 같다.
    let identical = m.maxAbsDiff == 0
    // ② 절대 임계는 어두운 씬에서 무력하다 — 기준선 meanLuma 로 정규화한 상대 지표를 함께 본다.
    let relDiff = m.meanAbsDiff / (max(baselineMeanLuma, goldenDarkLumaFloor) * 255.0)
    // ③ 아주 어두운 씬은 절대·상대 모두 둔하다 — 비검정 픽셀 비율의 급락으로 본다.
    let structureLoss = baselineMeanLuma < goldenDarkLumaFloor
        && m.meanAbsDiff > baselineMeanLuma * 255.0 * 0.5
    let threshold: DiffThreshold = deterministic ? .strict : .lax
    let pass = identical
        || (passes(m, threshold) && relDiff <= goldenRelativeTolerance && !structureLoss)
    return GoldenVerdict(identical: identical, relDiff: relDiff,
                         structureLoss: structureLoss, pass: pass)
}
