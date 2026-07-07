import Foundation

public struct WallpaperProject: Equatable {
    public let id: String          // 폴더명 (워크샵 ID)
    public let type: WallpaperType
    public let fileName: String?   // project.json "file"
    public let previewName: String?// project.json "preview"
    public let title: String
    public let tags: [String]
    public let contentRating: String?
    public let workshopId: String?
    public let dependency: String? // 프리셋 전용
    public let folderURL: URL
    public let presetOverrides: [String: PropertyValue]
    public let presetFolderURL: URL?

    public init(id: String, type: WallpaperType, fileName: String?, previewName: String?,
                title: String, tags: [String], contentRating: String?, workshopId: String?,
                dependency: String?, folderURL: URL, presetOverrides: [String: PropertyValue] = [:],
                presetFolderURL: URL? = nil) {
        self.id = id
        self.type = type
        self.fileName = fileName
        self.previewName = previewName
        self.title = title
        self.tags = tags
        self.contentRating = contentRating
        self.workshopId = workshopId
        self.dependency = dependency
        self.folderURL = folderURL
        self.presetOverrides = presetOverrides
        self.presetFolderURL = presetFolderURL
    }
}
