import XCTest
@testable import WapleCompatCore
import WapleCore

/// `WapleCompatCore` 의 첫 테스트.
///
/// 이 타깃은 2026-08-19 에 처음 생겼다. 그전까지 `WapleCompat` 은 통째로 `.executableTarget`
/// 이라 **어떤 테스트 타깃도 의존할 수 없었고**(`grep -rn "import WapleCompat" Tests/` = 0건)
/// 1,799줄이 무테스트였다. 같은 원인으로 `SnapshotTests` 는 판정 수식을 베껴 자기 산수를
/// 단언했다 — 프로덕션 로직을 지워도 통과하는 상태였다.
///
/// 여기서는 **GPU·코퍼스 없이 판정 가능한 순수 로직**만 고정한다. 렌더 경로가 필요한 부분은
/// `WapleRenderTests` 의 실물 코퍼스 테스트가 맡는다.
final class DeepScanHelpersTests: XCTestCase {

    // MARK: Report.pct — 리포트 전체가 이 한 함수로 백분율을 만든다

    func testPercentFormatsAndGuardsZeroDenominator() {
        XCTAssertEqual(Report.pct(1, 2), "50.0%")
        XCTAssertEqual(Report.pct(0, 7), "0.0%")
        XCTAssertEqual(Report.pct(7, 7), "100.0%")
        XCTAssertEqual(Report.pct(1, 3), "33.3%", "소수 1자리 반올림")
        // 분모 0 은 0 나눗셈이 아니라 "n/a" 여야 한다 — 스캔 대상이 0건인 카테고리가 실제로 있다.
        XCTAssertEqual(Report.pct(0, 0), "n/a")
        XCTAssertEqual(Report.pct(5, 0), "n/a")
        XCTAssertEqual(Report.pct(3, -1), "n/a", "음수 분모도 n/a")
    }

    // MARK: DeepAgg.addSample — 실패 표본 수집의 상한

    func testAddSampleRespectsCapPerKey() {
        let agg = DeepAgg()
        var dict: [String: [String]] = [:]
        for i in 0..<10 { agg.addSample(&dict, "k", "p\(i)") }
        // 기본 cap 4 — 리포트가 표본 몇 개만 싣기 위한 것이고, 상한이 없으면 손상 코퍼스에서
        // 리포트가 통째로 표본 목록이 된다.
        XCTAssertEqual(dict["k"]?.count, 4)
        XCTAssertEqual(dict["k"], ["p0", "p1", "p2", "p3"], "먼저 온 것을 남긴다")

        // 키가 다르면 각각 센다.
        for i in 0..<3 { agg.addSample(&dict, "other", "q\(i)") }
        XCTAssertEqual(dict["other"]?.count, 3)
        XCTAssertEqual(dict["k"]?.count, 4, "다른 키가 서로의 상한을 먹으면 안 된다")

        // cap 을 명시하면 그 값을 따른다.
        var d2: [String: [String]] = [:]
        for i in 0..<5 { agg.addSample(&d2, "k", "p\(i)", cap: 1) }
        XCTAssertEqual(d2["k"], ["p0"])
    }

    // MARK: firstErrorToken — 셰이더 컴파일 실패 집계의 키

    func testFirstErrorTokenExtractsMessageAfterErrorMarker() {
        let log = """
        note: something benign
        /tmp/x.metal:12:5: error: use of undeclared identifier 'PerformLighting_V1'
        /tmp/x.metal:19:1: error: second error should be ignored
        """
        XCTAssertEqual(DeepScan.firstErrorToken(log),
                       "use of undeclared identifier 'PerformLighting_V1'",
                       "첫 error: 뒤 메시지만, 파일/행 접두는 버린다")
    }

    func testFirstErrorTokenFallsBackWhenNoErrorLine() {
        XCTAssertEqual(DeepScan.firstErrorToken("warning: nothing here\n"), "unknown")
        XCTAssertEqual(DeepScan.firstErrorToken(""), "unknown")
    }

    /// 집계 키로 쓰이므로 길이 상한이 있어야 한다 — 긴 진단 하나가 리포트 표를 부순다.
    func testFirstErrorTokenIsBounded() {
        let long = "x:1:1: error: " + String(repeating: "z", count: 500)
        XCTAssertEqual(DeepScan.firstErrorToken(long).count, 80)
    }

