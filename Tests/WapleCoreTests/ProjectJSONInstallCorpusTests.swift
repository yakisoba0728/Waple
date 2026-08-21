import XCTest
@testable import WapleCore

/// `project.json` **읽기/쓰기 왕복**을 WE 설치본 전수(191건)로 잰다.
///
/// 왜 있는가
/// ---------
/// 이 클러스터의 질문은 하나였다 — "`ProjectJSONParser.parse` → `ProjectJSONBuilder` → 다시 파스
/// 했을 때 바이트 동일한가?" 답은 **아니다**이고, 중요한 것은 "아니다" 가 아니라 **어디서 얼마나
/// 잃는가**다. 종전 스위트는 그 답을 합성 픽스처 20여 건으로만 만졌다.
///
/// 여기서 못 박는 세 가지:
///  1. **최상위 키 전수** — 설치본 191건이 실제로 쓰는 키 15종과 그 JSON 타입. 파서가 읽는 10종과
///     한 번도 읽지 않는 8종(도수 142)이 갈린다.
///  2. **쓰기 쪽의 실제 폭** — `ProjectJSONBuilder` 에 있는 유일한 진입점은
///     `videoProject(file:preview:title:)` 하나다. 설치본 191건 중 그 함수가 **재현할 수 있는
///     것은 0건**이고, 파서가 읽는 키를 전부 다시 써도 바이트 동일은 **0건**이다(§왕복 테스트).
///  3. **읽기 쪽은 고정점이다** — 파서가 읽는 키만 다시 써서 재파스하면 191/191 이 같은
///     `WallpaperProject` 로 돌아온다. 즉 잃는 것은 "우리가 안 읽는 키" 뿐이고, 읽는 키가
///     2차 파스에서 변형되는 자리는 없다.
///
/// 코퍼스 규약은 `WallpaperCompatibilityCorpusAuditTests` 와 같다 — `WE_ROOT`(기본
/// `/home/user/Waple-wallpaper-source/wallpaper_engine`)가 없으면 조용히 스킵한다(ubuntu CI).
///
/// 대조 근거: `docs/re/package-format.md` §1.2(361건 전수 도수) · §5(리더 `0x14011d7d0` 의 키별
/// 동작) · §5.5(읽히지 않는 키). 여기 수치는 **설치본 191건만**의 분모라 §1.2 의 361(설치본 +
/// 동봉 `WEAssets/`)과 다르다 — 스코프 라벨을 반드시 같이 읽어라.
final class ProjectJSONInstallCorpusTests: XCTestCase {

    // MARK: - 코퍼스 수집

