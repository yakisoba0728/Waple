import XCTest
@testable import WapleCore

/// `WallpaperCompatibilityAnalyzer` 의 씬 마운트 규약이 **렌더러와 일치**하는지 고정한다.
///
/// 이 스캐너의 계약은 "이슈 없음 = 렌더 가능" 이다. 그래서 렌더러(`SceneRenderer.mount`)와
/// 마운트 규약이 갈리면 계약이 **양방향으로** 거짓이 된다. 수정 전 실측(리눅스 드라이버, 6케이스):
///
///     케이스              수정 전                          수정 후
///     odd-unpacked       features=[]                      전 피처 검출
///     plain-unpacked     features=[]                      전 피처 검출
///     notype-unpacked    features=[]                      전 피처 검출
///     odd-packed         error/missingScenePackage ←거짓  이슈 없음
///     badjson-unpacked   이슈 없음 ←거짓                  error/missingScenePackage
///     broken-unpacked    error/missingScenePackage        (동일)
///
/// 즉 ① 언팩 씬은 **한 건도 검사되지 않았고**(설치본 실측 188/188 이 언팩), ② 이름이 관례가
/// 아닌 씬은 렌더러가 정상으로 여는데 "렌더 불가" 로 단정됐으며, ③ 깨진 씬이 무이슈로 통과했다.
final class WallpaperCompatibilitySceneMountTests: XCTestCase {
    private static let sceneBody = """
    {"general":{"orthogonalprojection":{"width":100,"height":100}},
     "objects":[{"image":"models/layer.json"},{"particle":"particles/rain.json"},{"light":"lpoint"}]}
    """

    /// ① 언팩 + `file` 이 관례 이름이 아닌 씬(설치본 `ricepod`/`fantasticcar` 형태).
    func testUnpackedSceneWithNonConventionalFileNameIsAnalyzed() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFolder(root, "odd-unpacked",
                        project: #"{"type":"scene","file":"ricepod.json"}"#,
                        files: ["ricepod.json": Self.sceneBody])

