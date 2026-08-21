import XCTest
@testable import WapleCore

/// `WallpaperPathSecurity` 적대적 검증.
///
/// 이 타입은 Waple 의 **경로 봉쇄 경계**다 — 웹 월페이퍼 브리지
/// (`wallpaperRequestRandomFileForProperty` · fetchall 디렉터리 열거 · `waple-asset://` 스킴
/// 핸들러)와 씬/패키지 로더가 전부 여기를 지난다. 그런데 2026-08-21 까지 **전용 테스트가
/// 하나도 없었다**(`grep -rl WallpaperPathSecurity Tests/` = 간접 사용 3건뿐).
///
/// 참고 — WE 에는 대응물이 없다. `webwallpaper64.exe` 의 디렉터리 감시 진입점
/// 0x1400098a0 은 `is_directory`(0x140006980) 로 디렉터리 여부만 보고 곧장
/// `FindFirstChangeNotificationW(path, bWatchSubtree=1, 0x13)`(0x140009988) 을 건다 —
/// **프로젝트 폴더 봉쇄 검사가 없다**. 즉 아래 규칙들은 WE 호환이 아니라 Waple 고유의
/// 강화이므로, 패리티가 아니라 **불변식이 실제로 성립하는지**를 고정한다.
final class WallpaperPathSecurityTests: XCTestCase {

    // MARK: - 어휘적 봉쇄

    func testAcceptsPlainRelativePaths() {
        XCTAssertEqual(WallpaperPathSecurity.normalizedRelativePath("assets/a.png"), "assets/a.png")
        XCTAssertEqual(WallpaperPathSecurity.normalizedRelativePath("./a.png"), "a.png")
        XCTAssertEqual(WallpaperPathSecurity.normalizedRelativePath("a//b.png"), "a/b.png")
        XCTAssertEqual(WallpaperPathSecurity.normalizedRelativePath("a/./b.png"), "a/b.png")
        XCTAssertEqual(WallpaperPathSecurity.normalizedRelativePath("  a.png  "), "a.png")
        XCTAssertEqual(WallpaperPathSecurity.normalizedRelativePath("\t\na.png\r\n"), "a.png")
    }

    /// 상위 탈출 — 직접·혼합 구분자·중간 삽입 전부.
    func testRejectsDotDotTraversal() {
        for raw in ["..", "../", "../secret", "a/../../secret", "a/..",
                    "..\\secret", "a\\..\\..\\secret", "AAA/../BBB", "a/../b"] {
            XCTAssertNil(WallpaperPathSecurity.normalizedRelativePath(raw), "허용되면 안 된다: \(raw)")
        }
    }

    /// 퍼센트 인코딩 — 1~4중 인코딩까지는 디코드해서 거부한다.
    func testRejectsPercentEncodedTraversal() {
        for raw in ["%2e%2e/secret", "%2E%2E%2Fsecret", "..%2fsecret", "..%5csecret",
                    "%252e%252e/secret", "%25252e%25252e/secret", "%2525252e%2525252e/secret"] {
            XCTAssertNil(WallpaperPathSecurity.normalizedRelativePath(raw), "허용되면 안 된다: \(raw)")
        }
    }

    /// 디코드 상한(4회)을 넘긴 입력은 **거부되지 않지만 탈출도 아니다** — 남은 `%2e%2e` 는
    /// 리터럴 이름 하나로 취급된다. 결과에 `..` 성분이 들어가지 않는다는 것이 불변식이다.
    func testDeeplyEncodedTraversalStaysLiteral() {
        let out = WallpaperPathSecurity.normalizedRelativePath("%252525252e%252525252e/secret")
        XCTAssertNotNil(out)
        let parts = (out ?? "").split(separator: "/").map(String.init)
        XCTAssertFalse(parts.contains(".."), "정규화 결과에 `..` 성분이 남으면 안 된다: \(out ?? "nil")")
    }

    func testRejectsAbsoluteAndUNCAndScheme() {
        for raw in ["/etc/passwd", "\\\\server\\share\\x", "//server/share/x",
                    "file:///etc/passwd", "FILE:///etc/passwd", "http://evil/x",
                    "waple-asset://wallpaper/x", "javascript:alert(1)",
                    "C:\\Windows\\win.ini", "c:/Windows/win.ini"] {
            XCTAssertNil(WallpaperPathSecurity.normalizedRelativePath(raw), "허용되면 안 된다: \(raw)")
        }
    }

    func testRejectsNulAndEmpty() {
        for raw in ["a\u{0000}b", "a%00b", "%00", "", "   ", "///", "\\\\\\", "\u{0000}"] {
            XCTAssertNil(WallpaperPathSecurity.normalizedRelativePath(raw), "허용되면 안 된다: \(String(reflecting: raw))")
        }
        XCTAssertNil(WallpaperPathSecurity.normalizedRelativePath(nil))
    }

    /// 스킴처럼 **보이지 않는** 콜론은 통과해야 한다(정상 파일명 무회귀).
    func testColonThatIsNotASchemeIsAllowed() {
        XCTAssertEqual(WallpaperPathSecurity.normalizedRelativePath("a/b:c"), "a/b:c")
        XCTAssertEqual(WallpaperPathSecurity.normalizedRelativePath(".:/x"), ".:/x")
        XCTAssertEqual(WallpaperPathSecurity.normalizedRelativePath("1:/x"), "1:/x")
    }

