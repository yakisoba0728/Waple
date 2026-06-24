import Foundation

public struct LibraryEntry: Codable, Equatable {
    public let id: String
    public let title: String
    public let typeRaw: String
    public let fileName: String?
    public let previewName: String?
    public var bookmark: Data

    public init(id: String, title: String, typeRaw: String,
                fileName: String?, previewName: String?, bookmark: Data) {
        self.id = id
        self.title = title
        self.typeRaw = typeRaw
        self.fileName = fileName
        self.previewName = previewName
        self.bookmark = bookmark
    }
}
