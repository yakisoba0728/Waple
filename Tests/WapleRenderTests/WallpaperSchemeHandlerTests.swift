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
}
