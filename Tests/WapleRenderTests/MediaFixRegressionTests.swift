import AppKit
import AVFoundation
import XCTest
@testable import WapleCore
@testable import WapleRender

/// fix-g4 감사 항목 회귀 테스트 — VideoRenderer/SceneAudioPlayer/FFmpegConverter/VideoTextureExtractor/
/// RendererFactory/NowPlayingProvider/OggVorbis 수정분(F550–F566).
/// [2026-08-25] `@MainActor` — `VideoRenderer`/`RendererFactory` 가 `@MainActor` 가 되면서
/// 필요해졌다. 그 타입들은 원래부터 "상태가 메인 큐 한정"(파일 머리말)이었고 이제 타입이 그걸 말한다.
@MainActor
final class MediaFixRegressionTests: XCTestCase {

    // MARK: 공용 헬퍼

    private func spin(until predicate: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private static func silentWAV(seconds: Double = 1.0, sampleRate: Int = 8000) -> Data {
        let n = Int(Double(sampleRate) * seconds)
        let dataBytes = n * 2
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(Data("RIFF".utf8)); u32(36 + dataBytes); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(dataBytes)
        d.append(Data(repeating: 0, count: dataBytes))
        return d
    }

    // MARK: F550 — 변환 결과물 자체의 재생 실패는 재변환하지 않는다

    /// 변환 경유(webm) 배경의 변환 결과물 mp4 가 재생 중 실패하면, 종전엔 그 실패한 mp4 를 다시
    /// ffmpeg 로 재인코딩(무의미 루프)했다. 원본에 대한 1회 변환만 일어나야 한다.
    func testConvertedOutputFailureDoesNotReconvert() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0x01]).write(to: dir.appendingPathComponent("movie.webm"))
        let broken = dir.appendingPathComponent("broken.mp4")
        try Data([0x00, 0x01, 0x02]).write(to: broken)   // 재생 불가 쓰레기 mp4

        var requested: [URL] = []
        var completion: ((URL?) -> Void)?
        let renderer = VideoRenderer(converterAvailable: { true },
                                     convert: { url, cb in requested.append(url); completion = cb })
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        try renderer.mount(in: container, project: project(id: "conv", fileName: "movie.webm", dir: dir))
        XCTAssertEqual(requested.count, 1)

        completion?(broken)   // 변환 완료 → 쓰레기 mp4 장착 → 비동기 재생 실패 유도
        spin(until: { renderer.lastError != nil }, timeout: 5)
        XCTAssertNotNil(renderer.lastError, "변환 결과물의 재생 실패가 기록돼야")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))   // 회복 시도가 일어날 여유
        XCTAssertEqual(requested.count, 1,
                       "F550: 변환 결과물 자체의 재생 실패를 재변환하면 안 된다(무의미 루프)")
        renderer.teardown()
    }

    // MARK: F551 — mount 시점 창 가림 상태 반영

    func testIsOccludedAtMountReflectsWindowVisibility() {
        XCTAssertFalse(VideoRenderer.isOccludedAtMount(nil), "headless(창 없음)는 기존 동작(재생) 유지")
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                           styleMask: [.titled], backing: .buffered, defer: false)
        XCTAssertFalse(win.occlusionState.contains(.visible), "표시된 적 없는 창은 비가시")
        XCTAssertTrue(VideoRenderer.isOccludedAtMount(win), "가려진 창에 mount 되면 재생 보류")
    }

    // MARK: F552 — stale didFinishPlaying 이 재트리거된 새 곡을 절단하지 않는다

    /// trigger 직전 자연종료 곡의 stale 종료 통지가 메인 홉을 거쳐 도착하면, 종전엔 stopped=false 만 보고
    /// play(at: next) 로 새 곡을 끊었다(gap=0 경로 — F410 세대 가드 미적용). 플레이어 동일성으로 폐기돼야 한다.
    func testStaleDidFinishPlayingDoesNotCutRetriggeredTrack() {
        let pkg = ScenePackage.assemble([
            (name: "sounds/a.wav", data: Self.silentWAV(seconds: 1.0)),
            (name: "sounds/b.wav", data: Self.silentWAV(seconds: 1.0)),
        ])
        let pl = Playlist(entries: ["sounds/a.wav", "sounds/b.wav"], mode: "single", package: pkg,
                          authorVolume: 1, settingVolume: 0, minTime: 0, maxTime: 0)
        XCTAssertTrue(pl.startFirstPlayable())
        let old = pl.playerForTesting
        XCTAssertNotNil(old)
        pl.trigger()   // 재트리거 — 새 플레이어로 교체(처음부터, index 0)
        let current = pl.playerForTesting
        XCTAssertNotNil(current)
        XCTAssertFalse(old === current)

        pl.audioPlayerDidFinishPlaying(old!, successfully: true)   // stale 종료 통지(메인 스레드에서 직접 전달)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        XCTAssertTrue(pl.playerForTesting === current,
                      "F552: stale 종료 통지가 새 플레이어를 교체하면 안 된다")
        XCTAssertEqual(pl.indexForTesting, 0,
                       "F552: 재트리거 직후 stale 통지가 다음 곡으로 넘기면 안 된다")
        pl.stop()
    }

    /// 정상 종료 통지(현재 플레이어의 자연종료)는 여전히 다음 곡으로 진행 — 가드의 오작동 방지.
    func testLegitDidFinishPlayingAdvancesPlaylist() {
        let pkg = ScenePackage.assemble([
            (name: "sounds/a.wav", data: Self.silentWAV(seconds: 1.0)),
            (name: "sounds/b.wav", data: Self.silentWAV(seconds: 1.0)),
        ])
        let pl = Playlist(entries: ["sounds/a.wav", "sounds/b.wav"], mode: "single", package: pkg,
                          authorVolume: 1, settingVolume: 0, minTime: 0, maxTime: 0)
        XCTAssertTrue(pl.startFirstPlayable())
        let first = pl.playerForTesting
        XCTAssertNotNil(first)
        pl.audioPlayerDidFinishPlaying(first!, successfully: true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(pl.indexForTesting, 1, "정상 종료 통지는 다음 곡으로 진행해야")
        XCTAssertFalse(pl.playerForTesting === first)
        pl.stop()
    }
}

