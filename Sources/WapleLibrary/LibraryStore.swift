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
        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch CocoaError.fileReadNoSuchFile {
            return  // 최초 실행: 인덱스 없음(정상).
        } catch {
            NSLog("%@", "[Waple] library index unreadable at \(indexURL.path): \(error) — preserving file, starting empty")
            indexCorrupt = true
            return
        }
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
        // 손상된 인덱스를 덮어쓰기 전에 1회 백업(데이터 손실 방지).
        if indexCorrupt {
            let backup = indexURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            do {
                try FileManager.default.moveItem(at: indexURL, to: backup)
                NSLog("%@", "[Waple] backed up corrupt library index to \(backup.path)")
            } catch {
                NSLog("%@", "[Waple] failed to back up corrupt library index at \(indexURL.path): \(error)")
            }
            indexCorrupt = false
        }
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
