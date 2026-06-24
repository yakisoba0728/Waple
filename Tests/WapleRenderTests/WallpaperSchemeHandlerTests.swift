import XCTest
@testable import WapleRender

final class WallpaperSchemeHandlerTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/wp", isDirectory: true)

    func testResolvesNormalPath() {
        let u = WallpaperSchemeHandler.fileURL(forRequestPath: "/index.html", root: root)
        XCTAssertEqual(u?.path, "/tmp/wp/index.html")
    }

    func testResolvesNestedPath() {
        let u = WallpaperSchemeHandler.fileURL(forRequestPath: "/js/a.js", root: root)
        XCTAssertEqual(u?.path, "/tmp/wp/js/a.js")
    }

    func testRejectsPathTraversal() {
        XCTAssertNil(WallpaperSchemeHandler.fileURL(forRequestPath: "/../etc/passwd", root: root))
        XCTAssertNil(WallpaperSchemeHandler.fileURL(forRequestPath: "/../../secret", root: root))
    }

    /// URL.path 는 이미 퍼센트 디코딩되어 들어오므로 %2e%2e 도 ../ 로 풀려 거부돼야 한다.
    func testRejectsPercentEncodedTraversal() {
        let p1 = URL(string: "waple-asset://wallpaper/%2e%2e/secret")!.path
        XCTAssertNil(WallpaperSchemeHandler.fileURL(forRequestPath: p1, root: root))
        let p2 = URL(string: "waple-asset://wallpaper/%2e%2e%2fsecret")!.path
        XCTAssertNil(WallpaperSchemeHandler.fileURL(forRequestPath: p2, root: root))
    }

    /// 빈/루트 경로는 루트 자신으로 해석돼야 한다.
    func testRootItselfResolves() {
        XCTAssertEqual(WallpaperSchemeHandler.fileURL(forRequestPath: "/", root: root)?.path, "/tmp/wp")
    }

    /// 루트와 이름 접두사를 공유하는 형제 디렉터리는 거부돼야 한다(가드의 "+ /" 가 막는다).
    func testRejectsSiblingPrefix() {
        XCTAssertNil(WallpaperSchemeHandler.fileURL(forRequestPath: "/../wp-evil/x", root: root))
    }

    /// 패키지 안 심볼릭 링크가 루트 밖을 가리키면 거부돼야 한다(실디스크 검증).
    func testRejectsSymlinkEscape() throws {
        let fm = FileManager.default
        let realRoot = fm.temporaryDirectory.appendingPathComponent("wp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: realRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: realRoot) }
        let outside = fm.temporaryDirectory.appendingPathComponent("secret-\(UUID().uuidString).txt")
        try Data("topsecret".utf8).write(to: outside)
        defer { try? fm.removeItem(at: outside) }
        let link = realRoot.appendingPathComponent("leak")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(WallpaperSchemeHandler.fileURL(forRequestPath: "/leak", root: realRoot))
    }
}
