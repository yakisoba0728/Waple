import XCTest
@testable import WapleLibrary

/// 감사 V06 — ZipImporter.findProjectRoots 심링크 미추종 가드(Sources/WapleLibrary/ZipImporter.swift:21-26)
/// 커버리지. 악성 zip 의 링크(evil→/)로 전체 디스크를 걷거나, 외부 경로의 project.json 을 배경 루트로
/// 오인해 importZip 이 외부 원본 폴더를 imported/ 로 이동(파괴)하는 것을 막는 가드다
/// (F580 경로탈출 회귀 테스트 LibraryImportFixRegressionTests 와 같은 계열).
final class ZipImporterSymlinkTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WapleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// project.json 하나를 담은 배경 폴더 픽스처(부모 디렉터리까지 생성).
    private func writeProject(_ folder: URL, title: String) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"type":"video","file":"wallpaper.mp4","title":"\#(title)"}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
    }

    /// 심링크 대상(외부) 최상위의 project.json 은 루트로 채택되지 않아야 한다 — 링크를 따라가면
    /// fileExists 가 링크를 해석해 link 자체가 배경 루트로 오인된다(외부 원본 이동·파괴 경로).
    /// 양성 대조로 실제 중첩 배경은 여전히 찾는지 함께 검증한다.
    func testFindProjectRootsDoesNotAdoptSymlinkTargetAsRoot() throws {
        let corpus = tmp.appendingPathComponent("corpus", isDirectory: true)
        let external = tmp.appendingPathComponent("external", isDirectory: true)
        // 양성 대조: 탐색 루트 아래 실제 중첩 배경(발견돼야 함).
        let real = corpus.appendingPathComponent("Real/Wallpaper", isDirectory: true)
        try writeProject(real, title: "Real")
        // 심링크 대상 외부 폴더 — 최상위에 project.json(link/project.json 으로 해석됨).
        try writeProject(external, title: "External")
        try FileManager.default.createSymbolicLink(
            at: corpus.appendingPathComponent("link"),
            withDestinationURL: external)

        let roots = ZipImporter.findProjectRoots(in: corpus)
        XCTAssertEqual(roots.map { $0.standardizedFileURL.path },
                       [real.standardizedFileURL.path],
                       "심링크(link → external)는 걷지 않아 외부 project.json 이 루트가 되면 안 된다")
        XCTAssertFalse(roots.contains { $0.lastPathComponent == "link" },
                       "심링크 경로 자체가 루트로 채택되면 안 된다")
    }

    /// 심링크 대상 트리 아래 중첩된 project.json 도 재귀 탐색으로 발견되면 안 된다
    /// (외부 트리 전체를 걷지 않음 — 전체 디스크 스캔 방지 가드의 핵심).
    func testFindProjectRootsDoesNotWalkIntoSymlinkedTree() throws {
        let corpus = tmp.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        let external = tmp.appendingPathComponent("external", isDirectory: true)
        // 외부 트리는 폴더 하나를 더 감싼 중첩 구조 — 링크를 따라가야만 도달 가능.
        try writeProject(external.appendingPathComponent("Evil", isDirectory: true), title: "Evil")
        try FileManager.default.createSymbolicLink(
            at: corpus.appendingPathComponent("link"),
            withDestinationURL: external)

        let roots = ZipImporter.findProjectRoots(in: corpus)
        XCTAssertTrue(roots.isEmpty,
                      "심링크 아래 중첩 project.json 도 루트로 채택되면 안 된다 — 실제: \(roots.map(\.path))")
    }
}
