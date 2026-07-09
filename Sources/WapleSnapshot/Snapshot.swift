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

    public init(gitSHA: String, label: String, thumbWidth: Int, thumbHeight: Int,
                captureTime: Float, createdAt: String, entries: [SnapshotEntry],
                empties: [String], failures: [String]) {
        self.gitSHA = gitSHA; self.label = label
        self.thumbWidth = thumbWidth; self.thumbHeight = thumbHeight
        self.captureTime = captureTime; self.createdAt = createdAt
        self.entries = entries; self.empties = empties; self.failures = failures
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
public struct DiffThreshold: Equatable {
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
