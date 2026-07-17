import Foundation
import AppKit
import CoreGraphics
import WapleCore
import WapleRender
import WapleSnapshot

/// 씬 픽셀 스냅샷 회귀 파이프라인(캡처/비교 드라이버).
/// 렌더러는 호출만 — SceneRenderer.mount/captureFrames/pause/setSpectrum 공개 API 재사용.
/// 헤드리스 캡처 규약은 RealPackagesGroundTruthTests 와 동일:
/// nowPlaying 스텁 + 고정 시각 t + 오디오 무신호(pause+silent) + 고정 파티클 시드로 결정성 확보.
enum SnapshotPipeline {

    // 고정 캡처 조건(변경 시 베이스라인 재생성 필요).
    // WAPLE_THUMB_W/H: 골든 대비 고해상 단건 캘리브 캡처용 오버라이드(예: HDR bloom #22 — 256×144 는
    // 글로우 반경/강도 판독 불가). 스냅샷 비교는 크기 불일치를 즉시 명시 오류로 거른다(SnapshotCompare).
    static let thumbW = ProcessInfo.processInfo.environment["WAPLE_THUMB_W"].flatMap(Int.init) ?? 256
    static let thumbH = ProcessInfo.processInfo.environment["WAPLE_THUMB_H"].flatMap(Int.init) ?? 144
    static let captureT: Float = 6.0   // 인트로 페이드가 끝난 정상상태(GT 규약과 동일)
    static let fitMode: FitMode = .fill
    /// 벽시계 텍스트(시계/날짜 레이어)가 재캡처마다 동일 픽셀이 되도록 JS Date 무인자/now 를 핀하는 고정
    /// epoch(ms) — 임의 상수(2024-01-01 12:00:00 UTC). 변경 시 시계/날짜 씬 베이스라인 재생성 필요.
    static let captureEpochMillis: Double = 1_704_110_400_000

    /// 폴링 없이 항상 "정지" — 미디어 씬이 osascript 를 스폰하지 않게(결정적·TCC 무).
    struct StoppedNowPlaying: NowPlayingProvider { func fetch() -> NowPlayingInfo? { nil } }

    enum Frame { case pixels([UInt8], png: URL); case empty }

    // MARK: 씬 열거

