import Foundation
import WapleCore
import WapleLibrary

enum LibraryTypeFilter: String, CaseIterable {
    case all, scene, video, web
    var label: String {
        switch self {
        case .all: return "전체"; case .scene: return "장면"; case .video: return "동영상"; case .web: return "웹"
        }
    }
}

enum LibrarySortOrder: String, CaseIterable {
    case recentFirst, name
    var label: String { self == .recentFirst ? "최근 추가순" : "이름순" }
}

/// 필터 기준(사이드바 상태). 빈 집합 = 그 축 무필터.
struct LibraryFilterCriteria: Equatable {
    var types: Set<LibraryTypeFilter> = []
    var tags: Set<String> = []
    var ratings: Set<String> = []
    var favoritesOnly = false
    var isActive: Bool { !types.isEmpty || !tags.isEmpty || !ratings.isEmpty || favoritesOnly }
}

/// 그리드 표시용 순수 필터/정렬 — 스토어 순서(추가순)를 입력으로 받는다.
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
        case .recentFirst: return out.reversed()   // 스토어는 import 순 append — 역순 = 최신순
        // 이름순은 실행 로케일과 무관하게 결정적이어야 한다(ko 로케일은 한글을 라틴보다 앞세움) —
        // 로케일 미지정 비교(케이스 무시·숫자 인지)로 고정.
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
        default: return .all   // preset 등 — 타입 필터에 안 걸리고 '전체'에만 표시
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
