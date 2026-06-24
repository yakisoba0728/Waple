import Foundation
import Combine
import WapleCore
import WapleLibrary

final class LibraryViewModel: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published var selectedId: String?

    /// 적용 요청을 AppDelegate 로 전달한다(폴더 URL).
    var onApply: ((URL) -> Void)?

    /// 사용자에게 보여줄 오류 메시지를 AppDelegate 로 전달한다.
    var onError: ((String) -> Void)?

    private let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
        self.entries = store.entries
        self.selectedId = store.selectedId
    }

    func importParent(_ url: URL) {
        let imported = store.importParent(url)
        entries = store.entries
        if imported.isEmpty {
            onError?("가져온 배경이 없습니다. 선택한 폴더에 유효한 project.json 이 있는지 확인하세요.")
        }
    }

    func apply(_ entry: LibraryEntry) {
        guard let folder = store.resolveFolderURL(for: entry) else {
            onError?("‘\(entry.title)’의 폴더를 찾을 수 없습니다. 다시 가져오세요.")
            return
        }
        store.select(entry.id)
        selectedId = entry.id
        onApply?(folder)
    }

    func previewURL(for entry: LibraryEntry) -> URL? {
        guard let folder = store.resolveFolderURL(for: entry),
              let preview = entry.previewName else { return nil }
        return folder.appendingPathComponent(preview)
    }

    func isSupported(_ entry: LibraryEntry) -> Bool {
        WallpaperType.from(entry.typeRaw).isSupportedInMVP
    }
}
