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
        let importsDir = baseDirectory.appendingPathComponent("imports", isDirectory: true)
        // 폴더명 충돌 시 -2, -3 … 회피 — 기존 가져오기를 말없이 덮어쓰지 않는다(P-D2).
        let unique = uniqueFolderName(base: name.isEmpty ? "video" : name) {
            fm.fileExists(atPath: importsDir.appendingPathComponent($0, isDirectory: true).path)
        }
        let folder = importsDir.appendingPathComponent(unique, isDirectory: true)
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

    /// 충돌 없는 폴더명(순수): base 가 없으면 그대로, 있으면 "base-2", "base-3" … 첫 빈 이름.
    /// ponytail: '같은 원본 재가져오기' 판별(내용 비교)은 생략 — 존재하면 무조건 suffix.
    /// 다른 배경을 말없이 덮어쓰는 유실보다 중복 폴더가 낫다. 필요해지면 원본 파일 크기 비교로 승급.
    static func uniqueFolderName(base: String, existing: (String) -> Bool) -> String {
        guard existing(base) else { return base }
        var n = 2
        while existing("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
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
