import XCTest

/// 영어 UI 문자열 커버리지 오라클.
///
/// Waple 의 현지화 규약은 **키 = 한국어 원문**이다. SwiftUI 의 `Text("한국어")` 리터럴은
/// `LocalizedStringKey` 로 해석되므로 호출부를 고치지 않아도 `en.lproj/Localizable.strings`
/// 하나로 영어가 나온다(AppKit 경로만 `NSLocalizedString` 으로 감쌌다).
///
/// 그 규약은 **조용히 깨진다** — 새 한국어 문자열을 UI 에 추가하고 번역을 빼먹으면
/// 영어 시스템에서 그 자리만 한국어로 남고, 아무 것도 실패하지 않는다. 이 테스트가
/// 소스와 strings 파일의 차집합을 양방향으로 잡는다.
final class LocalizationCoverageTests: XCTestCase {

    /// 리포 루트 — 테스트 바이너리는 .build 안이라 소스 파일 위치에서 거슬러 올라간다.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/WapleAppTests/...
            .deletingLastPathComponent()          // WapleAppTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // repo root
    }

    /// UI 로 표시되는 리터럴을 뽑는 패턴. SwiftUI 표시 API + 명시 NSLocalizedString.
    private static let patterns = [
        #"NSLocalizedString\(\s*"((?:[^"\\]|\\.)*)""#,
        #"(?:Text|Button|Label|Toggle|Picker|Section|TextField|SecureField|Link|Menu|Stepper"#
            + #"|navigationTitle|help|alert|confirmationDialog|accessibilityLabel|accessibilityHint)"#
            + #"\(\s*"((?:[^"\\]|\\.)*)""#,
        #"(?:label|title|message|placeholder|tooltip)\s*:\s*"((?:[^"\\]|\\.)*)""#,
    ]

    private static func containsHangul(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x3130...0x318F).contains($0.value) }
    }

    /// Sources/Waple 전체에서 한글 UI 리터럴을 추출한다(파일 단위 전문 매칭 — 여러 줄 호출도 잡는다).
    private func sourceKeys() throws -> Set<String> {
        let root = Self.repoRoot.appendingPathComponent("Sources/Waple")
        var keys: Set<String> = []
        let regexes = try Self.patterns.map { try NSRegularExpression(pattern: $0, options: [.dotMatchesLineSeparators]) }
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return keys
        }
        for case let url as URL in e where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let full = NSRange(text.startIndex..<text.endIndex, in: text)
            for rx in regexes {
                for m in rx.matches(in: text, range: full) {
                    guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { continue }
                    let s = String(text[r])
                    if Self.containsHangul(s) { keys.insert(s) }
                }
            }
        }
        return keys
    }

    /// `"키" = "값";` 형태의 .strings 파서(주석·빈 줄 무시). 이스케이프는 \" 만 쓴다.
    private func stringsKeys(_ relative: String) throws -> Set<String> {
        let url = Self.repoRoot.appendingPathComponent(relative)
        let text = try String(contentsOf: url, encoding: .utf8)
        let rx = try NSRegularExpression(pattern: #"^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;"#,
                                         options: [.anchorsMatchLines])
        var keys: Set<String> = []
        for m in rx.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            if let r = Range(m.range(at: 1), in: text) { keys.insert(String(text[r])) }
        }
        return keys
    }

    /// 소스에 있는 한글 UI 문자열은 전부 영어 번역이 있어야 한다.
    func testEveryKoreanUIStringHasEnglishTranslation() throws {
        let source = try sourceKeys()
        XCTAssertGreaterThan(source.count, 80,
                             "추출이 사실상 실패했다(패턴이 깨졌을 가능성) — 소스 키 \(source.count)개")
        let english = try stringsKeys("Resources/en.lproj/Localizable.strings")
        let missing = source.subtracting(english).sorted()
        XCTAssertTrue(missing.isEmpty,
                      "영어 번역 누락 \(missing.count)건 — Resources/en.lproj/Localizable.strings 에 추가할 것:\n"
                        + missing.map { "  \"\($0)\" = \"\";" }.joined(separator: "\n"))
    }

    /// 반대로 소스에서 사라진 번역은 남겨두지 않는다 — 지워진 UI 의 잔재가 파일을 오염시킨다.
    func testNoOrphanTranslations() throws {
        let source = try sourceKeys()
        let english = try stringsKeys("Resources/en.lproj/Localizable.strings")
        let orphans = english.subtracting(source).sorted()
        XCTAssertTrue(orphans.isEmpty,
                      "소스에 없는 번역 \(orphans.count)건(오타이거나 UI 가 지워진 것):\n"
                        + orphans.map { "  \($0)" }.joined(separator: "\n"))
    }

    /// ko.lproj 는 **비어 있어야** 한다 — 키가 곧 한국어라 항목을 넣으면 이중 관리가 된다.
    func testKoreanCatalogStaysEmpty() throws {
        let ko = try stringsKeys("Resources/ko.lproj/Localizable.strings")
        XCTAssertTrue(ko.isEmpty,
                      "ko.lproj 에 항목이 생겼다(\(ko.count)건) — 키가 곧 한국어 원문이므로 불필요하다")
    }
}