    func testNormalizedPathComponentRejectsAnySeparator() {
        XCTAssertEqual(WallpaperPathSecurity.normalizedPathComponent("a.png"), "a.png")
        XCTAssertEqual(WallpaperPathSecurity.normalizedPathComponent("./a.png"), "a.png")
        for raw in ["a/b.png", "a\\b.png", "a%2fb", "..", "%2e%2e", "/a"] {
            XCTAssertNil(WallpaperPathSecurity.normalizedPathComponent(raw), "허용되면 안 된다: \(raw)")
        }
    }

    // MARK: - contains

    func testContainsRejectsSiblingPrefix() throws {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("proj")
        let sibling = base.appendingPathComponent("proj-evil")
        XCTAssertFalse(WallpaperPathSecurity.contains(sibling.appendingPathComponent("x"), in: root),
                       "`proj-evil` 가 `proj` 의 접두 일치로 통과하면 안 된다")
        XCTAssertTrue(WallpaperPathSecurity.contains(root, in: root))
        XCTAssertTrue(WallpaperPathSecurity.contains(root.appendingPathComponent("a/b"), in: root))
        // 루트 표기에 트레일링 슬래시가 붙어도 같은 판정.
        XCTAssertTrue(WallpaperPathSecurity.contains(root.appendingPathComponent("x"),
                                                     in: URL(fileURLWithPath: root.path + "/")))
    }

    // MARK: - 심링크 탈출 (보안 경계 본체)

    /// 루트 안의 심링크가 밖을 가리킬 때, **그 아래 이름이 존재하든 말든** 봉쇄돼야 한다.
    ///
    /// `link/missing.txt` 가 이 테스트의 핵심이다 — 2026-08-21 이전 구현은 후보 전체가
    /// 존재할 때만 realpath 를 떠서, 아직 없는 이름은 검사가 통째로 생략되고
    /// `root/link/missing.txt`(= `/outside/missing.txt`)를 그대로 돌려줬다.
    func testSymlinkEscapeIsBlockedEvenWhenLeafIsMissing() throws {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("proj")
        let outside = base.appendingPathComponent("outside")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try Data("ok".utf8).write(to: root.appendingPathComponent("ok.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("filelink"),
                                  withDestinationURL: outside.appendingPathComponent("secret.txt"))
        // 중첩: root/sub/deeplink -> outside
        let sub = root.appendingPathComponent("sub")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: sub.appendingPathComponent("deeplink"), withDestinationURL: outside)

        // 정상 경로는 그대로 통과한다(무회귀).
        XCTAssertNotNil(WallpaperPathSecurity.containedFileURL("ok.txt", root: root))
        // 아직 없는 정상 이름도 통과한다 — 조상이 전부 루트 안이므로.
        XCTAssertNotNil(WallpaperPathSecurity.containedFileURL("not-there-yet.png", root: root))
        XCTAssertNotNil(WallpaperPathSecurity.containedFileURL("sub/not-there-yet.png", root: root))

        for raw in ["link", "link/secret.txt", "link/missing.txt",
                    "filelink", "sub/deeplink/secret.txt", "sub/deeplink/missing.txt",
                    "../outside/secret.txt", "%2e%2e/outside/secret.txt"] {
            XCTAssertNil(WallpaperPathSecurity.containedFileURL(raw, root: root),
                         "심링크/탈출이 통과했다: \(raw)")
        }
    }

    /// 루트 **자체**가 심링크여도 그 아래는 정상 동작해야 한다(양성 대조 — 위 수정이
    /// realRoot 를 쓰지 않고 rootURL 만 대조했다면 여기서 전부 nil 이 된다).
    func testSymlinkedRootStillResolvesItsOwnFiles() throws {
        let base = try makeTempDir()
        let real = base.appendingPathComponent("real")
        let fm = FileManager.default
        try fm.createDirectory(at: real.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("ok".utf8).write(to: real.appendingPathComponent("sub/a.txt"))
        let linkedRoot = base.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linkedRoot, withDestinationURL: real)

        XCTAssertNotNil(WallpaperPathSecurity.containedFileURL("sub/a.txt", root: linkedRoot))
        XCTAssertNotNil(WallpaperPathSecurity.containedFileURL("sub/missing.txt", root: linkedRoot))
        XCTAssertNil(WallpaperPathSecurity.containedFileURL("../real/sub/a.txt", root: linkedRoot))
    }

    /// 어떤 입력이 와도 반환값은 **루트 안**이어야 한다 — 심링크 해석 후 기준으로.
    /// 개별 벡터의 nil 여부가 아니라 이 불변식이 경계의 정의다.
    func testReturnedURLNeverResolvesOutsideRoot() throws {
        let base = try makeTempDir()
        let root = base.appendingPathComponent("proj")
        let outside = base.appendingPathComponent("outside")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        let realRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let vectors = [
            "a.png", "sub/a.png", "./a.png", "a//b.png", "....//secret", "...",
            "%252525252e%252525252e/secret", "%c0%ae%c0%ae/secret", "%2525252e%2525252e/secret",
            "link/missing.txt", "link/secret.txt", "a%2fb", "a%252fb",
            "𝓪.png", "a/b:c", ".:/etc/passwd", "~/.ssh/id_rsa", "a\u{2028}b",
        ]
        for raw in vectors {
            guard let url = WallpaperPathSecurity.containedFileURL(raw, root: root) else { continue }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            XCTAssertTrue(WallpaperPathSecurity.contains(resolved, in: realRoot),
                          "루트 밖으로 해석된다: \(raw) -> \(resolved.path)")
        }
    }

    // MARK: - helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("waple_pathsec_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
}
