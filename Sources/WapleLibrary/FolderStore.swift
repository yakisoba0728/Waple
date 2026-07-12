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
