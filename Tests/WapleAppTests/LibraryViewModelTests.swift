import Combine
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

    // MARK: - 드롭된 id → 지원 엔트리 해석 (w5d-displays 시트 내 드래그앤드롭)

    func testSupportedEntryForId_resolvesSupportedEntry() throws {
        let dir = tempDir()
        try seedLibrary(dir, entries: [entry(id: "wp1", title: "Sunset")])   // typeRaw: "scene" — 지원됨
        let vm = makeVM(dir: dir)
        XCTAssertEqual(vm.supportedEntry(forId: "wp1")?.title, "Sunset")
    }

    func testSupportedEntryForId_nilForUnsupportedType() throws {
        let dir = tempDir()
        let unsupported = LibraryEntry(id: "app1", title: "App", typeRaw: "application",
                                       fileName: nil, previewName: nil, bookmark: Data())
        try seedLibrary(dir, entries: [unsupported])
        let vm = makeVM(dir: dir)
        XCTAssertNil(vm.supportedEntry(forId: "app1"), "지원 예정 타입은 드래그앤드롭 대상에서 제외")
    }

    func testSupportedEntryForId_nilForUnknownId() {
        let vm = makeVM(dir: tempDir())
        XCTAssertNil(vm.supportedEntry(forId: "ghost"))
    }

    // MARK: - 전역 선택 엔트리 (w5d-displays 미할당 모니터 미리보기 폴백)

    func testGlobalEntryReflectsSelectedId() throws {
        let dir = tempDir()
        try seedLibrary(dir, entries: [entry(id: "wp1", title: "Sunset")])
        let vm = makeVM(dir: dir)
        XCTAssertNil(vm.globalEntry, "초기 selectedId 없음 → nil")
        vm.selectedId = "wp1"
        XCTAssertEqual(vm.globalEntry?.title, "Sunset")
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

    // MARK: - 비동기 임포트(A2)

    /// A2: zip 임포트는 해제(ditto, 무거움)를 백그라운드 큐에서 돌리고, 완료 시 메인에서 entries 를
    /// 갱신한다(종전엔 routeImport 호출 스레드=메인에서 ditto 가 끝날 때까지 UI 정지).
    func testImportZipCompletesAsynchronouslyWithEntriesUpdated() throws {
        let dir = tempDir()
        let vm = makeVM(dir: dir)
        // 픽스처: wrapper/111/project.json + 더미 mp4 를 담은 zip(ditto 생성 — LibraryStoreTests 관례).
        let pkg = tempDir().appendingPathComponent("pkg", isDirectory: true)
        let inner = pkg.appendingPathComponent("111", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let json = #"{"type":"video","file":"wallpaper.mp4","preview":"preview.jpg","title":"zipwp"}"#
        try Data(json.utf8).write(to: inner.appendingPathComponent("project.json"))
        try Data("dummy".utf8).write(to: inner.appendingPathComponent("wallpaper.mp4"))
        let zipURL = tempDir().appendingPathComponent("wp.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", pkg.path, zipURL.path]
        try ditto.run(); ditto.waitUntilExit()
        XCTAssertEqual(ditto.terminationStatus, 0, "픽스처 zip 생성")

        let exp = expectation(description: "zip 임포트 완료(메인 홉)")
        var cancellable: AnyCancellable?
        cancellable = vm.$entries.dropFirst().sink { entries in
            if !entries.isEmpty { exp.fulfill() }
        }
        vm.importZip(zipURL)
        wait(for: [exp], timeout: 15)
        withExtendedLifetime(cancellable) {}
        XCTAssertEqual(vm.entries.map(\.id), ["111"])
    }

    /// A2: 동영상 임포트도 prepare(복사+프리뷰 디코드, 무거움)를 백그라운드 큐에서 돌리고, 완료 시
    /// 메인에서 스토어 등록(importFolder) 후 entries 를 갱신한다. 준비 단계는 스텁 주입(실 디코드 생략).
    func testImportVideoFileCompletesAsynchronouslyWithEntriesUpdated() throws {
        let dir = tempDir()
        let vm = makeVM(dir: dir)
        let prepared = tempDir().appendingPathComponent("prepared", isDirectory: true)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        let json: [String: Any] = ["type": "video", "file": "a.mp4", "title": "Stub"]
        try JSONSerialization.data(withJSONObject: json).write(to: prepared.appendingPathComponent("project.json"))
        vm.videoPrepare = { _ in prepared }

        let exp = expectation(description: "동영상 임포트 완료(메인 홉)")
        var cancellable: AnyCancellable?
        cancellable = vm.$entries.dropFirst().sink { entries in
            if !entries.isEmpty { exp.fulfill() }
        }
        vm.importVideoFile(URL(fileURLWithPath: "/tmp/source.mp4"))
        wait(for: [exp], timeout: 10)
        withExtendedLifetime(cancellable) {}
        XCTAssertEqual(vm.entries.map(\.title), ["Stub"])
    }

    /// A2 실패 경로: 해제 불가 zip 도 메인 홉에서 onNotify 를 태운다(무응답 없이 오류 전달).
    func testImportZipExtractionFailureReportsError() {
        let dir = tempDir()
        let vm = makeVM(dir: dir)
        let exp = expectation(description: "오류 전달(메인 홉)")
        var message: String?
        vm.onNotify = { msg in message = msg; exp.fulfill() }
        vm.importZip(URL(fileURLWithPath: "/tmp/waple-missing-\(UUID().uuidString).zip"))
        wait(for: [exp], timeout: 10)
        XCTAssertNotNil(message)
        XCTAssertTrue(vm.entries.isEmpty)
    }

    // MARK: - 폴더 삭제

    /// 보고 있던 폴더를 지우면 사이드바 선택도 함께 풀려야 한다.
    ///
    /// 안 그러면 activeFolder 가 없는 폴더를 가리킨 채 남아 그리드가 0건이 되는데, 그 0 은
    /// 검색·필터가 활성이 아니라 무결과 안내도 안 뜬다 — 사이드바의 그 행도 이미 사라져서
    /// 되돌아갈 곳이 화면에 없다. 폴더 삭제 진입점이 인스펙터라 삭제하는 쪽과 보고 있는 쪽이
    /// 다를 수 있어서 실제로 닿기 쉬운 경로다.
    func testDeletingTheActiveFolderClearsTheSelection() {
        let dir = tempDir()
        let vm = makeVM(dir: dir)
        vm.folders.createFolder("Anime")
        vm.activeFolder = "Anime"
        vm.deleteFolder("Anime")
        XCTAssertNil(vm.activeFolder)
        XCTAssertTrue(vm.folders.folders.isEmpty)
    }

    /// 다른 폴더를 지우는 것은 지금 보고 있는 자리를 흔들지 않는다.
    func testDeletingAnotherFolderKeepsTheSelection() {
        let vm = makeVM(dir: tempDir())
        vm.folders.createFolder("Anime")
        vm.folders.createFolder("Abstract")
        vm.activeFolder = "Anime"
        vm.deleteFolder("Abstract")
        XCTAssertEqual(vm.activeFolder, "Anime")
    }

    // MARK: - 프리뷰 상태(유실 vs 프리뷰 부재)

    /// 실제 폴더를 만들고 스토어에 등록해 북마크가 유효한 엔트리를 얻는다.
    private func importedEntry(into dir: URL, preview: String?) throws -> (LibraryViewModel, LibraryEntry) {
        let store = LibraryStore(baseDirectory: dir)
        let pkg = tempDir().appendingPathComponent("pkg", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        var json: [String: Any] = ["type": "video", "file": "a.mp4", "title": "P"]
        if let preview {
            json["preview"] = preview
            try Data("x".utf8).write(to: pkg.appendingPathComponent(preview))
        }
        try JSONSerialization.data(withJSONObject: json).write(to: pkg.appendingPathComponent("project.json"))
        let entry = try store.importFolder(pkg)
        let vm = LibraryViewModel(store: store, playlist: PlaylistStore(baseDirectory: dir),
                                  monitors: MonitorAssignmentStore(baseDirectory: dir),
                                  favorites: FavoritesStore(baseDirectory: dir),
                                  folders: FolderStore(baseDirectory: dir))
        return (vm, entry)
    }

    func testPreviewStateResolvesImageWhenPreviewFileExists() throws {
        let (vm, entry) = try importedEntry(into: tempDir(), preview: "preview.jpg")
        guard case .image(let url) = vm.previewState(for: entry) else {
            return XCTFail("프리뷰 파일이 있으면 .image")
        }
        XCTAssertEqual(url.lastPathComponent, "preview.jpg")
    }

    /// 프리뷰 파일만 없는 것은 **정상**이다(가져온 동영상 등). 유실과 같은 값으로 뭉개면
    /// 멀쩡한 배경에 경고 배지가 붙는다.
    func testPreviewStateIsNoPreviewWhenOnlyThePreviewFileIsMissing() throws {
        let (vm, entry) = try importedEntry(into: tempDir(), preview: nil)
        XCTAssertEqual(vm.previewState(for: entry), .noPreview)
    }

    /// 북마크가 깨진 엔트리 — 종전에는 previewURL 이 nil 이라 '프리뷰 없음' 과 구별되지
    /// 않았다. 이 항목은 적용하면 실패하므로 화면이 달라야 한다.
    func testPreviewStateIsMissingFolderWhenBookmarkCannotResolve() {
        let vm = makeVM(dir: tempDir())
        XCTAssertEqual(vm.previewState(for: entry(id: "gone", title: "Gone")), .missingFolder)
        XCTAssertNil(vm.previewURL(for: entry(id: "gone", title: "Gone")),
                     "기존 previewURL 계약은 그대로 — 유실이든 부재든 URL 은 없다")
    }

    // MARK: - 임포트 피드백

    /// 후보 폴더 n개를 담은 상위 폴더를 만든다. `valid` 개만 project.json 을 갖는다 —
    /// 나머지는 스토어가 조용히 건너뛰던 부분 실패의 재료다.
    private func seedParent(valid: Int, invalid: Int) throws -> URL {
        let parent = tempDir()
        for i in 0..<valid {
            let f = parent.appendingPathComponent("ok\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
            let json: [String: Any] = ["type": "video", "file": "a.mp4", "title": "ok\(i)"]
            try JSONSerialization.data(withJSONObject: json).write(to: f.appendingPathComponent("project.json"))
        }
        for i in 0..<invalid {
            let f = parent.appendingPathComponent("bad\(i)", isDirectory: true)
            try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        }
        return parent
    }

    private func waitForNotice(_ vm: LibraryViewModel, _ act: () -> Void) -> String? {
        let exp = expectation(description: "임포트 안내(메인 홉)")
        var message: String?
        vm.onNotify = { msg in
            guard message == nil else { return }
            message = msg
            exp.fulfill()
        }
        act()
        wait(for: [exp], timeout: 15)
        return message
    }

    /// 다섯 중 셋만 들어왔는데 화면이 조용하던 것이 이 커밋 전의 동작이다 — 스토어가
    /// `try?` 로 실패를 삼키고, 뷰모델은 전량 실패일 때만 말했다.
    func testPartialParentImportTellsHowManyLanded() throws {
        let vm = makeVM(dir: tempDir())
        let parent = try seedParent(valid: 3, invalid: 2)
        let message = waitForNotice(vm) { vm.importParent(parent) }
        XCTAssertEqual(vm.entries.count, 3)
        XCTAssertEqual(message, "5개 중 3개만 가져왔습니다. 나머지는 project.json 이 없거나 읽을 수 없습니다.")
    }

    /// 전량 성공도 알린다 — 이미 있던 배경을 다시 가져오면 그리드가 그대로라 아무 일도
    /// 일어나지 않은 것처럼 보인다.
    func testFullParentImportReportsSuccess() throws {
        let vm = makeVM(dir: tempDir())
        let parent = try seedParent(valid: 2, invalid: 0)
        let message = waitForNotice(vm) { vm.importParent(parent) }
        XCTAssertEqual(message, "배경 2개를 가져왔습니다.")
    }

    /// 전량 실패는 종전 문구를 그대로 쓴다(무회귀) — 부분 실패 문구로 뭉뚱그리면 "왜 하나도
    /// 안 들어왔나" 에 답하지 못한다.
    func testEmptyParentImportKeepsTheOriginalGuidance() throws {
        let vm = makeVM(dir: tempDir())
        let parent = try seedParent(valid: 0, invalid: 2)
        let message = waitForNotice(vm) { vm.importParent(parent) }
        XCTAssertEqual(message, "가져온 배경이 없습니다. 선택한 폴더에 유효한 project.json 이 있는지 확인하세요.")
    }

    /// 진행 표시는 끝나면 반드시 내려가야 한다 — 남으면 스피너가 영원히 도는 화면이 된다.
    func testImportProgressFlagRisesAndFalls() throws {
        let vm = makeVM(dir: tempDir())
        let parent = try seedParent(valid: 1, invalid: 0)
        vm.importParent(parent)
        XCTAssertTrue(vm.isImporting, "큐에 넣는 즉시 켜진다(백그라운드 완료를 기다리지 않는다)")
        _ = waitForNotice(vm) {}
        XCTAssertFalse(vm.isImporting)
    }
}
