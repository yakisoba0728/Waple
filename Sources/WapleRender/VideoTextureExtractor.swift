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

    /// 비디오 .tex의 내장 MP4 바이트를 캐시 파일로 추출(유효하면 재사용) → URL.
    public static func extractMP4(textureEntryName: String, package: ScenePackage, sceneID: String, cacheDir: URL) -> URL? {
        guard let texData = package.data(for: textureEntryName),
              let tex = TexImage.parse(texData), tex.payload == .video else { return nil }
        let fm = FileManager.default
        let url = cacheDir.appendingPathComponent("\(sceneID).mp4")
        let expected = tex.payloadRange.count
        // 캐시 적중: 단, 크기가 기대치와 일치할 때만 재사용한다. 같은 sceneID 로 콘텐츠가
        // 바뀌었거나(앱이 도중에 죽어) 부분 기록된 파일이 남은 경우는 무효화하고 재추출한다.
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int {
            if size == expected { return url }
            NSLog("%@", "[Waple] stale/partial mp4 cache at \(url.path) (size \(size) != \(expected)) — re-extracting")
            try? fm.removeItem(at: url)
        }
        do {
            try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        } catch {
            NSLog("%@", "[Waple] failed to create mp4 cache dir \(cacheDir.path): \(error)")
            return nil
        }
        let mp4 = texData.subdata(in: tex.payloadRange)
        do {
            try mp4.write(to: url, options: [.atomic])
        } catch {
            NSLog("%@", "[Waple] failed to write mp4 cache \(url.path): \(error)")
            return nil
        }
        return url
    }

    public static func defaultCacheDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Waple/cache", isDirectory: true)
    }
}
