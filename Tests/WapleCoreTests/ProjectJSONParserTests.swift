import XCTest
@testable import WapleCore

final class ProjectJSONParserTests: XCTestCase {
    private func parse(_ json: String, folder: String = "/tmp/123") throws -> WallpaperProject {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        return try ProjectJSONParser.parse(data: Data(json.utf8), folderURL: url)
    }

    func testParsesVideoProject() throws {
        let p = try parse(#"{"type":"video","file":"wallpaper.mp4","preview":"preview.jpg","title":"Test"}"#)
        XCTAssertEqual(p.type, .video)
        XCTAssertEqual(p.fileName, "wallpaper.mp4")
        XCTAssertEqual(p.previewName, "preview.jpg")
        XCTAssertEqual(p.title, "Test")
        XCTAssertEqual(p.id, "123")
    }

    func testParsesCapitalSceneType() throws {
        let p = try parse(#"{"type":"Scene","file":"scene.json","preview":"preview.gif","title":"S"}"#)
        XCTAssertEqual(p.type, .scene)
    }

    func testParsesPresetWithoutTypeButWithDependency() throws {
        let p = try parse(#"{"preview":"preview.jpg","title":"P","dependency":"2593802559"}"#)
        XCTAssertEqual(p.type, .preset)
        XCTAssertEqual(p.dependency, "2593802559")
        XCTAssertNil(p.fileName)
    }

    func testMissingTitleFallsBackToFolderName() throws {
        let p = try parse(#"{"type":"video"}"#, folder: "/tmp/999")
        XCTAssertEqual(p.title, "999")
    }

    func testParsesTagsAndContentRatingAndWorkshopId() throws {
        let p = try parse(#"{"type":"video","tags":["Anime","Game"],"contentrating":"Everyone","workshopid":"2913506072"}"#)
        XCTAssertEqual(p.tags, ["Anime", "Game"])
        XCTAssertEqual(p.contentRating, "Everyone")
        XCTAssertEqual(p.workshopId, "2913506072")
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try parse("not json {")) { error in
            XCTAssertEqual(error as? ProjectParseError, .invalidJSON)
        }
    }

    func testMissingFileThrowsFileNotFound() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)", isDirectory: true)
        XCTAssertThrowsError(try ProjectJSONParser.parse(folderURL: url)) { error in
            XCTAssertEqual(error as? ProjectParseError, .fileNotFound)
        }
    }
}
