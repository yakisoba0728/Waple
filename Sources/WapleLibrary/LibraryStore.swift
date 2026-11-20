import Foundation
import WapleCore

/// `@unchecked Sendable` 근거 — 이 클래스가 지키는 두 규율을 타입에 적어 둔 것이다.
///
/// 1) **가변 상태(`entries`/`selectedId`/library.json 쓰기)는 메인 스레드 전용이다.** 임포트
///    경로(`LibraryViewModel.importParent/importZip/importVideoFile`)가 무거운 I/O 를 백그라운드
///    큐에서 돌리면서도 스토어 등록만은 반드시 `DispatchQueue.main.async` 홉 안에서 하는 것이
///    그 규율이고, 각 함수의 주석("스토어 변경 메인 한정 규약 유지")이 근거다.
/// 2) **백그라운드에서 불리는 두 메서드는 인스턴스 상태를 아예 건드리지 않는다** —
///    `scanImportableFolders`(FileManager 순회)와 `extractZipToTemp`(ditto 해제)는 `self` 의
///    저장 프로퍼티를 읽지도 쓰지도 않는다. 즉 큐를 넘어가는 것은 참조뿐이고 그 참조로 하는 일이
///    순수하다.
///
/// 컴파일러는 (1)도 (2)도 볼 수 없다. 규율이 깨지는 순간(백그라운드에서 `entries` 를 만지는 코드가
/// 새로 생기면) 이 표기는 거짓이 되므로, 새 메서드를 백그라운드에서 부르기 전에 위 둘을 확인할 것.
public final class LibraryStore: @unchecked Sendable {
    private let baseDirectory: URL
    public var storageDirectory: URL { baseDirectory }
    private let indexURL: URL
    public private(set) var entries: [LibraryEntry] = []
    public private(set) var selectedId: String?

