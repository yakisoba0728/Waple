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

    /// **공백뿐인 `workshopid` 는 부재로 본다.**
    ///
    /// 그러지 않으면 `id` 와 `title` 이 **둘 다 빈 문자열**이 되는 데다(title 폴백이 id 다),
    /// 더 나쁘게는 `LibraryStore.importExtractedZipCounting` 의
    /// `let hasStableId = parsed?.workshopId != nil` 이 참이 되어 "같은 배경의 재가져오기" 로
    /// 오판하고 **이미 있는 관리 폴더를 지운 뒤 덮어쓴다**. WE export 관례상 zip 루트 폴더명은
    /// `Wallpaper/` 처럼 비유일하므로, 서로 다른 두 배경이 무통지로 서로를 지우는 경로가 된다
    /// (F247·F581 이 막으려던 손실이 빈 문자열 하나로 되살아난다).
    ///
    /// 실물에서는 이 값이 `strtoull` 결과로만 심기므로(package-format §5.4 — `0x14010aadf` →
    /// `0x14010ab27`) 빈 문자열이 올 수 없다. **설치본 191건 도달 0**(키 자체가 0건).
    func testBlankWorkshopIdIsTreatedAsAbsent() throws {
        for raw in ["\"\"", "\"   \"", "\"\\t\\n\""] {
            let p = try parse(#"{"type":"video","workshopid":\#(raw)}"#, folder: "/tmp/SomeWrapperName")
            XCTAssertNil(p.workshopId, "공백뿐인 workshopid(\(raw))는 부재여야 한다")
            XCTAssertEqual(p.id, "SomeWrapperName", "id 는 폴더명으로 폴백해야 한다")
            XCTAssertEqual(p.title, "SomeWrapperName", "title 폴백이 빈 문자열이 되면 안 된다")
        }
        // 공백을 **포함**하는(비어 있지 않은) 값은 그대로 둔다 — 유일·안정하므로 위 손실 경로가
        // 없고, 원문을 말없이 다듬으면 오히려 id 가 드리프트한다.
        XCTAssertEqual(try parse(#"{"type":"video","workshopid":" 123 "}"#).workshopId, " 123 ")
    }

    // MARK: - Foundation 구현 의존 축 (브리프 #21)
    //
    // 이 파서는 `AssetJSON` → `JSONSerialization` 위에 얹혀 있다. 리눅스는
    // swift-corelibs-foundation, macOS 는 Apple Foundation 이라 **답이 갈리는 축이 있다.**
    // 아래 테스트들은 (a) 갈리지 **않는** 것으로 실측된 축만 값으로 단언하고,
    // (b) 갈리는 축은 `#if canImport(Darwin)` 으로 양쪽 실측값을 각각 단언한다.

    /// **중복 키 승자는 플랫폼마다 다르고, 그 차이가 여기까지 도달한다.**
    ///
    /// `AssetJSONLenientTests.testDuplicateKeysWinnerIsPlatformDependent` 가 잰 축이
    /// `project.json` 에서는 **타입 분류를 바꾼다**: `{"type":"video","type":"scene"}` 가
    /// 리눅스에서는 scene, macOS 에서는 video 다. 실측 근거는 두 개다 —
    /// 리눅스는 이 컨테이너 실행, macOS 는 CI run 32492467832(job 96803096432, 커밋 `1bc9835`)
    /// 에서 `("Optional(1)") is not equal to ("Optional(2)")` 로 붉었던 그 실패다.
    ///
    /// WE(jsoncpp)는 `rejectDupKeys=false`(`0x14009238b`)라 **뒤가 이긴다** — 즉 리눅스가 WE 와
    /// 같고 macOS 가 갈린다. 고치려면 파스 전 중복 키 전처리가 필요한데 모든 자산 JSON 에 비용을
    /// 물리는 변경이라 `AssetJSON` 쪽 `[미해결]` 로 남아 있다. 여기서는 **거동을 못 박기만 한다.**
    /// 설치본 191건 중 최상위 중복 키를 가진 파일은 **0건**이다(원문 바이트 스캔 실측).
    func testDuplicateTopLevelKeyWinnerIsPlatformDependent() throws {
        #if canImport(Darwin)
        let expectedType = WallpaperType.video      // Apple Foundation — 앞이 이긴다
        let expectedFile = "first.json"
        #else
        let expectedType = WallpaperType.scene      // swift-corelibs — 뒤가 이긴다(WE 와 같다)
        let expectedFile = "second.json"
        #endif
        let p = try parse(#"{"type":"video","type":"scene","file":"first.json","file":"second.json"}"#)
        XCTAssertEqual(p.type, expectedType)
        XCTAssertEqual(p.fileName, expectedFile)
    }

    /// **정수 `workshopid` 의 자릿수는 양쪽 Foundation 이 같다** — `NSNumber` 태그가 정수면
    /// `stringValue` 가 자릿수를 그대로 낸다. 여기서 값으로 단언해도 안전한 이유다.
    ///
    /// **실수 `workshopid` 는 다르다.** 리눅스 실측은 `{"workshopid":1108426854.0}` →
    /// `"1108426854.0"` 인데(태그가 `d`), Apple Foundation 의 `NSNumber.stringValue` 형식은 이
    /// 컨테이너에서 잴 수 없다. 그래서 **철자를 단언하지 않고 수치 동등성만** 본다 —
    /// 한쪽만 적으면 반대편 CI 가 붉어진다. 실수 workshopid 는 실물에 존재하지 않는다
    /// (WE 는 `strtoull` 결과를 심는다). `[미해결 — macOS 실측 불가]`
    func testNumericWorkshopIdFormattingAcrossFoundations() throws {
        XCTAssertEqual(try parse(#"{"workshopid":0}"#).workshopId, "0")
        XCTAssertEqual(try parse(#"{"workshopid":2913506072}"#).workshopId, "2913506072")
        XCTAssertEqual(try parse(#"{"workshopid":9223372036854775807}"#).workshopId, "9223372036854775807")

        let real = try XCTUnwrap(try parse(#"{"workshopid":1108426854.0}"#).workshopId)
        XCTAssertEqual(Double(real), 1108426854, "철자는 구현마다 달라도 값은 같아야 한다")
        XCTAssertFalse(real.isEmpty)
    }

    /// `true`/`false` 는 `workshopid` 가 되지 않는다 — `JSONSerialization` 은 불리언도 `NSNumber`
    /// 로 주고 Swift 동적 캐스트가 `true as? Int == 1` 로 섞어 주므로, `CFGetTypeID` 선배제가
    /// 없으면 `{"workshopid":true}` 가 id `"1"` 이 된다. 두 플랫폼 공통.
    func testBooleanWorkshopIdIsNotAnId() throws {
        for raw in ["true", "false"] {
            let p = try parse(#"{"type":"video","workshopid":\#(raw)}"#, folder: "/tmp/999")
            XCTAssertNil(p.workshopId, "불리언 workshopid(\(raw))")
            XCTAssertEqual(p.id, "999")
        }
    }

    /// `tags` 는 **원소가 하나라도 문자열이 아니면 배열 전체가 사라진다**(`as? [String]` 실패).
    /// 부분 수용이 아니라 전무 — 왕복에서 잃는 자리라 명시해 둔다. 두 플랫폼 공통이고,
    /// WE 는 `tags` 를 아예 읽지 않으므로(§5.5 — `wallpaper64.exe` 에 문자열 부재) 파리티
    /// 문제는 아니다. 설치본 도달: `tags` 보유 2건, 둘 다 전건 문자열.
    func testNonStringTagElementDropsTheWholeArray() throws {
        XCTAssertEqual(try parse(#"{"type":"scene","tags":["Anime","Game"]}"#).tags, ["Anime", "Game"])
        XCTAssertEqual(try parse(#"{"type":"scene","tags":["Anime",1]}"#).tags, [])
        XCTAssertEqual(try parse(#"{"type":"scene","tags":["Anime",null]}"#).tags, [])
        XCTAssertEqual(try parse(#"{"type":"scene","tags":"Anime"}"#).tags, [])
        XCTAssertEqual(try parse(#"{"type":"scene","tags":[]}"#).tags, [])
    }

    /// `null` 은 어느 문자열 키에서도 값이 되지 않는다(`NSNull as? String` 실패) — 두 플랫폼 공통.
    /// WE 도 `preview` 가 문자열이 아니면 **null 로 덮어쓴다**(`0x14011e027`)고, `title` 이
    /// 문자열이 아니면 폴더명으로 채운다(`0x14011e0f7`) — 같은 결론이다.
    func testNullValuedStringKeysBehaveAsAbsent() throws {
        let p = try parse(#"{"type":"scene","file":null,"preview":null,"title":null,"contentrating":null,"workshopid":null}"#,
                          folder: "/tmp/777")
        XCTAssertNil(p.fileName)
        XCTAssertNil(p.previewName)
        XCTAssertNil(p.contentRating)
        XCTAssertNil(p.workshopId)
        XCTAssertEqual(p.title, "777", "title 이 null 이면 폴더명 폴백")
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
