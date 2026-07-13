import XCTest
import AppKit
@testable import WapleCore
@testable import WapleRender

/// H1 회귀: 비디오-텍스처를 참조하는 scene-type 씬은 mount 가 VideoRenderer 에 위임하며 Metal
/// device/queue/pipeline 을 설정하지 않아, 과거 captureFrames 가 [] 를 반환 → 헤드리스 캡처가
/// 빈 프레임(스냅샷 empties·still 배경 실패)이 되었다. 수정 후 추출 mp4 에서 프레임을 뽑아 유효 콘텐츠를 낸다.
final class VideoBackedSceneCaptureTests: XCTestCase {

    // MARK: 시간 클램프 (헤르메틱 — 코퍼스 무관)

    func testClampCaptureTimeWithinDuration() {
        // 정상: t 가 [0, dur) 안이면 그대로.
        XCTAssertEqual(VideoTextureExtractor.clampCaptureTime(6.0, duration: 30.0), 6.0, accuracy: 1e-9)
    }

    func testClampCaptureTimeShortLoop() {
        // 짧은 루프(4s)에 t=6 → 끝 근처(dur-0.05)로 클램프. 클램프 없으면 copyCGImage 가 throw → 빈 프레임.
        XCTAssertEqual(VideoTextureExtractor.clampCaptureTime(6.0, duration: 4.0), 3.95, accuracy: 1e-9)
    }

    func testClampCaptureTimeUnknownDuration() {
        // duration 미상(0/비유한): max(0,t) 로 두고 디코드 폴백에 위임.
        XCTAssertEqual(VideoTextureExtractor.clampCaptureTime(6.0, duration: 0), 6.0, accuracy: 1e-9)
        XCTAssertEqual(VideoTextureExtractor.clampCaptureTime(6.0, duration: .nan), 6.0, accuracy: 1e-9)
        XCTAssertEqual(VideoTextureExtractor.clampCaptureTime(-2.0, duration: 30.0), 0.0, accuracy: 1e-9)
    }

    // MARK: 실코퍼스 empty→content (env-guarded — RealVideosGroundTruthTests 관례)

    /// 코퍼스에서 비디오-백드 씬을 찾아, 가장 작은 N개를 mount → captureFrames(t=6) →
    /// (a) 유효 PNG 산출(과거 []), (b) 단색이 아닌 실제 콘텐츠, (c) 재마운트 캡처와 결정적 일치 를 검증.
    func testVideoBackedScenesCaptureContent() throws {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds")
        guard FileManager.default.fileExists(atPath: base) else { throw XCTSkip("no real pkgs dir") }

        // 비디오-백드 scene-type 씬 목록(실제 해석 체인으로 판별) + pkg 크기.
        let folders = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: base), includingPropertiesForKeys: nil)
        var videoBacked: [(id: String, folder: URL, size: Int)] = []
        for folder in folders {
            guard let project = try? ProjectJSONParser.parse(folderURL: folder), project.type == .scene else { continue }
            let pkg = folder.appendingPathComponent("scene.pkg")
            guard let data = try? Data(contentsOf: pkg, options: .mappedIfSafe),
                  let package = try? ScenePackage.parse(data),
                  let doc = try? SceneDocument.parse(package: package),
                  VideoTextureExtractor.videoLayer(in: doc, package: package) != nil else { continue }
            let size = (try? pkg.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            videoBacked.append((folder.lastPathComponent, folder, size))
        }
        guard !videoBacked.isEmpty else { throw XCTSkip("no video-backed scenes in corpus") }
        NSLog("%@", "[H1] video-backed scenes detected: \(videoBacked.count)")

        // 가장 작은 3개만(추출·디코드 비용 억제) — empty→content 재현엔 충분.
        let sample = videoBacked.sorted { $0.size < $1.size }.prefix(3)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("h1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let W = 256, H = 144
        for s in sample {
            let project = try XCTUnwrap(try? ProjectJSONParser.parse(folderURL: s.folder))
            let rgba1 = try captureRGBA(project: project, w: W, h: H, dir: tmp.appendingPathComponent("a-\(s.id)"))
            // (a)+(b): 유효 프레임 + 단색 아님(콘텐츠 존재).
            XCTAssertNotNil(rgba1, "\(s.id): 비디오-백드 캡처가 빈 프레임(수정 실패)")
            let px1 = try XCTUnwrap(rgba1)
            XCTAssertTrue(isNonUniform(px1), "\(s.id): 단색 프레임 — 콘텐츠 없음")
            // (c): 독립 재마운트 캡처가 결정적으로 일치(스냅샷 셀프체크 규약).
            let rgba2 = try captureRGBA(project: project, w: W, h: H, dir: tmp.appendingPathComponent("b-\(s.id)"))
            let px2 = try XCTUnwrap(rgba2, "\(s.id): 2차 캡처 empty")
            XCTAssertEqual(px1, px2, "\(s.id): 비결정 캡처(같은 t 두 캡처가 불일치)")
        }
    }

    // MARK: helpers

    private func captureRGBA(project: WallpaperProject, w: Int, h: Int, dir: URL) throws -> [UInt8]? {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: w, height: h)), project: project)
        defer { r.teardown() }
        guard let png = r.captureFrames(width: w, height: h, times: [6.0], toDir: dir).first else { return nil }
        return pngRGBA(png, w: w, h: h)
    }

    private func pngRGBA(_ url: URL, w: Int, h: Int) -> [UInt8]? {
        guard let img = NSImage(contentsOf: url),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    /// 최소 한 채널이 서로 다른 값을 가지면 true(단색 프레임 배제).
    private func isNonUniform(_ px: [UInt8]) -> Bool {
        guard px.count >= 8 else { return false }
        let first = Array(px.prefix(3))
        var i = 4
        while i + 2 < px.count {
            if Array(px[i..<i+3]) != first { return true }
            i += 4
        }
        return false
    }
}
