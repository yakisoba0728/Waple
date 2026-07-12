import Foundation

public struct LibraryEntry: Codable, Equatable {
    public let id: String
    public let title: String
    public let typeRaw: String
    public let fileName: String?
    public let previewName: String?
    public var bookmark: Data
    /// project.json tags(임포트 시 채움; nil=구버전 인덱스 — LibraryStore 백필 대상).
    public var tags: [String]?
    /// project.json contentrating(원문 그대로 — 필터 표시는 UI 가 매핑).
    public var contentRating: String?
    /// 워크샵 평점 0…1(vote_data.score, 다운로드 시 저장). 로컬 임포트는 nil.
    public var rating: Double?

    public init(id: String, title: String, typeRaw: String,
                fileName: String?, previewName: String?, bookmark: Data,
                tags: [String]? = nil, contentRating: String? = nil, rating: Double? = nil) {
        self.id = id
        self.title = title
        self.typeRaw = typeRaw
        self.fileName = fileName
        self.previewName = previewName
        self.bookmark = bookmark
        self.tags = tags
        self.contentRating = contentRating
        self.rating = rating
    }
}
