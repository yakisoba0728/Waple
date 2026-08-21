import XCTest
@testable import WapleCompatCore
import WapleCore

/// **두 스캐너가 같은 사실을 두 갈래로 계산하던 자리들** — 하나로 합친 뒤 그 합침을 못박는다.
///
/// 왜 이 파일이 새로 필요한가
/// --------------------------
/// `WapleCompatCore` 는 2026-08-19 에 라이브러리로 쪼개졌고, 2026-08-21 에야
/// `linux-render-typecheck.sh --compat` 의 타입체크 대상이 됐다. 그때까지 이 모듈의 테스트는
/// `DeepScanHelpersTests` **한 파일 8메서드**뿐이었고, 그 8개가 보는 것은
/// `Report.pct` · `DeepAgg.addSample` · `firstErrorToken`(3) · 언팩 마운트 1케이스 · `rawJSON` 관용
/// 파스 · 타임아웃 상수뿐이다. 즉 **프로젝트 레벨 판정 로직(`scanProject`/`scanProperties`/
/// `scanWeb`/코퍼스 열거)은 전부 무테스트**였고, 그 층이 바로 형제 스캐너
/// `WallpaperCompatibilityAnalyzer` 와 **중복**인 층이다(`docs/re/compatibility-analyzer.md` §5).
/// 중복 + 무테스트 = 조용히 갈린다. 실제로 갈려 있었다.
///
/// **이 타깃은 리눅스에서 실행되지 않는다**(`import Metal`/`AVFoundation`/`WapleRender`).
/// 리눅스에서는 `--compat` 이 타입체크만 하고, 실제 실행은 macOS CI 가 처음 한다.
/// 그래서 여기 담는 것은 **GPU·실물 코퍼스 없이 판정 가능한 순수 로직**뿐이다 — 합성 폴더와
/// 문자열만 쓴다. 실물 도달 수치는 `WapleCoreTests/WallpaperCompatibilityCorpusAuditTests`
/// (리눅스에서도 돈다)가 따로 고정한다.
final class CompatCoreParityTests: XCTestCase {

    // MARK: 하네스

    private var roots: [URL] = []

