import AVFoundation
import AppKit
import Foundation
import WapleCore
import WapleLibrary

/// 원시 mp4/mov 파일을 최소 project.json 배경으로 감싸 가져올 수 있게 준비한다(작업 5, OWE 계보).
enum VideoImport {
    static let extensions: Set<String> = ["mp4", "mov"]

    static func isVideoFile(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// 관리 폴더(base/imports/<파일명>)를 만들어 동영상 복사 + preview.jpg + project.json 기록.
    /// 성공 시 importFolder 대상 폴더 URL, 실패 시 nil.
    static func prepare(from videoURL: URL,
                        baseDirectory: URL = LibraryStore.defaultBaseDirectory()) -> URL? {
        let fm = FileManager.default
        let name = videoURL.deletingPathExtension().lastPathComponent
        let folder = baseDirectory.appendingPathComponent("imports", isDirectory: true)
            .appendingPathComponent(name.isEmpty ? "video" : name, isDirectory: true)
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }

        let fileName = videoURL.lastPathComponent
        let dest = folder.appendingPathComponent(fileName)
        try? fm.removeItem(at: dest)
        guard (try? fm.copyItem(at: videoURL, to: dest)) != nil else { return nil }

        writePreview(from: dest, to: folder.appendingPathComponent("preview.jpg"))

        let json = ProjectJSONBuilder.videoProject(file: fileName, preview: "preview.jpg", title: name)
        guard (try? Data(json.utf8).write(to: folder.appendingPathComponent("project.json"), options: .atomic)) != nil
        else { return nil }
        return folder
    }

    /// t=1s 프레임(실패 시 t=0)을 JPEG preview 로. 실패는 조용히 — 미리보기는 폴백일 뿐.
    /// ponytail: AppDelegate.extractVideoFrame 와 유사(그쪽은 PNG). 커밋 경계 유지 위해 소량 중복 허용.
    private static func writePreview(from videoURL: URL, to output: URL) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        let cg: CGImage
        do {
            cg = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: 600), actualTime: nil)
        } catch {
            guard let zero = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return }
            cg = zero
        }
        guard let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [:]) else { return }
        try? jpeg.write(to: output, options: .atomic)
    }
}
