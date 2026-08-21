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

    // MARK: - general.supportsaudioprocessing (CProject::SupportsAudioProcessing 0x14010d100–0x14010d161)

    /// 설치본 실측 3건(`audiophile` / `corsair_o_tron` / `demon_core` 의 project.json)이 쓰는 형태.
    func testParsesSupportsAudioProcessingTrue() throws {
        let p = try parse(#"{"type":"scene","file":"scene.json","general":{"supportsaudioprocessing":true}}"#)
        XCTAssertTrue(p.supportsAudioProcessing)
    }

    /// 설치본 `techno/techno.json` 이 쓰는 형태(그쪽은 씬 파일이지만 값 모양은 같다).
    func testParsesSupportsAudioProcessingFalse() throws {
        let p = try parse(#"{"type":"scene","file":"scene.json","general":{"supportsaudioprocessing":false}}"#)
        XCTAssertFalse(p.supportsAudioProcessing)
    }

    /// 키 부재 = false. 0x14010d132 의 find 가 널 Value 를 내고 0x14010d141 의 태그 검사(5)에서
    /// 걸러진다 — 동봉 자산 170건 전부가 이 경로다.
    func testSupportsAudioProcessingDefaultsToFalseWhenKeyAbsent() throws {
        let p = try parse(#"{"type":"scene","file":"scene.json","general":{"properties":{}}}"#)
        XCTAssertFalse(p.supportsAudioProcessing)
    }

    /// `general` 블록 자체가 없어도 false — 0x14010d11b 가 objectValue(태그 7) 가 아니면 즉시 false.
    func testSupportsAudioProcessingDefaultsToFalseWithoutGeneralBlock() throws {
        let p = try parse(#"{"type":"video","file":"clip.mp4"}"#)
        XCTAssertFalse(p.supportsAudioProcessing)
    }

    /// `general` 이 object 가 아닌 경우(0x14010d11b 의 `cmp byte [rax+8], 7` 불일치)도 false.
    func testSupportsAudioProcessingIgnoresNonObjectGeneral() throws {
        let p = try parse(#"{"type":"video","file":"clip.mp4","general":"supportsaudioprocessing"}"#)
        XCTAssertFalse(p.supportsAudioProcessing)
    }

    /// 0x14010d141 은 jsoncpp booleanValue(태그 5)만 통과시킨다. `1`/`"true"` 는 각각 태그 1/4 라
    /// 원본에선 false 다 — Foundation 의 `1 as? Bool == true` 브리징에 끌려가면 안 된다.
    func testSupportsAudioProcessingRejectsNonBooleanTags() throws {
        for raw in ["1", "0", "\"true\"", "null", "[]", "{}"] {
            let p = try parse(#"{"type":"scene","file":"s.json","general":{"supportsaudioprocessing":\#(raw)}}"#)
            XCTAssertFalse(p.supportsAudioProcessing, "비-bool 태그(\(raw))는 원본과 같이 false 여야 한다")
        }
    }
}
