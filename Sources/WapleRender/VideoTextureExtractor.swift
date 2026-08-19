import CryptoKit
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
        // F559: 캐시 적중 검증 보강 — 크기 일치만으로는 동일 크기의 다른 콘텐츠가 stale 재사용됐다.
        // 페이로드 지문(사이드카 .fp)까지 일치해야 재사용. 지문 없는 구 캐시는 1회 재추출 후 지문 생성.
        let fp = fingerprint(range: tex.payloadRange, in: texData)
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int,
           size == expected,
           let stored = try? String(contentsOf: fingerprintURL(for: url), encoding: .utf8),
           stored == fp {
            touch(url)   // 마지막 접근 갱신(LRU) — evict 순서에서 최근 사용을 보존
            return url
        }
        if fm.fileExists(atPath: url.path) {
            NSLog("%@", "[Waple] stale/partial mp4 cache at \(url.path) — re-extracting")
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
            try? fp.write(to: fingerprintURL(for: url), atomically: true, encoding: .utf8)   // F559 지문 사이드카
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

    /// F559: 캐시 지문 — 크기 + 선두/말미 64KB SHA256(전체 해시는 대형 페이로드에서 비용 — 표본 해시로 절충).
    static func fingerprint(range: Range<Int>, in data: Data) -> String {
        var h = SHA256()
        var countLE = UInt64(range.count).littleEndian
        withUnsafeBytes(of: &countLE) { h.update(bufferPointer: $0) }
        let head = min(64 * 1024, range.count)
        h.update(data: data[range.lowerBound..<(range.lowerBound + head)])
        if range.count > head {
            h.update(data: data[(range.upperBound - head)..<range.upperBound])
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// F559: 지문 사이드카 경로(<name>.mp4.fp) — evictOldest 의 *.mp4 집계엔 걸리지 않는다.
    static func fingerprintURL(for mp4URL: URL) -> URL {
        mp4URL.appendingPathExtension("fp")
    }

    /// cacheDir 의 *.mp4 개수가 keep 을 넘으면 mtime 오래된 것부터 (count-keep)개 제거.
    static func evictOldest(in dir: URL, keep: Int) {
        let fm = FileManager.default
        guard keep >= 0, let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return }
        // F560: 활성(SceneVideoLayer 사용 중) mp4 는 evict 대상에서 제외 — 사용 중 파일을 지우면
        // 라이브 AVPlayer 는 열린 fd 로 버티나, 지연 생성되는 헤드리스 AVAssetImageGenerator 는 첫 디코드 실패.
        let mp4s = items.filter { $0.pathExtension == "mp4" && !isActive($0) }
        guard mp4s.count > keep else { return }
        func mtime(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        let oldestFirst = mp4s.sorted { mtime($0) < mtime($1) }
        for u in oldestFirst.prefix(mp4s.count - keep) {
            try? fm.removeItem(at: u)
            try? fm.removeItem(at: fingerprintURL(for: u))   // F559 사이드카 동반 정리
        }
    }

    // MARK: - F560 활성 mp4 레지스트리(evict 보호)

    /// 활성 추적은 참조수로 — 동일 URL 이 복수 레이어(멀티모니터 동일 씬)에 쓰일 수 있다.
    /// 키는 standardizedFileURL.path — contentsOfDirectory 가 /var → /private/var 심링크를 해소해
    /// 돌려주므로 URL 직접 비교는 어긋난다(테스트로 확인).
    private static let activeLock = NSLock()
    /// nonisolated(unsafe): 직렬화 주체는 바로 위 activeLock 이다 — markActive/unmarkActive/isActive
    /// 세 접근점이 전부 lock/unlock 구간 안이다(컴파일러가 못 보는 그 사실만 표기로 알린다).
    nonisolated(unsafe) private static var activeRefCounts: [String: Int] = [:]

    /// SceneVideoLayer 가 mp4 를 잡는 동안 등록(teardown/deinit 시 unmarkActive).
    static func markActive(_ url: URL) {
        activeLock.lock()
        activeRefCounts[url.standardizedFileURL.path, default: 0] += 1
        activeLock.unlock()
    }

    static func unmarkActive(_ url: URL) {
        activeLock.lock()
        let key = url.standardizedFileURL.path
        if let n = activeRefCounts[key] {
            activeRefCounts[key] = n > 1 ? n - 1 : nil
        }
        activeLock.unlock()
    }

    static func isActive(_ url: URL) -> Bool {
        activeLock.lock(); defer { activeLock.unlock() }
        return activeRefCounts[url.standardizedFileURL.path] != nil
    }

    public static func defaultCacheDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Waple/cache", isDirectory: true)
    }
}
