import XCTest
@testable import WapleCore

/// `assets/zcompat/web/*.json` — WE 의 웹 월페이퍼 호환성 패치 전표.
///
/// 근거 주소는 `Sources/WapleCore/WebCompatPatch.swift` 헤더에 있다(바이너리는
/// `bin/webwallpaper64.exe`). 여기서는 **동봉 5건이 실제로 파스되고 적용되는지**를 고정한다.
/// 순수 문자열 로직이라 리눅스 레인에서 그대로 돈다.
final class WebCompatPatchTests: XCTestCase {

    // MARK: - 동봉 전수

    /// 동봉 `zcompat/web` 5건 전수. 파스 결과 액션 수와 내용이 파일과 일치해야 한다.
    func testBundledPatchSetsParse() throws {
        let root = try assetsRoot()
        let dir = root.appendingPathComponent("zcompat/web", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(files, ["780658164.json", "780662613.json", "780675904.json",
                               "784979889.json", "854685299.json"],
                       "동봉 zcompat/web 은 5건이다 — 늘거나 줄면 이 테스트의 기대치를 갱신해라")

        // texImage2D 널 가드 4건: 같은 전표(액션 4개)를 공유한다.
        for id in ["780658164", "780662613", "780675904", "854685299"] {
            let set = WebCompatPatch.parse(try Data(contentsOf: dir.appendingPathComponent("\(id).json")))
            XCTAssertEqual(set.actions.count, 4, "\(id): actions 4건")
            XCTAssertEqual(set.actions.map(\.file),
                           ["index_files/index.min.js.Download",
                            "js/index.min.js", "js/index2.min.js", "js/index3.min.js"])
            // 3건은 (t,e) 이름, index2 만 (e,t) 로 미니파이어 이름이 뒤집혔다.
            XCTAssertEqual(set.actions[1].replace, "u(t,e){t.texImage2D")
            XCTAssertEqual(set.actions[1].insert, "u(t,e){if(e!=null)t.texImage2D")
            XCTAssertEqual(set.actions[2].replace, "u(e,t){e.texImage2D")
            XCTAssertEqual(set.actions[2].insert, "u(e,t){if(t!=null)e.texImage2D")
        }

        // three.js 알파 배경 → 불투명 + 고정 클리어컬러 1건.
        let alpha = WebCompatPatch.parse(
            try Data(contentsOf: dir.appendingPathComponent("784979889.json")))
        XCTAssertEqual(alpha.actions.count, 1)
        XCTAssertEqual(alpha.actions[0].file, "js/index.js")
        XCTAssertEqual(alpha.actions[0].replace,
                       "renderer = new THREE.WebGLRenderer({alpha: true, antialias: true });")
        XCTAssertTrue(alpha.actions[0].insert.contains("alpha: false"))
        XCTAssertTrue(alpha.actions[0].insert.contains("setClearColor( 0xe0dacd, 1)"))
    }

    /// 워크샵 ID 로 조회했을 때 동봉 5건이 전부 잡혀야 한다(스킴 핸들러가 쓰는 진입점).
    func testBundledPatchSetsResolveByProjectID() throws {
        let root = try assetsRoot()
        for id in ["780658164", "780662613", "780675904", "784979889", "854685299"] {
            let set = WebCompatPatch.load(projectID: id, in: [root])
            XCTAssertFalse(set.isEmpty, "\(id) 전표를 못 찾았다")
        }
        XCTAssertTrue(WebCompatPatch.load(projectID: "999999999", in: [root]).isEmpty,
                      "없는 ID 는 빈 전표")
    }

    /// 동봉 5건이 **실제로 문자열을 바꾸는지**. WE 가 고치려는 원문 형태를 그대로 넣고 확인한다.
    func testBundledPatchSetsActuallyRewriteTheirTargets() throws {
        let root = try assetsRoot()

        // ① texImage2D 널 가드 — WebGL 텍스처 업로드에 null 이 들어오면 CEF 는 예외를 던지고
        //    페이지가 통째로 멈춘다. 가드 한 줄을 함수 앞머리에 끼워 넣는 패치다.
        let set = WebCompatPatch.load(projectID: "780658164", in: [root])
        let original = "function u(t,e){t.texImage2D(3553,0,6408,6408,5121,e);}"
        let patched = WebCompatPatch.applied(original, actions: set.actions(forRelativePath: "js/index.min.js"))
        XCTAssertEqual(patched, "function u(t,e){if(e!=null)t.texImage2D(3553,0,6408,6408,5121,e);}")

        // 같은 전표라도 파일이 다르면 다른 액션이 걸린다(index2 는 인자 이름이 뒤집힌 판).
        let two = WebCompatPatch.applied("function u(e,t){e.texImage2D(0);}",
                                         actions: set.actions(forRelativePath: "js/index2.min.js"))
        XCTAssertEqual(two, "function u(e,t){if(t!=null)e.texImage2D(0);}")

        // 다른 파일에는 아무 액션도 안 걸린다.
        XCTAssertTrue(set.actions(forRelativePath: "js/other.js").isEmpty)

        // ② three.js 알파 — alpha:true 로 만든 렌더러는 데스크탑 합성에서 배경이 비어 보인다.
        let alpha = WebCompatPatch.load(projectID: "784979889", in: [root])
        let src = "var renderer = new THREE.WebGLRenderer({alpha: true, antialias: true });\n"
        let out = WebCompatPatch.applied(src, actions: alpha.actions(forRelativePath: "js/index.js"))
        XCTAssertTrue(out.contains("alpha: false"))
        XCTAssertTrue(out.contains("renderer.setClearColor( 0xe0dacd, 1);"))
        XCTAssertFalse(out.contains("alpha: true"))
    }

    // MARK: - 스키마 판정(WE 분기 그대로)

    /// `actions` 가 배열이 아니면 전표 통째 무시(0x14000c76f).
    func testActionsMustBeArray() {
        XCTAssertTrue(WebCompatPatch.parse(Data(#"{"actions":{"file":"a"}}"#.utf8)).isEmpty)
        XCTAssertTrue(WebCompatPatch.parse(Data(#"{"actions":"nope"}"#.utf8)).isEmpty)
        XCTAssertTrue(WebCompatPatch.parse(Data(#"{}"#.utf8)).isEmpty)
        XCTAssertTrue(WebCompatPatch.parse(Data("not json".utf8)).isEmpty)
    }

    /// 항목 하나가 망가져도 **그 항목만** 버리고 나머지는 산다(0x14000d0ca 가 다음 항목으로 간다).
    func testMalformedActionSkipsOnlyThatEntry() {
        let json = """
        {"actions":[
          {"file":"a.js","replace":"x","insert":"y"},
          {"file":"b.js","replace":"x"},
          {"file":"c.js","replace":1,"insert":"y"},
          "just a string",
          {"file":"d.js","replace":"x","insert":"z"}
        ]}
        """
        let set = WebCompatPatch.parse(Data(json.utf8))
        XCTAssertEqual(set.actions.map(\.file), ["a.js", "d.js"])
    }

    /// jsoncpp 태그 4 는 문자열만이다 — 숫자·불리언은 문자열로 승격되지 않는다.
    func testNonStringValuesAreRejected() {
        let json = #"{"actions":[{"file":"a.js","replace":"x","insert":true}]}"#
        XCTAssertTrue(WebCompatPatch.parse(Data(json.utf8)).isEmpty)
    }

    /// 빈 `replace` 는 버린다 — Waple 의 의도적 분기(WE 는 여기서 무한 루프한다).
    func testEmptyReplaceIsDropped() {
        let json = #"{"actions":[{"file":"a.js","replace":"","insert":"z"},{"file":"b.js","replace":"q","insert":""}]}"#
        let set = WebCompatPatch.parse(Data(json.utf8))
        XCTAssertEqual(set.actions.map(\.file), ["b.js"], "빈 needle 만 버린다 — 빈 insert 는 정상(삭제)")
        XCTAssertEqual(WebCompatPatch.applied("aqb", actions: set.actions), "ab")
    }

    /// WE 파서는 jsoncpp 라 줄 주석·트레일링 콤마를 허용한다(`AssetJSON` 과 같은 관용도).
    func testLenientJSONIsAccepted() {
        let json = """
        {"actions":[
          // 널 가드
          {"file":"a.js","replace":"x","insert":"y"},
        ]}
        """
        XCTAssertEqual(WebCompatPatch.parse(Data(json.utf8)).actions.count, 1)
    }

    // MARK: - 치환 의미론

    /// 전체 치환이고, 진행 위치를 `insert` 길이만큼 민다 — 넣은 텍스트는 다시 매치되지 않는다.
    func testReplacesEveryOccurrenceWithoutRematchingInsertedText() {
        let action = WebCompatPatch.Action(file: "a.js", replace: "ab", insert: "xaby")
        XCTAssertEqual(WebCompatPatch.applied("ab-ab-ab", actions: [action]), "xaby-xaby-xaby")
    }

    /// 매치가 없으면 원문 그대로(바이트 동일).
    func testNoMatchLeavesContentUntouched() {
        let action = WebCompatPatch.Action(file: "a.js", replace: "zzz", insert: "!")
        let src = Data("hello".utf8)
        XCTAssertEqual(WebCompatPatch.applied(src, actions: [action]), src)
    }

    /// 여러 액션은 선언 순서대로 **누적** 적용된다.
    func testActionsApplyInDeclarationOrder() {
        let a = WebCompatPatch.Action(file: "a.js", replace: "1", insert: "2")
        let b = WebCompatPatch.Action(file: "a.js", replace: "2", insert: "3")
        XCTAssertEqual(WebCompatPatch.applied("1", actions: [a, b]), "3")
        XCTAssertEqual(WebCompatPatch.applied("1", actions: [b, a]), "2")
    }

    /// 비 UTF-8 바이트가 섞여 있어도 손상시키지 않는다(바이트 단위 치환).
    func testBinarySafeReplacement() {
        var src = Data([0xff, 0xfe])
        src.append(Data("needle".utf8))
        src.append(Data([0x00, 0xff]))
        let action = WebCompatPatch.Action(file: "a", replace: "needle", insert: "N")
        var expected = Data([0xff, 0xfe])
        expected.append(Data("N".utf8))
        expected.append(Data([0x00, 0xff]))
        XCTAssertEqual(WebCompatPatch.applied(src, actions: [action]), expected)
    }

    // MARK: - 경로 대조

    /// 구분자·선행 슬래시·대소문자는 무시하고 같은 파일로 본다(WE 는 이 경로로 파일을 연다).
    func testRelativePathMatchingIsSeparatorAndCaseInsensitive() {
        let json = #"{"actions":[{"file":"js\\Index.min.js","replace":"x","insert":"y"}]}"#
        let set = WebCompatPatch.parse(Data(json.utf8))
        XCTAssertEqual(set.actions.count, 1)
        for probe in ["js/index.min.js", "/js/index.min.js", "js\\index.min.js", "./js/INDEX.MIN.JS"] {
            XCTAssertEqual(set.actions(forRelativePath: probe).count, 1, "경로 대조 실패: \(probe)")
        }
        XCTAssertTrue(set.actions(forRelativePath: "js/index.min.js.map").isEmpty)
        XCTAssertTrue(set.actions(forRelativePath: "").isEmpty)
    }

    /// 전표가 언급하는 파일 집합 — 스킴 핸들러가 요청마다 전체 스캔하지 않게 하는 게이트.
    func testReferencedFilesIsNormalized() {
        let json = #"{"actions":[{"file":"JS\\A.js","replace":"x","insert":"y"},{"file":"js/a.js","replace":"p","insert":"q"}]}"#
        XCTAssertEqual(WebCompatPatch.parse(Data(json.utf8)).referencedFiles, ["js/a.js"])
    }

    /// 프로젝트 ID 는 파일명 조각으로 들어가므로 경로 탈출을 끊는다.
    func testProjectIDSanitization() {
        XCTAssertNil(WebCompatPatch.sanitizedProjectID(""))
        XCTAssertNil(WebCompatPatch.sanitizedProjectID(".."))
        XCTAssertNil(WebCompatPatch.sanitizedProjectID("../../etc/passwd"))
        XCTAssertNil(WebCompatPatch.sanitizedProjectID("a\\b"))
        XCTAssertEqual(WebCompatPatch.sanitizedProjectID("780658164"), "780658164")
    }

    // MARK: -

    /// 동봉 자산 루트. `WAPLE_WE_ASSETS`(리눅스 하네스가 넣는다) → 상위 디렉터리 탐색 순.
    private func assetsRoot() throws -> URL {
        if let p = ProcessInfo.processInfo.environment["WAPLE_WE_ASSETS"], !p.isEmpty,
           FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("Sources/WapleRender/Resources/WEAssets",
                                                      isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("zcompat").path) {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("WAPLE_WE_ASSETS 미지정 — 동봉 자산 트리를 못 찾았다")
    }
}
