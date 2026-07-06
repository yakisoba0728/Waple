import XCTest
import AVFoundation
@testable import WapleRender

final class FFmpegConverterTests: XCTestCase {

    // ── 순수 로직 ──────────────────────────────────────────────────────────

    func testNeedsConversionMatchesUnsupportedContainers() {
        XCTAssertTrue(FFmpegConverter.needsConversion(URL(fileURLWithPath: "/a/x.mkv")))
        XCTAssertTrue(FFmpegConverter.needsConversion(URL(fileURLWithPath: "/a/x.avi")))
        XCTAssertTrue(FFmpegConverter.needsConversion(URL(fileURLWithPath: "/a/x.webm")))
        XCTAssertFalse(FFmpegConverter.needsConversion(URL(fileURLWithPath: "/a/x.mp4")))
        XCTAssertFalse(FFmpegConverter.needsConversion(URL(fileURLWithPath: "/a/x.mov")))
    }

    func testCachedURLDeterministicAndDistinct() {
        let a1 = FFmpegConverter.cachedURL(for: URL(fileURLWithPath: "/x/a.mkv"))
        let a2 = FFmpegConverter.cachedURL(for: URL(fileURLWithPath: "/x/a.mkv"))
        let b = FFmpegConverter.cachedURL(for: URL(fileURLWithPath: "/x/b.mkv"))
        XCTAssertEqual(a1, a2)                        // 같은 원본 → 같은 캐시(재사용)
        XCTAssertNotEqual(a1, b)                      // 다른 원본 → 다른 캐시
        XCTAssertEqual(a1.pathExtension, "mp4")
        XCTAssertTrue(a1.path.contains("Waple/converted"))
    }

    func testArgumentsVideotoolboxThenLibx264() {
        let inp = URL(fileURLWithPath: "/a/in.mkv"), out = URL(fileURLWithPath: "/b/out.mp4")
        let vt = FFmpegConverter.arguments(input: inp, output: out, useVideotoolbox: true)
        XCTAssertTrue(vt.contains("h264_videotoolbox"))
        XCTAssertFalse(vt.contains("libx264"))
        XCTAssertEqual(vt[vt.firstIndex(of: "-i")! + 1], "/a/in.mkv")  // -i 다음이 입력
        XCTAssertEqual(vt[vt.firstIndex(of: "-c:a")! + 1], "aac")       // 오디오 aac
        XCTAssertEqual(vt.last, "/b/out.mp4")                            // 마지막이 출력

        let sw = FFmpegConverter.arguments(input: inp, output: out, useVideotoolbox: false)
        XCTAssertTrue(sw.contains("libx264"))                           // 폴백 코덱
        XCTAssertFalse(sw.contains("h264_videotoolbox"))
    }

    // ── ffmpeg 실존 시 라운드트립(부재 시 skip) ─────────────────────────────

    func testConvertRoundtrip() throws {
        try XCTSkipUnless(FFmpegConverter.isAvailable, "ffmpeg not installed — skip roundtrip")
        let ff = FFmpegConverter.executableURL!
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // tiny 1초 합성 mkv(오디오 없음 — 변환기가 video-only 도 처리하는지 겸사겸사 검증).
        let src = dir.appendingPathComponent("tiny.mkv")
        let gen = Process(); gen.executableURL = ff
        gen.arguments = ["-y", "-f", "lavfi", "-i", "color=c=red:s=64x36:d=1", "-pix_fmt", "yuv420p", src.path]
        gen.standardOutput = FileHandle.nullDevice; gen.standardError = FileHandle.nullDevice
        try gen.run(); gen.waitUntilExit()
        try XCTSkipUnless(gen.terminationStatus == 0, "ffmpeg test mkv generation failed")

        let cached = FFmpegConverter.cachedURL(for: src)
        defer { try? FileManager.default.removeItem(at: cached) }
        let exp = expectation(description: "convert")
        var result: URL?
        FFmpegConverter.convert(src, timeout: 60) { result = $0; exp.fulfill() }
        wait(for: [exp], timeout: 90)

        let mp4 = try XCTUnwrap(result, "conversion returned nil")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp4.path))
        XCTAssertEqual(mp4.pathExtension, "mp4")
        XCTAssertTrue(VideoRenderer.isSupportedContainer(mp4))     // AVFoundation 재생 가능 컨테이너
        // 캐시 히트: 재호출 시 즉시 같은 경로 반환.
        let exp2 = expectation(description: "cachehit")
        var again: URL?
        FFmpegConverter.convert(src, timeout: 60) { again = $0; exp2.fulfill() }
        wait(for: [exp2], timeout: 5)
        XCTAssertEqual(again, mp4)
    }
}
