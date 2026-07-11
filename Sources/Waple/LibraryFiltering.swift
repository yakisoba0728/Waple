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

/// 그리드 표시용 순수 필터/정렬 — 스토어 순서(추가순)를 입력으로 받는다.
enum LibraryFiltering {
    static func apply(_ entries: [LibraryEntry], search: String,
                      type: LibraryTypeFilter, sort: LibrarySortOrder) -> [LibraryEntry] {
        var out = entries
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            out = out.filter { $0.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        if type != .all {
            out = out.filter { entryType($0) == type }
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

    private static func entryType(_ e: LibraryEntry) -> LibraryTypeFilter {
        switch WallpaperType.from(e.typeRaw) {
        case .scene: return .scene
        case .video: return .video
        case .web: return .web
        default: return .all   // preset 등 — 타입 필터에 안 걸리고 '전체'에만 표시
        }
    }
}