// MARK: - F553 코드북 OOM 가드 강화

extension MediaFixRegressionTests {
    /// LSB-first 비트 라이터(코드북 비트스트림 생성용 — VorbisBitReader 규약과 동일).
    private struct LSBWriter {
        private(set) var bytes: [UInt8] = []
        private var cur: UInt8 = 0, n = 0
        mutating func bits(_ v: UInt32, _ count: Int) { for i in 0..<count { bit((v >> UInt32(i)) & 1) } }
        mutating func bit(_ b: UInt32) {
            cur |= UInt8(b & 1) << UInt8(n); n += 1
            if n == 8 { bytes.append(cur); cur = 0; n = 0 }
        }
        mutating func finish() -> [UInt8] { if n > 0 { bytes.append(cur) }; return bytes }
    }

    /// F553: ordered 코드북이 entries=2^24 짜리로 상한을 equality 통과해 수백MB 트라이/수억 회 삽입을
    /// 유발했다. 실질 상한(1<<20) 초과는 즉시 corrupt.
    func testCodebookRejectsEntriesAbovePracticalCap() {
        var w = LSBWriter()
        w.bits(0x564342, 24)                       // sync "BCV"
        w.bits(1, 16)                              // dimensions = 1
        w.bits(UInt32((1 << 20) + 1), 24)          // entries = 실질 상한 + 1
        var r = VorbisBitReader(w.finish())
        XCTAssertThrowsError(try VorbisCodebook.parse(&r)) { e in
            guard case VorbisError.corrupt = e else { return XCTFail("expected .corrupt, got \(e)") }
        }
    }

    /// 가드 강화가 정상 코드북을 거부하지 않는지 — 소형 ordered 코드북은 그대로 파스돼야 한다.
    func testSmallOrderedCodebookStillParses() throws {
        var w = LSBWriter()
        w.bits(0x564342, 24)
        w.bits(1, 16)                              // dim 1
        w.bits(4, 24)                              // entries 4
        w.bit(1)                                   // ordered
        w.bits(0, 5)                               // 시작 길이 = 1
        w.bits(1, 3)                               // ilog(4)=3비트: 1개 → lengths[0]=1
        w.bits(1, 2)                               // ilog(3)=2비트: 1개 → lengths[1]=2
        w.bits(2, 2)                               // ilog(2)=2비트: 2개 → lengths[2..3]=3
        w.bits(0, 4)                               // lookup type 0
        var r = VorbisBitReader(w.finish())
        let book = try VorbisCodebook.parse(&r)
        XCTAssertEqual(book.entries, 4)
        XCTAssertEqual(book.dimensions, 1)
    }
}

