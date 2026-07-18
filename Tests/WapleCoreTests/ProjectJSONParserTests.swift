import XCTest
@testable import WapleCore

final class ProjectJSONParserTests: XCTestCase {
    private func parse(_ json: String, folder: String = "/tmp/123") throws -> WallpaperProject {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        return try ProjectJSONParser.parse(data: Data(json.utf8), folderURL: url)
    }

    // 작업 5: 원시 동영상 임포트 최소 project.json 은 파서로 왕복 가능해야 한다.
    func testProjectJSONBuilderVideoRoundTrips() throws {
        let json = ProjectJSONBuilder.videoProject(file: "clip.mp4", preview: "preview.jpg", title: "My Clip")
        let p = try parse(json, folder: "/tmp/clip")
        XCTAssertEqual(p.type, .video)
        XCTAssertEqual(p.fileName, "clip.mp4")
        XCTAssertEqual(p.previewName, "preview.jpg")
        XCTAssertEqual(p.title, "My Clip")
    }

    func testParsesVideoProject() throws {
        let p = try parse(#"{"type":"video","file":"wallpaper.mp4","preview":"preview.jpg","title":"Test"}"#)
        XCTAssertEqual(p.type, .video)
        XCTAssertEqual(p.fileName, "wallpaper.mp4")
        XCTAssertEqual(p.previewName, "preview.jpg")
        XCTAssertEqual(p.title, "Test")
        XCTAssertEqual(p.id, "123")
    }

    func testRejectsEscapingFileAndPreviewPaths() throws {
        let p = try parse(#"{"type":"video","file":"../outside.mp4","preview":"/tmp/private.jpg","title":"Test"}"#)
        XCTAssertNil(p.fileName)
        XCTAssertNil(p.previewName)
    }

    func testNormalizesRelativeAssetPaths() throws {
        let p = try parse(#"{"type":"video","file":"./movies/wallpaper.mp4","preview":"images/./preview.jpg","title":"Test"}"#)
        XCTAssertEqual(p.fileName, "movies/wallpaper.mp4")
        XCTAssertEqual(p.previewName, "images/preview.jpg")
    }

    func testRejectsPercentEncodedTraversalFileAndPreviewPaths() throws {
        let p = try parse(#"{"type":"web","file":"%2e%2e/secret.html","preview":"assets/%2e%2e/preview.jpg"}"#)
        XCTAssertNil(p.fileName)
        XCTAssertNil(p.previewName)
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
        XCTAssertEqual(p.presetFolderURL, URL(fileURLWithPath: "/tmp/123", isDirectory: true))
    }

    func testParsesPresetOverrideValues() throws {
        let p = try parse(#"{"dependency":"2593802559","preset":{"enabled":true,"amount":2,"name":"Yeezus","unset":null}}"#)
        XCTAssertEqual(p.type, .preset)
        XCTAssertEqual(p.presetOverrides["enabled"], .bool(true))
        XCTAssertEqual(p.presetOverrides["amount"], .number(2))
        XCTAssertEqual(p.presetOverrides["name"], .string("Yeezus"))
        XCTAssertNil(p.presetOverrides["unset"], "null preset values do not override dependency defaults")
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

    func testParsesNumericWorkshopIdAsString() throws {
        let p = try parse(#"{"type":"video","workshopid":1108426854}"#)

        XCTAssertEqual(p.workshopId, "1108426854")
    }

    // F194: 관리 위치 이동·zip 재래핑에도 안정적인 identity — workshopid 가 있으면 폴더 basename
    // 대신 그것을 id 로 채택한다(basename 은 `Wallpaper/` 같은 WE export 관례로 비유일).
    func testIdPrefersWorkshopIdOverFolderBasename() throws {
        let p = try parse(#"{"type":"video","workshopid":"2913506072"}"#, folder: "/tmp/SomeWrapperName")
        XCTAssertEqual(p.id, "2913506072", "폴더 basename 대신 workshopid 를 identity 로 채택해야 한다")
    }

    func testIdFallsBackToFolderBasenameWithoutWorkshopId() throws {
        let p = try parse(#"{"type":"video"}"#, folder: "/tmp/SomeWrapperName")
        XCTAssertEqual(p.id, "SomeWrapperName", "workshopid 없으면 종전대로 폴더명에 폴백")
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