    // MARK: 언팩 씬 마운트 — 3차 웨이브 AB

    /// **종전 `scanScene` 은 `scene.pkg`/`gifscene.pkg` 가 없으면 곧장 `false` 였다.**
    /// WE 2.8.42 설치본 실측: 씬 프로젝트 **188/188 이 언팩**이고 두 루트 전체에 `.pkg` 가 0개다
    /// (`WapleCoreTests/WallpaperCompatibilityCorpusAuditTests` 가 그 분포를 고정한다). 즉 `--deep`
    /// 을 설치본에 겨누면 188건이 전부 "미지원" 으로 세어졌는데, 렌더러는 그 188건을 정상
    /// 마운트한다(`SceneRenderer.swift:1485`). 형제 스캐너는 G-E3-01/02 에서 이미 고쳤고 여기만
    /// 남아 있었다. 이 테스트는 GPU 없이 도는 CPU 경로만 탄다(엔트리에 tex/mdl/particle 이 없다).
    func testScanSceneMountsUnpackedFolderWithDeclaredFileName() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DeepScanMount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // `file` 이 관례 이름이 아니다 — 설치본의 ricepod/fantasticcar/techno/audiophile 4건 형태.
        try Data(#"{"type":"scene","file":"ricepod.json"}"#.utf8)
            .write(to: root.appendingPathComponent("project.json"))
        try Data("""
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"image":"models/layer.json"},{"particle":"particles/rain.json"}]}
        """.utf8).write(to: root.appendingPathComponent("ricepod.json"))

        let raw = try XCTUnwrap(DeepScan.rawJSON(root.appendingPathComponent("project.json")))
        let project = ProjectJSONParser.parse(json: raw, folderURL: root)
        let agg = DeepAgg()
        let supported = DeepScan.scanScene(root, project: project, assetsDir: nil, agg: agg)

        XCTAssertTrue(supported, "언팩 씬을 마운트하지 못하면 --deep --strict 가 전건을 미지원으로 센다")
        XCTAssertEqual(agg.sceneAttempt, 1)
        XCTAssertEqual(agg.sceneParseOK, 1, "SceneDocument 가 실제로 만들어져야 한다")
        XCTAssertEqual(agg.sceneSupported, 1)
    }

