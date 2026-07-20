import XCTest
import AppKit
@testable import WapleCore
@testable import WapleRender

/// M6: scene 이 video 오브젝트를 레이어로 포함할 때, 종전엔 mount 가 씬을 통째로 VideoRenderer 로
/// 스왑해 형제 레이어가 전부 소실됐다. 수정 후엔 video 를 일반 레이어로 합성한다 — buildLayers 가
/// video-.tex 레이어에 SceneVideoLayer 공급자를 붙이고(스왑 아님), captureFrames/draw 가
/// buildDisplayTextures 로 프레임을 형제 레이어와 함께 렌더한다.
final class VideoBackedSceneCaptureTests: XCTestCase {
    private func makeTex(format: Int, w: Int, h: Int, payload: [UInt8]) -> Data {
        var b: [UInt8] = []
        b += Array("TEXV0005".utf8) + [0] + Array("TEXI0001".utf8) + [0]
        b += i32(format) + i32(0) + i32(w) + i32(h) + i32(w) + i32(h)
        b += Array("TEXB0001".utf8) + [0] + payload
        return Data(b)
    }

    // MARK: 시간 wrap (헤르메틱 — 코퍼스/디바이스 무관)

    func testWrapLoopsWithinDuration() {
        // 루프 재생: 짧은 4s 비디오에 scene-time 6 → 6 mod 4 = 2(다른 애니 레이어와 동일 scene-time 정합).
        XCTAssertEqual(SceneVideoLayer.wrap(6.0, duration: 4.0), 2.0, accuracy: 1e-9)
        XCTAssertEqual(SceneVideoLayer.wrap(3.0, duration: 4.0), 3.0, accuracy: 1e-9)   // dur 내면 그대로
        XCTAssertEqual(SceneVideoLayer.wrap(-1.0, duration: 4.0), 3.0, accuracy: 1e-9)  // 음수 wrap
    }

    func testWrapUnknownDuration() {
        // duration 미상(0/비유한): max(0,t) 로 두고 디코드 폴백에 위임.
        XCTAssertEqual(SceneVideoLayer.wrap(6.0, duration: 0), 6.0, accuracy: 1e-9)
        XCTAssertEqual(SceneVideoLayer.wrap(6.0, duration: .nan), 6.0, accuracy: 1e-9)
        XCTAssertEqual(SceneVideoLayer.wrap(-2.0, duration: 0), 0.0, accuracy: 1e-9)
    }

    // MARK: 스왑 아닌 합성 경로 선택 (합성 pkg — 디바이스 게이트)

