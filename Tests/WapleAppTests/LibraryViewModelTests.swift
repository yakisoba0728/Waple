import XCTest
@testable import Waple
import WapleCore
import WapleLibrary

/// LibraryViewModel(Waple 내부 타입) 핵심 로직 검증 — 재생목록 토글 + 모니터 할당 표시.
/// SwiftUI 뷰는 제외. 스토어는 임시 디렉터리로 실제 생성한다.
final class LibraryViewModelTests: XCTestCase {

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func entry(id: String, title: String) -> LibraryEntry {
        LibraryEntry(id: id, title: title, typeRaw: "scene",
                     fileName: nil, previewName: nil, bookmark: Data())
    }

    /// library.json 을 미리 심어 LibraryStore.entries 를 채운다(북마크는 assignedEntryTitle 이 안 씀).
    private struct SeedIndex: Codable { var entries: [LibraryEntry]; var selectedId: String? }
    private func seedLibrary(_ dir: URL, entries: [LibraryEntry]) throws {
        let data = try JSONEncoder().encode(SeedIndex(entries: entries, selectedId: nil))
        try data.write(to: dir.appendingPathComponent("library.json"))
    }

    private func makeVM(dir: URL) -> LibraryViewModel {
        LibraryViewModel(store: LibraryStore(baseDirectory: dir),
                         playlist: PlaylistStore(baseDirectory: dir),
                         monitors: MonitorAssignmentStore(baseDirectory: dir),
                         favorites: FavoritesStore(baseDirectory: dir),
                         folders: FolderStore(baseDirectory: dir))
    }

    // MARK: - 재생목록 토글

    func testTogglePlaylist_roundtripAndCallback() {
        let dir = tempDir()
        let vm = makeVM(dir: dir)
        var changedCount = 0
        vm.onPlaylistChanged = { changedCount += 1 }
        let e = entry(id: "wp1", title: "Sunset")

        XCTAssertFalse(vm.isInPlaylist(e))
        vm.togglePlaylist(e)
        XCTAssertTrue(vm.isInPlaylist(e), "토글 → 참여")
        XCTAssertEqual(changedCount, 1, "onPlaylistChanged 콜백(타이머 재구성 트리거)")
        vm.togglePlaylist(e)
        XCTAssertFalse(vm.isInPlaylist(e), "재토글 → 제거")
        XCTAssertEqual(changedCount, 2)
    }

    func testTogglePlaylist_persistsToStore() {
        let dir = tempDir()
        makeVM(dir: dir).togglePlaylist(entry(id: "wp1", title: "A"))
        // 새 스토어로 재로드 → 영속 확인.
        XCTAssertEqual(PlaylistStore(baseDirectory: dir).ids, ["wp1"])
    }

    // MARK: - 모니터 할당 표시

    func testAssignedEntryTitle_reflectsAssignment() throws {
        let dir = tempDir()
        try seedLibrary(dir, entries: [entry(id: "wp1", title: "Sunset"),
                                       entry(id: "wp2", title: "Ocean")])
        let vm = makeVM(dir: dir)
        XCTAssertEqual(vm.entries.count, 2, "심어둔 라이브러리 엔트리 로드")

        XCTAssertNil(vm.assignedEntryTitle(forScreen: "disp1"), "미할당 화면 → nil")
        vm.assign(vm.entries[0], toScreen: "disp1")
        XCTAssertEqual(vm.assignedEntryTitle(forScreen: "disp1"), "Sunset", "할당 배경 제목 표시")

        vm.clearAssignment(forScreen: "disp1")
        XCTAssertNil(vm.assignedEntryTitle(forScreen: "disp1"), "해제 → nil")
    }

    func testAssign_persistsToMonitorStore() throws {
        let dir = tempDir()
        try seedLibrary(dir, entries: [entry(id: "wp1", title: "Sunset")])
        let vm = makeVM(dir: dir)
        vm.assign(vm.entries[0], toScreen: "disp9")
        // 새 스토어로 재로드 → 영속 확인.
        XCTAssertEqual(MonitorAssignmentStore(baseDirectory: dir).assignment(for: "disp9"), "wp1")
    }

    func testAssignmentCallbackFires() throws {
        let dir = tempDir()
        try seedLibrary(dir, entries: [entry(id: "wp1", title: "Sunset")])
        let vm = makeVM(dir: dir)
        var changed = 0
        vm.onAssignmentsChanged = { changed += 1 }
        vm.assign(vm.entries[0], toScreen: "disp1")
        vm.clearAssignment(forScreen: "disp1")
        XCTAssertEqual(changed, 2, "할당/해제 각각 즉시 재적용 트리거")
    }

    func testPropertyEditForAssignedNonSelectedEntryTriggersAssignmentReapply() throws {
        let dir = tempDir()
        try seedLibrary(dir, entries: [entry(id: "wp1", title: "Assigned"),
                                       entry(id: "wp2", title: "Selected")])
        let vm = makeVM(dir: dir)
        vm.assign(vm.entries[0], toScreen: "disp1")

        var assignmentReapplyCount = 0
        var globalApplyCount = 0
        vm.onAssignmentsChanged = { assignmentReapplyCount += 1 }
        vm.onApply = { _ in globalApplyCount += 1; return true }

        vm.setProperty(key: "enabled-\(UUID().uuidString)", value: .bool(true), for: vm.entries[0])

        XCTAssertEqual(assignmentReapplyCount, 1, "assigned wallpaper edits should update live assigned renderers")
        XCTAssertEqual(globalApplyCount, 0, "assigned-only edits must not promote that wallpaper to the global selection")
    }

