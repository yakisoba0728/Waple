import Foundation

/// 즐겨찾기 id 집합(favorites.json 영속) — 스토어 손상 백업 규약 공유.
public final class FavoritesStore {
    private let fileURL: URL
    public private(set) var ids: Set<String> = []
    private var corrupt = false
    private var loadFailed = false

    public init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("favorites.json")
        guard let data = readStoreFile(fileURL, what: "favorites.json", note: "starting empty", loadFailed: &loadFailed) else { return }
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
        guard !loadFailed else {
            NSLog("%@", "[Waple] favorites.json save skipped — earlier read failed transiently, avoiding clobber")
            return
        }
        backupCorruptStoreFile(fileURL, &corrupt)
        do { try JSONEncoder().encode(ids).write(to: fileURL, options: .atomic) }
        catch { NSLog("%@", "[Waple] favorites save failed: \(error)") }
    }
}
