import XCTest
import AVFoundation
@testable import WapleRender

final class FFmpegConverterTests: XCTestCase {

    // ── 순수 로직 ──────────────────────────────────────────────────────────

    func testNeedsConversionMatchesUnsupportedContainers() {
        XCTAssertTrue(FFmpegConverter.needsConversion(URL(fileURLWithPath: "/a/x.mkv")))
        XCTAssertTrue(FFmpegConverter.needsConversion(URL(fileURLWithPath: "/a/x.avi")))
        XCTAssertTrue(FFmpegConverter.needsConversion(URL(fileURLWithPath: "/a/x.webm")))
        XCTAssertTrue(FFmpegConverter.needsConversion(URL(fileURLWithPath: "/a/x.wmv")))
        XCTAssertTrue(FFmpegConverter.needsConversion(URL(fileURLWithPath: "/a/x.flv")))
        XCTAssertTrue(FFmpegConverter.needsConversion(URL(fileURLWithPath: "/a/x.ogv")))
        XCTAssertTrue(FFmpegConverter.needsConversion(URL(fileURLWithPath: "/a/x.mpg")))
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

    func testCachedURLChangesWhenExistingSourceChanges() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("clip.webm")
        try Data([0x01]).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1000)],
            ofItemAtPath: source.path)
        let first = FFmpegConverter.cachedURL(for: source)

        try Data([0x02]).write(to: source)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2000)],
            ofItemAtPath: source.path)
        let second = FFmpegConverter.cachedURL(for: source)

        XCTAssertNotEqual(first, second, "same-path source changes must not reuse stale ffmpeg output")
    }

    func testConvertCacheHitCompletionRunsOnMainThread() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("cached.webm")
        try Data([0x01, 0x02, 0x03]).write(to: source)
        let cached = FFmpegConverter.cachedURL(for: source)
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try makeTinyMP4(at: cached)
        defer { try? FileManager.default.removeItem(at: cached) }

        let exp = expectation(description: "cache hit callback")
        // [2026-08-25] 참조 박스 — `FFmpegConverter.convert` 의 완료 콜백이 `@Sendable` 이 되면서
        // 캡처한 `var` 를 콜백 안에서 바꾸는 것이 `.v6` 에서 **에러**가 된다. 동기화는
        // `exp.fulfill()` ↔ `wait(for:)` 쌍이 이미 하고 있으므로 박스만 있으면 된다
        // (`SceneVideoLayer.swift:84 SemaphoreResultBox` 의 근거와 같은 형태).
        let callbackURL = SemaphoreResultBox<URL?>(nil)
        let callbackWasMain = SemaphoreResultBox<Bool>(false)
        DispatchQueue.global(qos: .utility).async {
            FFmpegConverter.convert(source) { url in
                callbackURL.value = url
                callbackWasMain.value = Thread.isMainThread
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(callbackURL.value, cached)
        XCTAssertTrue(callbackWasMain.value, "all converter completions should enter renderer/app code on main")
    }

    func testConvertDoesNotReuseZeroByteCacheHit() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("cached.webm")
        try Data([0x01, 0x02, 0x03]).write(to: source)
        let cached = FFmpegConverter.cachedURL(for: source)
        try FileManager.default.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: cached)
        defer { try? FileManager.default.removeItem(at: cached) }

        let exp = expectation(description: "invalid cache ignored")
        // [2026-08-25] 참조 박스 — `FFmpegConverter.convert` 의 완료 콜백이 `@Sendable` 이 되면서
        // 캡처한 `var` 를 콜백 안에서 바꾸는 것이 `.v6` 에서 **에러**가 된다. 동기화는
        // `exp.fulfill()` ↔ `wait(for:)` 쌍이 이미 하고 있으므로 박스만 있으면 된다
        // (`SceneVideoLayer.swift:84 SemaphoreResultBox` 의 근거와 같은 형태).
        let callbackURL = SemaphoreResultBox<URL?>(nil)
        FFmpegConverter.convert(source, timeout: 5) { url in
            callbackURL.value = url
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)

        XCTAssertNil(callbackURL.value, "zero-byte converted cache entries should not be reused")
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

    func testDetectExecutableIgnoresPathByDefault() {
        let env = ["PATH": "/tmp/attacker"]
        let found = FFmpegConverter.detectExecutable(
            environment: env,
            knownExecutablePaths: [],
            isExecutable: { $0 == "/tmp/attacker/ffmpeg" })

        XCTAssertNil(found)
    }

    func testDetectExecutableUsesKnownFixedPath() {
        let found = FFmpegConverter.detectExecutable(
            environment: ["PATH": "/tmp/attacker"],
            knownExecutablePaths: ["/opt/homebrew/bin/ffmpeg"],
            isExecutable: { $0 == "/opt/homebrew/bin/ffmpeg" || $0 == "/tmp/attacker/ffmpeg" })

        XCTAssertEqual(found?.path, "/opt/homebrew/bin/ffmpeg")
    }

    func testDetectExecutableUsesExplicitOptInExecutablePath() {
        let found = FFmpegConverter.detectExecutable(
            environment: [FFmpegConverter.explicitExecutableEnv: "/tmp/custom/ffmpeg", "PATH": "/tmp/attacker"],
            knownExecutablePaths: [],
            isExecutable: { $0 == "/tmp/custom/ffmpeg" || $0 == "/tmp/attacker/ffmpeg" })

        XCTAssertEqual(found?.path, "/tmp/custom/ffmpeg")
    }

    func testDetectExecutableUsesPathOnlyWhenOptedIn() {
        let found = FFmpegConverter.detectExecutable(
            environment: [FFmpegConverter.trustPathEnv: "1", "PATH": "/tmp/attacker:relative"],
            knownExecutablePaths: [],
            isExecutable: { $0 == "/tmp/attacker/ffmpeg" || $0 == "relative/ffmpeg" })

        XCTAssertEqual(found?.path, "/tmp/attacker/ffmpeg")
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
        // [2026-08-25] 참조 박스 — `FFmpegConverter.convert` 의 완료 콜백이 `@Sendable` 이 되면서
        // 캡처한 `var` 를 콜백 안에서 바꾸는 것이 `.v6` 에서 **에러**가 된다. 동기화는
        // `exp.fulfill()` ↔ `wait(for:)` 쌍이 이미 하고 있으므로 박스만 있으면 된다
        // (`SceneVideoLayer.swift:84 SemaphoreResultBox` 의 근거와 같은 형태).
        let result = SemaphoreResultBox<URL?>(nil)
        FFmpegConverter.convert(src, timeout: 60) { result.value = $0; exp.fulfill() }
        wait(for: [exp], timeout: 90)

        let mp4 = try XCTUnwrap(result.value, "conversion returned nil")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp4.path))
        XCTAssertEqual(mp4.pathExtension, "mp4")
        XCTAssertTrue(VideoRenderer.isSupportedContainer(mp4))     // AVFoundation 재생 가능 컨테이너
        // 캐시 히트: 재호출 시 즉시 같은 경로 반환.
        let exp2 = expectation(description: "cachehit")
        let again = SemaphoreResultBox<URL?>(nil)
        FFmpegConverter.convert(src, timeout: 60) { again.value = $0; exp2.fulfill() }
        wait(for: [exp2], timeout: 5)
        XCTAssertEqual(again.value, mp4)
    }
}
