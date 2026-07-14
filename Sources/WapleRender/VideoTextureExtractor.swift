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
    /// cacheKey: 캐시 파일명(기본 sceneID). 한 씬에 video 레이어가 여럿(예 3019043758=2, 3363473482=4)이면
    /// sceneID 만으론 상호 덮어씀 → 호출부가 "sceneID_레이어인덱스" 같은 고유 키를 넘긴다.
    public static func extractMP4(textureEntryName: String, package: ScenePackage, sceneID: String,
                                  cacheKey: String? = nil, cacheDir: URL) -> URL? {
        guard let texData = package.data(for: textureEntryName),
              let tex = TexImage.parse(texData), tex.payload == .video else { return nil }
        let fm = FileManager.default
        let url = cacheDir.appendingPathComponent("\(cacheKey ?? sceneID).mp4")
        let expected = tex.payloadRange.count
        // 캐시 적중: 단, 크기가 기대치와 일치할 때만 재사용한다. 같은 sceneID 로 콘텐츠가
        // 바뀌었거나(앱이 도중에 죽어) 부분 기록된 파일이 남은 경우는 무효화하고 재추출한다.
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int {
            if size == expected {
                touch(url)   // 마지막 접근 갱신(LRU) — evict 순서에서 최근 사용을 보존
                return url
            }
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
        evictOldest(in: cacheDir, keep: maxCachedVideos)  // 새 파일 기록 후 상한 초과분 정리
        return url
    }

    /// 캐시할 씬 mp4 최대 개수. 초과 시 마지막 접근(mtime)이 가장 오래된 것부터 evict.
    /// (씬별 mp4 는 수백 MB — 무한 잔존하면 디스크를 잠식하므로 상한 필요.)
    public static let maxCachedVideos = 8

    /// 캐시 적중 파일의 마지막 접근 시각(mtime)을 now 로 갱신 — LRU evict 순서용.
    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// cacheDir 의 *.mp4 개수가 keep 을 넘으면 mtime 오래된 것부터 (count-keep)개 제거.
    static func evictOldest(in dir: URL, keep: Int) {
        let fm = FileManager.default
        guard keep >= 0, let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        let mp4s = items.filter { $0.pathExtension == "mp4" }
        guard mp4s.count > keep else { return }
        func mtime(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let oldestFirst = mp4s.sorted { mtime($0) < mtime($1) }
        for u in oldestFirst.prefix(mp4s.count - keep) { try? fm.removeItem(at: u) }
    }

    public static func defaultCacheDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Waple/cache", isDirectory: true)
    }
}
