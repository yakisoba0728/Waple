# SP2′: 필터 사이드바 + 라이브러리 백엔드 Implementation Plan

> 상태: **완료·판정 통과(2026-07-12)**.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) 구문.

**Goal:** 설치됨 탭에 접이식 필터 사이드바(즐겨찾기·유형·나이 등급·태그)와 그 백엔드(즐겨찾기·폴더·평점·라이브러리 제거·메타 백필)를 붙이고, 상세 패널 액션과 속성 편집기를 정돈한다.

**Architecture:** 스토어는 전부 기존 패턴(Codable JSON + `readStoreFile`/`backupCorruptStoreFile`) 복제. 필터링·폴더 가시성은 순수 함수로 추출해 TDD. 뷰는 네이티브(List 사이드바·Toggle·confirmationDialog). 스펙: [2026-07-12-native-ui-redesign.md](../specs/2026-07-12-native-ui-redesign.md) §7·SP2′.

**Tech Stack:** SwiftUI(macOS 14+), 외부 의존성 0.

## Global Constraints

- 커스텀 hex 금지(시맨틱/재질/accentColor), 치수는 `Metrics` 상수(신규 필요 시 Metrics에 추가), SF Symbols.
- 커밋 `기능(ui)/기능(라이브러리)/정리:` 관례, 한국어, push 금지, main 직접.
- 매 태스크 `swift build` + 해당 스위트 그린 후 커밋. macOS에 `timeout` 없음(백그라운드+kill).
- 캡처는 /tmp만(리포 커밋 금지).
- 기존 콜백 계약(onApply 등) 시그니처 유지. `LibraryViewModel.init`은 이 플랜에서 favorites/folders 파라미터가 **추가**된다(호출 3곳 동시 수정 — AppDelegate:21, LibraryViewModelTests:29·138).

---

### Task 1: LibraryEntry 메타 확장 + 백필 + 평점 저장 (WapleLibrary)

**Files:**
- Modify: `Sources/WapleLibrary/LibraryEntry.swift`
- Modify: `Sources/WapleLibrary/LibraryStore.swift`
- Test: `Tests/WapleLibraryTests/LibraryMetadataTests.swift` (신규)

**Interfaces:**
- Produces: `LibraryEntry.tags: [String]?` / `.contentRating: String?` / `.rating: Double?` (전부 optional — 기존 library.json 디코드 호환).
  `LibraryStore.setRating(_ rating: Double, id: String)` / `LibraryStore.backfillMetadataIfNeeded()`(init 말미 자동 호출).
  importFolder 가 tags/contentRating 을 채움.

- [ ] **Step 1: 실패 테스트**

`Tests/WapleLibraryTests/LibraryMetadataTests.swift`:

```swift
import XCTest
@testable import WapleLibrary

final class LibraryMetadataTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// project.json 을 가진 배경 폴더 생성.
    private func makeWallpaper(in dir: URL, id: String, tags: [String], rating: String?) -> URL {
        let folder = dir.appendingPathComponent(id, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var json: [String: Any] = ["type": "video", "file": "a.mp4", "title": id, "tags": tags]
        if let rating { json["contentrating"] = rating }
        let data = try! JSONSerialization.data(withJSONObject: json)
        try! data.write(to: folder.appendingPathComponent("project.json"))
        return folder
    }

    func testImportFillsTagsAndContentRating() throws {
        let base = tempDir()
        let store = LibraryStore(baseDirectory: base)
        let folder = makeWallpaper(in: tempDir(), id: "w1", tags: ["Anime", "4K"], rating: "Everyone")
        let entry = try store.importFolder(folder)
        XCTAssertEqual(entry.tags, ["Anime", "4K"])
        XCTAssertEqual(entry.contentRating, "Everyone")
    }

    func testDecodeOldIndexWithoutNewFields() throws {
        // 구버전 index(신규 필드 부재)가 그대로 디코드되는지 — 마이그레이션 안전성.
        let old = """
        {"entries":[{"id":"x","title":"t","typeRaw":"video","bookmark":""}],"selectedId":null}
        """
        let base = tempDir()
        try old.data(using: .utf8)!.write(to: base.appendingPathComponent("library.json"))
        let store = LibraryStore(baseDirectory: base)
        XCTAssertEqual(store.entries.first?.id, "x")
        XCTAssertNil(store.entries.first?.rating)
    }

    func testBackfillFillsNilTagsFromDisk() throws {
        let base = tempDir()
        let folder = makeWallpaper(in: tempDir(), id: "w2", tags: ["Nature"], rating: nil)
        // 1차 스토어로 정상 임포트 후, 인덱스에서 tags 를 지워 구버전 상태를 재현.
        var store: LibraryStore? = LibraryStore(baseDirectory: base)
        _ = try store!.importFolder(folder)
        store = nil
        let url = base.appendingPathComponent("library.json")
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var entries = raw["entries"] as! [[String: Any]]
        entries[0].removeValue(forKey: "tags")
        entries[0].removeValue(forKey: "contentRating")
        raw["entries"] = entries
        try JSONSerialization.data(withJSONObject: raw).write(to: url)
        // 재로드 → init 백필이 디스크 project.json 에서 채워야 한다.
        let reloaded = LibraryStore(baseDirectory: base)
        XCTAssertEqual(reloaded.entries.first?.tags, ["Nature"])
    }

    func testSetRatingPersists() throws {
        let base = tempDir()
        let folder = makeWallpaper(in: tempDir(), id: "w3", tags: [], rating: nil)
        let store = LibraryStore(baseDirectory: base)
        let entry = try store.importFolder(folder)
        store.setRating(0.87, id: entry.id)
        let reloaded = LibraryStore(baseDirectory: base)
        XCTAssertEqual(reloaded.entries.first?.rating, 0.87)
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter LibraryMetadataTests` → FAIL(멤버 부재).

- [ ] **Step 3: 구현**

`LibraryEntry.swift` — 프로퍼티 3개 추가(전부 `var`, init 파라미터 기본값 nil):

```swift
public struct LibraryEntry: Codable, Equatable {
    public let id: String
    public let title: String
    public let typeRaw: String
    public let fileName: String?
    public let previewName: String?
    public var bookmark: Data
    /// project.json tags(임포트 시 채움; nil=구버전 인덱스 — LibraryStore 백필 대상).
    public var tags: [String]?
    /// project.json contentrating(원문 그대로 — 필터 표시는 UI 가 매핑).
    public var contentRating: String?
    /// 워크샵 평점 0…1(vote_data.score, 다운로드 시 저장). 로컬 임포트는 nil.
    public var rating: Double?

    public init(id: String, title: String, typeRaw: String,
                fileName: String?, previewName: String?, bookmark: Data,
                tags: [String]? = nil, contentRating: String? = nil, rating: Double? = nil) {
        self.id = id; self.title = title; self.typeRaw = typeRaw
        self.fileName = fileName; self.previewName = previewName; self.bookmark = bookmark
        self.tags = tags; self.contentRating = contentRating; self.rating = rating
    }
}
```