    /// video 레이어 + 형제 이미지 레이어를 가진 씬을 mount → (a) 두 레이어 모두 GPULayer 로 생성(스왑이면
    /// 1개 풀스크린 비디오만 남음), (b) video 레이어에 SceneVideoLayer 공급자 부착(합성 경로 선택),
    /// (c) 형제는 공급자 없음. 디코드 가능한 실제 mp4 불필요 — 경로 선택만 검증(프레임 디코드는 실코퍼스 테스트).
    func testVideoLayerCompositesWithSiblingNotSwaps() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        // 오브젝트 2개: [0] 비디오 텍스처 레이어, [1] 형제 이미지(png) 레이어.
        let scene = Data(#"{"general":{"orthogonalprojection":{"width":100,"height":100},"clearcolor":"0 0 0"},"objects":[{"image":"models/vid.json","origin":"50 50 0","size":"100 100","scale":"1 1 1","angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}},{"image":"models/sib.json","origin":"50 50 0","size":"40 40","scale":"1 1 1","angles":"0 0 0","alpha":1,"color":"1 1 1","brightness":1,"visible":{"value":true}}]}"#.utf8)
        let vidModel = Data(#"{"material":"materials/vidmat.json"}"#.utf8)
        let sibModel = Data(#"{"material":"materials/sibmat.json"}"#.utf8)
        let vidMat = Data(#"{"passes":[{"shader":"genericimage2","textures":["v"]}]}"#.utf8)
        let sibMat = Data(#"{"passes":[{"shader":"flat"}]}"#.utf8)   // 무텍스처 → 솔리드 형제(디코드 무관하게 상존)
        let mp4: [UInt8] = [UInt8](i32(0x18)) + Array("ftypisom".utf8) + [1, 2, 3]     // video 페이로드(비-디코드 — 경로만)
        let pkg = encodePkg([
            ("scene.json", scene),
            ("models/vid.json", vidModel), ("materials/vidmat.json", vidMat),
            ("materials/v.tex", makeTex(format: 0, w: 100, h: 100, payload: mp4)),
            ("models/sib.json", sibModel), ("materials/sibmat.json", sibMat),
        ])
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("m6-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try pkg.write(to: dir.appendingPathComponent("scene.pkg"))
        try Data(#"{"type":"scene","title":"m6","file":"scene.pkg"}"#.utf8).write(to: dir.appendingPathComponent("project.json"))
        let project = try XCTUnwrap(try? ProjectJSONParser.parse(folderURL: dir))

        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100)), project: project)
        defer { r.teardown() }
        // (a) 스왑 아님 — video + 형제 레이어 모두 존재.
        XCTAssertEqual(r.layers.count, 2, "형제 레이어 소실(스왑 회귀)")
        // (b) video 레이어에만 공급자 부착.
        let withVideo = r.layers.filter { $0.video != nil }
        XCTAssertEqual(withVideo.count, 1, "video 공급자는 정확히 1개 레이어")
        // (c) 형제는 일반 레이어(공급자 없음).
        XCTAssertEqual(r.layers.filter { $0.video == nil }.count, 1)
        XCTAssertTrue(r.hasVideoLayer)
    }

    // MARK: 라이브 경로 스모크 (env-guarded — AVPlayerItemVideoOutput+CVMetalTextureCache)

    /// 헤드리스(AVAssetImageGenerator)와 별개인 라이브 디코드 경로를 검증: startLive → 런루프 펌프 →
    /// liveTexture 가 (a) non-nil 프레임 생성(CVMetalTextureCache 경로·텍스처 수명), (b) 재생이 진행하며
    /// 프레임이 변화(정지 아님). 코퍼스 비디오로 실디코드 스모크(스냅샷 셀프체크가 못 잡는 경로).
    func testLiveVideoLayerProducesAdvancingFrames() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"]
            ?? (NSHomeDirectory() + "/Downloads/wallpaper_dev/backgrounds/3665954520")
        guard FileManager.default.fileExists(atPath: base + "/scene.pkg") else { throw XCTSkip("no real video scene") }
        let pkg = try ScenePackage.parse(try Data(contentsOf: URL(fileURLWithPath: base + "/scene.pkg"), options: .mappedIfSafe))
        let doc = try SceneDocument.parse(package: pkg)
        let vname = try XCTUnwrap(VideoTextureExtractor.videoLayer(in: doc, package: pkg))
        let mp4 = try XCTUnwrap(VideoTextureExtractor.extractMP4(
            textureEntryName: vname, package: pkg, sceneID: "livetest", cacheKey: "livetest_v",
            cacheDir: VideoTextureExtractor.defaultCacheDir()))
        let sv = SceneVideoLayer(mp4URL: mp4)
        defer { sv.teardown() }
        sv.startLive(device: device)
        XCTAssertTrue(sv.isLive)
        // 중앙 128×128 지문(코너는 정지 배경일 수 있음) — 프레임 변화 감지에 충분.
        func fingerprint() -> [UInt8]? {
            guard let t = sv.liveTexture(device: device) else { return nil }
            let w = min(t.width, 128), h = min(t.height, 128)
            let ox = max(0, (t.width - w) / 2), oy = max(0, (t.height - h) / 2)
            var b = [UInt8](repeating: 0, count: w * h * 4)
            t.getBytes(&b, bytesPerRow: w * 4, from: MTLRegionMake2D(ox, oy, w, h), mipmapLevel: 0)
            return b
        }
        // 최대 3s 런루프 펌프로 첫 프레임 확보(플레이어 준비+디코드).
        var samples: [[UInt8]] = []
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, samples.isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if let f = fingerprint() { samples.append(f) }
        }
        XCTAssertFalse(samples.isEmpty, "라이브 프레임 미생성(AVPlayerItemVideoOutput/CVMetalTextureCache 실패)")
        // 이후 ~1.5s 동안 여러 샘플 — 30fps 라면 수십 프레임, 최소 2개는 서로 달라야(재생 진행).
        let sampleEnd = Date().addingTimeInterval(1.5)
        while Date() < sampleEnd {
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            if let f = fingerprint() { samples.append(f) }
        }
        XCTAssertGreaterThan(Set(samples.map { $0 }).count, 1, "라이브 비디오가 진행하지 않음(정지 프레임만)")
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