    /// 감사 V06 회귀 테스트 계측: save() 호출 횟수(일괄 임포트의 인덱스 재작성 횟수 검증용).
    private(set) var saveCount = 0

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
        self.indexURL = baseDirectory.appendingPathComponent("library.json")
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("%@", "[Waple] failed to create library directory at \(baseDirectory.path): \(error)")
        }
        load()
        backfillMetadataIfNeeded()
    }

    public static func defaultBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Waple", isDirectory: true)
    }

    private struct Index: Codable {
        var entries: [LibraryEntry]
        var selectedId: String?
    }

    /// load() 가 손상된 인덱스를 발견하면 true. 다음 save() 는 덮어쓰기 전에 원본을 백업해
    /// 복구 가능한 파일을 무음으로 파괴하는 것을 막는다.
    private var indexCorrupt = false
    /// load() 에서 읽기 자체가 실패(권한·잠금 등 일시적) → 원본이 멀쩡할 수 있어 save() 를 건너뛴다.
    private var indexLoadFailed = false

    private func load() {
        guard let data = readStoreFile(indexURL, what: "library index at \(indexURL.path)",
                                       note: "starting empty", loadFailed: &indexLoadFailed) else { return }
        do {
            let idx = try JSONDecoder().decode(Index.self, from: data)
            entries = idx.entries
            selectedId = idx.selectedId
        } catch {
            NSLog("%@", "[Waple] library index corrupt at \(indexURL.path): \(error) — preserving file, starting empty")
            indexCorrupt = true
        }
    }

    public enum PersistenceError: Error {
        case indexUnavailable
        case indexWriteFailed(Error)
    }

    private func writeIndex(entries: [LibraryEntry], selectedId: String?) throws {
        saveCount += 1
        guard !indexLoadFailed else {
            throw PersistenceError.indexUnavailable
        }
        guard backupCorruptStoreFile(indexURL, &indexCorrupt) else {
            throw PersistenceError.indexUnavailable
        }
        let idx = Index(entries: entries, selectedId: selectedId)
        do {
            let data = try JSONEncoder().encode(idx)
            try data.write(to: indexURL, options: [.atomic])
        } catch {
            throw PersistenceError.indexWriteFailed(error)
        }
    }

    private func save() {
        do {
            try writeIndex(entries: entries, selectedId: selectedId)
        } catch {
            NSLog("%@", "[Waple] failed to save library index at \(indexURL.path): \(error)")
        }
    }

    @discardableResult
    public func importFolder(_ folderURL: URL, workshopItemID: String? = nil,
                             rating: Double? = nil) throws -> LibraryEntry {
        var next = entries
        let entry = try register(folderURL, in: &next, workshopItemID: workshopItemID, rating: rating)
        try writeIndex(entries: next, selectedId: selectedId)
        entries = next
        return entry
    }

    /// Prepare an index entry without publishing the batch until its single write succeeds.
    private func register(_ folderURL: URL, in entries: inout [LibraryEntry],
                          workshopItemID: String? = nil, rating: Double? = nil,
                          reuseExisting: Bool = true) throws -> LibraryEntry {
        let project = try ProjectJSONParser.parse(folderURL: folderURL)
        let bookmark = try folderURL.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        // F194: id 충돌 시, 기존 엔트리가 이 폴더와 다른 실경로(=서로 다른 배경이 우연히 같은 id로
        // 귀결 — 예: workshopid 없는 두 배경이 같은 폴더명)를 가리키면 무통지 대체(엔트리 실종 +
        // 북마크 앨리어싱) 대신 접미로 유일화해 둘 다 보존한다. 같은 실경로(재가져오기/갱신)면
        // 종전대로 덮어쓴다(테스트: testReimportUpdatesEntryAndMovesToEnd).
        let source = folderURL.resolvingSymlinksInPath().standardizedFileURL
        let sameSource = entries.first { existing in
            reuseExisting && (existing.id == project.id || isUniquifiedVariant(existing.id, base: project.id))
                && resolveFolderURL(for: existing, refreshing: false)?.resolvingSymlinksInPath().standardizedFileURL == source
        }
        let id = sameSource?.id ?? uniqueEntryId(basedOn: project.id, entries: entries)
        let entry = LibraryEntry(
            id: id,
            title: project.title,
            typeRaw: project.type.storageString,
            fileName: project.fileName,
            previewName: project.previewName,
            bookmark: bookmark,
            tags: project.tags,
            contentRating: project.contentRating,
            rating: rating.flatMap { (0...1).contains($0) ? $0 : nil } ?? sameSource?.rating,
            workshopItemID: workshopItemID ?? sameSource?.workshopItemID ?? Self.steamWorkshopItemID(for: source),
            installationID: sameSource != nil ? sameSource?.installationID : UUID()
        )
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        return entry
    }

    /// id 가 base 의 유일화 변형("base-2", "base-3" …)인지(F581 — 재임포트 동일 소스 탐색).
    private func isUniquifiedVariant(_ id: String, base: String) -> Bool {
        guard id.hasPrefix("\(base)-") else { return false }
        return Int(id.dropFirst(base.count + 1)) != nil
    }

    /// 이미 쓰이는 id 와 충돌할 때 접미(-2, -3, …)로 유일화한다.
    private func uniqueEntryId(basedOn base: String, entries: [LibraryEntry]) -> String {
        let existingIds = Set(entries.map(\.id))
        guard existingIds.contains(base) else { return base }
        var n = 2
        while existingIds.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    @discardableResult
    public func importParent(_ parentURL: URL) -> [LibraryEntry] {
        importFolders(scanImportableFolders(in: parentURL))
    }

    /// importParent 의 1단계 — 가져올 배경 폴더 후보 나열(순수 I/O, entries/index 무접촉).
    /// F582: 백그라운드 큐에서 호출 가능(메인 스레드 동기 I/O 방지 — LibraryViewModel.importParent 가
    /// importQueue 경유로 이 단계를 백그라운드에서 돌린다).
    public func scanImportableFolders(in parentURL: URL) -> [URL] {
        let fm = FileManager.default
        // 사용자가 상위 폴더가 아니라 개별 배경 폴더(project.json 포함)를 직접 고른 경우,
        // 하위 폴더만 순회하면 아무것도 가져오지 못한다. 자신이 배경 폴더면 직접 가져온다.
        if fm.fileExists(atPath: parentURL.appendingPathComponent("project.json").path) {
            return [parentURL]
        }
        let subs = (try? fm.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return subs.filter { sub in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: sub.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// scanImportableFolders 결과를 순서대로 가져온다(스토어 변경 — 메인 스레드 규약).
    /// F582: 일괄 임포트는 폴더마다 저장하지 않고 마지막에 한 번만 save() 한다(호출마다 전체
    /// 인덱스 재작성이 누적되는 O(n²) 방지).
    @discardableResult
    public func importFolders(_ folderURLs: [URL]) -> [LibraryEntry] {
        do { return try importFoldersPersisting(folderURLs) }
        catch {
            NSLog("%@", "[Waple] failed to commit imported folders: \(error)")
            return []
        }
    }

    public func importFoldersPersisting(_ folderURLs: [URL]) throws -> [LibraryEntry] {
        var next = entries
        var imported: [LibraryEntry] = []
        for url in folderURLs {
            if let entry = try? register(url, in: &next) { imported.append(entry) }
        }
        if !imported.isEmpty {
            try writeIndex(entries: next, selectedId: selectedId)
            entries = next
        }
        return imported
    }

    /// zip 을 임시 디렉터리에 풀어, 담긴 모든 배경을 가져온다(작업 4).
    /// 배경 폴더는 관리 위치(base/imported/<폴더명>)로 **이동**해 북마크가 임시 정리 후에도 유효하게 한다
    /// (importFolder 는 폴더를 그 자리에서 북마크만 하므로, 임시 해제물을 지우면 엔트리가 깨진다).
    /// `extract` 주입으로 테스트 가능(기본 ditto). 가져온 엔트리 반환.
    @discardableResult
    public func importZip(_ zipURL: URL,
                          extract: (URL, URL) throws -> Bool = ZipImporter.dittoExtract) -> [LibraryEntry] {
        guard let temp = extractZipToTemp(zipURL, extract: extract) else { return [] }
        return importExtractedZip(temp)
    }

    /// zip 해제 단계(A2 — ditto waitUntilExit 블로킹 구간을 백그라운드 큐로 넘기기 위한 분리).
    /// 스토어 상태(entries/index)를 전혀 건드리지 않으므로 백그라운드 호출이 안전하다.
    /// 성공 시 해제된 임시 디렉터리(호출자가 importExtractedZip 에 넘겨 등록·정리), 실패 시 nil(정리됨).
    public func extractZipToTemp(_ zipURL: URL,
                                 extract: (URL, URL) throws -> Bool = ZipImporter.dittoExtract) -> URL? {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("WapleZip-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: temp, withIntermediateDirectories: true)) != nil,
              (try? extract(zipURL, temp)) == true else {
            try? fm.removeItem(at: temp)
            return nil
        }
        return temp
    }

    /// extractZipToTemp 가 해제해 둔 임시 디렉터리의 배경들을 관리 위치로 옮겨 가져온다.
    /// 스토어 변경(importFolder → entries/save)을 포함하므로 스토어 규약대로 메인 스레드에서 호출.
    /// temp 는 성공/실패 무관하게 항상 정리된다.
    @discardableResult
    public func importExtractedZip(_ temp: URL) -> [LibraryEntry] {
        importExtractedZipCounting(temp).imported
    }

    /// 위와 같되 **시도한 개수**를 함께 돌려준다.
    ///
    /// 성공 개수만으로는 부분 실패를 사용자에게 전할 수 없다 — zip 안에 배경이 다섯인데 셋만
    /// 들어와도 화면에는 아무 말이 없고, 왜 둘이 빠졌는지는 로그(F584)를 봐야만 알 수 있었다.
    /// 시도 수를 아는 것은 이 루프뿐이라 여기서 함께 내보낸다. 기존 반환형을 바꾸지 않으려고
    /// 메서드를 더한 것이다 — 이 타깃의 시그니처 변경은 최소로 한다.
    public func importExtractedZipCounting(_ temp: URL) -> (imported: [LibraryEntry], attempted: Int) {
        do { return try importExtractedZipPersisting(temp) }
        catch {
            NSLog("%@", "[Waple] failed to commit imported archive: \(error)")
            return ([], 0)
        }
    }

    public func importExtractedZipPersisting(_ temp: URL) throws -> (imported: [LibraryEntry], attempted: Int) {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: temp) }   // 임시 해제 작업공간 정리
        let importedDir = baseDirectory.appendingPathComponent("imported", isDirectory: true)
        let roots = ZipImporter.findProjectRoots(in: temp, fileManager: fm)
        guard !roots.isEmpty else { return ([], 0) }
        try fm.createDirectory(at: importedDir, withIntermediateDirectories: true)
        var next = entries
        var imported: [LibraryEntry] = []
        var movedFolders: [URL] = []
        var reservedNames = Set(entries.map(\.id))
        for entry in entries {
            if let folder = resolveFolderURL(for: entry, refreshing: false),
               folder.deletingLastPathComponent().standardizedFileURL.path == importedDir.standardizedFileURL.path {
                reservedNames.insert(folder.lastPathComponent)
            }
        }
        for root in roots {
            guard let project = try? ProjectJSONParser.parse(folderURL: root) else { continue }
            // An archive can claim any workshop ID. Never replace another managed folder from its claim.
            let baseName = WallpaperPathSecurity.normalizedPathComponent(project.id) ?? root.lastPathComponent
            let name = uniqueManagedName(baseName, reservedNames: reservedNames, in: importedDir, fm: fm)
            let dest = importedDir.appendingPathComponent(name, isDirectory: true)
            do {
                try fm.moveItem(at: root, to: dest)
            } catch {
                NSLog("%@", "[Waple] failed to move \(root.path) into library: \(error) — skipping")
                continue
            }
            do {
                let entry = try register(dest, in: &next, reuseExisting: false)
                imported.append(entry)
                movedFolders.append(dest)
                reservedNames.insert(name)
            } catch {
                NSLog("%@", "[Waple] failed to register imported folder \(dest.path): \(error) — rolling back")
                try? fm.removeItem(at: dest)
            }
        }
        if !imported.isEmpty {
            do { try writeIndex(entries: next, selectedId: selectedId) }
            catch {
                for folder in movedFolders { try? fm.removeItem(at: folder) }
                throw error
            }
            entries = next
        }
        return (imported, roots.count)
    }

    private func uniqueManagedName(_ base: String, reservedNames: Set<String>, in importedDir: URL, fm: FileManager) -> String {
        func isTaken(_ name: String) -> Bool {
            reservedNames.contains(name) || fm.fileExists(atPath: importedDir.appendingPathComponent(name).path)
        }
        guard isTaken(base) else { return base }
        var n = 2
        while isTaken("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    public func select(_ id: String) {
        selectedId = id
        save()
    }

    /// 엔트리 제거(파일은 건드리지 않음 — 인덱스 등록 해제). 선택 중이었으면 선택 해제.
    /// 스토어 간 orphan 정리는 호출자(LibraryViewModel.remove)가 오케스트레이션한다.
    @discardableResult
    public func remove(id: String) -> Bool {
        let next = entries.filter { $0.id != id }
        let selection = selectedId == id ? nil : selectedId
        do { try writeIndex(entries: next, selectedId: selection) }
        catch {
            NSLog("%@", "[Waple] failed to remove library entry: \(error)")
            return false
        }
        entries = next
        selectedId = selection
        return true
    }

    public func resolveFolderURL(for entry: LibraryEntry) -> URL? {
        resolveFolderURL(for: entry, refreshing: true)
    }

    private func resolveFolderURL(for entry: LibraryEntry, refreshing: Bool) -> URL? {
        var stale = false
        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: entry.bookmark,
                options: [], relativeTo: nil, bookmarkDataIsStale: &stale
            )
        } catch {
            NSLog("%@", "[Waple] failed to resolve bookmark for entry \(entry.id) (\(entry.title)): \(error)")
            return nil
        }
        // macOS 가 stale 을 표시하면 북마크를 재생성·영속화해야 향후 해석 실패를 막는다.
        // F840: 그 영속화를 **다음 런루프로 미룬다**. resolveFolderURL 은 LibraryViewModel.previewState
        // 경유로 SwiftUI `body` 평가 중에 불린다 — 종전에는 그 자리에서 entries 를 변형하고
        // library.json 을 통째로 다시 쓰는 동기 디스크 I/O 가 일어났다(뷰 업데이트 중 상태 변경 +
        // 그리드 스크롤마다 쓰기). 해석 결과는 지금 그대로 돌려주고 저장만 뒤로 미루면
        // 재해석 비용도, 저장 목적(다음 실행에서의 해석 실패 방지)도 그대로다.
        if refreshing, stale, let fresh = try? resolved.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            let entryId = entry.id
            let original = entry.bookmark
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let idx = self.entries.firstIndex(where: { $0.id == entryId }),
                      self.entries[idx].bookmark == original, original != fresh else { return }
                self.entries[idx].bookmark = fresh
                self.save()
            }
        }
        return resolved
    }

    /// 워크샵 평점 저장(0…1). 미존재 id 는 no-op.
    public func setRating(_ rating: Double, id: String) {
        guard (0...1).contains(rating), let i = entries.firstIndex(where: { $0.id == id }) else { return }
        var next = entries
        next[i].rating = rating
        do { try writeIndex(entries: next, selectedId: selectedId) }
        catch {
            NSLog("%@", "[Waple] failed to save workshop rating: \(error)")
            return
        }
        entries = next
    }

    private static func steamWorkshopItemID(for folder: URL) -> String? {
        let components = Array(folder.pathComponents.suffix(5))
        guard components.count == 5,
              components.prefix(4).elementsEqual(["steamapps", "workshop", "content", "431960"]),
              let id = components.last, (1...20).contains(id.utf8.count),
              id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return id
    }

    /// 구버전 인덱스(tags==nil) 엔트리의 tags/contentRating 을 디스크 project.json 에서 1회 백필.
    ///
    /// **[2026-09-01 r3-M64] 실패 두 종류를 가른다.**
    /// `tags == nil` 은 "아직 백필 안 함" 이고 `[]` 는 "백필했는데 태그가 없더라" 다 —
    /// 재시도 조건이 `== nil` 이라 **`[]` 로 마킹하면 영영 다시 안 본다.** 그런데 종전에는
    /// **북마크 해석 실패도** 같은 `[]` 로 마킹했다. 북마크 해석 실패는 외장 볼륨 미마운트·
    /// 네트워크 볼륨 미연결처럼 **일시적**일 수 있는데(그래서 `resolveFolderURL` 은 stale
    /// 북마크를 재생성·영속화하는 경로까지 갖고 있다), `init` 이 무조건 이 함수를 부르므로
    /// **볼륨을 안 꽂은 채 한 번만 기동해도 그 배경의 태그가 영구 소실**됐다.
    ///
    /// 이제 해석 실패(`resolveFolderURL == nil`)는 `nil` 로 남겨 다음 실행에 다시 시도한다.
    /// 폴더는 열렸는데 `project.json` 파스가 실패한 경우만 `[]` 로 못 박는다 — 그쪽은
    /// 볼륨이 붙어 있는 상태에서 관측한 **안정적** 결과다.
    ///
    /// 비용: 미해석 엔트리 수만큼 북마크 해석이 매 실행 1회 더 돈다(디스크 읽기는 없다).
    /// 종전의 "매 실행 재시도 I/O 를 막는다" 는 목적은 **파스 I/O** 쪽에서 그대로 유지된다.
    func backfillMetadataIfNeeded() {
        var changed = false
        for i in entries.indices where entries[i].tags == nil || entries[i].workshopItemID == nil {
            guard let folder = resolveFolderURL(for: entries[i], refreshing: entries[i].tags == nil) else {
                continue   // 일시적일 수 있다 — nil 로 남겨 다음 실행에 재시도
            }
            if entries[i].workshopItemID == nil,
               let id = Self.steamWorkshopItemID(for: folder),
               let manifest = WallpaperPathSecurity.containedFileURL("project.json", root: folder),
               (try? manifest.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                entries[i].workshopItemID = id
                changed = true
            }
            guard entries[i].tags == nil else { continue }
            changed = true
            guard let project = try? ProjectJSONParser.parse(folderURL: folder) else {
                entries[i].tags = []   // 볼륨은 붙어 있는데 project.json 이 없거나 깨졌다(안정적)
                continue
            }
            entries[i].tags = project.tags
            entries[i].contentRating = project.contentRating
        }
        if changed { save() }
    }
}
