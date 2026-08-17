import XCTest
@testable import Waple
import WapleCore
import WapleLibrary

/// 감사 V06 — LibraryViewModel.apply(_:) 3분기 커버리지(Sources/Waple/LibraryViewModel.swift:279-293).
/// ① 북마크 해석 실패 → onNotify + 미적용(마운트 미시도·선택 미변경)
/// ② onApply(마운트) false → onNotify + 기존 선택 유지(영속 없음)
/// ③ 성공 → store.select 영속 + selectedId 갱신
final class LibraryApplyBranchTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }   // $TMPDIR 리터 방지
        tempDirs = []
        super.tearDown()
    }

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    private func makeVM(store: LibraryStore, dir: URL) -> LibraryViewModel {
        LibraryViewModel(store: store,
                         playlist: PlaylistStore(baseDirectory: dir),
                         monitors: MonitorAssignmentStore(baseDirectory: dir),
                         favorites: FavoritesStore(baseDirectory: dir),
                         folders: FolderStore(baseDirectory: dir))
    }

    /// 임시 배경 폴더(project.json + 더미 자산) 생성(LibraryViewModelTests 관례와 동일).
    /// importFolder 는 폴더를 그 자리에서 북마크만 하므로 해석 결과는 이 경로 그대로다.
    private func makeWallpaperFolder(id: String) throws -> URL {
        let folder = tempDir().appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = #"{"type":"video","file":"wallpaper.mp4","title":"\#(id)"}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("project.json"))
        try Data("dummy".utf8).write(to: folder.appendingPathComponent("wallpaper.mp4"))
        return folder
    }

    // MARK: - ① 북마크 해석 실패

    /// 깨진 북마크 → 폴더 해석 실패: onNotify 로 안내하고 마운트(onApply)는 시도하지 않으며
    /// 선택도 바뀌지 않아야 한다.
    func testApplyUnresolvableBookmarkReportsErrorWithoutMounting() {
        let dir = tempDir()
        let vm = makeVM(store: LibraryStore(baseDirectory: dir), dir: dir)
        let ghost = LibraryEntry(id: "ghost", title: "Ghost", typeRaw: "video",
                                 fileName: nil, previewName: nil, bookmark: Data("garbage".utf8))
        var errors: [String] = []
        var mountAttempts = 0
        vm.onNotify = { errors.append($0) }
        vm.onApply = { _ in mountAttempts += 1; return true }

        XCTAssertFalse(vm.apply(ghost))
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("폴더를 찾을 수 없습니다"), "해석 실패 안내 메시지")
        XCTAssertEqual(mountAttempts, 0, "폴더 해석 실패 시 마운트 시도 자체가 없어야 한다")
        XCTAssertNil(vm.selectedId, "미적용 — 뷰모델 선택 미변경")
        XCTAssertNil(LibraryStore(baseDirectory: dir).selectedId, "미적용 — 선택 영속 없음")
    }

    // MARK: - ② 마운트(onApply) 실패

    /// 마운트 실패 → onNotify + 기존 선택 유지: 강조/저장된 선택이 항상 실제 표시되는 배경과
    /// 일치하도록, 실패한 후보로 선택을 옮기지 않는다(소스 주석의 계약).
    func testApplyMountFailureKeepsExistingSelection() throws {
        let dir = tempDir()
        let store = LibraryStore(baseDirectory: dir)
        let entry = try store.importFolder(makeWallpaperFolder(id: "wp1"))
        let vm = makeVM(store: store, dir: dir)
        // 기존 선택을 심는다 — 실패 시 이 값이 그대로 유지돼야 한다.
        vm.selectedId = "wp0"
        store.select("wp0")
        var errors: [String] = []
        vm.onNotify = { errors.append($0) }
        vm.onApply = { _ in false }

        XCTAssertFalse(vm.apply(entry))
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("적용하지 못했습니다"), "마운트 실패 안내 메시지")
        XCTAssertEqual(vm.selectedId, "wp0", "마운트 실패 시 기존 선택 유지")
        XCTAssertEqual(LibraryStore(baseDirectory: dir).selectedId, "wp0",
                       "실패한 후보 id 로 선택이 영속되면 안 된다")
    }

    // MARK: - ③ 성공 — select 영속 + selectedId 갱신

    /// 마운트 성공 → 북마크 해석된 폴더로 onApply 가 호출되고, 선택이 스토어 인덱스에
    /// 영속(재로드 검증)되며 selectedId 가 갱신된다.
    func testApplySuccessMountsAndPersistsSelection() throws {
        let dir = tempDir()
        let store = LibraryStore(baseDirectory: dir)
        let folder = try makeWallpaperFolder(id: "wp1")
        let entry = try store.importFolder(folder)
        let vm = makeVM(store: store, dir: dir)
        var mounted: [URL] = []
        var errors: [String] = []
        vm.onApply = { url in mounted.append(url); return true }
        vm.onNotify = { errors.append($0) }

        XCTAssertTrue(vm.apply(entry))
        XCTAssertEqual(mounted.map { $0.standardizedFileURL.path },
                       [folder.standardizedFileURL.path], "북마크 해석된 원본 폴더로 마운트 요청")
        XCTAssertTrue(errors.isEmpty, "성공 경로는 onNotify 를 타지 않는다")
        XCTAssertEqual(vm.selectedId, "wp1", "뷰모델 선택 갱신")
        XCTAssertEqual(LibraryStore(baseDirectory: dir).selectedId, "wp1",
                       "store.select 가 인덱스에 영속돼야 한다(재로드 검증)")
    }
}