    private static func installRoot() -> URL? {
        let path = ProcessInfo.processInfo.environment["WE_ROOT"]
            ?? "/home/user/Waple-wallpaper-source/wallpaper_engine"
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// 트리 아래 `project.json` 을 가진 폴더 전부(경로 정렬).
    private static func projectFolders(under root: URL) -> [URL] {
        var out: [URL] = []
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in en {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) {
                out.append(url.standardizedFileURL)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    private struct Entry {
        let folder: URL
        let data: Data
        let raw: [String: Any]
        let project: WallpaperProject
    }

    /// 설치본 전수. 없으면 `XCTSkip`.
    private static func corpus() throws -> [Entry] {
        guard let root = installRoot() else { throw XCTSkip("WE 설치본 트리 없음(WE_ROOT)") }
        var out: [Entry] = []
        for folder in projectFolders(under: root) {
            let url = folder.appendingPathComponent("project.json")
            let data = try Data(contentsOf: url)
            guard let raw = AssetJSON.dictionary(data) else {
                XCTFail("project.json 이 JSON 오브젝트가 아니다: \(url.path)")
                continue
            }
            out.append(Entry(folder: folder, data: data, raw: raw,
                             project: ProjectJSONParser.parse(json: raw, folderURL: folder)))
        }
        guard !out.isEmpty else { throw XCTSkip("설치본에 project.json 이 없다") }
        return out
    }

    /// **파서가 실제로 읽는 최상위 키 전수.** `ProjectJSONParser.parse(json:folderURL:)` 본문에서
    /// `obj[...]` 로 조회되는 이름이 이것뿐이다 — 새 키를 읽기 시작하면 아래 도수 테스트가 먼저 깨진다.
    private static let keysParserReads: Set<String> = [
        "workshopid", "type", "file", "preview", "title", "tags", "contentrating",
        "dependency", "preset", "general",
    ]

    // MARK: - 1. 최상위 키 전수

    /// 설치본 191건이 쓰는 최상위 키 **15종**과 도수. `docs/re/package-format.md` §1.2 의
    /// 361건 표와 같은 목록이고 분모만 다르다(설치본 191).
    func testTopLevelKeyCensus() throws {
        let corpus = try Self.corpus()
        XCTAssertEqual(corpus.count, 191, "설치본 project.json 수 — 코퍼스가 바뀌면 아래 수치 전부 재측정")

        var counts: [String: Int] = [:]
        var kinds: [String: Set<String>] = [:]
        for e in corpus {
            for (k, v) in e.raw {
                counts[k, default: 0] += 1
                kinds[k, default: []].insert(Self.jsonKind(v))
            }
        }
        print("== 최상위 키 도수(설치본 191): "
              + counts.sorted { $0.key < $1.key }
                  .map { "\($0.key)=\($0.value)\((kinds[$0.key] ?? []).sorted())" }.joined(separator: " "))

        XCTAssertEqual(counts, [
            "file": 191, "title": 189, "general": 180, "type": 152, "version": 89,
            "official": 19, "preview": 19, "authorsteamid": 12, "visibility": 10,
            "timestamp": 4, "description": 3, "templateoptions": 3,
            "approved": 2, "contentrating": 2, "tags": 2,
        ], "설치본 최상위 키 도수")

        // **타입도 함께 고정한다** — 키 이름만 같고 타입이 흔들리는 코퍼스 변화를 잡기 위해서다.
        // (`version` 이 int 인 것이 §5.5 의 "읽히지 않는다" 와 별개로 기록될 값이다: 89건 전부 `0`.)
        XCTAssertEqual(kinds.mapValues { $0.sorted().joined(separator: "|") }, [
            "file": "string", "title": "string", "general": "object", "type": "string",
            "version": "int", "official": "bool", "preview": "string",
            "authorsteamid": "string", "visibility": "string", "timestamp": "int",
            "description": "string", "templateoptions": "array",
            "approved": "bool", "contentrating": "string", "tags": "array",
        ], "최상위 키의 JSON 타입 — 한 키가 두 타입으로 오면 여기서 `|` 로 드러난다")

        // `general` 하위는 딱 둘이다. `ProjectJSONParser` 는 그중 `supportsaudioprocessing` 만 읽고
        // `properties`(180건)는 `WallpaperProperties` 가 별도로 읽는다 — 즉 `WallpaperProject`
        // 한 값만으로는 180건의 프로퍼티 스키마를 **되쓸 수 없다**(아래 왕복 테스트의 핵심 손실).
        var general: [String: Int] = [:]
        for e in corpus {
            for (k, _) in (e.raw["general"] as? [String: Any]) ?? [:] { general[k, default: 0] += 1 }
        }
        XCTAssertEqual(general, ["properties": 180, "supportsaudioprocessing": 3])

        // 파서가 읽는 10종 중 설치본에 **실제로 등장하는 것은 7종**이다.
        // `workshopid`·`dependency`·`preset` 은 설치본 도달 0 — 그 세 경로는 이 코퍼스로 검증되지
        // 않는다는 사실 자체가 기록이다(합성 픽스처가 `ProjectJSONParserTests` 에 있다).
        XCTAssertEqual(Set(counts.keys).intersection(Self.keysParserReads),
                       ["file", "title", "general", "type", "preview", "contentrating", "tags"])
        for absent in ["workshopid", "dependency", "preset"] {
            XCTAssertNil(counts[absent], "\(absent) 은 설치본 도달 0이어야 한다")
        }
    }

    /// **파서가 한 번도 읽지 않는 키 8종 · 도수 142 · 파일 107/191.**
    /// 곧 "쓰기" 가 원문을 보지 않고 `WallpaperProject` 만으로 재구성하면 이만큼이 사라진다.
    /// 8종 전부 `wallpaper64.exe` 안에 문자열조차 없거나(§5.5) 런타임이 안 읽는 저작 UI 전용이라
    /// **렌더 동작에는 영향이 없다** — 잃는 것은 라이브러리/저작 메타다.
    func testKeysTheParserNeverReads() throws {
        let corpus = try Self.corpus()
        var dropped: [String: Int] = [:]
        var filesWithDrop = 0
        for e in corpus {
            let d = Set(e.raw.keys).subtracting(Self.keysParserReads)
            for k in d { dropped[k, default: 0] += 1 }
            if !d.isEmpty { filesWithDrop += 1 }
        }
        print("== 파서 미독 키: \(dropped.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))")

        XCTAssertEqual(dropped, [
            "version": 89, "official": 19, "authorsteamid": 12, "visibility": 10,
            "timestamp": 4, "description": 3, "templateoptions": 3, "approved": 2,
        ], "파서가 읽지 않는 최상위 키")
        XCTAssertEqual(dropped.values.reduce(0, +), 142, "미독 키 총 도수")
        XCTAssertEqual(filesWithDrop, 107, "미독 키를 하나라도 가진 파일 수")
        XCTAssertEqual(corpus.count - filesWithDrop, 84, "최상위 키가 전부 읽히는 파일 수")
    }

    // MARK: - 2. 왕복 — 바이트 동일은 0/191

    /// **`ProjectJSONBuilder` 의 유일한 진입점으로는 설치본 191건 중 0건도 재현할 수 없다.**
    ///
    /// `videoProject(file:preview:title:)` 는 `"type":"video"` 를 상수로 박고 네 키만 쓴다.
    /// 설치본은 scene 188 · web 2 · application 1 이라 타입부터 어긋나고, `preview` 도 19건에만
    /// 있다. 즉 **현행 쓰기 API 는 "임포트한 원시 동영상을 감싸는" 한 가지 용도 전용**이고
    /// 일반적인 `project.json` 라이터가 아니다 — 이 테스트가 그 사실을 못 박는다.
    func testVideoBuilderCannotReproduceAnyInstallProject() throws {
        let corpus = try Self.corpus()
        var reproduced = 0
        for e in corpus {
            let built = ProjectJSONBuilder.videoProject(
                file: e.project.fileName ?? "",
                preview: e.project.previewName ?? "",
                title: e.project.title)
            if Data(built.utf8) == e.data { reproduced += 1 }
        }
        XCTAssertEqual(reproduced, 0, "videoProject 로 바이트 재현되는 설치본 프로젝트 수")

        // 양성 대조: 그 함수가 만든 것은 그 함수로 재현된다(왕복이 원리적으로 불가능한 게 아니라
        // **모양이 다를 뿐**이라는 확인).
        let mine = ProjectJSONBuilder.videoProject(file: "clip.mp4", preview: "preview.jpg", title: "My Clip")
        let again = try XCTUnwrap(AssetJSON.dictionary(Data(mine.utf8)))
        let p = ProjectJSONParser.parse(json: again, folderURL: URL(fileURLWithPath: "/tmp/clip", isDirectory: true))
        XCTAssertEqual(ProjectJSONBuilder.videoProject(file: p.fileName ?? "", preview: p.previewName ?? "",
                                                       title: p.title), mine)
    }

    /// **파서가 읽는 키를 전부 되써도 바이트 동일은 0/191 이다** — 네 가지 기계적 이유가 있고,
    /// 그중 어느 하나도 파서/빌더 수정으로는 없앨 수 없다(`JSONSerialization` 이 형식을 정한다).
    ///
    ///  1. **줄 끝.** 설치본 191건은 **전건 CRLF** 다. `JSONSerialization` 은 LF 만 낸다.
    ///  2. **들여쓰기.** 189건이 탭 1칸, 2건이 스페이스 2칸이다.
    ///     `JSONSerialization` 은 `.prettyPrinted` 에서 **스페이스 2칸 고정**이고 탭을 낼 방법이 없다.
    ///  3. **키 순서.** 원문 191건 중 키가 사전순인 것은 177건뿐이다(14건은 저작 순서).
    ///     `.sortedKeys` 는 그 14건을 재배치하고, 빼면 나머지 177건의 순서가 Swift `Dictionary`
    ///     해시 순서(실행마다 다름)로 무너진다.
    ///  4. **미독 키 8종**(위 테스트, 142건)이 애초에 출력에 없다.
    ///
    /// 그래서 이 리포에서 "왕복" 의 의미는 **바이트가 아니라 값**이어야 한다(다음 테스트).
    ///
    /// **줄 나눔은 바이트로 한다(브리프 함정 #11).** Swift `String` 은 그래핌 클러스터 단위로
    /// 순회하고 `"\r\n"` 은 **한 개의 `Character`** 라 `Character("\r\n") != "\n"` 이다 —
    /// `String.split(separator: "\n")` 은 CRLF 파일을 **한 줄**로 본다. 이 테스트의 초판이
    /// 바로 그 함정에 빠져 191건 전부를 "한 줄" 로 셌다(전건 CRLF 라 100% 오판이었다).
    func testNoInstallProjectSurvivesAByteIdenticalRewrite() throws {
        let corpus = try Self.corpus()
        var byteIdentical = 0
        var crlfOnly = 0
        var tabIndented = 0, twoSpaceIndented = 0, singleLine = 0
        var sortedKeyOrder = 0
        for e in corpus {
            let rewritten = try XCTUnwrap(
                try? JSONSerialization.data(withJSONObject: Self.rewritableObject(e.project),
                                            options: [.sortedKeys, .prettyPrinted]))
            if rewritten == e.data { byteIdentical += 1 }

            let lines = e.data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            let lineFeeds = lines.count - 1
            let crlfs = lines.dropLast().filter { $0.last == UInt8(ascii: "\r") }.count
            if lineFeeds > 0, crlfs == lineFeeds { crlfOnly += 1 }
            if lineFeeds == 0 { singleLine += 1 }
            else if let indent = lines.dropFirst().lazy
                .map({ $0.prefix { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") } })
                .first(where: { !$0.isEmpty }) {
                if indent.first == UInt8(ascii: "\t") { tabIndented += 1 }
                if Array(indent) == [UInt8(ascii: " "), UInt8(ascii: " ")] { twoSpaceIndented += 1 }
            }
            // 원문 키 순서가 사전순인가 — `JSONSerialization` 은 원문 순서를 아예 보존하지 않으므로
            // 여기서 재는 것은 "`.sortedKeys` 가 재배치하는 파일 수" 의 하한이다.
            let keysInFileOrder = Self.topLevelKeysInFileOrder(e.data)
            if keysInFileOrder == keysInFileOrder.sorted() { sortedKeyOrder += 1 }
        }
        XCTAssertEqual(byteIdentical, 0, "파서가 읽는 키를 전부 되써도 바이트 동일한 파일 수")
        XCTAssertEqual(crlfOnly, 191, "줄 끝이 전건 CRLF 인가 — LF 만 내는 직렬화로는 재현 불가")
        XCTAssertEqual(tabIndented, 189, "탭 들여쓰기 파일 수")
        XCTAssertEqual(twoSpaceIndented, 2, "스페이스 2칸 들여쓰기 파일 수")
        XCTAssertEqual(singleLine, 0, "한 줄짜리 project.json 은 설치본에 없다")
        XCTAssertEqual(sortedKeyOrder, 177, "원문 키 순서가 이미 사전순인 파일 수(나머지 14건은 재배치된다)")
    }

    /// **읽기는 고정점이다** — `parse` → (읽은 키만) 되쓰기 → `parse` 가 191/191 같은 값을 낸다.
    ///
    /// 이게 참이어야 "잃는 것은 우리가 안 읽는 키뿐" 이라고 말할 수 있다. 거짓이면 읽는 키조차
    /// 2차 파스에서 변형된다는 뜻이다. 실제로 잠기는 자리들:
    ///  · 확장자 유도(`type` 부재 39건)가 1차에서 정한 타입이 2차에서 **다시 유도되어도 같은가**
    ///    — `storageString` 으로 명시된 뒤에도 `preset` 가드가 안 걸리는지가 여기서 검증된다.
    ///  · `WallpaperPathSecurity.normalizedRelativePath` 가 **멱등**인가(정규화 결과를 다시 넣어도
    ///    같은가).
    ///  · `title` 폴백(2건 — `projects/templates/flag`·`gif` 는 `title` 이 없어 폴더명이 들어간다)이
    ///    2차에서 그대로 문자열 `title` 로 실려 같은 값을 내는가.
    func testParsedProjectIsAFixedPointUnderRewrite() throws {
        let corpus = try Self.corpus()
        var mismatches: [String] = []
        for e in corpus {
            let data = try XCTUnwrap(try? JSONSerialization.data(withJSONObject: Self.rewritableObject(e.project)))
            let again = ProjectJSONParser.parse(json: try XCTUnwrap(AssetJSON.dictionary(data)),
                                                folderURL: e.folder)
            if again != e.project { mismatches.append(e.folder.lastPathComponent) }
        }
        XCTAssertEqual(mismatches, [], "되쓰기 후 재파스가 달라진 프로젝트")
    }

    // MARK: - 3. 유도·정규화 실측

    /// 유도된 타입 분포와 `type` 원문 분포. **`type` 을 생략한 39건**이 확장자 유도의 도달 건수다.
    ///
    /// 그리고 **선언된 `type` 과 확장자 유도 결과가 어긋나는 파일은 0건**이다. 이게
    /// `ProjectJSONParser.swift` 의 `[미해결]`("WE 는 `type` 을 안 읽고 유도로 덮어쓴다 —
    /// 맞추면 워크샵 코퍼스 분류가 바뀐다")의 **설치본 도달을 0으로 만든다**: 여기서는 어느 규칙을
    /// 써도 같은 답이 나온다. 갈릴 수 있는 것은 워크샵 코퍼스뿐이고 그건 이 컨테이너에 없다.
    func testTypeDerivationReachAndConflicts() throws {
        let corpus = try Self.corpus()
        var declared: [String: Int] = [:]
        var derivedTypes: [String: Int] = [:]
        var conflicts: [String] = []
        for e in corpus {
            declared[(e.raw["type"] as? String) ?? "<부재>", default: 0] += 1
            derivedTypes[e.project.type.storageString, default: 0] += 1
            // `type` 을 지운 사본으로 순수 유도만 돌려 본다(= WE 의 `0x14011e520` 규칙).
            var stripped = e.raw
            stripped["type"] = nil
            let inferred = ProjectJSONParser.parse(json: stripped, folderURL: e.folder).type
            if let d = e.raw["type"] as? String, WallpaperType.from(d) != inferred {
                conflicts.append("\(e.folder.lastPathComponent): 선언 \(d) vs 유도 \(inferred.storageString)")
            }
        }
        XCTAssertEqual(declared, ["scene": 150, "<부재>": 39, "web": 2], "`type` 원문 분포")
        XCTAssertEqual(derivedTypes, ["scene": 188, "web": 2, "application": 1], "파서 산출 타입 분포")
        XCTAssertEqual(conflicts, [], "선언 type 과 확장자 유도가 어긋나는 프로젝트(WE 는 유도가 이긴다)")
    }

    /// `file`·`preview` 에 대한 경로 정규화는 설치본 전건에서 **항등**이다.
    /// `docs/re/package-format.md` §1.1c 가 워크샵 pkg 엔트리 11,338종에 대해 같은 결론을 냈고
    /// (역슬래시·`..`·절대경로 전건 0), 여기 191건의 매니페스트 값도 같다.
    /// 곧 정규화가 왕복에서 값을 바꾸는 일은 이 코퍼스에서 일어나지 않는다.
    func testPathNormalizationIsIdentityOnTheWholeInstall() throws {
        let corpus = try Self.corpus()
        var files: [String: Int] = [:]
        var previews: [String: Int] = [:]
        var changed: [String] = []
        for e in corpus {
            for (key, parsed) in [("file", e.project.fileName), ("preview", e.project.previewName)] {
                guard let raw = e.raw[key] as? String else { continue }
                if parsed != raw { changed.append("\(e.folder.lastPathComponent).\(key): \(raw) → \(parsed ?? "nil")") }
            }
            files[e.project.fileName ?? "<nil>", default: 0] += 1
            if let p = e.project.previewName { previews[p, default: 0] += 1 }
        }
        XCTAssertEqual(changed, [], "정규화가 값을 바꾼 자리")
        XCTAssertEqual(files, ["scene.json": 183, "index.html": 2, "audiophile.json": 1,
                               "fantasticcar.json": 1, "gifscene.json": 1, "ricepod.json": 1,
                               "sheep.exe": 1, "techno.json": 1], "`file` 값 분포")
        XCTAssertEqual(previews, ["preview.jpg": 14, "preview.gif": 5], "`preview` 값 분포(19건)")
    }

    /// **읽는 키마다 "몇 건이 실제로 값을 얻는가"** 를 따로 못 박는다.
    ///
    /// 왜 따로 두는가: 앞의 고정점 테스트는 **되쓰기 후 같은 값**만 본다. 어떤 키를 파서가 통째로
    /// 읽지 않게 되어도(예: `contentrating` 을 항상 nil 로) 1차와 2차가 똑같이 nil 이라 고정점은
    /// 초록으로 남는다 — 돌연변이 검증에서 실제로 그 구멍을 확인했다. 키별 도달 수치를 여기서
    /// 고정해야 "읽기를 멈춘" 회귀가 잡힌다.
    func testPerKeyReachOfParsedFields() throws {
        let corpus = try Self.corpus()
        XCTAssertEqual(corpus.filter { $0.project.fileName != nil }.count, 191, "fileName")
        XCTAssertEqual(corpus.filter { $0.project.previewName != nil }.count, 19, "previewName")
        XCTAssertEqual(corpus.filter { $0.project.contentRating != nil }.count, 2, "contentRating")
        XCTAssertEqual(corpus.filter { !$0.project.tags.isEmpty }.count, 2, "tags")
        XCTAssertEqual(corpus.filter { $0.project.supportsAudioProcessing }.count, 3, "supportsAudioProcessing")
        // 설치본 도달 0인 네 경로 — 합성 픽스처로만 검증된다는 사실 자체가 기록이다.
        XCTAssertEqual(corpus.filter { $0.project.workshopId != nil }.count, 0, "workshopId")
        XCTAssertEqual(corpus.filter { $0.project.dependency != nil }.count, 0, "dependency")
        XCTAssertEqual(corpus.filter { !$0.project.presetOverrides.isEmpty }.count, 0, "presetOverrides")
        XCTAssertEqual(corpus.filter { $0.project.presetFolderURL != nil }.count, 0, "presetFolderURL")

        // `title` 은 189건이 원문, 2건이 폴더명 폴백(`projects/templates/flag`·`gif`)이다.
        // WE 도 `title` 이 문자열이 아니면 폴더명을 채워 넣는다(`0x14011e0f7`).
        let fallback = corpus.filter { $0.raw["title"] == nil }.map { $0.folder.lastPathComponent }.sorted()
        XCTAssertEqual(fallback, ["flag", "gif"], "title 이 없어 폴더명으로 채워지는 프로젝트")
        for e in corpus where e.raw["title"] == nil {
            XCTAssertEqual(e.project.title, e.folder.lastPathComponent)
        }
        XCTAssertEqual(corpus.filter { ($0.raw["title"] as? String) == $0.project.title }.count, 189,
                       "원문 title 이 그대로 실린 건수")

        // 값 표본도 고정한다 — 도수만 맞고 값이 뒤바뀌는 회귀를 막는다.
        let rated = corpus.filter { $0.project.contentRating != nil }
            .map { "\($0.folder.lastPathComponent)=\($0.project.contentRating!)" }.sorted()
        XCTAssertEqual(rated, ["dino_run=Everyone", "neon_sunset=Everyone"])
        let tagged = corpus.filter { !$0.project.tags.isEmpty }
            .map { "\($0.folder.lastPathComponent)=\($0.project.tags.joined(separator: "/"))" }.sorted()
        XCTAssertEqual(tagged, ["dino_run=Pixel art", "neon_sunset=Retro"])
    }

    /// `general.supportsaudioprocessing` 의 설치본 도달 — **3건**이고 전부 `true` 다.
    /// (`CProject::SupportsAudioProcessing` `0x14010d100`–`0x14010d161`. 키 부재 188건은 false.)
    func testSupportsAudioProcessingReach() throws {
        let corpus = try Self.corpus()
        let on = corpus.filter { $0.project.supportsAudioProcessing }.map { $0.folder.lastPathComponent }.sorted()
        XCTAssertEqual(on, ["audiophile", "corsair_o_tron", "demon_core"],
                       "오디오 반응을 선언한 설치본 프로젝트")
    }

    // MARK: - 보조

    private static func jsonKind(_ v: Any) -> String {
        if v is NSNull { return "null" }
        if EffectManifest.isJSONBool(v) { return "bool" }
        if let n = v as? NSNumber {
            // 정수/실수 구분은 `NSNumber` 태그가 아니라 **값이 정수인가**로 판정한다 —
            // 두 Foundation 구현이 같은 리터럴에 다른 태그를 줄 수 있는 축이라, 태그를 단언하면
            // 리눅스 초록이 macOS 초록이 아니게 된다(브리프 #21).
            return n.doubleValue == n.doubleValue.rounded() && abs(n.doubleValue) < 1e15 ? "int" : "real"
        }
        if v is String { return "string" }
        if v is [Any] { return "array" }
        if v is [String: Any] { return "object" }
        return "기타"
    }

    /// 파서가 **읽는 키만** 담은 오브젝트 — 현행 도메인 타입 `WallpaperProject` 가 표현할 수 있는
    /// 최대치이자 곧 "쓰기" 의 상한이다.
    ///
    /// **왜 프로덕션 API 로 만들지 않았는가(의도적)**: 이 오브젝트는 설치본 180/191 의
    /// `general.properties`(= 유저 프로퍼티 스키마 전체)와 미독 키 8종 142건을 통째로 버린다.
    /// 그런 라이터를 `ProjectJSONBuilder` 에 공개하면 실물 `project.json` 을 덮어쓰는 순간
    /// **무통지 데이터 손실**이 된다. 소비자도 없다 — 쓰기 호출부는 `VideoImport.prepare` 하나뿐이고
    /// 그건 새 폴더에 최소 매니페스트를 **새로 만든다**(원문을 왕복시키지 않는다).
    /// 그래서 "왕복 가능성" 은 여기 테스트 안에서만 재고, 손실 수치를 위 테스트들이 못 박는다.
    private static func rewritableObject(_ p: WallpaperProject) -> [String: Any] {
        var out: [String: Any] = ["type": p.type.storageString, "title": p.title]
        if let f = p.fileName { out["file"] = f }
        if let v = p.previewName { out["preview"] = v }
        if !p.tags.isEmpty { out["tags"] = p.tags }
        if let c = p.contentRating { out["contentrating"] = c }
        if let w = p.workshopId { out["workshopid"] = w }
        if let d = p.dependency { out["dependency"] = d }
        if p.supportsAudioProcessing { out["general"] = ["supportsaudioprocessing": true] }
        if !p.presetOverrides.isEmpty {
            var preset: [String: Any] = [:]
            for (k, v) in p.presetOverrides {
                switch v {
                case .string(let s): preset[k] = s
                case .bool(let b): preset[k] = b
                case .number(let d): preset[k] = d
                case .none: continue      // 파서가 `NSNull` 을 버리므로 되쓰기에서도 안 낸다
                }
            }
            out["preset"] = preset
        }
        return out
    }

    /// 원문 바이트에서 최상위 키를 **등장 순서대로** 뽑는다(`JSONSerialization` 은 순서를 안 준다).
    /// 최상위 깊이의 `"이름":` 만 센다 — 설치본은 전건 들여쓰기된 다중행이라 이 스캔으로 충분하다.
    private static func topLevelKeysInFileOrder(_ data: Data) -> [String] {
        var keys: [String] = []
        var depth = 0
        var inString = false
        var escaped = false
        var current = ""
        var lastString: String?
        for byte in data {
            let c = Character(UnicodeScalar(byte))
            if inString {
                if escaped { escaped = false; current.append(c); continue }
                if c == "\\" { escaped = true; current.append(c); continue }
                if c == "\"" { inString = false; lastString = current; current = ""; continue }
                current.append(c)
                continue
            }
            switch c {
            case "\"": inString = true
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            case ":": if depth == 1, let s = lastString { keys.append(s) }
            default: break
            }
        }
        return keys
    }
}