`LibraryStore.swift`:
- `importFolder` 의 entry 생성에 `tags: project.tags, contentRating: project.contentRating` 전달.
- init 말미(`load()` 다음)에 `backfillMetadataIfNeeded()` 호출 추가.
- 메서드 추가:

```swift
    /// 워크샵 평점 저장(0…1). 미존재 id 는 no-op.
    public func setRating(_ rating: Double, id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].rating = rating
        save()
    }

    /// 구버전 인덱스(tags==nil) 엔트리의 tags/contentRating 을 디스크 project.json 에서 1회 백필.
    /// 폴더 해석 실패 엔트리는 빈 값([])으로 마킹해 매 실행 재시도 I/O 를 막는다.
    func backfillMetadataIfNeeded() {
        var changed = false
        for i in entries.indices where entries[i].tags == nil {
            changed = true
            guard let folder = resolveFolderURL(for: entries[i]),
                  let project = try? ProjectJSONParser.parse(folderURL: folder) else {
                entries[i].tags = []
                continue
            }
            entries[i].tags = project.tags
            entries[i].contentRating = project.contentRating
        }
        if changed { save() }
    }
```

- [ ] **Step 4: 통과 확인** — `swift test --filter LibraryMetadataTests && swift test --filter WapleLibraryTests 2>&1 | tail -1` → 전부 PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WapleLibrary Tests/WapleLibraryTests/LibraryMetadataTests.swift
git commit -m "기능(라이브러리): 엔트리 메타 확장(tags·contentRating·rating) + 구버전 백필 + 평점 저장"
```

---

### Task 2: FavoritesStore + FolderStore + 스토어 orphan API

**Files:**
- Create: `Sources/WapleLibrary/FavoritesStore.swift`, `Sources/WapleLibrary/FolderStore.swift`
- Modify: `Sources/WapleLibrary/PlaylistStore.swift`, `Sources/WapleLibrary/MonitorAssignmentStore.swift`
- Test: `Tests/WapleLibraryTests/FavoritesFolderStoreTests.swift` (신규)

**Interfaces:**
- Produces:
  - `FavoritesStore(baseDirectory:)` — `isFavorite(_ id: String) -> Bool`, `toggle(_ id: String)`, `remove(_ id: String)`, `var ids: Set<String>`.
  - `FolderStore(baseDirectory:)` — `struct Folder: Codable, Equatable { var name: String; var ids: [String] }`,
    `var folders: [Folder]`, `createFolder(_ name: String)`, `move(_ id: String, to folderName: String?)`(nil=폴더 해제),
    `folderName(of id: String) -> String?`, `removeEntry(_ id: String)`, `removeFolder(_ name: String)`(항목은 루트로).
  - `PlaylistStore.remove(_ id: String)` / `MonitorAssignmentStore.removeAssignments(entryId: String)`.

- [ ] **Step 1: 실패 테스트**

`Tests/WapleLibraryTests/FavoritesFolderStoreTests.swift`:

```swift
import XCTest
@testable import WapleLibrary

final class FavoritesFolderStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testFavoritesToggleAndPersist() {
        let base = tempDir()
        let s = FavoritesStore(baseDirectory: base)
        XCTAssertFalse(s.isFavorite("a"))
        s.toggle("a")
        XCTAssertTrue(s.isFavorite("a"))
        XCTAssertTrue(FavoritesStore(baseDirectory: base).isFavorite("a"))  // 영속
        s.toggle("a")
        XCTAssertFalse(s.isFavorite("a"))
    }

    func testFolderMoveAndRemove() {
        let base = tempDir()
        let s = FolderStore(baseDirectory: base)
        s.createFolder("메인")
        s.move("w1", to: "메인")
        XCTAssertEqual(s.folderName(of: "w1"), "메인")
        s.move("w1", to: "메인")                       // 중복 이동 멱등
        XCTAssertEqual(s.folders.first?.ids, ["w1"])
        s.move("w1", to: nil)                          // 루트로
        XCTAssertNil(s.folderName(of: "w1"))
        s.move("w2", to: "새폴더")                      // 미존재 폴더 → 자동 생성
        XCTAssertEqual(FolderStore(baseDirectory: base).folderName(of: "w2"), "새폴더")
        s.removeFolder("새폴더")
        XCTAssertNil(s.folderName(of: "w2"))
    }

    func testOrphanAPIs() {
        let base = tempDir()
        let pl = PlaylistStore(baseDirectory: base)
        pl.ids = ["a", "b", "a"]
        pl.remove("a")
        XCTAssertEqual(pl.ids, ["b"])
        let mon = MonitorAssignmentStore(baseDirectory: base)
        mon.setAssignment("a", for: "display-1")
        mon.setAssignment("c", for: "display-2")
        mon.removeAssignments(entryId: "a")
        XCTAssertNil(mon.assignment(for: "display-1"))
        XCTAssertEqual(mon.assignment(for: "display-2"), "c")
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter FavoritesFolderStoreTests` → FAIL.

- [ ] **Step 3: 구현**

`FavoritesStore.swift`:

```swift
import Foundation

/// 즐겨찾기 id 집합(favorites.json 영속) — 스토어 손상 백업 규약 공유.
public final class FavoritesStore {
    private let fileURL: URL
    public private(set) var ids: Set<String> = []
    private var corrupt = false

    public init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("favorites.json")
        guard let data = readStoreFile(fileURL, what: "favorites.json", note: "starting empty", corrupt: &corrupt) else { return }
        do { ids = try JSONDecoder().decode(Set<String>.self, from: data) }
        catch { NSLog("%@", "[Waple] favorites.json corrupt — preserving, starting empty: \(error)"); corrupt = true }
    }

    public func isFavorite(_ id: String) -> Bool { ids.contains(id) }

    public func toggle(_ id: String) {
        if !ids.insert(id).inserted { ids.remove(id) }
        save()
    }

    public func remove(_ id: String) {
        guard ids.remove(id) != nil else { return }
        save()
    }

    private func save() {
        backupCorruptStoreFile(fileURL, &corrupt)
        do { try JSONEncoder().encode(ids).write(to: fileURL, options: .atomic) }
        catch { NSLog("%@", "[Waple] favorites save failed: \(error)") }
    }
}
```

`FolderStore.swift`:

```swift
import Foundation

