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

    private func load() {
        guard let data = readStoreFile(indexURL, what: "library index at \(indexURL.path)",
                                       note: "starting empty", corrupt: &indexCorrupt) else { return }
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
        let entry = LibraryEntry(
            id: project.id,
            title: project.title,
            typeRaw: project.type.storageString,
            fileName: project.fileName,
            previewName: project.previewName,
            bookmark: bookmark
        )
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        save()
        return entry
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
            // ponytail: 관리 폴더명=원본 폴더명(=WE 워크샵 id) 유지로 project id 안정.
            // 콜 간 동명 충돌(재import)은 덮어씀 — WE id 는 유일하므로 실질 재import.
            // 단 한 zip 에 동명 루트가 2개+면 서로 다른 배경 — 접미(-2,-3)로 유일화.
            var name = root.lastPathComponent
            if usedNames.contains(name) {
                var n = 2
                while usedNames.contains("\(name)-\(n)")
                        || fm.fileExists(atPath: importedDir.appendingPathComponent("\(name)-\(n)").path) { n += 1 }
                name = "\(name)-\(n)"
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

    public func select(_ id: String) {
        selectedId = id
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
}
