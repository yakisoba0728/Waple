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
        // 감사 V06: 선택 집합이 그 축의 available 전체를 덮으면(사이드바 '전체' 버튼 또는 개별 토글
        // 전부 체크) 그 축은 무필터로 간주 — 종전엔 이 상태도 필터 활성이라 태그/등급 없는 배경이 전부
        // 숨겨졌다. available 목록은 입력 엔트리에서 유도(LibraryViewModel.availableTags/Ratings 와 동일
        // 산식 — 필터가 켜진 상태에선 입력이 전체 엔트리라 같은 집합이 된다).
        let allTags = Set(entries.flatMap { $0.tags ?? [] })
        let allRatings = Set(entries.compactMap(\.contentRating))
        // 감사 V07: 유형 축도 동일 규약 — available 은 사이드바가 나열하는 고정 3종(동적 유도 불필요).
        // 3종 전부 체크 = 무필터 — entryType 이 .all 로 매핑되는 배경(preset 등)도 그대로 보인다.
        let allTypes: Set<LibraryTypeFilter> = [.scene, .video, .web]
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
        if !criteria.types.isEmpty, !criteria.types.isSuperset(of: allTypes) {   // 감사 V07: 전체 선택 = 무필터
            out = out.filter { criteria.types.contains(entryType($0)) }
        }
        if !criteria.tags.isEmpty, !criteria.tags.isSuperset(of: allTags) {   // 감사 V06: 전체 선택 = 무필터
            out = out.filter { !(criteria.tags.isDisjoint(with: $0.tags ?? [])) }
        }
        if !criteria.ratings.isEmpty, !criteria.ratings.isSuperset(of: allRatings) {   // 감사 V06: 동일
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

    /// 검색/필터가 활성인데 결과가 0건인가(그리드 dead-end 판정, w5d-library). 활성이 아니면(예: 빈
    /// 폴더를 그냥 탐색 중) 대상이 아니다 — 그 경우는 원래 비어있을 수 있는 정상 상태다.
    static func isSearchOrFilterDeadEnd(searchText: String, criteria: LibraryFilterCriteria, filteredCount: Int) -> Bool {
        let active = !searchText.trimmingCharacters(in: .whitespaces).isEmpty || criteria.isActive
        return active && filteredCount == 0
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