// MARK: - F555 비디오 비동기 실패 표면화(notification)

extension MediaFixRegressionTests {
    /// ffmpeg 변환 실패 시 lastError 기록과 함께 .wapleVideoPlaybackFailed 가 발행돼야 한다.
    func testConversionFailurePostsNotification() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("broken.webm")
        try Data([0x01]).write(to: source)

        var completion: ((URL?) -> Void)?
        let renderer = VideoRenderer(converterAvailable: { true }, convert: { _, cb in completion = cb })
        var received: [Notification] = []
        let obs = NotificationCenter.default.addObserver(
            forName: .wapleVideoPlaybackFailed, object: nil, queue: nil
        ) { received.append($0) }
        defer { NotificationCenter.default.removeObserver(obs) }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        try renderer.mount(in: container, project: project(id: "nf", fileName: "broken.webm", dir: dir))
        completion?(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        XCTAssertEqual(received.count, 1, "F555: 변환 실패 notification 1건")
        XCTAssertEqual(received.first?.userInfo?["url"] as? URL, source)
        renderer.teardown()
    }

    /// 재생 중 실패 + 회복 불가(ffmpeg 부재)면 최종 실패로 notification 발행.
    func testUnrecoverablePlaybackFailurePostsNotification() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("broken.mp4")
        try Data([0x00, 0x01, 0x02]).write(to: source)

        let renderer = VideoRenderer(converterAvailable: { false }, convert: { _, _ in })
        var received: [Notification] = []
        let obs = NotificationCenter.default.addObserver(
            forName: .wapleVideoPlaybackFailed, object: nil, queue: nil
        ) { received.append($0) }
        defer { NotificationCenter.default.removeObserver(obs) }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        try renderer.mount(in: container, project: project(id: "nf2", fileName: "broken.mp4", dir: dir))
        spin(until: { !received.isEmpty }, timeout: 5)
        XCTAssertFalse(received.isEmpty, "F555: 회복 불가한 재생 실패는 표면화돼야 한다")
        renderer.teardown()
    }
}

// MARK: - F556 videoFallback 은 webm 만(ffmpeg 부재 시)

extension MediaFixRegressionTests {
    func testWebViewPlayableContainerOnlyWebm() {
        XCTAssertTrue(RendererFactory.webViewPlayableContainer("webm"))
        XCTAssertTrue(RendererFactory.webViewPlayableContainer("WEBM"))
        for ext in ["mkv", "avi", "wmv", "flv", "ogv", "mpg", "mpeg"] {
            XCTAssertFalse(RendererFactory.webViewPlayableContainer(ext), ext)
        }
    }

    /// F556: ffmpeg 부재 시 mkv/avi 등 재생 불가 컨테이너를 videoFallback(WKWebView)으로 라우팅하지 않는다 —
    /// nil 반환으로 실패 표면화(검은 화면 + apply 성공 오표시 방지). webm 은 기존 webm 폴섹 유지.
    func testFactoryDoesNotRouteUnplayableContainersToVideoFallback() {
        func project(_ file: String) -> WallpaperProject {
            WallpaperProject(id: "x", type: .video, fileName: file, previewName: nil,
                             title: "t", tags: [], contentRating: nil, workshopId: nil,
                             dependency: nil, folderURL: URL(fileURLWithPath: "/tmp/x", isDirectory: true))
        }
        if FFmpegConverter.isAvailable {
            for ext in ["webm", "mkv", "avi"] {
                XCTAssertTrue(RendererFactory.makeRenderer(for: project("a.\(ext)")) is VideoRenderer, ext)
            }
        } else {
            XCTAssertTrue(RendererFactory.makeRenderer(for: project("a.webm")) is WebRenderer)
            for ext in ["mkv", "avi", "wmv", "flv", "ogv", "mpg", "mpeg"] {
                XCTAssertNil(RendererFactory.makeRenderer(for: project("a.\(ext)")),
                             "F556: ffmpeg 부재 시 \(ext) 는 videoFallback 이 아니라 실패(nil)")
            }
        }
    }
}

// MARK: - F557 동일 소스 동시 convert 직렬화