    func testEditablePropertiesForPresetComeFromDependencyWithPresetOverrides() throws {
        let storeDir = tempDir()
        defer { try? FileManager.default.removeItem(at: storeDir) }
        let corpus = tempDir()
        defer { try? FileManager.default.removeItem(at: corpus) }

        let dependency = corpus.appendingPathComponent("dep1", isDirectory: true)
        try FileManager.default.createDirectory(at: dependency, withIntermediateDirectories: true)
        try """
        {"type":"web","file":"index.html","title":"Dependency","general":{"properties":{
          "amount":{"type":"slider","value":0.5,"order":0},
          "enabled":{"type":"bool","value":false,"order":1}
        }}}
        """.write(to: dependency.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        try "<html></html>".write(to: dependency.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)

        let preset = corpus.appendingPathComponent("preset1", isDirectory: true)
        try FileManager.default.createDirectory(at: preset, withIntermediateDirectories: true)
        try """
        {"type":"preset","title":"Preset","dependency":"dep1","preset":{"amount":0.75,"enabled":true}}
        """.write(to: preset.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        let store = LibraryStore(baseDirectory: storeDir)
        store.importParent(corpus)
        let vm = LibraryViewModel(store: store,
                                  playlist: PlaylistStore(baseDirectory: storeDir),
                                  monitors: MonitorAssignmentStore(baseDirectory: storeDir),
                                  favorites: FavoritesStore(baseDirectory: storeDir),
                                  folders: FolderStore(baseDirectory: storeDir))
        let presetEntry = try XCTUnwrap(vm.entries.first { $0.id == "preset1" })

        let props = vm.editableProperties(for: presetEntry)
        let byKey = Dictionary(uniqueKeysWithValues: props.map { ($0.key, $0) })

        XCTAssertEqual(byKey["amount"]?.value, .number(0.75))
        XCTAssertEqual(byKey["enabled"]?.value, .bool(true))
    }

    // MARK: - 속성 패널 자동 노출 (w5d-settings-ia)

    func testSelectForPropertiesViewRevealsPanel() throws {
        let dir = tempDir()
        try seedLibrary(dir, entries: [entry(id: "wp1", title: "Sunset")])
        let vm = makeVM(dir: dir)
        vm.panelVisible = false   // 접힌 상태(사용자가 이전에 숨김)
        vm.selectForPropertiesView(vm.entries[0])
        XCTAssertEqual(vm.focusedId, "wp1", "포커스는 기존과 동일하게 설정")
        XCTAssertTrue(vm.panelVisible, "접혀 있던 패널이 함께 열려야 라벨이 약속한 속성이 보인다")
    }

    func testPanelVisibleDefaultsToTrue() {
        let vm = makeVM(dir: tempDir())
        XCTAssertTrue(vm.panelVisible, "기존 동작(항상 노출) 무회귀 — 최초 상태는 보임")
    }

    // MARK: - Finder에서 보기 (w5d-library)

    func testFolderURLResolvesRealImportedFolder() throws {
        let dir = tempDir()
        let store = LibraryStore(baseDirectory: dir)
        let wallpaperFolder = tempDir()
        let json: [String: Any] = ["type": "video", "file": "a.mp4", "title": "Real"]
        try JSONSerialization.data(withJSONObject: json).write(to: wallpaperFolder.appendingPathComponent("project.json"))
        let imported = try store.importFolder(wallpaperFolder)
        let vm = LibraryViewModel(store: store, playlist: PlaylistStore(baseDirectory: dir),
                                  monitors: MonitorAssignmentStore(baseDirectory: dir),
                                  favorites: FavoritesStore(baseDirectory: dir),
                                  folders: FolderStore(baseDirectory: dir))
        let url = try XCTUnwrap(vm.folderURL(for: imported), "실제 임포트된 폴더는 해석돼야 한다")
        XCTAssertEqual(url.standardizedFileURL.path, wallpaperFolder.standardizedFileURL.path)
    }

    func testFolderURLNilForUnresolvableBookmark() {
        let vm = makeVM(dir: tempDir())
        XCTAssertNil(vm.folderURL(for: entry(id: "ghost", title: "Ghost")), "빈 북마크는 해석 실패 → nil")
    }

    func testAssignedEntryLookup() throws {
        let dir = tempDir()
        let e = entry(id: "wp9", title: "Aurora")
        try seedLibrary(dir, entries: [e])
        let vm = makeVM(dir: dir)
        vm.assign(e, toScreen: "display-7")
        XCTAssertEqual(vm.assignedEntry(forScreen: "display-7")?.id, "wp9")
        XCTAssertNil(vm.assignedEntry(forScreen: "display-none"))
        vm.clearAssignment(forScreen: "display-7")
        XCTAssertNil(vm.assignedEntry(forScreen: "display-7"))
    }
}