/// 라이브러리 폴더(folders.json 영속): 폴더명 → 엔트리 id 목록. 항목은 최대 1개 폴더 소속.
public final class FolderStore {
    public struct Folder: Codable, Equatable {
        public var name: String
        public var ids: [String]
        public init(name: String, ids: [String]) { self.name = name; self.ids = ids }  // 비-@testable 테스트가 생성
    }

    private let fileURL: URL
    public private(set) var folders: [Folder] = []
    private var corrupt = false

    public init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("folders.json")
        guard let data = readStoreFile(fileURL, what: "folders.json", note: "starting empty", corrupt: &corrupt) else { return }
        do { folders = try JSONDecoder().decode([Folder].self, from: data) }
        catch { NSLog("%@", "[Waple] folders.json corrupt — preserving, starting empty: \(error)"); corrupt = true }
    }

    public func createFolder(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !folders.contains(where: { $0.name == n }) else { return }
        folders.append(Folder(name: n, ids: []))
        save()
    }

    /// 항목을 폴더로 이동(nil=루트로). 미존재 폴더명은 생성. 기존 소속은 해제.
    public func move(_ id: String, to folderName: String?) {
        for i in folders.indices { folders[i].ids.removeAll { $0 == id } }
        if let name = folderName {
            if !folders.contains(where: { $0.name == name }) {
                folders.append(Folder(name: name, ids: []))
            }
            if let i = folders.firstIndex(where: { $0.name == name }) {
                folders[i].ids.append(id)
            }
        }
        save()
    }

    public func folderName(of id: String) -> String? {
        folders.first { $0.ids.contains(id) }?.name
    }

    public func removeEntry(_ id: String) {
        let before = folders
        for i in folders.indices { folders[i].ids.removeAll { $0 == id } }
        if folders != before { save() }
    }

    /// 폴더 삭제 — 담긴 항목은 루트로 돌아간다(항목 삭제 아님).
    public func removeFolder(_ name: String) {
        let before = folders.count
        folders.removeAll { $0.name == name }
        if folders.count != before { save() }
    }

    private func save() {
        backupCorruptStoreFile(fileURL, &corrupt)
        do { try JSONEncoder().encode(folders).write(to: fileURL, options: .atomic) }
        catch { NSLog("%@", "[Waple] folders save failed: \(error)") }
    }
}
```

`PlaylistStore.swift` 메서드 추가:

```swift
    /// 라이브러리 제거 연동: 해당 id 전부 제거(orphan 정리).
    public func remove(_ id: String) {
        guard model.ids.contains(id) else { return }
        model.ids.removeAll { $0 == id }
    }
```

`MonitorAssignmentStore.swift` 메서드 추가:

```swift
    /// 라이브러리 제거 연동: 이 엔트리를 가리키는 화면 할당 전부 해제(orphan 정리).
    public func removeAssignments(entryId: String) {
        let keys = map.filter { $0.value == entryId }.map(\.key)
        guard !keys.isEmpty else { return }
        for k in keys { map.removeValue(forKey: k) }
        save()
    }
```

- [ ] **Step 4: 통과 확인** — `swift test --filter FavoritesFolderStoreTests && swift test --filter WapleLibraryTests 2>&1 | tail -1`.

- [ ] **Step 5: Commit**

```bash
git add Sources/WapleLibrary Tests/WapleLibraryTests/FavoritesFolderStoreTests.swift
git commit -m "기능(라이브러리): FavoritesStore·FolderStore 신설 + 재생목록/모니터 orphan 정리 API"
```

---

### Task 3: 라이브러리 제거 — 스토어 + VM 오케스트레이션

**Files:**
- Modify: `Sources/WapleLibrary/LibraryStore.swift`
- Modify: `Sources/Waple/LibraryViewModel.swift`
- Modify: `Sources/Waple/AppDelegate.swift` (VM 생성부 :21)
- Test: `Tests/WapleAppTests/LibraryRemovalTests.swift` (신규), Modify: `Tests/WapleAppTests/LibraryViewModelTests.swift` (생성부 2곳)

**Interfaces:**
- Produces: `LibraryStore.remove(id: String)`(선택 중이면 selectedId=nil).
  `LibraryViewModel.init(store:playlist:monitors:favorites:folders:)` — **파라미터 2개 추가**(기본값 없음, 호출 3곳 수정).
  `LibraryViewModel.remove(_ entry: LibraryEntry)` — 전 스토어 orphan 정리 + entries 갱신 + focusedId 해제 + 할당 변경 시 onAssignmentsChanged 발화.
  `LibraryViewModel.isFavorite(_:) -> Bool` / `toggleFavorite(_:)` / `let favorites: FavoritesStore` / `let folders: FolderStore`.

- [ ] **Step 1: 실패 테스트**

`Tests/WapleAppTests/LibraryRemovalTests.swift`:

```swift
import XCTest
import WapleLibrary
@testable import Waple

