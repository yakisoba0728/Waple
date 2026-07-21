import Combine
import XCTest
@testable import Waple
import WapleLibrary

/// 비디오/상위 폴더 임포트 결함 수정(F582, F583) 회귀 모음 — 각 테스트는 개별 F주석을 참조한다.
final class VideoImportFixRegressionTests: XCTestCase {
    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeVM(dir: URL) -> LibraryViewModel {
        LibraryViewModel(store: LibraryStore(baseDirectory: dir),
                         playlist: PlaylistStore(baseDirectory: dir),
                         monitors: MonitorAssignmentStore(baseDirectory: dir),
                         favorites: FavoritesStore(baseDirectory: dir),
                         folders: FolderStore(baseDirectory: dir))
    }

    // MARK: - F583: 비디오 임포트 실패 경로 부분 산출물 정리

    /// prepare 가 폴더 생성 후 복사에 실패하면 만든 폴더를 정리해야 한다(고아 폴더 방지).
    func testPrepareCleansUpFolderWhenCopyFails() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("nope.mp4")   // 원본 부재 → copyItem 실패
        XCTAssertNil(VideoImport.prepare(from: missing, baseDirectory: dir))
        let importsDir = dir.appendingPathComponent("imports", isDirectory: true)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: importsDir.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "F583: 실패 시 만든 폴더를 정리해야 한다 — \(leftovers)")
    }

    /// prepare 성공 후 스토어 등록(importFolder)이 실패하면 준비 폴더를 정리하고 onError 를 태운다.
    func testImportVideoFileFailureCleansPreparedFolder() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let prepared = tempDir().appendingPathComponent("prepared", isDirectory: true)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prepared.deletingLastPathComponent()) }
        // project.json 없음 → importFolder 실패 유도
        let vm = makeVM(dir: dir)
        vm.videoPrepare = { _ in prepared }
        let exp = expectation(description: "등록 실패 오류 전달(메인 홉)")
        vm.onError = { _ in exp.fulfill() }
        vm.importVideoFile(URL(fileURLWithPath: "/tmp/source.mp4"))
        wait(for: [exp], timeout: 10)
        XCTAssertTrue(vm.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.path),
                       "F583: 등록 실패한 준비 폴더는 정리돼야 한다")
    }

    // MARK: - F582: 상위 폴더 임포트 비동기화(importQueue 경유)

    /// 상위 폴더 임포트도 zip/동영상처럼 importQueue 를 거쳐, 완료 시 메인에서 entries 를 갱신한다.
    func testImportParentCompletesAsynchronouslyWithEntriesUpdated() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let corpus = tempDir()
        defer { try? FileManager.default.removeItem(at: corpus) }
        let wp = corpus.appendingPathComponent("wp1", isDirectory: true)
        try FileManager.default.createDirectory(at: wp, withIntermediateDirectories: true)
        let json = #"{"type":"video","file":"wallpaper.mp4","title":"P"}"#
        try Data(json.utf8).write(to: wp.appendingPathComponent("project.json"))

        let vm = makeVM(dir: dir)
        let exp = expectation(description: "상위 폴더 임포트 완료(메인 홉)")
        var cancellable: AnyCancellable?
        cancellable = vm.$entries.dropFirst().sink { entries in
            if !entries.isEmpty { exp.fulfill() }
        }
        vm.importParent(corpus)
        wait(for: [exp], timeout: 10)
        withExtendedLifetime(cancellable) {}
        XCTAssertEqual(vm.entries.map(\.id), ["wp1"])
    }

    /// 가져올 배경이 없는 폴더도 메인 홉에서 onError 를 태운다(무응답 없이 오류 전달).
    func testImportParentEmptyReportsError() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = tempDir()
        defer { try? FileManager.default.removeItem(at: empty) }
        let vm = makeVM(dir: dir)
        let exp = expectation(description: "오류 전달(메인 홉)")
        var message: String?
        vm.onError = { msg in message = msg; exp.fulfill() }
        vm.importParent(empty)
        wait(for: [exp], timeout: 10)
        XCTAssertNotNil(message)
        XCTAssertTrue(vm.entries.isEmpty)
    }
}