    static func sceneFolders(root: String) -> [URL] {
        let base = URL(fileURLWithPath: root).appendingPathComponent("backgrounds")
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("scene.pkg").path)
                   || fm.fileExists(atPath: $0.appendingPathComponent("gifscene.pkg").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: 단일 캡처(마운트 → 고정조건 렌더 → 256×144 PNG)

    /// 프레임을 내면 .pixels(정규화 RGBA + PNG경로), 픽셀이 없으면(비디오-백드 등) .empty.
    /// 마운트 스로우는 호출자로 전파(→ failures 버킷).
    static func captureFrame(project: WallpaperProject, into tmp: URL) throws -> Frame {
        let r = SceneRenderer()
        r.nowPlayingProvider = StoppedNowPlaying()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: thumbW, height: thumbH)), project: project)
        r.pause()                    // 라이브 입력(오디오 캡처·시차) 정지 → 결정성
        r.setSpectrum(.silent)       // 오디오-반응 효과를 무신호로 고정
        let urls = r.captureFrames(width: thumbW, height: thumbH, times: [captureT], toDir: tmp)
        r.teardown()
        guard let png = urls.first, let rgba = pngToRGBA(png, width: thumbW, height: thumbH) else { return .empty }
        return .pixels(rgba, png: png)
    }

    /// PNG → width×height RGBA8(premultipliedLast) 정규화 바이트. 캡처/비교가 동일 경로로 로드해야 diff 가 일관.
    static func pngToRGBA(_ url: URL, width: Int, height: Int) -> [UInt8]? {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var px = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &px, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none   // 1:1 이라 무관하나 결정성 위해 고정
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return px
    }

    // MARK: --capture (자기-일관 셀프체크 포함 → 결정/비결정 자동 분류)

    static func runCapture(root: String, outDir: URL, label: String?) -> Int32 {
        let start = Date()
        let sha = gitSHA()
        let lbl = label ?? sha
        let dst = outDir.appendingPathComponent(lbl, isDirectory: true)
        let thumbs = dst.appendingPathComponent("thumbs", isDirectory: true)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_snap_cap", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: thumbs, withIntermediateDirectories: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)

        let restore = pinRenderSettings(root: root)
        defer { restore() }

        let folders = sceneFolders(root: root)
        var entries: [SnapshotEntry] = [], empties: [String] = [], failures: [String] = []
        var nonDet: [String] = []

        for folder in folders {
            let id = folder.lastPathComponent
            autoreleasepool {
                do {
                    let project = try ProjectJSONParser.parse(folderURL: folder)
                    guard case let .pixels(rgba1, png1) = try captureFrame(project: project, into: tmp) else {
                        empties.append(id); return
                    }
                    // 썸네일 복사는 2차 캡처 전에 — 캡처 파일명이 고정(frame_t6.0.png)이라 셀프체크가
                    // png1 을 덮어쓰면 썸네일(2차)과 manifest hash/meanLuma(1차 rgba1)가 영구 불일치.
                    try? fm.removeItem(at: thumbs.appendingPathComponent("\(id).png"))
                    try? fm.copyItem(at: png1, to: thumbs.appendingPathComponent("\(id).png"))
                    // 셀프체크: 독립 재마운트로 두 번째 캡처 → 프레임 산출 씬만 2× (empty/fail 은 1×).
                    var deterministic = true, selfMax = 0, note: String? = nil
                    if case let .pixels(rgba2, _) = (try? captureFrame(project: project, into: tmp)) ?? .empty {
                        let sd = diffRGBA(rgba1, rgba2)
                        selfMax = sd.maxAbsDiff
                        deterministic = passes(sd, .selfConsistent)
                        if !deterministic { note = "self-diff mean=\(String(format: "%.2f", sd.meanAbsDiff)) frac=\(String(format: "%.4f", sd.fracExceeding))"; nonDet.append(id) }
                    } else {
                        deterministic = false; note = "second capture empty"; nonDet.append(id)
                    }
                    entries.append(SnapshotEntry(id: id, width: thumbW, height: thumbH,
                                                 hash: fnv1a(rgba1), meanLuma: meanLuma(rgba: rgba1),
                                                 deterministic: deterministic, selfMaxDiff: selfMax, note: note))
                } catch {
                    failures.append(id)
                    fputs("[snap] mount FAILED \(id): \(error)\n", stderr)
                }
            }
        }

        let manifest = SnapshotManifest(
            gitSHA: sha, label: lbl, thumbWidth: thumbW, thumbHeight: thumbH,
            captureTime: captureT, createdAt: ISO8601DateFormatter().string(from: Date()),
            entries: entries.sorted { $0.id < $1.id }, empties: empties.sorted(), failures: failures.sorted())
        do {
            try manifest.encoded().write(to: dst.appendingPathComponent("manifest.json"))
        } catch {
            fputs("[snap] manifest write failed: \(error)\n", stderr); return 2
        }

        let det = entries.count - nonDet.count
        let dt = Date().timeIntervalSince(start)
        print("""
        [snap capture] \(lbl)  (git \(sha))
          scenes=\(folders.count)  captured=\(entries.count)  empty=\(empties.count)  failed=\(failures.count)
          determinism: 결정 \(det) / 비결정 \(nonDet.count)\(nonDet.isEmpty ? "" : "  " + nonDet.prefix(12).joined(separator: ","))
          empties(범위 밖 비디오-백드 추정 포함): \(empties.prefix(20).joined(separator: ","))\(empties.count > 20 ? " …+\(empties.count - 20)" : "")
          elapsed=\(String(format: "%.1f", dt))s  →  \(dst.path)
        """)
        if !failures.isEmpty { fputs("[snap] ⚠️ \(failures.count) 씬 마운트 실패: \(failures.joined(separator: ","))\n", stderr) }
        return failures.isEmpty ? 0 : 1
    }

    // MARK: 공용 설정 핀(base-assets + fitMode) — GT 하니스와 동일 규약

    static func pinRenderSettings(root: String) -> () -> Void {
        let oldFit = SceneRenderSettings.fitMode
        SceneRenderSettings.fitMode = fitMode
        let oldBase = BaseAssetsSettings.baseAssetsDirectory
        let oldEpoch = TextScriptEngine.captureDateEpochMillis
        TextScriptEngine.captureDateEpochMillis = captureEpochMillis
        let assetsPath = ProcessInfo.processInfo.environment["WAPLE_BASE_ASSETS"] ?? (root + "/assets")
        if FileManager.default.fileExists(atPath: assetsPath + "/shaders/common.h") {
            BaseAssetsSettings.baseAssetsDirectory = URL(fileURLWithPath: assetsPath, isDirectory: true)
        }
        return { SceneRenderSettings.fitMode = oldFit; BaseAssetsSettings.baseAssetsDirectory = oldBase
                 TextScriptEngine.captureDateEpochMillis = oldEpoch }
    }

    /// cwd 의 git HEAD 단축 sha(레이블 기본값용 — 코드 리포 버전이 의도, 코퍼스 root 와 무관).
    /// 리포 밖에서 실행하면 "unknown" — 그럴 땐 --label 로 지정.
    static func gitSHA() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["rev-parse", "--short", "HEAD"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "unknown" }
        p.waitUntilExit()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "unknown" : s
    }
}