    private func makeRoot(_ name: String = "CompatParity") -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        roots.append(url)
        return url
    }

    override func tearDown() {
        for r in roots { try? FileManager.default.removeItem(at: r) }
        roots = []
        super.tearDown()
    }

    @discardableResult
    private func writeProject(_ dir: URL, _ json: String, extra: [String: String] = [:]) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(json.utf8).write(to: dir.appendingPathComponent("project.json"))
        for (name, body) in extra {
            // 컴포넌트를 하나씩 붙인다 — `appendingPathComponent("js/main.js")` 한 방은
            // Foundation 구현에 따라 `/` 를 퍼센트 인코딩할 수 있어(리눅스/맥 갈림) 못 믿는다.
            var target = dir
            for part in name.split(separator: "/").map(String.init) {
                target = target.appendingPathComponent(part)
            }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? Data(body.utf8).write(to: target)
        }
        return dir
    }

    private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }
    private func path(_ url: URL) -> String { url.standardizedFileURL.path }

    /// `base/a/b` — 컴포넌트를 하나씩 붙인다(위 `writeProject` 와 같은 이유).
    private func sub(_ base: URL, _ relative: String) -> URL {
        var out = base
        for part in relative.split(separator: "/").map(String.init) {
            out = out.appendingPathComponent(part, isDirectory: true)
        }
        return out
    }

    // MARK: - ① 코퍼스 열거 — 사본 셋을 하나로

    /// 종전에는 "루트에서 프로젝트 폴더를 찾는" 규칙이 **세 벌**이었다:
    /// `WallpaperCompatibilityAnalyzer`(정본) · `DeepScan.projectContainer/projectFolders` ·
    /// `SnapshotPipeline.sceneContainer`. 앞의 둘은 글자만 다르고 뜻이 같았지만 **셋째는 첫
    /// 분기를 빼먹은 채 주석에 "DeepScan 과 동일 규칙" 이라고 적혀 있었다** — 아래 ⓓ 케이스가
    /// 그것이다. 지금은 셋 다 같은 함수를 부르므로, 이 테스트는 그 전달을 못박는다.
    ///
    /// 네 배치 전부 설치본/동봉 도달은 다음과 같다(합성 케이스가 아니라 실물 기준):
    ///   ⓐ 개발 루트(`<root>/backgrounds/*`) — 설치본 0(설치본은 `assets/`·`projects/` 배치다),
    ///     실물 개발 코퍼스 `~/Downloads/wallpaper_dev` 가 이 모양이다(이 컨테이너에는 없다).
    ///   ⓑ 프로젝트 폴더들의 부모 — 설치본 `assets/`·`projects/` 하위에서 실제로 쓰이는 배치.
    ///   ⓒ 단일 프로젝트 폴더 — 설치본 191건 전부가 이 모드로 감사된다.
    ///   ⓓ `backgrounds` 라는 **이름의 프로젝트 폴더** — 설치본·동봉 **0건**. 그래서 종전
    ///     `SnapshotPipeline` 의 어긋남이 아무한테도 안 잡혔다.
    func testCorpusEnumerationIsOneRuleAcrossAllThreeScanners() throws {
        // ⓐ 개발 루트 배치
        let devRoot = makeRoot("DevRoot")
        writeProject(sub(devRoot, "backgrounds/aaa"), #"{"type":"scene","file":"scene.json"}"#)
        writeProject(sub(devRoot, "backgrounds/bbb"), #"{"type":"scene","file":"scene.json"}"#)

        // ⓑ 프로젝트 폴더들의 부모(backgrounds 없음)
        let flatRoot = makeRoot("FlatRoot")
        writeProject(flatRoot.appendingPathComponent("p1"), #"{"type":"scene","file":"scene.json"}"#)
        writeProject(flatRoot.appendingPathComponent("p2"), #"{"type":"web","file":"index.html"}"#)

        // ⓒ 단일 프로젝트 폴더
        let single = makeRoot("Single")
        writeProject(single, #"{"type":"scene","file":"scene.json"}"#)

        // ⓓ `backgrounds` 가 프로젝트 폴더 이름인 루트
        let odd = makeRoot("OddRoot")
        writeProject(odd.appendingPathComponent("backgrounds"), #"{"type":"scene","file":"scene.json"}"#)
        writeProject(odd.appendingPathComponent("zzz"), #"{"type":"scene","file":"scene.json"}"#)

        for root in [devRoot, flatRoot, single, odd] {
            let canonical = WallpaperCompatibilityAnalyzer.projectContainerURL(for: root)
            XCTAssertEqual(path(DeepScan.projectContainer(root)), path(canonical),
                           "DeepScan 이 형제 스캐너와 다른 컨테이너를 고른다: \(root.lastPathComponent)")
            XCTAssertEqual(path(SnapshotPipeline.sceneContainer(root: root.path)), path(canonical),
                           "SnapshotPipeline 이 형제 스캐너와 다른 컨테이너를 고른다: \(root.lastPathComponent)")

            let expected = try WallpaperCompatibilityAnalyzer.projectFolders(in: canonical)
            XCTAssertEqual(names(DeepScan.projectFolders(canonical)), names(expected),
                           "DeepScan 폴더 열거가 갈렸다: \(root.lastPathComponent)")
        }

        // 규칙 자체도 못박는다 — 전달만 검사하면 정본이 통째로 틀려도 초록이다.
        XCTAssertEqual(names(DeepScan.projectFolders(DeepScan.projectContainer(devRoot))), ["aaa", "bbb"])
        XCTAssertEqual(names(DeepScan.projectFolders(DeepScan.projectContainer(flatRoot))), ["p1", "p2"])
        XCTAssertEqual(names(DeepScan.projectFolders(DeepScan.projectContainer(single))),
                       [single.lastPathComponent], "컨테이너 자신이 프로젝트면 자기 하나")
        // ⓓ: `backgrounds` 는 프로젝트지 컨테이너가 아니다 — 컨테이너는 root, 후보는 둘 다.
        XCTAssertEqual(names(DeepScan.projectFolders(DeepScan.projectContainer(odd))), ["backgrounds", "zzz"],
                       "backgrounds 라는 이름의 프로젝트 폴더를 컨테이너로 오인하면 자기 자신이 사라진다")
    }

    /// 못 읽는 디렉터리는 **"프로젝트 0개" 와 다른 사건**이다. 정본은 던지고, DeepScan 은
    /// 자체 0건 가드가 있어 삼킨다 — 그 비대칭이 의도임을 못박는다(조용한 `[]` 가 CI 성공
    /// 오인의 고전적 경로다: F150/F151/F520 이 반복해서 막은 자리).
    func testMissingContainerThrowsInAnalyzerButIsSwallowedByDeepScan() {
        let missing = makeRoot("Missing").appendingPathComponent("nope", isDirectory: true)
        XCTAssertThrowsError(try WallpaperCompatibilityAnalyzer.projectFolders(in: missing))
        XCTAssertEqual(DeepScan.projectFolders(missing), [])
    }

    // MARK: - ② 표시 조건 사다리 — 술어 둘을 하나로

    /// 종전: 분석기 `canEvaluate(c)` / DeepScan `canEvaluate(c) && evaluate(c, values:) != nil`.
    /// 두 술어가 다른 것을 재는데 이름도 주석도 그 차이를 말하지 않았다.
    func testConditionSupportLadder() {
        typealias Support = WallpaperCompatibilityAnalyzer.PropertyConditionSupport
        func support(_ c: String?, _ v: [String: PropertyValue] = [:]) -> Support {
            WallpaperCompatibilityAnalyzer.conditionSupport(c, values: v)
        }
        // 조건 없음 — WE 템플릿이 `!property.condition || evalCondition(...)` 라 빈 문자열은
        // JS falsy → evalCondition 을 아예 부르지 않는다. 설치본 도달 1건(dino_run/god_rays).
        XCTAssertEqual(support(nil), .absent)
        XCTAssertEqual(support(""), .absent)
        XCTAssertEqual(support("   \t "), .absent, "공백뿐인 조건도 조건이 아니다")

        // 평가 가능 — 실물 설치본에 있는 형태.
        XCTAssertEqual(support("showbottom.value > 0", ["showbottom": .number(1)]), .evaluated)
        XCTAssertEqual(support("style.value=='1'", ["style": .string("1")]), .evaluated)
        // 값 사전이 비어도 파스는 정확하다 — 그래서 분석기는 경고를 내지 않는다.
        XCTAssertNotEqual(support("showbottom.value > 0"), .unsupported)

        // 미지원 문법 — 파서가 정확히 못 읽는다. 두 문자열 모두 형제 스위트가 이미
        // `XCTAssertFalse(PropertyConditionEvaluator.canEvaluate(...))` 로 고정한 것들이라
        // (`WapleCoreTests` 의 `PropertyConditionEvaluatorTests` · `TranslationEvalFixRegressionTests`)
        // 여기서 새로 추측한 값이 아니다.
        XCTAssertEqual(support("enabled.value =="), .unsupported, "우변이 없는 비교")
        // F423/F694: 최상위 삼항의 갈래가 대입식이면 근사값을 쓰되 exact=false → 경고 대상.
        XCTAssertEqual(support("en.value && !(t.value == 1) ? e.text = 'x' : false"), .unsupported)
    }

    /// 사다리가 실제로 DeepScan 집계에 그대로 연결되는지 — 두 카운터의 의미를 못박는다.
    func testScanPropertiesCountsConditionsThroughTheSharedLadder() {
        let properties: [String: Any] = [
            // 조건 없음(빈 문자열) — 세지 않는다.
            "a": ["type": "bool", "value": true, "condition": ""] as [String: Any],
            // 평가 가능 — total + evaluable
            "b": ["type": "slider", "value": 0.5, "condition": "a.value"] as [String: Any],
            // 미지원 — total 만 (`canEvaluate=false` 는 형제 스위트가 이미 고정한 문자열)
            "c": ["type": "color", "value": "1 1 1", "condition": "enabled.value =="] as [String: Any],
            // 조건 키 자체가 없다
            "d": ["type": "combo", "value": "x"] as [String: Any],
        ]
        let agg = DeepAgg()
        DeepScan.scanProperties(raw: ["general": ["properties": properties] as [String: Any]], agg: agg)

        XCTAssertEqual(agg.propsProjects, 1)
        XCTAssertEqual(agg.conditionsTotal, 2, "빈 조건과 조건 부재는 분모에 안 들어간다")
        XCTAssertEqual(agg.conditionsEvaluable, 1)
        XCTAssertEqual(agg.propertyTypeCounts, ["bool": 1, "slider": 1, "color": 1, "combo": 1])
        XCTAssertEqual(agg.unsupportedPropertyTypes, [:], "넷 다 currentPropertyTypes 안에 있다")
    }

    /// 미지 타입 집계는 **형제 스캐너와 같은 집합**(`currentPropertyTypes`)을 봐야 한다 —
    /// 이건 이미 단일 소스지만, 참조가 끊기면 조용히 갈리므로 여기서 잡는다.
    func testScanPropertiesUnsupportedTypesUseTheAnalyzerSet() {
        // WE 스키마엔 있는데 Waple 집합엔 없는 셋 — 설치본/동봉 도달 0건이지만
        // 워크샵 코퍼스에서는 실재한다(여기서 측정 불가).
        let properties: [String: Any] = [
            "v": ["type": "volume", "value": 1] as [String: Any],
            "l": ["type": "combolutfilters", "value": "none"] as [String: Any],
            "hr": ["type": "divider"] as [String: Any],
            // 양쪽 다에 있는 것
            "c": ["type": "color", "value": "1 1 1"] as [String: Any],
        ]
        let agg = DeepAgg()
        DeepScan.scanProperties(raw: ["general": ["properties": properties] as [String: Any]], agg: agg)
        XCTAssertEqual(agg.unsupportedPropertyTypes, ["volume": 1, "combolutfilters": 1, "divider": 1])
        for t in agg.unsupportedPropertyTypes.keys {
            XCTAssertFalse(WallpaperCompatibilityAnalyzer.currentPropertyTypes.contains(t))
            XCTAssertTrue(WallpaperCompatibilityAnalyzer.weBrowserPropertyTypes.contains(t),
                          "\(t) 는 WE 스키마에는 있는 타입이다 — 경고는 우연히 맞는 것이지 근거가 아니다")
        }
    }

    // MARK: - ③ WE 브라우저 프로퍼티 타입 스키마 — §3.3 실측을 코드로 고정

    /// `docs/re/compatibility-analyzer.md` §3.3 의 표를 코드로 굳힌다. 근거는 설치본
    /// `ui/dist/scripts/scripts.js` 한 파일이고, 2026-08-21 에 독립적으로 다시 떴다:
    ///   · `views/includes/browseruserproperties.html`(char [750195,757420), 7,225자) 의
    ///     `ng-if` **13자리 · 고유 12종** — `color` 만 `===`, `volume` 만 두 자리.
    ///   · **형제 `browseruserpropertiesgroup.html`(484바이트)에는 타입 비교가 0건이다.**
    ///     `group` 을 아는 것은 JS 컨트롤러(byte @88625 `"group"===l.type`)다.
    /// → 브라우저 패널이 아는 타입 총 **13종**.
    func testWEBrowserPropertyTypeSchemaIsThirteen() {
        let we = WallpaperCompatibilityAnalyzer.weBrowserPropertyTypes
        XCTAssertEqual(we.count, 13, "템플릿 12 + JS 컨트롤러의 group 1")
        XCTAssertEqual(we.sorted(), [
            "bool", "color", "combo", "combolutfilters", "directory", "divider", "file",
            "group", "scenetexture", "slider", "textinput", "usershortcut", "volume",
        ])
        // 종전 문서·주석이 흔들렸던 두 수를 못박는다.
        XCTAssertEqual(we.subtracting(["group"]).count, 12, "템플릿 분기 고유 타입은 12종")
        XCTAssertTrue(we.contains("divider"),
                      "divider 는 벽지 유저 프로퍼티 타입이 맞다 — droplist/에디터 인스펙터/컨텍스트 메뉴의 동명 타입과 헷갈리지 말 것")
    }

    /// 두 집합의 차이는 **양방향**이고 어느 쪽도 근거가 없다(§3.3). 차이가 움직이면 근거가
    /// 바뀐 것이므로 사람이 다시 봐야 한다 — 그래서 수가 아니라 **원소**를 고정한다.
    /// 설치본 191 + 동봉 170 에 등장하는 타입은 `color·slider·combo·bool` 넷뿐이라
    /// 아래 7종 전부 **코퍼스 도달 0건**이다.
    func testPropertyTypeSetDifferenceIsPinnedInBothDirections() {
        XCTAssertEqual(WallpaperCompatibilityAnalyzer.wePropertyTypesMissingFromWaple.sorted(),
                       ["combolutfilters", "divider", "volume"],
                       "실물이 쓰면 경고가 나간다 — PropertyControl.kind 가 셋 다 .displayOnly 라 우연히 맞다")
        XCTAssertEqual(WallpaperCompatibilityAnalyzer.waplePropertyTypesNotInWESchema.sorted(),
                       ["checkbox", "label", "text", "texture"],
                       "checkbox=템플릿옵션/플러그인설정 · texture=씬에디터 인스펙터 · text/label=근거 0건")
        XCTAssertEqual(WallpaperCompatibilityAnalyzer.currentPropertyTypes.count, 14)
    }

    // MARK: - ④ 웹 브리지 신호 — 탐지 문자열 사본 둘을 하나로

    /// 종전: 분석기 10종 / `DeepScan.scanWeb` **2종**. 같은 벽지를 두 스캐너에 물리면 서로 다른
    /// 얘기를 했고 어느 쪽이 정본인지 코드에 안 적혀 있었다. 이제 문자열은 한 벌뿐이다.
    func testWebBridgeSignalDetectionIsOneTable() {
        let samples: [(WebBridgeSignal, String)] = [
            (.propertyListener, "window.wallpaperPropertyListener = {};"),
            (.webLifecycle, "function wallpaperWillGoBackground(){}"),
            (.serviceWorker, "navigator.ServiceWorker.register('sw.js')"),
            (.randomFile, "window.wallpaperRequestRandomFileForProperty('bg', cb)"),
            (.pluginBridge, "window.wallpaperPluginListener = { onPluginLoaded: f };"),
            (.audioListener, "window.wallpaperRegisterAudioListener(f)"),
            (.mediaIntegration, "window.wallpaperRegisterMediaStatusListener(f)"),
            (.webGL, "var gl = c.getContext('webgl');"),
            (.fileURL, "img.src = 'file:///C:/x.png';"),
        ]
        XCTAssertEqual(samples.count, WebBridgeSignal.allCases.count, "신호를 더하면 표본도 더해라")
        for (expected, text) in samples {
            let hit = WebBridgeSignal.signals(in: text)
            XCTAssertTrue(hit.contains(expected), "\(expected.rawValue) 를 못 잡았다: \(text)")
        }
        // 아무 신호도 없는 텍스트 — 오탐 대조.
        XCTAssertEqual(WebBridgeSignal.signals(in: "<html><body>hello</body></html>"), [])
        // `wallpaperMedia` 부분일치는 `wallpaperMediaIntegration` 도 잡는다(webwallpaper64.exe 실측 13종 중 하나).
        XCTAssertTrue(WebBridgeSignal.signals(in: "wallpaperMediaIntegration").contains(.mediaIntegration))
    }

    /// 어떤 신호가 **이슈로 승격**되는지 — 승격 기준은 "Waple 브리지가 그 이름을 정의하지
    /// 않거나 파리티가 불확실할 때" 다. 태그로만 남는 넷은 브리지가 실제로 구현한다.
    func testWebBridgeSignalIssuePromotionIsPinned() {
        let promoted = WebBridgeSignal.allCases.filter { $0.issueCode != nil }
        XCTAssertEqual(promoted.map(\.rawValue).sorted(),
                       ["audioListener", "mediaIntegration", "pluginBridge", "randomFile", "serviceWorker"])
        XCTAssertEqual(WebBridgeSignal.pluginBridge.issueCode, .webPluginBridge)
        XCTAssertEqual(WebBridgeSignal.serviceWorker.issueCode, .webServiceWorker)
        for s in promoted {
            XCTAssertFalse(s.issueMessage.isEmpty, "\(s.rawValue) 승격 문구가 비었다")
        }
        for s in WebBridgeSignal.allCases where s.issueCode == nil {
            XCTAssertTrue(s.issueMessage.isEmpty)
        }
    }

    /// `DeepScan.scanWeb` 의 두 카운터가 정말 그 표를 타는지 — 그리고 **엔트리 파일 하나만
    /// 읽는다**는 남은 차이도 함께 못박는다(분석기는 최대 64파일/2MB 를 따라간다).
    /// 설치본 web 2/2 가 정확히 이 모양이다: 엔트리는 `index.html` 이고 신호는 하위 `js/` 에 있다.
    func testScanWebReadsOnlyTheEntryFileAndUsesTheSharedTable() {
        let root = makeRoot("Web")
        let folder = writeProject(root.appendingPathComponent("w1"), #"{"type":"web","file":"index.html"}"#, extra: [
            "index.html": "<script src=\"js/main.js\"></script>",
            "js/main.js": "window.wallpaperRequestRandomFileForProperty('x', f); navigator.serviceWorker.register('sw');",
        ])
        let raw = DeepScan.rawJSON(folder.appendingPathComponent("project.json"))!
        let project = ProjectJSONParser.parse(json: raw, folderURL: folder)

        let agg = DeepAgg()
        XCTAssertTrue(DeepScan.scanWeb(folder, project: project, agg: agg))
        XCTAssertEqual(agg.webTotal, 1)
        XCTAssertEqual(agg.webIndexPresent, 1)
        XCTAssertEqual(agg.webRandomFile, 0, "엔트리 파일만 읽는다 — 이게 형제 스캐너와 남은 차이다")
        XCTAssertEqual(agg.webServiceWorker, 0)

        // 같은 신호가 엔트리 자체에 있으면 잡힌다(표가 실제로 연결돼 있다는 양성 대조).
        let inline = writeProject(root.appendingPathComponent("w2"), #"{"type":"web","file":"index.html"}"#, extra: [
            "index.html": "<script>window.wallpaperRequestRandomFileForProperty('x', f);" +
                          "navigator.serviceWorker.register('sw');</script>",
        ])
        let raw2 = DeepScan.rawJSON(inline.appendingPathComponent("project.json"))!
        let agg2 = DeepAgg()
        XCTAssertTrue(DeepScan.scanWeb(inline, project: ProjectJSONParser.parse(json: raw2, folderURL: inline), agg: agg2))
        XCTAssertEqual(agg2.webRandomFile, 1)
        XCTAssertEqual(agg2.webServiceWorker, 1)

        // 엔트리가 없으면 미지원(그리고 신호는 0).
        let broken = writeProject(root.appendingPathComponent("w3"), #"{"type":"web","file":"gone.html"}"#)
        let raw3 = DeepScan.rawJSON(broken.appendingPathComponent("project.json"))!
        let agg3 = DeepAgg()
        XCTAssertFalse(DeepScan.scanWeb(broken, project: ProjectJSONParser.parse(json: raw3, folderURL: broken), agg: agg3))
        XCTAssertEqual(agg3.webIndexPresent, 0)
    }

    // MARK: - ⑤ preset 의존 — 여기만 런타임과 같고 형제 스캐너가 느슨하다

    /// F137/F411 로직. **분석기는 존재만 보고 DeepScan 은 마운트 가능한 타입까지 본다** —
    /// 런타임(`PresetResolver` + `RendererFactory`)이 후자와 같으므로 이 파일이 정본이다
    /// (분석기 쪽이 거짓 음성; 설치본 preset 0건이라 도달 0 — `docs/re/…` §7-4).
    /// 그 "더 엄격한" 판정이 지금까지 무테스트였다.
    func testPresetDependencyResolvesByIDOrFolderAndRequiresMountableType() {
        let root = makeRoot("Preset")
        func scan(_ name: String, _ json: String, known: [String: WallpaperType]) -> DeepAgg {
            let folder = writeProject(root.appendingPathComponent(name), json)
            let agg = DeepAgg()
            DeepScan.scanProject(folder, assetsDir: nil, knownTypes: known, agg: agg)
            return agg
        }
        // ⓐ 폴더명으로 해소
        var agg = scan("p1", #"{"type":"preset","dependency":"targetfolder"}"#,
                       known: ["targetfolder": .scene])
        XCTAssertEqual(agg.presetTotal, 1)
        XCTAssertEqual(agg.presetResolved, 1)
        XCTAssertEqual(agg.projTypeSupported["preset"], 1)

        // ⓑ workshopid(project id)로 해소 — F411 이 형제 스캐너에서 고친 것과 같은 사고.
        //    F194 이후 project id 는 `workshopid ?? 폴더명` 이라 둘이 다를 수 있다.
        agg = scan("p2", #"{"type":"preset","dependency":"1234567890"}"#, known: ["1234567890": .video])
        XCTAssertEqual(agg.presetResolved, 1)

        // ⓒ 존재하지만 마운트 불가 타입 — 런타임이 실패하므로 미해소가 맞다.
        for badType in [WallpaperType.application, .preset, .unknown("weird")] {
            agg = scan("p3-\(badType.storageString)", #"{"type":"preset","dependency":"dep"}"#, known: ["dep": badType])
            XCTAssertEqual(agg.presetTotal, 1)
            XCTAssertEqual(agg.presetResolved, 0, "\(badType.storageString) 의존은 런타임에서 못 연다")
            XCTAssertNil(agg.projTypeSupported["preset"])
        }

        // ⓓ 코퍼스에 없음 / 의존 키 자체가 없음
        agg = scan("p4", #"{"type":"preset","dependency":"nope"}"#, known: ["other": .scene])
        XCTAssertEqual(agg.presetResolved, 0)
        agg = scan("p5", #"{"type":"preset"}"#, known: ["other": .scene])
        XCTAssertEqual(agg.presetTotal, 1)
        XCTAssertEqual(agg.presetResolved, 0)
    }

    /// `scanProject` 의 나머지 디스패치 — `type` 별로 어디로 가고 무엇이 집계되는가.
    /// (씬/비디오는 자산 디코드가 붙으므로 여기서는 **분류만** 본다.)
    func testScanProjectClassifiesInvalidAndApplicationWithoutCrashing() {
        let root = makeRoot("Dispatch")
        // project.json 이 JSON 객체가 아니다 → "invalid" 로 세고 파스 OK 는 안 올린다.
        let bad = root.appendingPathComponent("bad", isDirectory: true)
        try? FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try? Data("not json at all".utf8).write(to: bad.appendingPathComponent("project.json"))
        let agg = DeepAgg()
        DeepScan.scanProject(bad, assetsDir: nil, knownTypes: [:], agg: agg)
        XCTAssertEqual(agg.projectJSONTotal, 1)
        XCTAssertEqual(agg.projectJSONOK, 0)
        XCTAssertEqual(agg.projTypeTotal["invalid"], 1)

        // application 은 렌더러가 없다 → 집계는 되지만 supported 아님(형제 스캐너의 .error 와 같은 뜻).
        let app = writeProject(root.appendingPathComponent("app"), #"{"type":"application","file":"a.exe"}"#)
        let agg2 = DeepAgg()
        DeepScan.scanProject(app, assetsDir: nil, knownTypes: [:], agg: agg2)
        XCTAssertEqual(agg2.projTypeTotal["application"], 1)
        XCTAssertNil(agg2.projTypeSupported["application"])
    }

    /// **CI 성공 오인 가드**(감사 V06). 루트 오타나 `--only` 오지정으로 프로젝트가 0개면
    /// "0건 리포트 + exit 0" 이 되어 CI 가 성공으로 읽는다 — F150/F151/F520 이 형제 모드에서
    /// 반복해서 막은 바로 그 경로다. `run` 의 셋째 반환값 `projectsFound` 가 그 신호이고,
    /// 지금까지 무테스트였다. 폴더가 0개면 `compileShaders`(Metal) 앞에서 빠져나오므로
    /// 이 테스트는 GPU 를 건드리지 않는다.
    func testRunSignalsProjectsNotFoundForBadRootOrBadOnlyFilter() {
        let empty = makeRoot("EmptyRoot")
        let r1 = DeepScan.run(rootPath: empty.path, only: nil)
        XCTAssertFalse(r1.projectsFound, "빈 루트를 '성공' 으로 돌려주면 CI 가 초록으로 읽는다")
        XCTAssertEqual(r1.unsupported, 0)
        XCTAssertTrue(r1.report.isEmpty)

        // 존재하지 않는 경로도 같은 신호.
        XCTAssertFalse(DeepScan.run(rootPath: empty.appendingPathComponent("nope").path, only: nil).projectsFound)

        // `--only` 가 아무 폴더에도 안 맞으면 역시 0개다(이쪽이 실제로 더 자주 난다).
        let withProject = makeRoot("OnlyFilter")
        writeProject(withProject.appendingPathComponent("realone"), #"{"type":"web","file":"index.html"}"#)
        XCTAssertFalse(DeepScan.run(rootPath: withProject.path, only: "typo").projectsFound)
    }

    // MARK: - ⑥ 스냅샷 파이프라인의 씬 열거 — 언팩 폴백

    /// 종전 규칙은 `scene.pkg`/`gifscene.pkg` **파일 존재**뿐이라 언팩 코퍼스에서 0개였다.
    /// WE 2.8.42 설치본 씬 **188/188**, 동봉 WEAssets **170/170** 이 전부 언팩이다.
    /// 폴백은 **pkg 가 0개일 때만** 돈다 — pkg 코퍼스의 결과를 바꾸지 않기 위해서다
    /// (그 결과가 곧 256×144 골든 매니페스트의 엔트리 집합이다).
    func testSceneFoldersFallsBackToProjectJSONOnlyWhenNoPackageExists() {
        // 전건 언팩 — 종전 0개, 지금은 열거된다.
        let unpacked = makeRoot("Unpacked")
        writeProject(sub(unpacked, "backgrounds/s1"),
                     #"{"type":"scene","file":"scene.json"}"#, extra: ["scene.json": "{}"])
        // `type` 생략 + `.json` 확장자 → ProjectJSONParser 의 확장자 추론으로 scene(G-E3-03).
        writeProject(sub(unpacked, "backgrounds/s2"),
                     #"{"file":"fantasticcar.json"}"#, extra: ["fantasticcar.json": "{}"])
        // 씬이 아닌 것은 제외돼야 한다.
        writeProject(sub(unpacked, "backgrounds/v1"), #"{"type":"video","file":"a.mp4"}"#)
        XCTAssertEqual(names(SnapshotPipeline.sceneFolders(root: unpacked.path)), ["s1", "s2"])

        // pkg 가 하나라도 있으면 **종전 동작 그대로** — 언팩 형제는 안 들어온다.
        let mixed = makeRoot("Mixed")
        let packed = sub(mixed, "backgrounds/packed")
        writeProject(packed, #"{"type":"scene","file":"scene.json"}"#, extra: ["scene.pkg": "PKG"])
        writeProject(sub(mixed, "backgrounds/loose"),
                     #"{"type":"scene","file":"scene.json"}"#, extra: ["scene.json": "{}"])
        XCTAssertEqual(names(SnapshotPipeline.sceneFolders(root: mixed.path)), ["packed"],
                       "pkg 코퍼스의 캡처 집합은 바뀌면 안 된다 — 골든 매니페스트가 그 집합이다")

        // 단일 씬 폴더 직접 지정(pkg) 도 종전대로.
        XCTAssertEqual(names(SnapshotPipeline.sceneFolders(root: packed.path)), [packed.lastPathComponent])
    }

    // MARK: - ⑦ 자산 경로 해석 — 렌더러와 같은 봉쇄 규약

    /// `PkgAssets.baseAssetURL` 은 렌더러의 `baseAssetURL` 사본이고, **루트 밖으로 나가면
    /// 안 된다**. 무테스트였다.
    func testPkgAssetsBaseAssetURLIsCaseInsensitiveAndContained() throws {
        let root = makeRoot("Assets")
        let pkgDir = root.appendingPathComponent("pkg", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)
        let materials = assets.appendingPathComponent("Materials", isDirectory: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: pkgDir.appendingPathComponent("scene.json"))
        try Data("{}".utf8).write(to: materials.appendingPathComponent("Glass.json"))
        try Data("secret".utf8).write(to: root.appendingPathComponent("outside.txt"))

        let pkg = try XCTUnwrap(ScenePackage.fromDirectory(pkgDir))
        let res = PkgAssets(package: pkg, assetsDir: assets)

        // 대소문자 무시 컴포넌트 순회 — WE 자산은 표기가 섞여 있다.
        XCTAssertNotNil(res.baseAssetURL("materials/glass.json"))
        XCTAssertNotNil(res.baseAssetURL("Materials/Glass.json"))
        // 없는 것은 nil
        XCTAssertNil(res.baseAssetURL("materials/nope.json"))
        // 루트 밖 탈출은 차단
        XCTAssertNil(res.baseAssetURL("../outside.txt"))
        XCTAssertNil(res.baseAssetURL("/etc/passwd"))
        // assetsDir 이 없으면 언제나 nil
        XCTAssertNil(PkgAssets(package: pkg, assetsDir: nil).baseAssetURL("materials/glass.json"))
    }

    // MARK: - ⑧ 잔챙이지만 회귀하면 조용한 것들

    func testFirstExistingReturnsTheFirstPresentPath() {
        let root = makeRoot("FirstExisting")
        let there = root.appendingPathComponent("here.txt")
        try? Data("x".utf8).write(to: there)
        let missing = root.appendingPathComponent("nope.txt")
        XCTAssertEqual(DeepScan.firstExisting([missing, there])?.lastPathComponent, "here.txt")
        XCTAssertEqual(DeepScan.firstExisting([there, missing])?.lastPathComponent, "here.txt")
        XCTAssertNil(DeepScan.firstExisting([missing]))
        XCTAssertNil(DeepScan.firstExisting([]))
    }

    /// 실패 표본 배열의 상한 — `addSample` 의 형제(딕셔너리 아닌 배열 판)이고 무테스트였다.
    func testAddSample2RespectsCap() {
        let agg = DeepAgg()
        var arr: [String] = []
        for i in 0..<20 { agg.addSample2(&arr, "p\(i)") }
        XCTAssertEqual(arr.count, 8, "기본 cap 8")
        XCTAssertEqual(arr.first, "p0", "먼저 온 것을 남긴다")
        var small: [String] = []
        for i in 0..<5 { agg.addSample2(&small, "q\(i)", cap: 2) }
        XCTAssertEqual(small, ["q0", "q1"])
    }
}
