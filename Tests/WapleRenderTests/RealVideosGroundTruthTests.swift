import XCTest
import AVFoundation
@testable import WapleCore
@testable import WapleRender

/// 실물 동영상 배경 전수 재생 검증(env-guarded — RealPackagesGroundTruthTests 와 동일 데이터 관례).
/// mount → RunLoop 스핀 → item readyToPlay && 재생 중(rate>0) 어서션: 진짜 디코드·재생 확인.
/// [2026-08-25] `@MainActor` — `VideoRenderer`/`RendererFactory` 가 `@MainActor` 가 되면서
/// 필요해졌다. 그 타입들은 원래부터 "상태가 메인 큐 한정"(파일 머리말)이었고 이제 타입이 그걸 말한다.
@MainActor
final class RealVideosGroundTruthTests: XCTestCase {
    func testAllRealVideosPlay() throws {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        guard FileManager.default.fileExists(atPath: base) else { throw XCTSkip("no real pkgs dir") }
        let folders = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: base), includingPropertiesForKeys: nil)
        var tested = 0, failed: [String] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let project = try? ProjectJSONParser.parse(folderURL: folder), project.type == .video,
                  let file = project.fileName else { continue }
            let url = folder.appendingPathComponent(file)
            guard VideoRenderer.isSupportedContainer(url) else {
                NSLog("%@", "[WapleGT] video \(project.id): unsupported container (web fallback path) — skip")
                continue
            }
            let r = VideoRenderer()
            do {
                try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
            } catch {
                failed.append("\(project.id): mount \(error)"); continue
            }
            // readyToPlay + 재생 대기(최대 5초).
            let deadline = Date(timeIntervalSinceNow: 5)
            var ok = false
            while Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
                if let error = r.lastError {
                    failed.append("\(project.id): playback error \(error)")
                    break
                }
                if let p = r.player, p.currentItem?.status == .readyToPlay, p.rate > 0 { ok = true; break }
            }
            if ok, r.lastError == nil { tested += 1 } else if r.lastError == nil {
                failed.append("\(project.id): not playing (status=\(String(describing: r.player?.currentItem?.status.rawValue)))")
            }
            r.teardown()
        }
        NSLog("%@", "[WapleGT] videos playing=\(tested) failed=\(failed)")
        XCTAssertGreaterThan(tested, 0)
        XCTAssertEqual(failed.count, 0, "\(failed)")
    }
}