        let p = try project(in: root, id: "odd-unpacked")
        XCTAssertEqual(p.issues.filter { $0.severity == .error }.count, 0, "\(p.issues)")
        XCTAssertTrue(p.detectedFeatures.contains("sceneLayer"), p.detectedFeatures.description)
        XCTAssertTrue(p.detectedFeatures.contains("sceneParticle"), p.detectedFeatures.description)
        XCTAssertTrue(p.detectedFeatures.contains("sceneLight"), p.detectedFeatures.description)
    }

    /// ① 관례 이름이어도 **언팩이면** 종전엔 통째로 안 봤다 — 이쪽이 도달 범위의 대부분이다.
    func testUnpackedSceneWithConventionalFileNameIsAnalyzed() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFolder(root, "plain-unpacked",
                        project: #"{"type":"scene","file":"scene.json"}"#,
                        files: ["scene.json": Self.sceneBody])

        let p = try project(in: root, id: "plain-unpacked")
        XCTAssertEqual(p.issues.filter { $0.severity == .error }.count, 0, "\(p.issues)")
        XCTAssertTrue(p.detectedFeatures.contains("sceneLayer"), p.detectedFeatures.description)
    }

    /// ① `type` 생략 → `ProjectJSONParser` 확장자 추론으로 `.scene`(설치본 `techno`/`audiophile`).
    func testUnpackedSceneWithInferredTypeIsAnalyzed() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFolder(root, "notype-unpacked",
                        project: #"{"file":"techno.json"}"#,
                        files: ["techno.json": Self.sceneBody])

        let p = try project(in: root, id: "notype-unpacked")
        XCTAssertEqual(p.type, "scene", "확장자 추론이 깨지면 이 케이스 자체가 무의미해진다")
        XCTAssertTrue(p.detectedFeatures.contains("sceneLayer"), p.detectedFeatures.description)
    }

    /// ② **거짓 치명** — 패키지 엔트리 이름이 관례가 아니면 "SceneDocument 를 만들 수 없다" 고
    /// 단정했다. 렌더러는 `project.fileName` 으로 정상 해소한다(SceneRenderer.swift:1246).
    func testPackagedSceneWithNonConventionalEntryNameIsNotFalselyBlocked() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeFolder(root, "odd-packed",
                                     project: #"{"type":"scene","file":"ricepod.json"}"#,
                                     files: [:])
        try Self.makePkg([("ricepod.json", Data(Self.sceneBody.utf8))])
            .write(to: folder.appendingPathComponent("scene.pkg"))

        let p = try project(in: root, id: "odd-packed")
        XCTAssertFalse(p.isBlocked, "\(p.issues)")
        XCTAssertTrue(p.detectedFeatures.contains("sceneLayer"), p.detectedFeatures.description)
    }

    /// ③ **거짓 통과** — 언팩 씬의 문서가 깨져 있으면 렌더러는 마운트에 실패한다. 종전엔 이슈
    /// 없이 통과했다(= "이슈 없음 = 렌더 가능" 계약이 이 경로에서 깨져 있었다).
    func testUnpackedSceneWithUnparsableDocumentIsReported() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFolder(root, "badjson-unpacked",
                        project: #"{"type":"scene","file":"scene.json"}"#,
                        files: ["scene.json": "{ this is not json"])

        let p = try project(in: root, id: "badjson-unpacked")
        XCTAssertTrue(p.issues.contains { $0.code == .missingScenePackage && $0.severity == .error },
                      "\(p.issues)")
    }

    /// 선행 판정(`analyzeTypeAndFiles`)과 **중복 보고하지 않는다** — 파일이 아예 없는 경우에만
    /// 두 판정이 겹친다. 겹칠 때 남는 것은 먼저 나온 한 건이다.
    func testMissingSceneDocumentIsReportedExactlyOnce() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeFolder(root, "broken-unpacked",
                        project: #"{"type":"scene","file":"scene.json"}"#,
                        files: ["readme.txt": "not json"])

        let p = try project(in: root, id: "broken-unpacked")
        XCTAssertEqual(p.issues.filter { $0.code == .missingScenePackage }.count, 1, "\(p.issues)")
    }

    // MARK: - ④ 마운트 **선택자** 파리티 (3차 웨이브 AB)
    //
    // 위 ①~③ 은 "폴더도 마운트한다" 를 고정하지만, **무엇을 마운트할지 고르는 함수**가 같은지는
    // 보지 않는다. 렌더러는 2026-08-21 부터 `ScenePackage.resolveMountSource`(SceneRenderer:1454)
    // 를 쓰는데 스캐너만 `scene.pkg`/`gifscene.pkg` 이름 존재로 골랐다. 아래 셋은 그 시점부터
    // 스캐너와 렌더러가 **다른 파일을 열던** 자리다. `check_scene_mount_parity.py` 는 이 셋을
    // 보지 않는다(그 게이트가 보는 것은 후보 이름 리스트와 `fromDirectory` 존재뿐이다).

    /// ④-a `file:"techno.json"` 부재 + `techno.pkg` 존재 → WE/렌더러는 **pkg** 를 연다.
    /// 종전 스캐너는 관례 이름 두 개만 찾아 못 보고 폴더로 떨어져 **거짓 치명**을 냈다.
    func testSiblingPkgOfDeclaredFileIsMountedLikeRenderer() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeFolder(root, "sibling-pkg",
                                     project: #"{"type":"scene","file":"techno.json"}"#,
                                     files: [:])
        try Self.makePkg([("techno.json", Data(Self.sceneBody.utf8))])
            .write(to: folder.appendingPathComponent("techno.pkg"))

        XCTAssertEqual(ScenePackage.resolveMountSource(folderURL: folder, fileName: "techno.json"),
                       .package(folder.appendingPathComponent("techno.pkg")),
                       "전제가 깨지면 이 테스트는 무의미하다")
        let p = try project(in: root, id: "sibling-pkg")
        XCTAssertFalse(p.isBlocked, "\(p.issues)")
        XCTAssertTrue(p.detectedFeatures.contains("sceneLayer"), p.detectedFeatures.description)
    }

    /// ④-b `Scene.pkg` — 대소문자만 다른 표기. `legacyPackageURL` 은 잡고 종전 스캐너는 놓쳤다.
    /// (리눅스/대소문자 구분 APFS 에서만 서로 다른 이름이다.)
    func testCaseVariantPackageNameIsMountedLikeRenderer() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try writeFolder(root, "case-pkg",
                                     project: #"{"type":"scene","file":"scene.json"}"#,
                                     files: [:])
        try Self.makePkg([("scene.json", Data(Self.sceneBody.utf8))])
            .write(to: folder.appendingPathComponent("Scene.pkg"))
        // 대소문자 무시 파일시스템이면 위 쓰기가 곧 `scene.pkg` 라 이 케이스가 성립하지 않는다.
        try XCTSkipIf(FileManager.default.fileExists(atPath: folder.appendingPathComponent("scene.pkg").path),
                      "대소문자 무시 파일시스템 — 이 케이스는 성립하지 않는다")

        let p = try project(in: root, id: "case-pkg")
        XCTAssertFalse(p.isBlocked, "\(p.issues)")
        XCTAssertTrue(p.detectedFeatures.contains("sceneLayer"), p.detectedFeatures.description)
    }

    /// ④-c 선언된 `scene.json` 이 **디스크에 실재**하는데 잔존 `scene.pkg` 도 있을 때 —
    /// WE/렌더러는 폴더(= 디스크의 `scene.json`)를 연다. 종전 스캐너는 pkg 를 열어 **다른 씬**을
    /// 검사했다. 두 문서에 서로 다른 오브젝트를 넣어 어느 쪽을 읽었는지 피처로 구별한다.
    func testDeclaredFileOnDiskWinsOverStalePackage() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let onDisk = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"text":{"script":"return 'x';"}}]}
        """
        let stale = """
        {"general":{"orthogonalprojection":{"width":100,"height":100}},
         "objects":[{"particle":"particles/rain.json"}]}
        """
        let folder = try writeFolder(root, "stale-pkg",
                                     project: #"{"type":"scene","file":"scene.json"}"#,
                                     files: ["scene.json": onDisk])
        try Self.makePkg([("scene.json", Data(stale.utf8))])
            .write(to: folder.appendingPathComponent("scene.pkg"))

        let p = try project(in: root, id: "stale-pkg")
        XCTAssertTrue(p.detectedFeatures.contains("sceneText"),
                      "디스크의 scene.json 을 읽어야 한다: \(p.detectedFeatures)")
        XCTAssertFalse(p.detectedFeatures.contains("sceneParticle"),
                       "잔존 pkg 를 읽으면 안 된다: \(p.detectedFeatures)")
    }

    // MARK: - helpers

    private func makeTemp() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WapleSceneMount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeFolder(_ root: URL, _ id: String, project json: String,
                             files: [String: String]) throws -> URL {
        let folder = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
        for (name, contents) in files {
            let url = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return folder
    }

    private func project(in root: URL, id: String) throws -> WallpaperCompatibilityProjectReport {
        let report = try WallpaperCompatibilityAnalyzer.scan(rootURL: root)
        return try XCTUnwrap(report.projects.first { $0.id == id })
    }

    /// `ScenePackageTests.makePkg` 와 같은 포맷(PKGV0001) — 이 스위트가 그 타입에 의존하지 않게 복제.
    private static func makePkg(_ files: [(String, Data)]) -> Data {
        func i32(_ v: Int) -> [UInt8] { withUnsafeBytes(of: Int32(v).littleEndian) { Array($0) } }
        let ver = Array("PKGV0001".utf8)
        var out = i32(ver.count) + ver + i32(files.count)
        var offset = 0
        for (name, data) in files {
            let nm = Array(name.utf8)
            out += i32(nm.count) + nm + i32(offset) + i32(data.count)
            offset += data.count
        }
        for (_, data) in files { out += [UInt8](data) }
        return Data(out)
    }
}
