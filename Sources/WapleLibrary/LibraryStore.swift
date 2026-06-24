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
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
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

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let idx = try? JSONDecoder().decode(Index.self, from: data) else { return }
        entries = idx.entries
        selectedId = idx.selectedId
    }

    private func save() {
        let idx = Index(entries: entries, selectedId: selectedId)
        if let data = try? JSONEncoder().encode(idx) {
            try? data.write(to: indexURL)
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
        return try? URL(
            resolvingBookmarkData: entry.bookmark,
            options: [], relativeTo: nil, bookmarkDataIsStale: &stale
        )
    }
}