extension MediaFixRegressionTests {
    /// 동일 소스에 대한 동시 convert 2건이 모두 유효 캐시 URL 을 받아야 한다(경주로 유효 출력 삭제 후 nil 방지).
    func testConcurrentConvertsOfSameSourceBothReturnCache() throws {
        try XCTSkipUnless(FFmpegConverter.isAvailable, "ffmpeg not installed — skip")
        let ff = FFmpegConverter.executableURL!
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("tiny.mkv")
        let gen = Process(); gen.executableURL = ff
        gen.arguments = ["-y", "-f", "lavfi", "-i", "color=c=red:s=64x36:d=1", "-pix_fmt", "yuv420p", src.path]
        gen.standardOutput = FileHandle.nullDevice; gen.standardError = FileHandle.nullDevice
        try gen.run(); gen.waitUntilExit()
        try XCTSkipUnless(gen.terminationStatus == 0, "ffmpeg test mkv generation failed")

        let cached = FFmpegConverter.cachedURL(for: src)
        defer { try? FileManager.default.removeItem(at: cached) }
        let exp1 = expectation(description: "convert1"), exp2 = expectation(description: "convert2")
        var r1: URL?, r2: URL?
        FFmpegConverter.convert(src, timeout: 60) { r1 = $0; exp1.fulfill() }
        FFmpegConverter.convert(src, timeout: 60) { r2 = $0; exp2.fulfill() }
        wait(for: [exp1, exp2], timeout: 120)
        XCTAssertEqual(r1, cached, "F557: 동시 변환 경주에서도 유효 캐시 반환")
        XCTAssertEqual(r2, cached)
    }
}

// MARK: - F559/F560 씬 mp4 캐시 지문 검증 + 활성 evict 보호

extension MediaFixRegressionTests {
    /// TEX 헤더 + 임의 페이로드(VideoTextureExtractorTests 와 동일 구조).
    private func makeTex(payload: [UInt8]) -> Data {
        var b: [UInt8] = []
        b += bytes(tag("TEXV0005"), tag("TEXI0001"))
        b += bytes(i32b(0), i32b(0), i32b(100), i32b(100), i32b(100), i32b(100))
        b += bytes(tag("TEXB0001"), payload)
        return Data(b)
    }

