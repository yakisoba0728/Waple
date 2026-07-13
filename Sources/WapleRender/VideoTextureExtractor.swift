import Foundation
import AVFoundation
import AppKit
import CoreGraphics
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

    // MARK: 헤드리스 프레임 캡처 (비디오-백드 씬)

    /// 요청 시각 t 를 [0, duration) 로 클램프. duration 미상(비유한/0 이하)이면 max(0,t) 그대로 두고
    /// 디코드 실패는 호출부 폴백(.zero)에 맡긴다. 짧은 루프(예 4s)에 t=6 을 요청해도 끝 근처 프레임을 얻는다.
    static func clampCaptureTime(_ t: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0 else { return max(0, t) }
        return min(max(0, t), max(0, duration - 0.05))
    }

    /// 비디오-백드 씬의 헤드리스 캡처: mount 가 이미 추출해 둔 mp4 에서 시각 t(클램프) 프레임을 **정확
    /// 디코드**(tolerance=0 → 스냅샷 셀프체크 2× 결정성)해 width×height PNG(aspect-fill, 라이브 .fill
    /// videoGravity 와 동형)로 기록한다. 디코드 실패 시 t=0 폴백(AppDelegate.extractVideoFrame 관례).
    /// 성공=true(url 기록). AVFoundation 이 못 읽는 컨테이너(webm 등)는 false → 호출부가 빈 프레임 처리.
    @discardableResult
    public static func captureFramePNG(mp4URL: URL, at t: Double, width: Int, height: Int, to url: URL) -> Bool {
        guard width > 0, height > 0 else { return false }
        let asset = AVURLAsset(url: mp4URL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let clamped = clampCaptureTime(t, duration: asset.duration.seconds)
        let cg: CGImage
        do {
            cg = try gen.copyCGImage(at: CMTime(seconds: clamped, preferredTimescale: 600), actualTime: nil)
        } catch {
            guard let zero = try? gen.copyCGImage(at: .zero, actualTime: nil) else {
                NSLog("%@", "[Waple] video-backed frame capture failed for \(mp4URL.lastPathComponent): \(error)")
                return false
            }
            cg = zero
        }
        return writeScaledPNG(cg, width: width, height: height, to: url)
    }

    /// CGImage → width×height aspect-fill(센터-크롭) PNG 기록. 결정적(동일 입력→동일 출력).
    private static func writeScaledPNG(_ cg: CGImage, width: Int, height: Int, to url: URL) -> Bool {
        guard cg.width > 0, cg.height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        let sw = CGFloat(cg.width), sh = CGFloat(cg.height)
        let scale = max(CGFloat(width) / sw, CGFloat(height) / sh)   // fill: 큰 축 기준
        let dw = sw * scale, dh = sh * scale
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: (CGFloat(width) - dw) / 2, y: (CGFloat(height) - dh) / 2, width: dw, height: dh))
        guard let out = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url, options: .atomic); return true }
        catch { NSLog("%@", "[Waple] video-backed frame PNG write failed \(url.path): \(error)"); return false }
    }
}
