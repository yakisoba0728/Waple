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
            if let file = project.fileName {
                let url = project.folderURL.appendingPathComponent(file)
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
        guard let name = project.previewName, !name.isEmpty else { return nil }
        return .previewImage(project.folderURL.appendingPathComponent(name))
    }

    /// 추출 결과 PNG 경로(배경 id 기준, 파일명 안전화).
    static func outputURL(projectId: String, stillDir: URL) -> URL {
        stillDir.appendingPathComponent("\(safeName(projectId)).png")
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