    /// 관용 JSON 배선 — 리더가 `AssetJSON` 을 타지 않으면 JSONC 자산에서 조용히 실패한다.
    /// 근거: WE 는 jsoncpp `allowComments`/`allowTrailingCommas` 를 둘 다 켠다(0x140091fe2·0x1400920b3).
    /// 실측: 자산 JSON 3,655개 중 63개가 JSONC 이고 그중 하나가 머티리얼
    /// (`defaultprojects/fantasticcar/materials/car/glass.json`, 줄 주석).
    func testRawJSONAcceptsCommentsAndTrailingCommas() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DeepScanJSONC-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{\r\n  \"type\": \"scene\", // 줄 주석\r\n  \"file\": \"scene.json\",\r\n}".utf8).write(to: url)
        let obj = try XCTUnwrap(DeepScan.rawJSON(url), "관용 파스가 안 걸리면 nil 이다")
        XCTAssertEqual(obj["type"] as? String, "scene")
        XCTAssertEqual(obj["file"] as? String, "scene.json")
    }

    // MARK: 상한 상수 — 회귀하면 무한 대기·무한 증가가 돌아온다

    func testTimeoutConstantsArePositiveAndFinite() {
        // F840-sweep: `sem.wait()` 무타임아웃을 고치며 도입했다. 0 이나 음수가 되면
        // 모든 비디오가 즉시 "재생 불가" 로 집계돼 스캔 결과가 조용히 뒤집힌다.
        XCTAssertGreaterThan(DeepScan.assetLoadTimeoutSeconds, 0)
        XCTAssertLessThanOrEqual(DeepScan.assetLoadTimeoutSeconds, 60,
                                 "상한이 너무 크면 타임아웃이 사실상 없는 것과 같다")
        XCTAssertGreaterThan(DeepScan.oggDecodeTimeBudget, 0)
    }

    // MARK: --inventory / --vis-blast 의 언팩 마운트 — 2026-08-25

    /// **`--inventory`/`--vis-blast` 는 언팩 코퍼스에서 전건 드롭하고도 exit 0 을 냈다.**
    ///
    /// `sceneFolders` 는 packed 가 0개면 `unpackedSceneFolders` 로 폴백하는데 그 폴백이 돌려주는
    /// 폴더는 **정의상 `.pkg` 가 없다**. 그런데 두 파이프라인은 `folder/scene.pkg` 를 직접 열고
    /// 실패하면 조용히 건너뛰었고, `folders.isEmpty` 가드는 폴더가 있으니 통과했다 —
    /// 결과가 `scenes=0` + exit 0 이다. 위 `scanScene` 이 3차 웨이브에서 고친 것과 **같은 결함**이
    /// 형제 둘에 남아 있었다.
    ///
    /// 여기서 잠그는 것은 마운트 **선택자**가 렌더러·DeepScan 과 같은 함수라는 것이다.
    func testProfileMountPackageOpensUnpackedFolderNotJustPkg() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProfileMount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // 관례 이름이 아닌 `file` — 설치본 4건이 이 형태다.
        try Data(#"{"type":"scene","file":"ricepod.json"}"#.utf8)
            .write(to: root.appendingPathComponent("project.json"))
        try Data("""
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"image":"models/layer.json"}]}
        """.utf8).write(to: root.appendingPathComponent("ricepod.json"))

        let pkg = try XCTUnwrap(ProfilePipeline.mountPackage(root),
                                "언팩 폴더를 못 열면 --inventory/--vis-blast 가 전건 드롭한다")
        // 선언된 `file` 이름으로 실제 바이트가 잡혀야 한다(엔트리 표가 루트 상대 경로다).
        XCTAssertNotNil(pkg.data(for: "ricepod.json"), "선언된 씬 파일이 패키지에서 조회돼야 한다")
    }

    /// negative control — **없는 `.pkg` 를 열었다고 우기지 않는다.**
    ///
    /// `resolveMountSource` 의 결정 순서상(선언 파일 실재 → stem `.pkg` 폴백 → legacy `.pkg` →
    /// `.directory`) `file: "scene.pkg"` 인데 그 파일이 없으면 마지막 `.directory` 로 떨어진다.
    /// 즉 마운트 자체는 서지만 **엔트리에 `scene.pkg` 는 없어야** 한다. 이게 깨지면 위 테스트의
    /// "언팩을 연다" 가 "아무거나 연다" 와 구별되지 않는다.
    func testProfileMountPackageDoesNotInventMissingPkgBytes() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProfileMountEmpty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"type":"scene","file":"scene.pkg"}"#.utf8)
            .write(to: root.appendingPathComponent("project.json"))

        let pkg = try XCTUnwrap(ProfilePipeline.mountPackage(root),
                                "폴더가 실재하므로 .directory 마운트는 서야 한다")
        XCTAssertNil(pkg.data(for: "scene.pkg"), "없는 pkg 바이트가 나오면 안 된다")
        XCTAssertNotNil(pkg.data(for: "project.json"), "폴더 마운트라면 실재하는 파일은 잡혀야 한다")
    }

    /// **전건 드롭은 성공이 아니다.** 진단 도구가 아무것도 못 읽고 exit 0 을 내면
    /// CI 나 사람이 "돌렸고 통과했다" 로 읽는다 — 이 리포가 반복해서 잡아내는 그 부류다.
    func testReportDropsFailsOnlyWhenNothingWasRead() {
        // 하나도 못 읽음 → 2
        XCTAssertEqual(ProfilePipeline.reportDrops(tag: "t", rows: 0, folders: 16,
                                                   dropped: (1...16).map { "s\($0)" }), 2)
        // 일부 드롭 → 0 (부분 코퍼스는 정상 상황)
        XCTAssertEqual(ProfilePipeline.reportDrops(tag: "t", rows: 12, folders: 16,
                                                   dropped: ["a", "b", "c", "d"]), 0)
        // 드롭 없음 → 0
        XCTAssertEqual(ProfilePipeline.reportDrops(tag: "t", rows: 16, folders: 16, dropped: []), 0)
        // 경계: 폴더가 0개면 드롭도 0이라 판정 대상이 아니다(그 자리는 F520 가드가 먼저 잡는다).
        XCTAssertEqual(ProfilePipeline.reportDrops(tag: "t", rows: 0, folders: 0, dropped: []), 0)
    }
}
