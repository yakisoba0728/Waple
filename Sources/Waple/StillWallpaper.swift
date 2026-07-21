import Foundation
import WapleCore
import WapleRender

/// 현재 배경에서 '정지 배경(still)'을 만들 때의 소스/경로 결정(순수 로직 — 테스트 대상).
///
/// 실제 프레임 추출(AVAssetImageGenerator / captureFrames)·파일 쓰기·setDesktopImageURL 은
/// AppDelegate 의 통합 지점에서 이 결정을 스위치해 수행한다.
enum StillWallpaper {
    /// 정지 배경 소스 전략.
    enum Source: Equatable {
        case videoFrame(URL)    // 동영상: t=1s 프레임 추출
        case sceneCapture       // 씬: SceneRenderer.captureFrames 1프레임
        case previewImage(URL)  // 웹/이미지/프리셋/미지원 컨테이너: preview 이미지 파일 그대로
    }

    /// 프로젝트에서 정지 배경 소스를 결정. 만들 수 없으면 nil(예: preview 없는 웹).
    static func source(for project: WallpaperProject) -> Source? {
        switch project.type {
        case .video:
            if let url = WallpaperPathSecurity.containedFileURL(project.fileName, root: project.folderURL) {
                // AVFoundation 이 못 읽는 컨테이너(webm/mkv)는 preview 로 폴백.
                if VideoRenderer.isSupportedContainer(url) { return .videoFrame(url) }
            }
            return previewSource(for: project)
        case .scene:
            return .sceneCapture
        default:  // web / image / preset / application / unknown
            return previewSource(for: project)
        }
    }

    /// preview 파일이 있으면 그 URL, 없으면 nil.
    private static func previewSource(for project: WallpaperProject) -> Source? {
        guard let url = WallpaperPathSecurity.containedFileURL(project.previewName, root: project.folderURL) else { return nil }
        return .previewImage(url)
    }

    /// 추출 결과 PNG 경로(배경 id 기준, 파일명 안전화). F484: size 를 넘기면 크기도 파일명에 포함 —
    /// 씬 캡처는 요청 크기로 렌더되므로, 해상도/종횡비가 다른 모니터끼리 같은 씬의 스틸을 공유하면
    /// 잘못된 크기 이미지가 된다(크기 무관 소스 — 비디오 프레임/preview — 는 nil 로 기존 경로 유지).
    static func outputURL(projectId: String, size: CGSize? = nil, stillDir: URL) -> URL {
        let base = safeName(projectId)
        guard let size else { return stillDir.appendingPathComponent("\(base).png") }
        return stillDir.appendingPathComponent("\(base)-\(Int(size.width))x\(Int(size.height)).png")
    }

    /// F484: 이 소스의 스틸이 요청 크기에 의존하는가 — 씬 캡처만 true(비디오 프레임/preview 는 원본
    /// 크기 고정이라 화면 크기와 무관). 캐시/출력 키에 크기를 포함할지의 기준.
    static func isSizeDependent(_ source: Source) -> Bool {
        if case .sceneCapture = source { return true }
        return false
    }

    /// F484: 스틸 생성 캐시 키 — 크기 의존 소스는 "<id>#<w>x<h>"(모니터별 크기 구분), 아니면 id 그대로.
    static func cacheKey(projectId: String, size: CGSize, sizeDependent: Bool) -> String {
        sizeDependent ? "\(projectId)#\(Int(size.width))x\(Int(size.height))" : projectId
    }

    /// 영숫자만 남기고 나머지는 '-' 로. 전부 비면 "still".
    static func safeName(_ s: String) -> String {
        let cleaned = s
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return cleaned.isEmpty ? "still" : cleaned
    }
}
