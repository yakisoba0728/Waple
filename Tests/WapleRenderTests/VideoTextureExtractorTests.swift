import XCTest
@testable import WapleRender
@testable import WapleCore

final class VideoTextureExtractorTests: XCTestCase {
    /// TEX 헤더 + 임의 페이로드.
    private func makeTex(format: Int, w: Int, h: Int, payload: [UInt8]) -> Data {
        var b: [UInt8] = []
        b += bytes(tag("TEXV0005"), tag("TEXI0001"))
        b += bytes(i32b(format), i32b(0), i32b(w), i32b(h), i32b(w), i32b(h))
        b += bytes(tag("TEXB0001"), payload)
        return Data(b)
    }
    private func scenePkg(videoTex: Bool) throws -> ScenePackage {
        let scene = Data(#"{"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},"objects":[{"image":"models/m.json","origin":"50 50 0","size":"100 100","scale":"1 1 1","angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}]}"#.utf8)
        let model = Data(#"{"material":"materials/mat.json"}"#.utf8)
        let material = Data(#"{"passes":[{"shader":"genericimage2","textures":["v"]}]}"#.utf8)
        let mp4: [UInt8] = [UInt8](i32(0x18)) + Array("ftypisom".utf8) + [1, 2, 3]
        let tex = makeTex(format: 0, w: 100, h: 100, payload: videoTex ? mp4 : [0x89, 0x50, 0x4E, 0x47, 1, 2])
        return try ScenePackage.parse(encodePkg([
            ("scene.json", scene), ("models/m.json", model), ("materials/mat.json", material), ("materials/v.tex", tex),
        ]))
    }

    func testDetectsVideoLayer() throws {
        let pkg = try scenePkg(videoTex: true)
        let doc = try SceneDocument.parse(package: pkg)
        XCTAssertEqual(VideoTextureExtractor.videoLayer(in: doc, package: pkg), "materials/v.tex")
    }

    func testNoVideoLayerForImageTex() throws {
        let pkg = try scenePkg(videoTex: false)
        let doc = try SceneDocument.parse(package: pkg)
        XCTAssertNil(VideoTextureExtractor.videoLayer(in: doc, package: pkg))
    }

    func testExtractsMP4Bytes() throws {
        let pkg = try scenePkg(videoTex: true)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WapleMP4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try XCTUnwrap(VideoTextureExtractor.extractMP4(textureEntryName: "materials/v.tex", package: pkg, sceneID: "42", cacheDir: dir))
        XCTAssertEqual(url.lastPathComponent, "42.mp4")
        let bytes = [UInt8](try Data(contentsOf: url))
        // mp4 박스: [size 4][ftyp...]
        XCTAssertEqual(Array(bytes[4..<8]), Array("ftyp".utf8))
    }

    /// 크기가 일치하는 유효 캐시는 재사용한다(동일 URL, 동일 바이트).
    func testReusesValidCache() throws {
        let pkg = try scenePkg(videoTex: true)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WapleMP4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let u1 = try XCTUnwrap(VideoTextureExtractor.extractMP4(textureEntryName: "materials/v.tex", package: pkg, sceneID: "42", cacheDir: dir))
        let first = try Data(contentsOf: u1)
        let u2 = try XCTUnwrap(VideoTextureExtractor.extractMP4(textureEntryName: "materials/v.tex", package: pkg, sceneID: "42", cacheDir: dir))
        XCTAssertEqual(u1, u2)
        XCTAssertEqual(try Data(contentsOf: u2), first)
    }

    /// 크기가 기대치와 다른 부분/오염 캐시는 무효화하고 재추출해야 한다.
    func testReextractsStaleCache() throws {
        let pkg = try scenePkg(videoTex: true)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WapleMP4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let u1 = try XCTUnwrap(VideoTextureExtractor.extractMP4(textureEntryName: "materials/v.tex", package: pkg, sceneID: "42", cacheDir: dir))
        let good = try Data(contentsOf: u1)
        // 잘린(부분 기록) 캐시로 오염시킨다.
        try Data([0x00]).write(to: u1)
        let u2 = try XCTUnwrap(VideoTextureExtractor.extractMP4(textureEntryName: "materials/v.tex", package: pkg, sceneID: "42", cacheDir: dir))
        XCTAssertEqual(try Data(contentsOf: u2), good)
    }

    func testExtractMP4NilForImageTex() throws {
        let pkg = try scenePkg(videoTex: false)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WapleMP4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(VideoTextureExtractor.extractMP4(textureEntryName: "materials/v.tex", package: pkg, sceneID: "x", cacheDir: dir))
    }

    // MARK: - LRU eviction (상한 N=8)

    /// 캐시 상한(N)까지 채운 뒤, 명시적 과거 mtime 을 부여하고 새 씬을 추출하면 가장 오래된 것이 evict 된다.
    func testEvictsOldestBeyondCap() throws {
        let pkg = try scenePkg(videoTex: true)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WapleMP4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = VideoTextureExtractor.maxCachedVideos
        let fm = FileManager.default
        // cap 개(s0..s{cap-1}) 추출 — 여기까지는 evict 없음(count == cap).
        for i in 0..<cap {
            _ = try XCTUnwrap(VideoTextureExtractor.extractMP4(textureEntryName: "materials/v.tex", package: pkg, sceneID: "s\(i)", cacheDir: dir))
        }
        // 과거 시각으로 mtime 을 s0(가장 오래됨) → s{cap-1}(가장 최근) 순으로 고정(결정적 순서).
        for i in 0..<cap {
            let u = dir.appendingPathComponent("s\(i).mp4")
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000 + Double(i))], ofItemAtPath: u.path)
        }
        // (cap+1)번째 추출 → 새 파일은 mtime=now(최신) → 가장 오래된 s0 evict.
        _ = try XCTUnwrap(VideoTextureExtractor.extractMP4(textureEntryName: "materials/v.tex", package: pkg, sceneID: "s\(cap)", cacheDir: dir))
        let remaining = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "mp4" }
        XCTAssertEqual(remaining.count, cap, "상한 유지")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("s0.mp4").path), "가장 오래된 s0 는 evict")
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("s\(cap).mp4").path), "새 씬은 잔존")
    }

    /// 캐시 적중(재추출)은 mtime 을 갱신(touch)하므로, 그 뒤 evict 에서 최근 접근 파일이 보존된다.
    func testCacheHitTouchProtectsFromEviction() throws {
        let pkg = try scenePkg(videoTex: true)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("WapleMP4-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cap = VideoTextureExtractor.maxCachedVideos
        let fm = FileManager.default
        for i in 0..<cap {
            _ = try XCTUnwrap(VideoTextureExtractor.extractMP4(textureEntryName: "materials/v.tex", package: pkg, sceneID: "s\(i)", cacheDir: dir))
        }
        for i in 0..<cap {
            let u = dir.appendingPathComponent("s\(i).mp4")
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000 + Double(i))], ofItemAtPath: u.path)
        }
        // s0 는 원래 가장 오래됨 — 캐시 적중으로 재추출하면 touch 되어 최신이 된다.
        _ = try XCTUnwrap(VideoTextureExtractor.extractMP4(textureEntryName: "materials/v.tex", package: pkg, sceneID: "s0", cacheDir: dir))
        // 새 씬 추출 → 이제 가장 오래된 것은 s1. s0 는 보존.
        _ = try XCTUnwrap(VideoTextureExtractor.extractMP4(textureEntryName: "materials/v.tex", package: pkg, sceneID: "s\(cap)", cacheDir: dir))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("s0.mp4").path), "최근 접근한 s0 는 보존")
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("s1.mp4").path), "이제 가장 오래된 s1 이 evict")
    }
}
