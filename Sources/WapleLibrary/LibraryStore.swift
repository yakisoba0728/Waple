import Foundation
import WapleCore

public final class LibraryStore {
    private let baseDirectory: URL
    private let indexURL: URL
    public private(set) var entries: [LibraryEntry] = []
    public private(set) var selectedId: String?

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

    private func save() {
        guard !indexLoadFailed else {
            NSLog("%@", "[Waple] library index save skipped at \(indexURL.path) — earlier read failed transiently, avoiding clobber")
            return
        }
        backupCorruptStoreFile(indexURL, &indexCorrupt)  // 손상 원본을 덮어쓰기 전 1회 백업
        let idx = Index(entries: entries, selectedId: selectedId)
        do {
            let data = try JSONEncoder().encode(idx)
            try data.write(to: indexURL, options: [.atomic])
        } catch {
            NSLog("%@", "[Waple] failed to save library index at \(indexURL.path): \(error)")
        }
    }

    @discardableResult
    public func importFolder(_ folderURL: URL) throws -> LibraryEntry {
        let project = try ProjectJSONParser.parse(folderURL: folderURL)
        let bookmark = try folderURL.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        // F194: id 충돌 시, 기존 엔트리가 이 폴더와 다른 실경로(=서로 다른 배경이 우연히 같은 id로
        // 귀결 — 예: workshopid 없는 두 배경이 같은 폴더명)를 가리키면 무통지 대체(엔트리 실종 +
        // 북마크 앨리어싱) 대신 접미로 유일화해 둘 다 보존한다. 같은 실경로(재가져오기/갱신)면
        // 종전대로 덮어쓴다(테스트: testReimportUpdatesEntryAndMovesToEnd).
        var id = project.id
        if let existing = entries.first(where: { $0.id == id }),
           let existingURL = resolveFolderURL(for: existing),
           existingURL.standardizedFileURL != folderURL.standardizedFileURL {
            id = uniqueEntryId(basedOn: id)
        }
        let entry = LibraryEntry(
            id: id,
            title: project.title,
            typeRaw: project.type.storageString,
            fileName: project.fileName,
            previewName: project.previewName,
            bookmark: bookmark,
            tags: project.tags,
            contentRating: project.contentRating
        )
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        save()
        return entry
    }

