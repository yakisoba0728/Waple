import Foundation
import WapleCore

public enum VideoTextureExtractor {
    /// 씬의 첫 비디오-텍스처 레이어 entry name(없으면 nil).
    public static func videoLayer(in doc: SceneDocument, package: ScenePackage) -> String? {
        for layer in doc.layers {
            guard let texData = package.data(for: layer.textureEntryName),
                  let tex = TexImage.parse(texData) else { continue }
            if tex.payload == .video { return layer.textureEntryName }
        }
        return nil
    }

    /// 비디오 .tex의 내장 MP4 바이트를 캐시 파일로 추출(있으면 재사용) → URL.
    public static func extractMP4(textureEntryName: String, package: ScenePackage, sceneID: String, cacheDir: URL) -> URL? {
        guard let texData = package.data(for: textureEntryName),
              let tex = TexImage.parse(texData), tex.payload == .video else { return nil }
        let url = cacheDir.appendingPathComponent("\(sceneID).mp4")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let mp4 = texData.subdata(in: tex.payloadRange)
        guard (try? mp4.write(to: url)) != nil else { return nil }
        return url
    }

    public static func defaultCacheDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Waple/cache", isDirectory: true)
    }
}
