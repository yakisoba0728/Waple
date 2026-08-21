// **리눅스 Foundation 결손 대역** — `URL` 의 보안 스코프 북마크 API.
// `scripts/dev/linux-render-typecheck.sh --lib` 의 `WapleLibrary` 컴파일에만 **함께 넣는다**
// (모듈이 아니라 파일이다 — `URL` 확장이라 대상 모듈 안에 있어야 보인다).
//
// 왜 심이 아니라 "결손" 인가
// -------------------------
// 이것은 애플 전용 프레임워크가 아니라 **Foundation 이 애플에서는 주는데 리눅스에서는 안 주는**
// 표면이다. `webkit.swift` 가 `HTTPURLResponse`·`autoreleasepool` 을 대신 내는 것과 같은 부류다
// (`docs/dev/linux-typecheck.md` §리눅스 Foundation 결손). macOS 에서는 무조건 보이므로 여기
// 있다고 해서 거짓 통과를 만들지 않는다.
//
// 실측(2026-08-21, swift 6.0.3, `import Foundation` 만 있는 파일):
//   `u.bookmarkData(options:includingResourceValuesForKeys:relativeTo:)`
//       → error: value of type 'URL' has no member 'bookmarkData'
//   `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)`
//       → error: no exact matches in call to initializer
//         (note 가 `fileURLWithPath:` 와 `filePath:` 두 후보만 댄다 = 그 이니셜라이저가 없다)
//
// 유일한 호출부는 `Sources/WapleLibrary/LibraryStore.swift` 세 곳이다:
//   :92  `try folderURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)`
//   :325 `try URL(resolvingBookmarkData: entry.bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)`
//   :339 `try? resolved.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)`
import Foundation

extension URL {
    /// 실제(macOS 14 SDK, `Foundation/URL.swift`):
    /// `public struct BookmarkCreationOptions: OptionSet, Sendable {
    ///      public init(rawValue: UInt)
    ///      public static var minimalBookmark: URL.BookmarkCreationOptions { get }
    ///      public static var suitableForBookmarkFile: URL.BookmarkCreationOptions { get }
    ///      public static var withSecurityScope: URL.BookmarkCreationOptions { get }
    ///      public static var securityScopeAllowOnlyReadAccess: URL.BookmarkCreationOptions { get } }`
    /// 확신 없음: `rawValue` 의 실제 폭(`UInt`)만 맞추었고 각 옵션의 **비트 값은 모른다** —
    /// 호출부가 `[]` 만 넘기므로 값이 흘러가는 자리가 없다. 값을 읽는 코드가 생기면 그때부터
    /// 조용히 틀린다.
    struct BookmarkCreationOptions: OptionSet, Sendable {
        let rawValue: UInt
        init(rawValue: UInt) { self.rawValue = rawValue }
        static let minimalBookmark = BookmarkCreationOptions(rawValue: 1 << 9)
        static let suitableForBookmarkFile = BookmarkCreationOptions(rawValue: 1 << 10)
        static let withSecurityScope = BookmarkCreationOptions(rawValue: 1 << 11)
        static let securityScopeAllowOnlyReadAccess = BookmarkCreationOptions(rawValue: 1 << 12)
    }

    /// 실제: `public struct BookmarkResolutionOptions: OptionSet, Sendable {
    ///          public init(rawValue: UInt)
    ///          public static var withoutUI: URL.BookmarkResolutionOptions { get }
    ///          public static var withoutMounting: URL.BookmarkResolutionOptions { get }
    ///          public static var withSecurityScope: URL.BookmarkResolutionOptions { get } }`
    /// 확신 없음: 위와 같은 이유로 비트 값 미확인.
    struct BookmarkResolutionOptions: OptionSet, Sendable {
        let rawValue: UInt
        init(rawValue: UInt) { self.rawValue = rawValue }
        static let withoutUI = BookmarkResolutionOptions(rawValue: 1 << 8)
        static let withoutMounting = BookmarkResolutionOptions(rawValue: 1 << 9)
        static let withSecurityScope = BookmarkResolutionOptions(rawValue: 1 << 10)
    }

    /// 실제: `public func bookmarkData(options: URL.BookmarkCreationOptions = [],
    ///          includingResourceValuesForKeys keys: Set<URLResourceKey>? = nil,
    ///          relativeTo url: URL? = nil) throws -> Data`
    /// 본문은 더미다. 이 도구는 타입만 본다 — 실제 북마크 왕복은 macOS 실행만이 답한다.
    func bookmarkData(options: BookmarkCreationOptions = [],
                      includingResourceValuesForKeys keys: Set<URLResourceKey>? = nil,
                      relativeTo url: URL? = nil) throws -> Data {
        Data()
    }

    /// 실제: `public init(resolvingBookmarkData data: Data,
    ///          options: URL.BookmarkResolutionOptions = [], relativeTo url: URL? = nil,
    ///          bookmarkDataIsStale: inout Bool) throws`
    init(resolvingBookmarkData data: Data,
         options: BookmarkResolutionOptions = [],
         relativeTo url: URL? = nil,
         bookmarkDataIsStale: inout Bool) throws {
        bookmarkDataIsStale = false
        self.init(fileURLWithPath: "/")
    }
}