    private func videoScenePkg(tail: [UInt8] = [1, 2, 3]) throws -> ScenePackage {
        let scene = Data(#"{"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},"objects":[{"image":"models/m.json","origin":"50 50 0","size":"100 100","scale":"1 1 1","angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}]}"#.utf8)
        let model = Data(#"{"material":"materials/mat.json"}"#.utf8)
        let material = Data(#"{"passes":[{"shader":"genericimage2","textures":["v"]}]}"#.utf8)
        let mp4: [UInt8] = [UInt8](i32(0x18)) + Array("ftypisom".utf8) + tail
        let tex = makeTex(payload: mp4)
        return try ScenePackage.parse(encodePkg([
            ("scene.json", scene), ("models/m.json", model), ("materials/mat.json", material), ("materials/v.tex", tex),
        ]))
    }

    private func extract(_ pkg: ScenePackage, sceneID: String, dir: URL) throws -> URL {
        try XCTUnwrap(VideoTextureExtractor.extractMP4(textureEntryName: "materials/v.tex", package: pkg,
                                                       sceneID: sceneID, cacheDir: dir))
    }

    /// F559: 같은 sceneID 로 동일 크기의 다른 콘텐츠가 유입(워크숍 아이템 업데이트)되면, 크기 일치만으로는
    /// stale 캐시를 재사용했다 — 지문 불일치로 재추출돼야 한다.
    func testSameSizeDifferentSceneContentIsReextracted() throws {
        let pkgA = try videoScenePkg(tail: [1, 2, 3])
        let pkgB = try videoScenePkg(tail: [9, 9, 9])   // 같은 크기, 다른 내용
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let u1 = try extract(pkgA, sceneID: "42", dir: dir)
        let first = try Data(contentsOf: u1)
        let u2 = try extract(pkgB, sceneID: "42", dir: dir)
        let second = try Data(contentsOf: u2)
        XCTAssertNotEqual(second, first,
                          "F559: 동일 크기 다른 콘텐츠의 stale 캐시는 재사용되면 안 된다")
        XCTAssertEqual([UInt8](second.suffix(3)), [9, 9, 9], "새 콘텐츠로 재추출돼야")
    }

    /// F559: 지문 없는 구 캐시는 1회 재추출 후 지문이 생성되고, 이후 적중한다.
    func testCacheWithoutFingerprintIsReextractedOnceThenHits() throws {
        let pkg = try videoScenePkg()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let u1 = try extract(pkg, sceneID: "42", dir: dir)
        let good = try Data(contentsOf: u1)
        try FileManager.default.removeItem(at: VideoTextureExtractor.fingerprintURL(for: u1))   // 구 캐시 시뮬레이션
        let u2 = try extract(pkg, sceneID: "42", dir: dir)
        XCTAssertEqual(try Data(contentsOf: u2), good)
        XCTAssertTrue(FileManager.default.fileExists(atPath: VideoTextureExtractor.fingerprintURL(for: u2).path),
                      "재추출 시 지문 사이드카 생성")
        let u3 = try extract(pkg, sceneID: "42", dir: dir)   // 지문 일치 → 캐시 적중
        XCTAssertEqual(try Data(contentsOf: u3), good)
    }

    /// F560: 활성(SceneVideoLayer 사용 중) mp4 는 가장 오래됐어도 evict 되지 않는다.
    func testActiveMp4IsNotEvicted() throws {
        let pkg = try videoScenePkg()
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = VideoTextureExtractor.maxCachedVideos
        let fm = FileManager.default
        for i in 0..<cap { _ = try extract(pkg, sceneID: "s\(i)", dir: dir) }
        for i in 0..<cap {
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000 + Double(i))],
                                 ofItemAtPath: dir.appendingPathComponent("s\(i).mp4").path)
        }
        let active = dir.appendingPathComponent("s0.mp4")   // 가장 오래된 것을 활성 마크
        VideoTextureExtractor.markActive(active)
        defer { VideoTextureExtractor.unmarkActive(active) }
        // cap+2 개까지 추출 → 활성 제외 집합(s1..)이 상한을 넘어 그중 가장 오래된 s1 이 evict.
        _ = try extract(pkg, sceneID: "s\(cap)", dir: dir)
        _ = try extract(pkg, sceneID: "s\(cap + 1)", dir: dir)
        XCTAssertTrue(fm.fileExists(atPath: active.path), "F560: 활성 mp4 는 가장 오래됐어도 보존")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("s1.mp4").path),
                       "활성 아닌 것 중 가장 오래된 s1 이 대신 evict")
    }

    /// F560: 활성 등록은 참조수 관리(멀티모니터 동일 씬) + teardown 멱등.
    func testSceneVideoLayerActiveRegistrationIsRefCountedAndIdempotent() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple-active-\(UUID().uuidString).mp4")
        let a = SceneVideoLayer(mp4URL: url)
        let b = SceneVideoLayer(mp4URL: url)
        XCTAssertTrue(VideoTextureExtractor.isActive(url))
        a.teardown()
        XCTAssertTrue(VideoTextureExtractor.isActive(url), "다른 레이어가 아직 사용 중")
        b.teardown()
        XCTAssertFalse(VideoTextureExtractor.isActive(url))
        b.teardown()   // 멱등 — 이중 해제로 참조수가 깨지면 안 된다
        XCTAssertFalse(VideoTextureExtractor.isActive(url))
        let c = SceneVideoLayer(mp4URL: url)
        XCTAssertTrue(VideoTextureExtractor.isActive(url))
        c.teardown()
        XCTAssertFalse(VideoTextureExtractor.isActive(url))
    }
}

// MARK: - F563 Ogg 페이지 메타 최소 검증

extension MediaFixRegressionTests {
    /// 페이지 경계 순회(오프셋 나열).
    private func pageRanges(_ b: [UInt8]) -> [(pos: Int, end: Int)] {
        var out: [(Int, Int)] = []
        var pos = 0
        while pos + 27 <= b.count {
            let nsegs = Int(b[pos + 26])
            var body = 0
            for i in 0..<nsegs { body += Int(b[pos + 27 + i]) }
            out.append((pos, pos + 27 + nsegs + body))
            pos += 27 + nsegs + body
        }
        return out
    }

    /// 유효 파일은 그대로 파스(버전/시퀀스/continued 검증 통과).
    func testOggValidFileStillParses() throws {
        let ogg = try OggPageReader.parse(TinyOgg.data)
        XCTAssertFalse(ogg.packets.isEmpty)
    }

