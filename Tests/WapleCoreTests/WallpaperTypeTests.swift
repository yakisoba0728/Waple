import XCTest
@testable import WapleCore

final class WallpaperTypeTests: XCTestCase {
    func testParsesKnownTypesCaseInsensitively() {
        XCTAssertEqual(WallpaperType.from("video"), .video)
        XCTAssertEqual(WallpaperType.from("Scene"), .scene)
        XCTAssertEqual(WallpaperType.from("WEB"), .web)
        XCTAssertEqual(WallpaperType.from("application"), .application)
        XCTAssertEqual(WallpaperType.from("preset"), .preset)
    }

    func testNilOrEmptyTypeBecomesPreset() {
        XCTAssertEqual(WallpaperType.from(nil), .preset)
        XCTAssertEqual(WallpaperType.from(""), .preset)
    }

    func testUnknownTypePreservesRawString() {
        XCTAssertEqual(WallpaperType.from("flux"), .unknown("flux"))
    }

    func testStorageStringRoundTrips() {
        for t: WallpaperType in [.video, .scene, .web, .application, .preset, .unknown("xyz")] {
            XCTAssertEqual(WallpaperType.from(t.storageString), t)
        }
    }

    func testOnlyVideoIsSupportedInMVP() {
        XCTAssertTrue(WallpaperType.video.isSupportedInMVP)
        XCTAssertFalse(WallpaperType.scene.isSupportedInMVP)
        XCTAssertFalse(WallpaperType.web.isSupportedInMVP)
    }
}