final class LibraryRemovalTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func makeWallpaper(id: String) -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + id, isDirectory: true)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json: [String: Any] = ["type": "video", "file": "a.mp4", "title": id]
        try! JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("project.json"))
        return folder
    }

    func testRemoveClearsAllStores() throws {
        let base = tempDir()
        let store = LibraryStore(baseDirectory: base)
        let playlist = PlaylistStore(baseDirectory: base)
        let monitors = MonitorAssignmentStore(baseDirectory: base)
        let favorites = FavoritesStore(baseDirectory: base)
        let folders = FolderStore(baseDirectory: base)
        let entry = try store.importFolder(makeWallpaper(id: "gone"))
        store.select(entry.id)
        playlist.ids = [entry.id]
        monitors.setAssignment(entry.id, for: "display-9")
        favorites.toggle(entry.id)
        folders.move(entry.id, to: "폴더A")

        let vm = LibraryViewModel(store: store, playlist: playlist, monitors: monitors,
                                  favorites: favorites, folders: folders)
        vm.focusedId = entry.id
        var assignmentsChanged = false
        vm.onAssignmentsChanged = { assignmentsChanged = true }

        vm.remove(entry)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(store.selectedId)
        XCTAssertTrue(playlist.ids.isEmpty)
        XCTAssertNil(monitors.assignment(for: "display-9"))
        XCTAssertFalse(favorites.isFavorite(entry.id))
        XCTAssertNil(folders.folderName(of: entry.id))
        XCTAssertNil(vm.focusedId)
        XCTAssertTrue(vm.entries.isEmpty)
        XCTAssertTrue(assignmentsChanged, "할당이 있던 항목 제거 → 재적용 트리거")
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter LibraryRemovalTests` → FAIL.

- [ ] **Step 3: 구현**

`LibraryStore.swift`:

```swift
    /// 엔트리 제거(파일은 건드리지 않음 — 인덱스 등록 해제). 선택 중이었으면 선택 해제.
    /// 스토어 간 orphan 정리는 호출자(LibraryViewModel.remove)가 오케스트레이션한다.
    public func remove(id: String) {
        entries.removeAll { $0.id == id }
        if selectedId == id { selectedId = nil }
        save()
    }
```

`LibraryViewModel.swift`:
- 프로퍼티 추가: `let favorites: FavoritesStore`, `let folders: FolderStore` (playlist/monitors 옆).
- init 파라미터 추가: `favorites: FavoritesStore, folders: FolderStore` → 저장.
- 메서드 추가:

```swift
    // MARK: - 즐겨찾기/제거

    func isFavorite(_ entry: LibraryEntry) -> Bool { favorites.isFavorite(entry.id) }

    func toggleFavorite(_ entry: LibraryEntry) {
        favorites.toggle(entry.id)
        objectWillChange.send()
    }

    /// 라이브러리에서 제거(파일 보존) + 전 스토어 orphan 정리. 적용 중 배경은 계속 재생된다
    /// (렌더러는 폴더를 직접 들고 있음) — Now Playing 표시는 '적용된 배경 없음'으로 떨어진다.
    func remove(_ entry: LibraryEntry) {
        let hadAssignment = monitors.all.values.contains(entry.id)
        store.remove(id: entry.id)
        playlist.remove(entry.id)
        monitors.removeAssignments(entryId: entry.id)
        favorites.remove(entry.id)
        folders.removeEntry(entry.id)
        entries = store.entries
        if selectedId == entry.id { selectedId = nil }
        if focusedId == entry.id { focusedId = nil }
        onPlaylistChanged?()
        if hadAssignment { onAssignmentsChanged?() }
    }
```

`AppDelegate.swift` :21 교체:

```swift
    private let favoritesStore = FavoritesStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private let folderStore = FolderStore(baseDirectory: LibraryStore.defaultBaseDirectory())
    private lazy var libraryVM = LibraryViewModel(store: store, playlist: playlistStore, monitors: monitorStore,
                                                  favorites: favoritesStore, folders: folderStore)
```

`LibraryViewModelTests.swift` 생성부 2곳(:29·:138): 같은 baseDirectory 로 `favorites: FavoritesStore(baseDirectory: dir), folders: FolderStore(baseDirectory: dir)` 인자 추가(각 테스트의 기존 지역 변수명에 맞춰).

- [ ] **Step 4: 통과 확인** — `swift test --filter LibraryRemovalTests && swift test --filter WapleAppTests 2>&1 | tail -1`.

- [ ] **Step 5: Commit**

```bash
git add Sources/WapleLibrary Sources/Waple Tests/WapleAppTests
git commit -m "기능(라이브러리): 항목 제거 + 전 스토어 orphan 정리 오케스트레이션 (BACKLOG remove 부재 해소)"
```

---

### Task 4: 필터 모델 확장 + 폴더 가시성 (순수 로직)

**Files:**
- Modify: `Sources/Waple/LibraryFiltering.swift`
- Modify: `Sources/Waple/LibraryViewModel.swift`
- Modify: `Sources/Waple/Shell/MainWindowView.swift` (typeFilter popover 제거)
- Test: `Tests/WapleAppTests/LibraryFilteringTests.swift` (전체 재작성)

**Interfaces:**
- Produces:
  - `struct LibraryFilterCriteria: Equatable { var types: Set<LibraryTypeFilter> = []; var tags: Set<String> = []; var ratings: Set<String> = []; var favoritesOnly = false }` — 빈 집합 = 해당 축 무필터. `var isActive: Bool`.
  - `LibraryFiltering.apply(_ entries:, search: String, criteria: LibraryFilterCriteria, sort: LibrarySortOrder, isFavorite: (String) -> Bool) -> [LibraryEntry]` (구 `type:` 시그니처 삭제).
  - `enum LibraryFolders { static func visible(entries:[LibraryEntry], folders:[FolderStore.Folder], active: String?) -> (folders: [FolderStore.Folder], entries: [LibraryEntry]) }` — 루트: 폴더 목록+미소속 엔트리 / active: 폴더 없음+소속 엔트리.
  - `LibraryViewModel`: `@Published var criteria = LibraryFilterCriteria()`, `@Published var activeFolder: String?`,
    `filteredEntries`(폴더 가시성 → criteria 필터), `visibleFolders: [FolderStore.Folder]`,
    `availableTags: [String]`, `availableRatings: [String]`. **구 `typeFilter` 삭제.**

- [ ] **Step 1: 테스트 재작성(실패 상태로)**

`Tests/WapleAppTests/LibraryFilteringTests.swift` 전체 교체:

```swift
import XCTest
import WapleLibrary
@testable import Waple

final class LibraryFilteringTests: XCTestCase {
    private func entry(_ id: String, _ title: String, _ type: String,
                       tags: [String] = [], rating: String? = nil) -> LibraryEntry {
        LibraryEntry(id: id, title: title, typeRaw: type, fileName: nil, previewName: nil,
                     bookmark: Data(), tags: tags, contentRating: rating)
    }
    private var sample: [LibraryEntry] {
        [entry("1", "바다", "scene", tags: ["Nature"], rating: "Everyone"),
         entry("2", "Alps", "video", tags: ["Nature", "4K"], rating: "Everyone"),
         entry("3", "네온", "web", tags: ["City"], rating: "Mature"),
         entry("4", "바다 야경", "video", tags: ["City"])]
    }
    private func apply(_ search: String = "", _ c: LibraryFilterCriteria = .init(),
                       sort: LibrarySortOrder = .recentFirst,
                       favorites: Set<String> = []) -> [String] {
        LibraryFiltering.apply(sample, search: search, criteria: c, sort: sort,
                               isFavorite: { favorites.contains($0) }).map(\.id)
    }

    func testNoCriteriaKeepsAll() { XCTAssertEqual(apply(), ["4", "3", "2", "1"]) }
    func testNameSortLocaleIndependent() {
        XCTAssertEqual(apply("", .init(), sort: .name), ["2", "3", "1", "4"])  // Alps, 네온, 바다, 바다 야경
    }
    func testSearchComposesWithType() {
        var c = LibraryFilterCriteria(); c.types = [.video]
        XCTAssertEqual(apply("바다", c), ["4"])
    }
    func testTypeMultiSelect() {
        var c = LibraryFilterCriteria(); c.types = [.video, .web]
        XCTAssertEqual(apply("", c), ["4", "3", "2"])
    }
    func testTagFilterAnyMatch() {
        var c = LibraryFilterCriteria(); c.tags = ["City"]
        XCTAssertEqual(apply("", c), ["4", "3"])
    }
    func testRatingFilterTreatsNilAsNoMatch() {
        var c = LibraryFilterCriteria(); c.ratings = ["Everyone"]
        XCTAssertEqual(apply("", c), ["2", "1"])
    }
    func testFavoritesOnly() {
        var c = LibraryFilterCriteria(); c.favoritesOnly = true
        XCTAssertEqual(apply("", c, favorites: ["3"]), ["3"])
    }
    func testFolderVisibilityRootHidesFolderedEntries() {
        let folders = [FolderStore.Folder(name: "메인", ids: ["1", "3"])]
        let root = LibraryFolders.visible(entries: sample, folders: folders, active: nil)
        XCTAssertEqual(root.folders.map(\.name), ["메인"])
        XCTAssertEqual(root.entries.map(\.id), ["2", "4"])
        let inside = LibraryFolders.visible(entries: sample, folders: folders, active: "메인")
        XCTAssertTrue(inside.folders.isEmpty)
        XCTAssertEqual(inside.entries.map(\.id), ["1", "3"])
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter LibraryFilteringTests` → 컴파일 실패(criteria 부재).

- [ ] **Step 3: 구현**

`LibraryFiltering.swift` — `LibraryTypeFilter`에서 `.all` 케이스는 유지하되 criteria 는 집합만 쓴다(빈=전체). `apply` 교체 + criteria/폴더 추가:

```swift
/// 필터 기준(사이드바 상태). 빈 집합 = 그 축 무필터.
struct LibraryFilterCriteria: Equatable {
    var types: Set<LibraryTypeFilter> = []
    var tags: Set<String> = []
    var ratings: Set<String> = []
    var favoritesOnly = false
    var isActive: Bool { !types.isEmpty || !tags.isEmpty || !ratings.isEmpty || favoritesOnly }
}

enum LibraryFiltering {
    static func apply(_ entries: [LibraryEntry], search: String,
                      criteria: LibraryFilterCriteria, sort: LibrarySortOrder,
                      isFavorite: (String) -> Bool) -> [LibraryEntry] {
        var out = entries
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            out = out.filter { $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        if !criteria.types.isEmpty {
            out = out.filter { criteria.types.contains(entryType($0)) }
        }
        if !criteria.tags.isEmpty {
            out = out.filter { !(criteria.tags.isDisjoint(with: $0.tags ?? [])) }
        }
        if !criteria.ratings.isEmpty {
            out = out.filter { $0.contentRating.map { criteria.ratings.contains($0) } ?? false }
        }
        if criteria.favoritesOnly {
            out = out.filter { isFavorite($0.id) }
        }
        switch sort {
        case .recentFirst: return out.reversed()
        case .name: return out.sorted {
            $0.title.compare($1.title, options: [.caseInsensitive, .numeric]) == .orderedAscending
        }
        }
    }

    static func entryType(_ e: LibraryEntry) -> LibraryTypeFilter {
        switch WallpaperType.from(e.typeRaw) {
        case .scene: return .scene
        case .video: return .video
        case .web: return .web
        default: return .all
        }
    }
}

/// 폴더 가시성(WE 참조): 루트 = 폴더 타일 + 미소속 항목, 폴더 안 = 그 폴더 항목만.
enum LibraryFolders {
    static func visible(entries: [LibraryEntry], folders: [FolderStore.Folder],
                        active: String?) -> (folders: [FolderStore.Folder], entries: [LibraryEntry]) {
        if let active {
            let ids = folders.first { $0.name == active }?.ids ?? []
            let inFolder = entries.filter { ids.contains($0.id) }
            return ([], inFolder)
        }
        let foldered = Set(folders.flatMap(\.ids))
        return (folders, entries.filter { !foldered.contains($0.id) })
    }
}
```
(기존 `LibraryTypeFilter`/`LibrarySortOrder` enum 과 주석은 유지. 구 `apply(_:search:type:sort:)`와 private `entryType`은 위 구현으로 대체.)

`LibraryViewModel.swift`:
- `@Published var typeFilter: LibraryTypeFilter = .all` **삭제** → `@Published var criteria = LibraryFilterCriteria()`, `@Published var activeFolder: String?` 추가.
- `filteredEntries` 교체 + 파생 프로퍼티:

```swift
    var filteredEntries: [LibraryEntry] {
        let scoped = LibraryFolders.visible(entries: entries, folders: folders.folders, active: activeFolder).entries
        return LibraryFiltering.apply(scoped, search: searchText, criteria: criteria,
                                      sort: sortOrder, isFavorite: { self.favorites.isFavorite($0) })
    }
    /// 루트에서만 노출되는 폴더 타일 목록(검색/필터 중엔 숨김 — 결과에 집중).
    var visibleFolders: [FolderStore.Folder] {
        guard activeFolder == nil, searchText.isEmpty, !criteria.isActive else { return [] }
        return folders.folders
    }
    var availableTags: [String] {
        Array(Set(entries.flatMap { $0.tags ?? [] })).sorted()
    }
    var availableRatings: [String] {
        Array(Set(entries.compactMap(\.contentRating))).sorted()
    }
```

주의: `visibleFolders` 가드의 의도는 "필터/검색 활성 시 폴더 숨기고 전체에서 검색" — 이때 filteredEntries 는 폴더 스코프 대신 전체를 봐야 하므로 `filteredEntries` 첫 줄을 다음으로:

```swift
        let scopeAll = activeFolder == nil && (!searchText.isEmpty || criteria.isActive)
        let scoped = scopeAll ? entries
            : LibraryFolders.visible(entries: entries, folders: folders.folders, active: activeFolder).entries
```

- 폴더 조작 API:

```swift
    func moveToFolder(_ entry: LibraryEntry, folder: String?) {
        folders.move(entry.id, to: folder)
        objectWillChange.send()
    }
```

`MainWindowView.swift`: 툴바의 필터 popover 블록(`.popover(isPresented: $showFilters) { Picker("유형"...) }`) 삭제 — 버튼은 `showFilters.toggle()` 유지(사이드바 배선은 Task 6). 필터 활성 표시로 버튼 라벨을 다음으로 교체:

```swift
                Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showFilters.toggle() } } label: {
                    Label("필터", systemImage: viewModel.criteria.isActive
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .help("필터 사이드바")
```

- [ ] **Step 4: 통과 확인** — `swift build && swift test --filter LibraryFilteringTests && swift test --filter WapleAppTests 2>&1 | tail -1`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Waple Tests/WapleAppTests/LibraryFilteringTests.swift
git commit -m "기능(ui): 필터 기준 확장(타입 다중·태그·등급·즐겨찾기) + 폴더 가시성 순수 로직"
```

---

### Task 5: 평점 파이프라인 (Steam vote_data)

**Files:**
- Modify: `Sources/Waple/WorkshopAPI.swift`
- Modify: `Sources/Waple/WorkshopView.swift` (finishDownload)
- Modify: `Sources/Waple/LibraryViewModel.swift` (setRating 경유)
- Test: `Tests/WapleAppTests/WorkshopAPITests.swift` (추가 2건)

**Interfaces:**
- Produces: `WorkshopItem.voteScore: Double?`(0…1), searchURL 에 `return_vote_data=true`,
  `LibraryViewModel.setRating(_ score: Double, for entry: LibraryEntry)`(store.setRating + entries 갱신).

- [ ] **Step 1: 실패 테스트 추가** (`WorkshopAPITests.swift` 말미에)

```swift
    func testSearchURLRequestsVoteData() {
        let url = WorkshopQuery.searchURL(apiKey: "K", page: 1, numPerPage: 10, searchText: "", sort: .trend)
        XCTAssertEqual(queryDict(url)["return_vote_data"], "true")
    }

    func testParseExtractsVoteScore() {
        let json = """
        {"response":{"publishedfiledetails":[
          {"publishedfileid":"7","title":"T","vote_data":{"score":0.91,"votes_up":10,"votes_down":1}},
          {"publishedfileid":"8","title":"U"}
        ]}}
        """
        let items = WorkshopResponseParser.parse(Data(json.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].voteScore, 0.91)
        XCTAssertNil(items[1].voteScore)
    }
```

- [ ] **Step 2: 실패 확인** — `swift test --filter WorkshopAPITests` → FAIL 2건.

- [ ] **Step 3: 구현**

`WorkshopAPI.swift`:
- `WorkshopItem`에 `let voteScore: Double?` 추가.
- `searchURL` queryItems 에 `.init(name: "return_vote_data", value: "true")` 추가.
- `item(from:)`에서:

```swift
        let vote = (obj["vote_data"] as? [String: Any]).flatMap { lenientDouble($0["score"]) }
```
  및 생성자에 `voteScore: vote` 전달. `lenientDouble` 헬퍼 추가(기존 lenientInt 패턴):

```swift
    private static func lenientDouble(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
```

`LibraryViewModel.swift`:

```swift
    /// 워크샵 다운로드 직후 평점 반영(0…1). 표시용 메타 — 실패 무해.
    func setRating(_ score: Double, for entry: LibraryEntry) {
        store.setRating(score, id: entry.id)
        entries = store.entries
    }
```

`WorkshopView.swift` `finishDownload`의 성공 분기 교체:

```swift
        guard let entry = library.importDownloaded(url) else {
            downloads[item.id] = DownloadUIState(phase: .failed, entryId: nil)
            return
        }
        if let score = item.voteScore { library.setRating(score, for: entry) }
        downloads[item.id] = DownloadUIState(phase: .done, entryId: entry.id)
```

- [ ] **Step 4: 통과 확인** — `swift test --filter WorkshopAPITests && swift test --filter WapleAppTests 2>&1 | tail -1`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Waple Tests/WapleAppTests/WorkshopAPITests.swift
git commit -m "기능(ui): 워크샵 평점 파이프라인 — return_vote_data 요청·voteScore 파싱·다운로드 시 저장"
```

---

### Task 6: 필터 사이드바 + 폴더 UI

**Files:**
- Create: `Sources/Waple/Surfaces/Installed/FilterSidebarView.swift`
- Modify: `Sources/Waple/Shell/MainWindowView.swift`, `Sources/Waple/WallpaperGridView.swift`

**Interfaces:**
- Consumes: `viewModel.criteria/availableTags/availableRatings/visibleFolders/activeFolder/moveToFolder/folders`(Task 4), `Metrics`.
- Produces: `FilterSidebarView(viewModel:)`. `Metrics.sidebarWidth: CGFloat = 220` 추가.
  스모크 지원: `MainWindowView`의 `showFilters` 초기값을 `ProcessInfo.processInfo.environment["WAPLE_SMOKE"] != nil`로(판정 캡처에 사이드바 노출).

- [ ] **Step 1: Metrics 추가** — `Metrics.swift`에 `static let sidebarWidth: CGFloat = 220`.

- [ ] **Step 2: FilterSidebarView 구현**

`Sources/Waple/Surfaces/Installed/FilterSidebarView.swift`:

```swift
import SwiftUI
import WapleLibrary

/// 설치됨 탭 필터 사이드바(WE 필터 패널의 네이티브 번역). 상태는 전부 viewModel.criteria.
struct FilterSidebarView: View {
    @ObservedObject var viewModel: LibraryViewModel

    var body: some View {
        List {
            Section {
                Toggle("즐겨찾기만", isOn: $viewModel.criteria.favoritesOnly)
                Button("필터 초기화") { viewModel.criteria = LibraryFilterCriteria() }
                    .disabled(!viewModel.criteria.isActive)
            } header: { Text("표시") }

            Section {
                ForEach([LibraryTypeFilter.scene, .video, .web], id: \.self) { t in
                    Toggle(t.label, isOn: binding(for: t, in: \.types))
                }
            } header: { Text("유형") }

            if !viewModel.availableRatings.isEmpty {
                Section {
                    ForEach(viewModel.availableRatings, id: \.self) { r in
                        Toggle(ratingLabel(r), isOn: binding(for: r, in: \.ratings))
                    }
                } header: { Text("나이 등급") }
            }

            if !viewModel.availableTags.isEmpty {
                Section {
                    HStack {
                        Button("전체") { viewModel.criteria.tags = Set(viewModel.availableTags) }
                        Button("없음") { viewModel.criteria.tags = [] }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    ForEach(viewModel.availableTags, id: \.self) { tag in
                        Toggle(tag, isOn: binding(for: tag, in: \.tags))
                    }
                } header: { Text("태그") }
            }
        }
        .listStyle(.sidebar)
        .frame(width: Metrics.sidebarWidth)
    }

    /// Set 멤버십 ↔ Toggle 바인딩(제네릭 — 타입/태그/등급 공용).
    private func binding<T: Hashable>(for value: T,
                                      in keyPath: WritableKeyPath<LibraryFilterCriteria, Set<T>>) -> Binding<Bool> {
        Binding(
            get: { viewModel.criteria[keyPath: keyPath].contains(value) },
            set: { on in
                if on { viewModel.criteria[keyPath: keyPath].insert(value) }
                else { viewModel.criteria[keyPath: keyPath].remove(value) }
            })
    }

    /// WE contentrating 원문 → 표시 라벨(미지 값은 원문 그대로).
    private func ratingLabel(_ raw: String) -> String {
        switch raw.lowercased() {
        case "everyone": return "전체 이용가"
        case "questionable": return "주의"
        case "mature": return "성인"
        default: return raw
        }
    }
}
```

- [ ] **Step 3: 셸 배선** — `MainWindowView.swift`:
- `@State private var showFilters = ProcessInfo.processInfo.environment["WAPLE_SMOKE"] != nil` 로 교체(스모크 캡처용 기본 노출).
- installed 분기 교체:

```swift
        case .installed:
            HStack(spacing: 0) {
                if showFilters {
                    FilterSidebarView(viewModel: viewModel)
                        .transition(.move(edge: .leading))
                    Divider()
                }
                WallpaperGridView(viewModel: viewModel)
                if panelVisible {
                    Divider()
                    SelectionPanelView(viewModel: viewModel)
                        .transition(.move(edge: .trailing))
                }
            }
```

- [ ] **Step 4: 그리드 폴더 타일 + 컨텍스트 메뉴** — `WallpaperGridView.swift`:
- `@State private var newFolderName = ""`, `@State private var folderPromptEntry: LibraryEntry?` 추가.
- `LazyVGrid` 내부 선두에 폴더 타일/뒤로 타일:

```swift
                        if let active = viewModel.activeFolder {
                            backTile(active)
                        }
                        ForEach(viewModel.visibleFolders, id: \.name) { folder in
                            folderTile(folder)
                        }
```

- 타일 뷰 2개 + 컨텍스트 메뉴 항목 추가:

```swift
    private func folderTile(_ folder: FolderStore.Folder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: Metrics.tileCorner)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25))
                Image(systemName: "folder.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(height: Metrics.tileThumbHeight)
            Text("\(folder.name)  ·  \(folder.ids.count)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.activeFolder = folder.name }
        .contextMenu {
            Button("폴더 삭제(항목은 유지)") {
                viewModel.folders.removeFolder(folder.name)
                viewModel.objectWillChange.send()
            }
        }
    }

    private func backTile(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: Metrics.tileCorner)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.15))
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 32)).foregroundStyle(.secondary)
            }
            .frame(height: Metrics.tileThumbHeight)
            Text("뒤로 — \(name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { viewModel.activeFolder = nil }
    }