    /// 이미 쓰이는 id 와 충돌할 때 접미(-2, -3, …)로 유일화한다.
    private func uniqueEntryId(basedOn base: String) -> String {
        let existingIds = Set(entries.map(\.id))
        var n = 2
        while existingIds.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    @discardableResult
    public func importParent(_ parentURL: URL) -> [LibraryEntry] {
        let fm = FileManager.default
        // 사용자가 상위 폴더가 아니라 개별 배경 폴더(project.json 포함)를 직접 고른 경우,
        // 하위 폴더만 순회하면 아무것도 가져오지 못한다. 자신이 배경 폴더면 직접 가져온다.
        if fm.fileExists(atPath: parentURL.appendingPathComponent("project.json").path) {
            if let entry = try? importFolder(parentURL) { return [entry] }
            return []
        }
        let subs = (try? fm.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var imported: [LibraryEntry] = []
        for sub in subs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let entry = try? importFolder(sub) { imported.append(entry) }
        }
        return imported
    }

    /// zip 을 임시 디렉터리에 풀어, 담긴 모든 배경을 가져온다(작업 4).
    /// 배경 폴더는 관리 위치(base/imported/<폴더명>)로 **이동**해 북마크가 임시 정리 후에도 유효하게 한다
    /// (importFolder 는 폴더를 그 자리에서 북마크만 하므로, 임시 해제물을 지우면 엔트리가 깨진다).
    /// `extract` 주입으로 테스트 가능(기본 ditto). 가져온 엔트리 반환.
    @discardableResult
    public func importZip(_ zipURL: URL,
                          extract: (URL, URL) -> Bool = ZipImporter.dittoExtract) -> [LibraryEntry] {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("WapleZip-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: temp, withIntermediateDirectories: true)) != nil,
              extract(zipURL, temp) else {
            try? fm.removeItem(at: temp)
            return []
        }
        defer { try? fm.removeItem(at: temp) }   // 임시 해제 작업공간 정리

        let importedDir = baseDirectory.appendingPathComponent("imported", isDirectory: true)
        try? fm.createDirectory(at: importedDir, withIntermediateDirectories: true)

        var imported: [LibraryEntry] = []
        var usedNames = Set<String>()   // 이번 zip 안의 동명 루트(WE export 관례 `Wallpaper/`) 상호 덮어쓰기 방지
        for root in ZipImporter.findProjectRoots(in: temp, fileManager: fm) {
            // F247: 관리 폴더명은 원본 래퍼 폴더명이 아니라 **project.json 이 선언한 id**
            // (workshopid 우선, 없으면 폴더명 폴백 — ProjectJSONParser.parse 와 동일 규칙)로 정한다.
            // 래퍼명(WE export 관례 `Wallpaper/`)은 비유일이라 그대로 쓰면, 동명이나 서로 다른
            // 배경의 두 번째 zip import 가 첫 배경의 관리 폴더를 조용히 지우고 그 위에 얹혀
            // 첫 엔트리의 북마크가 두 번째 배경 콘텐츠로 앨리어싱된다(무경고 데이터 손실).
            // move 전, 아직 임시 해제 위치에 있는 root 에서 미리 파싱한다.
            let parsed = try? ProjectJSONParser.parse(folderURL: root)
            let hasStableId = parsed?.workshopId != nil   // 전역 유일 식별자 — 있으면 재import 를 확정할 수 있다
            var name = parsed?.id ?? root.lastPathComponent
            if usedNames.contains(name) {
                name = uniqueManagedName(name, usedNames: usedNames, in: importedDir, fm: fm)
            }
            // 콜 간(이전 import) 충돌: workshopid 로 정체성이 확정된 경우만 "같은 배경 재가져오기"로
            // 보고 덮어쓴다. 확정할 수 없는데(workshopid 없음) 관리 폴더가 이미 있으면 지우지 않고
            // 유일화한다 — 폴더명 폴백만으로는 서로 다른 배경을 구분할 수 없기 때문(무통지 데이터 손실 방지).
            if fm.fileExists(atPath: importedDir.appendingPathComponent(name).path), !hasStableId {
                name = uniqueManagedName(name, usedNames: usedNames, in: importedDir, fm: fm)
            }
            usedNames.insert(name)
            let dest = importedDir.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: dest)
            guard (try? fm.moveItem(at: root, to: dest)) != nil,
                  let entry = try? importFolder(dest) else { continue }
            imported.append(entry)
        }
        return imported
    }

    private func uniqueManagedName(_ base: String, usedNames: Set<String>, in importedDir: URL, fm: FileManager) -> String {
        var n = 2
        while usedNames.contains("\(base)-\(n)")
                || fm.fileExists(atPath: importedDir.appendingPathComponent("\(base)-\(n)").path) { n += 1 }
        return "\(base)-\(n)"
    }

    public func select(_ id: String) {
        selectedId = id
        save()
    }

    /// 엔트리 제거(파일은 건드리지 않음 — 인덱스 등록 해제). 선택 중이었으면 선택 해제.
    /// 스토어 간 orphan 정리는 호출자(LibraryViewModel.remove)가 오케스트레이션한다.
    public func remove(id: String) {
        entries.removeAll { $0.id == id }
        if selectedId == id { selectedId = nil }
        save()
    }

    public func resolveFolderURL(for entry: LibraryEntry) -> URL? {
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
        if stale, let fresh = try? resolved.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
           let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].bookmark = fresh
            save()
        }
        return resolved
    }

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
}