    /// 시퀀스 갭(페이지 유실/재배열)은 오류로 표면화.
    func testOggSequenceGapIsRejected() {
        var b = [UInt8](TinyOgg.data)
        let pages = pageRanges(b)
        XCTAssertGreaterThanOrEqual(pages.count, 3)
        b[pages[2].pos + 18] &+= 1   // 페이지 2 의 시퀀스 변조(CRC 미검사라 재스탬프 불요)
        XCTAssertThrowsError(try OggPageReader.parse(Data(b))) { e in
            guard case OggError.corrupt(let msg) = e, msg.contains("sequence") else {
                return XCTFail("expected sequence gap, got \(e)")
            }
        }
    }

    /// continued 플래그 불일치(이질 데이터 접합 방지).
    func testOggContinuationFlagMismatchIsRejected() {
        var b = [UInt8](TinyOgg.data)
        let pages = pageRanges(b)
        XCTAssertGreaterThanOrEqual(pages.count, 3)
        // 페이지 2 는 continued 아님(직전 페이지가 패킷 경계에서 끝남). continued 를 심으면
        // 미완 패킷이 없는데 이어짐을 주장하는 셈이라 불일치여야 한다.
        b[pages[2].pos + 5] |= 1
        XCTAssertThrowsError(try OggPageReader.parse(Data(b))) { e in
            guard case OggError.corrupt(let msg) = e, msg.contains("continuation") else {
                return XCTFail("expected continuation mismatch, got \(e)")
            }
        }
    }

    /// 버전 바이트 비0 은 거부.
    func testOggNonzeroVersionIsRejected() {
        var b = [UInt8](TinyOgg.data)
        b[4] = 1
        XCTAssertThrowsError(try OggPageReader.parse(Data(b))) { e in
            guard case OggError.corrupt = e else { return XCTFail("expected .corrupt, got \(e)") }
        }
    }
}

// MARK: - F554/F564 아트워크 임시파일 고유화 + https 강제

extension MediaFixRegressionTests {
    /// F554: 임시 경로는 호출마다 고유해야 한다(다중 폴섹 경합 제거).
    func testArtworkTempURLIsUniquePerCall() {
        let a = AppleScriptNowPlayingProvider.artworkTempURL()
        let b = AppleScriptNowPlayingProvider.artworkTempURL()
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.lastPathComponent.hasPrefix("waple_artwork_"))
        XCTAssertEqual(a.pathExtension, "dat")
    }

    /// F564: 아트워크 URL 은 https 만 허용(평문 http 차단).
    func testArtworkURLRequiresHTTPS() {
        XCTAssertTrue(AppleScriptNowPlayingProvider.isValidArtworkURL(URL(string: "https://i.scdn.co/image/ab67616")!))
        XCTAssertFalse(AppleScriptNowPlayingProvider.isValidArtworkURL(URL(string: "http://i.scdn.co/image/x")!))
        XCTAssertFalse(AppleScriptNowPlayingProvider.isValidArtworkURL(URL(string: "ftp://example.com/x")!))
        XCTAssertFalse(AppleScriptNowPlayingProvider.isValidArtworkURL(URL(fileURLWithPath: "/tmp/x")))
    }
}

// MARK: - F5-2 라이브 비디오 트랙 preferredTransform 반영