```

- `contextMenu(for:supported:)`에 추가(재생목록 버튼 아래):

```swift
        Menu("폴더로 이동") {
            Button("새 폴더…") { folderPromptEntry = entry }
            if !viewModel.folders.folders.isEmpty { Divider() }
            ForEach(viewModel.folders.folders, id: \.name) { f in
                Button(f.name) { viewModel.moveToFolder(entry, folder: f.name) }
            }
            if viewModel.folders.folderName(of: entry.id) != nil {
                Divider()
                Button("폴더에서 제거") { viewModel.moveToFolder(entry, folder: nil) }
            }
        }
```

- `body` 말미(onDrop 뒤)에 새 폴더 알럿:

```swift
        .alert("새 폴더", isPresented: Binding(get: { folderPromptEntry != nil },
                                              set: { if !$0 { folderPromptEntry = nil } })) {
            TextField("폴더 이름", text: $newFolderName)
            Button("만들기") {
                if let e = folderPromptEntry, !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty {
                    viewModel.moveToFolder(e, folder: newFolderName)
                }
                newFolderName = ""; folderPromptEntry = nil
            }
            Button("취소", role: .cancel) { newFolderName = ""; folderPromptEntry = nil }
        }
```

- [ ] **Step 5: 빌드+테스트+스모크** — `swift build && swift test --filter WapleAppTests 2>&1 | tail -1 && { WAPLE_SMOKE=1 .build/debug/Waple & APP=$!; sleep 6; WID=$(swift scripts/window-id.swift Waple); screencapture -l"$WID" -x /tmp/sp2-t6.png; kill $APP; }` — 사이드바(표시/유형/태그 섹션) 노출 확인.

- [ ] **Step 6: Commit**

```bash
git add Sources/Waple
git commit -m "기능(ui): 필터 사이드바(즐겨찾기·유형·등급·태그) + 라이브러리 폴더 타일·이동 메뉴"
```

---

### Task 7: 상세 패널 액션 + 속성 편집기 정돈

**Files:**
- Modify: `Sources/Waple/SelectionPanelView.swift`, `Sources/Waple/PropertyEditorView.swift`
- Test: `Tests/WapleAppTests/PropertyLabelTests.swift` (신규)

**Interfaces:**
- Produces: `enum PropertyLabel { static func pretty(text: String?, key: String) -> String }` (순수).
  패널: 제목 옆 ♥ 즐겨찾기 토글, 평점 표시(rating 있을 때 "★ 4.6/5"), "라이브러리에서 제거"(role destructive + confirmationDialog → viewModel.remove).
  PropertyEditorView: 자체 헤더(제목·초기화 행) 제거 → 컨트롤 목록만. 초기화는 패널 "속성" 행으로 이동.

- [ ] **Step 1: 실패 테스트**

`Tests/WapleAppTests/PropertyLabelTests.swift`:

```swift
import XCTest
@testable import Waple

