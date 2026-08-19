import Foundation

/// Sendable: 저장 프로퍼티가 전부 값 타입(String/URL/배열/딕셔너리 + 아래 두 enum)이고 모두 let 이다.
/// 명시가 필요한 이유는 **public 타입은 Sendable 이 자동 추론되지 않기 때문**이고, 이게 없으면
/// 프로젝트를 백그라운드로 넘기는 모든 지점(VideoRenderer 의 ffmpeg 변환 완료 콜백,
/// DeepScan.concurrentPerform 의 병렬 스캔)이 "non-Sendable 캡처" 진단을 낸다.
public struct WallpaperProject: Equatable, Sendable {
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
