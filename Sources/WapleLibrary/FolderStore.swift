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
    /// 로드 시 읽기 자체가 실패(권한·잠금 등 일시적) → 원본이 멀쩡할 수 있어 save() 를 건너뛴다.
    private var loadFailed = false

    public init(baseDirectory: URL) {
        fileURL = baseDirectory.appendingPathComponent("folders.json")
        guard let data = readStoreFile(fileURL, what: "folders.json", note: "starting empty", loadFailed: &loadFailed) else { return }
        do { folders = try JSONDecoder().decode([Folder].self, from: data) }
        catch { NSLog("%@", "[Waple] folders.json corrupt — preserving, starting empty: \(error)"); corrupt = true }
    }

    /// 폴더명 정규화(트림) — createFolder·move 가 공유해 끝공백만 다른 이름이 별개 폴더로 중복 생성되는 걸 막는다.
    private func normalizedFolderName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces)
    }

    public func createFolder(_ name: String) {
        let n = normalizedFolderName(name)
        guard !n.isEmpty, !folders.contains(where: { $0.name == n }) else { return }
        folders.append(Folder(name: n, ids: []))
        save()
    }

    /// 항목을 폴더로 이동(nil=루트로). 미존재 폴더명은 생성. 기존 소속은 해제.
    public func move(_ id: String, to folderName: String?) {
        for i in folders.indices { folders[i].ids.removeAll { $0 == id } }
        if let raw = folderName {
            let name = normalizedFolderName(raw)
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
        guard !loadFailed else {
            NSLog("%@", "[Waple] folders.json save skipped — earlier read failed transiently, avoiding clobber")
            return
        }
        backupCorruptStoreFile(fileURL, &corrupt)
        do { try JSONEncoder().encode(folders).write(to: fileURL, options: .atomic) }
        catch { NSLog("%@", "[Waple] folders save failed: \(error)") }
    }
}