final class PropertyLabelTests: XCTestCase {
    func testHTMLStripped() {
        XCTAssertEqual(PropertyLabel.pretty(text: "<b>Color</b>", key: "c"), "Color")
    }
    func testLocalizationKeyPrettified() {
        XCTAssertEqual(PropertyLabel.pretty(text: "ui_browse_properties_scheme_color", key: "schemecolor"),
                       "Scheme color")
        XCTAssertEqual(PropertyLabel.pretty(text: nil, key: "playback_speed"), "Playback speed")
    }
    func testNormalTextPassesThrough() {
        XCTAssertEqual(PropertyLabel.pretty(text: "재생 속도", key: "rate"), "재생 속도")
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter PropertyLabelTests` → FAIL.

- [ ] **Step 3: 구현**

`PropertyEditorView.swift`:
- 파일 상단에 순수 헬퍼 추가:

```swift
/// 속성 라벨 표시(순수): HTML 태그 제거 + 미번역 로컬라이즈 키(ui_*/스네이크 케이스) 정돈.
enum PropertyLabel {
    static func pretty(text: String?, key: String) -> String {
        var raw = (text?.isEmpty == false ? text! : key)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 미번역 키 감지: 공백 없이 [a-z0-9_] 만이고 '_' 포함 — 접두 제거 후 사람이 읽게.
        let keyLike = raw.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil && raw.contains("_")
        guard keyLike else { return raw }
        for prefix in ["ui_browse_properties_", "ui_properties_", "ui_"] where raw.hasPrefix(prefix) {
            raw = String(raw.dropFirst(prefix.count))
            break
        }
        let words = raw.split(separator: "_").map(String.init)
        guard let first = words.first else { return raw }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}
```

- 기존 `label(_ p:)` 본문을 `PropertyLabel.pretty(text: p.text, key: p.key)` 호출로 교체.
- `body`의 헤더 `HStack { Text("\(entry.title) — 속성") ... 초기화 }` 와 그 아래 `Divider()` 를 삭제하고, 빈 상태/목록만 남긴다(패딩은 유지). `resetProperties` 호출부가 사라지므로 아래 패널에서 노출한다.

`SelectionPanelView.swift`:
- 제목 행을 HStack 으로 교체(♥ + 평점):

```swift
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.title).font(.title3.weight(.semibold)).lineLimit(2)
                        Spacer()
                        Button {
                            viewModel.toggleFavorite(entry)
                        } label: {
                            Image(systemName: viewModel.isFavorite(entry) ? "heart.fill" : "heart")
                                .foregroundStyle(viewModel.isFavorite(entry) ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help(viewModel.isFavorite(entry) ? "즐겨찾기 해제" : "즐겨찾기")
                    }
                    HStack(spacing: 6) {
                        Text(NowPlayingSubtitle.typeLabel(entry.typeRaw) + (supported ? "" : " · 지원 예정"))
                        if let r = entry.rating {
                            Label(String(format: "%.1f/5", r * 5), systemImage: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
```

- 액션 블록 끝(웹 조작 버튼 뒤)에 제거 버튼 + 다이얼로그 상태:

```swift
    @State private var confirmRemove = false
```

```swift
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Label("라이브러리에서 제거", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .confirmationDialog("'\(entry.title)'을(를) 라이브러리에서 제거할까요?",
                                        isPresented: $confirmRemove) {
                        Button("제거(파일은 유지)", role: .destructive) { viewModel.remove(entry) }
                        Button("취소", role: .cancel) {}
                    } message: {
                        Text("디스크의 원본 폴더는 삭제되지 않습니다. 재생목록·모니터 할당·즐겨찾기·폴더에서 함께 제거됩니다.")
                    }
```

- "속성" Divider 아래를 초기화 포함 행으로:

```swift
                HStack {
                    Text("속성").font(.headline)
                    Spacer()
                    Button("초기화") { viewModel.resetProperties(for: entry) }
                        .font(.caption)
                }
                PropertyEditorView(entry: entry, viewModel: viewModel).id(entry.id)
```

주의: `resetProperties` 후 편집기 상태 리프레시는 `.id(entry.id)`로는 안 됨(같은 id) — PropertyEditorView 가 onAppear 에서 로드하므로, 초기화 버튼은 `viewModel.resetProperties(for: entry)` 뒤 `viewModel.objectWillChange.send()` 를 함께 호출하고, PropertyEditorView 의 `props` 로드를 `.onAppear` + `.onReceive(viewModel.objectWillChange)`… 은 과함 — **간단히**: PropertyEditorView 에 `func reload()` 대신, 패널 초기화 버튼을 PropertyEditorView 내부로 두지 않기로 한 결정을 유지하되 리로드는 `.id(UUID())` 강제 대신 다음으로: SelectionPanelView 에 `@State private var propsGeneration = 0`, 초기화 버튼에서 `propsGeneration += 1`, `PropertyEditorView(...).id("\(entry.id)-\(propsGeneration)")`. (재마운트 = onAppear 재로드.)

- [ ] **Step 4: 통과 확인** — `swift test --filter PropertyLabelTests && swift build && swift test --filter WapleAppTests 2>&1 | tail -1`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Waple Tests/WapleAppTests/PropertyLabelTests.swift
git commit -m "기능(ui): 패널 즐겨찾기·평점·제거(확인 다이얼로그) + 속성 라벨 정돈·중복 헤더 제거"
```

---

### Task 8: 통합 검증 + 판정 캡처

**Files:** 없음(검증만)

- [ ] **Step 1: 3스위트 전체** — `swift test --filter WapleAppTests 2>&1 | tail -1 && swift test --filter WapleLibraryTests 2>&1 | tail -1 && swift test --filter WapleCoreTests 2>&1 | tail -1` → 전부 PASS(앱 스위트 기대: 기존 121 + 제거 1 + 필터 재작성 9(−5) + 평점 2 + 라벨 3 ≈ 131±, 정확 수는 출력 기준).

- [ ] **Step 2: 판정 캡처** — 사이드바 열림 상태(스모크 기본):

```bash
swift build
WAPLE_SMOKE=1 .build/debug/Waple & APP=$!
sleep 6
WID=$(swift scripts/window-id.swift Waple)
screencapture -l"$WID" -x /tmp/waple-sp2-filters.png
kill $APP
```

- [ ] **Step 3: 사용자 판정 요청** — /tmp/waple-sp2-filters.png 제시: 사이드바·폴더 타일·패널 액션이 네이티브답고 쓸만한가. 판정 통과 = SP2′ 완료.

---

## 태스크 순서와 의존

1(메타) → 2(스토어) → 3(제거+VM init 변경) → 4(필터 모델) → 5(평점) → 6(사이드바+폴더 UI) → 7(패널+편집기) → 8(검증·판정).
3의 VM init 변경과 4의 typeFilter 삭제는 각각 호출부 동시 수정 필수(태스크 내 명시). 매 커밋 그린.

## SP2′에서 의도적으로 안 하는 것

- 사이드바 해상도 필터(WE 참조에 있으나 메타 수집 필요 — 요청 시), 정렬 방향 토글(YAGNI)
- 디스플레이 화면(SP3′)·검색 탭(SP4′)·설정 창/트레이(SP5′)
- 워크샵 타일 평점 표시(SP4′에서 창작마당 재작성과 함께)
