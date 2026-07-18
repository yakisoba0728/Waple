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
            // 제목뿐 아니라 태그·지역화 유형 라벨까지 매칭(합집합) — 사용자가 장르/테마 단어로 검색해도
            // 그 메타데이터가 태그에만 있어 0건이 되던 문제(w5d-library). 제목 매칭 우선순위는 그대로
            // 유지(먼저 검사) — 이후 sort 단계는 매칭 경로를 구분하지 않는다(기존과 동일 규약).
            out = out.filter { entry in
                matches(entry.title, q)
                    || (entry.tags ?? []).contains { matches($0, q) }
                    || matches(NowPlayingSubtitle.typeLabel(entry.typeRaw), q)
            }
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

    private static func matches(_ text: String, _ q: String) -> Bool {
        text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
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