extension MediaFixRegressionTests {
    /// VideoTrackOrientation.classify 순수 판정 — 디헤드럴군 8원소(무회전/90/180/270 × 무미러/미러) 인식 +
    /// 임의 변환(스큐 등)은 nil(안전 무시 대상)로 거부.
    func testVideoTrackOrientationClassifiesDihedralTransforms() {
        XCTAssertEqual(VideoTrackOrientation.classify(.identity), .identity)
        XCTAssertEqual(VideoTrackOrientation.classify(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0)),
                       VideoTrackOrientation(quarterTurns: 1, mirroredX: false))
        XCTAssertEqual(VideoTrackOrientation.classify(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 64, ty: 64)),
                       VideoTrackOrientation(quarterTurns: 2, mirroredX: false))
        XCTAssertEqual(VideoTrackOrientation.classify(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 64)),
                       VideoTrackOrientation(quarterTurns: 3, mirroredX: false))
        XCTAssertEqual(VideoTrackOrientation.classify(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 64, ty: 0)),
                       VideoTrackOrientation(quarterTurns: 0, mirroredX: true))
        // 스큐(비-디헤드럴) — 안전 거부(nil), 오분기 대신 폴백.
        XCTAssertNil(VideoTrackOrientation.classify(CGAffineTransform(a: 1, b: 0.3, c: 0, d: 1, tx: 0, ty: 0)))
        // 임의 각도 회전(30°) — 8원소 어디에도 안 맞아야 함.
        XCTAssertNil(VideoTrackOrientation.classify(CGAffineTransform(rotationAngle: .pi / 6)))
    }


    /// 텍스처의 (x,y) 픽셀을 논리 RGB(채널 순서 무관)로 읽는다 — 헤드리스는 rgba8Unorm, 라이브(보정 경로)는
    /// bgra8Unorm 이라 픽셀 포맷별 순서를 맞춘다.
    private func rgbPixel(_ tex: MTLTexture, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        var px = [UInt8](repeating: 0, count: 4)
        tex.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        if tex.pixelFormat == .bgra8Unorm { return (Int(px[2]), Int(px[1]), Int(px[0])) }
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    /// F5-2: 라이브 경로(AVPlayerItemVideoOutput.copyPixelBuffer)가 트랙 preferredTransform(90°배수+미러)을
    /// 반영하는지 — 이미 정합인 헤드리스(AVAssetImageGenerator.appliesPreferredTrackTransform=true)와 4사분면
    /// 지문을 대조한다. 정사각형 mp4 라 회전해도 치수가 불변이라 좌표계 혼란 없이 직접 비교 가능.
    /// 수정 전: 라이브는 트랙 변환을 전혀 반영하지 않아 저장 그대로(TL=빨강/TR=초록/BL=파랑/BR=노랑)가 나와
    /// 90°회전된 헤드리스 배치와 어긋난다.
    func testLiveVideoAppliesTrackRotationLikeHeadless() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_f5_2_rot_\(UUID().uuidString).mp4")
        // 표준 90°시계방향 표시변환(iOS UIImage.Orientation.right 와 동일 관용값).
        try makeOrientedMP4(at: url, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0))
        defer { try? FileManager.default.removeItem(at: url) }

        let sv = SceneVideoLayer(mp4URL: url)
        defer { sv.teardown() }
        guard let headless = sv.headlessTexture(at: 0, device: device) else {
            throw XCTSkip("헤드리스 디코드 실패(환경 코덱 제약)")
        }

        sv.startLive(device: device)
        var live: MTLTexture?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, live == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            live = sv.liveTexture(device: device)
        }
        guard let live else { throw XCTSkip("라이브 첫 프레임 미생성(환경 제약)") }

        // 4사분면 중심(경계 아티팩트 회피) 대조.
        for (x, y) in [(16, 16), (48, 16), (16, 48), (48, 48)] {
            let h = rgbPixel(headless, x, y)
            let l = rgbPixel(live, x, y)
            let diff = abs(h.0 - l.0) + abs(h.1 - l.1) + abs(h.2 - l.2)
            XCTAssertLessThan(diff, 150,
                              "(\(x),\(y)) 헤드리스 rgb=\(h) vs 라이브 rgb=\(l) — 라이브가 트랙 회전을 반영하지 않음")
        }
    }

    /// F5-2: 미러(좌우 반전) 전용 트랙 변환도 라이브 경로에 반영돼야 한다(회전과 별개 vImage 경로).
    func testLiveVideoAppliesTrackMirrorLikeHeadless() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_f5_2_mirror_\(UUID().uuidString).mp4")
        // 순수 수평 미러(회전 없음).
        try makeOrientedMP4(at: url, transform: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 64, ty: 0))
        defer { try? FileManager.default.removeItem(at: url) }

        let sv = SceneVideoLayer(mp4URL: url)
        defer { sv.teardown() }
        guard let headless = sv.headlessTexture(at: 0, device: device) else {
            throw XCTSkip("헤드리스 디코드 실패(환경 코덱 제약)")
        }

        sv.startLive(device: device)
        var live: MTLTexture?
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, live == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            live = sv.liveTexture(device: device)
        }
        guard let live else { throw XCTSkip("라이브 첫 프레임 미생성(환경 제약)") }

        for (x, y) in [(16, 16), (48, 16), (16, 48), (48, 48)] {
            let h = rgbPixel(headless, x, y)
            let l = rgbPixel(live, x, y)
            let diff = abs(h.0 - l.0) + abs(h.1 - l.1) + abs(h.2 - l.2)
            XCTAssertLessThan(diff, 150,
                              "(\(x),\(y)) 헤드리스 rgb=\(h) vs 라이브 rgb=\(l) — 라이브가 트랙 미러를 반영하지 않음")
        }
    }
}
