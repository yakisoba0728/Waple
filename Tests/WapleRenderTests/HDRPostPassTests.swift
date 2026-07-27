import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// A2 HDR 톤맵 — 백화(>1.0 합의 [0,1] 하드클램프 = 순백) 해소 검증.
final class HDRPostPassTests: XCTestCase {

    // MARK: 커브 = saturate 클램프 (1x1 GPU) — >1 은 1.0(255), [0,1] 저역은 항등(ACES 곡선변형 제거).

    /// WE 최종 = saturate 클램프(무-ACES 5중확증). >1.0 입력은 정확히 1.0(255)으로 클램프되고,
    /// [0,1] 저역은 항등 통과 — ACES 는 저역도 곡선변형했으므로(0.25→≈0.37) 이 항등이 클램프 전환의 증거.
    func testClampsAboveOneAndKeepsLowRangeIdentity() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let post = try XCTUnwrap(HDRPostPass(device: device, outputFormat: .bgra8Unorm))

        // float src: r=4.0(>1), g=0.25(저역: 0.25*255=63.75→64), b=0.0. exposure 기본 1.0 = 항등.
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        sd.usage = [.renderTarget, .shaderRead]
        let src = try XCTUnwrap(device.makeTexture(descriptor: sd))
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        dd.usage = [.renderTarget, .shaderRead]; dd.storageMode = .shared
        let dst = try XCTUnwrap(device.makeTexture(descriptor: dd))

        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let clr = MTLRenderPassDescriptor()
        clr.colorAttachments[0].texture = src
        clr.colorAttachments[0].loadAction = .clear
        clr.colorAttachments[0].clearColor = MTLClearColor(red: 4, green: 0.25, blue: 0, alpha: 1)
        clr.colorAttachments[0].storeAction = .store
        try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: clr)).endEncoding()
        post.encode(cb: cb, src: src, dst: dst)
        cb.commit(); cb.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: 4)
        dst.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        let b = px[0], g = px[1], r = px[2]   // bgra8 바이트 순서
        XCTAssertEqual(r, 255, "R(입력4.0)은 정확히 1.0 으로 클램프(순백)")
        XCTAssert(abs(Int(g) - 64) <= 1, "G(입력0.25)는 항등 통과(≈64) — ACES 라면 ≈95 로 곡선변형, got \(g)")
        XCTAssertEqual(b, 0, "B(입력0)은 0(항등)")
    }

    func testTonemapKeepsZeroBlack() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let post = try XCTUnwrap(HDRPostPass(device: device, outputFormat: .bgra8Unorm))
        let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        sd.usage = [.renderTarget, .shaderRead]
        let src = try XCTUnwrap(device.makeTexture(descriptor: sd))
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        dd.usage = [.renderTarget, .shaderRead]; dd.storageMode = .shared
        let dst = try XCTUnwrap(device.makeTexture(descriptor: dd))
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let clr = MTLRenderPassDescriptor()
        clr.colorAttachments[0].texture = src
        clr.colorAttachments[0].loadAction = .clear
        clr.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        clr.colorAttachments[0].storeAction = .store
        try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: clr)).endEncoding()
        post.encode(cb: cb, src: src, dst: dst)
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: 4)
        dst.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(px[0], 0); XCTAssertEqual(px[1], 0); XCTAssertEqual(px[2], 0)
    }

    // MARK: e2e 씬 캡처 — float 누적 + 파이프라인 포맷 정합 + 톤맵 배선 + 무크래시를 한 번에 증명.

    /// brightness=3 흰 레이어(tint=3 → acc 에 3.0 기록)를 hdr on/off 로 캡처.
    private func brightestCenter(hdr: Bool, tag: String) throws -> NSColor {
        let scene = """
        {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0","hdr":\(hdr)},
         "objects":[{"id":1,"image":"models/w.json","origin":"960 540 0","size":"1920 1080","brightness":3.0}]}
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
            ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
            ("materials/w.tex", solidTex(255, 255, 255)),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_hdr_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_hdr_out_\(tag)")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        return try XCTUnwrap(rep.colorAt(x: 32, y: 18))
    }

    /// HDR 씬(brightness=3, 단일 불투명)은 saturate 클램프로 순백(1.0) — LDR 하드클램프와 동일 결과.
    /// 종전 ACES 는 여기서 <0.98 로 압축했으나 WE 는 클램프(무-ACES 5중확증)라 순백이 정답.
    /// float acc + 파이프라인 포맷 정합 + 무크래시도 함께 증명(e2e).
    func testHDRSceneClampsToWhiteLikeLDR() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let hdrC = try brightestCenter(hdr: true, tag: "on")
        let ldrC = try brightestCenter(hdr: false, tag: "off")
        // 대조(LDR): tint 3.0 이 bgra8 [0,1] 하드클램프 = 순백.
        XCTAssertGreaterThan(ldrC.redComponent, 0.99, "LDR 경로는 백화(클램프)해야 대조 유효")
        // HDR: float 누적 → 최종 saturate → LDR 과 동일하게 순백(ACES 압축 제거).
        XCTAssertGreaterThan(hdrC.redComponent, 0.99, "HDR float 경로도 saturate 클램프 = 순백")
        // 흰 입력(3,3,3) → per-channel 동일 클램프 = 무채색 유지.
        XCTAssertEqual(hdrC.redComponent, hdrC.greenComponent, accuracy: 0.02)
        XCTAssertEqual(hdrC.greenComponent, hdrC.blueComponent, accuracy: 0.02)
    }

    /// Y-flip 가드: 톤맵 패스(풀스크린 삼각형 샘플)가 blit(정확 복사)과 세로 방향이 일치해야 한다.
    /// 상단 밴드만 밝은 씬을 hdr on/off 로 캡처 — 두 경로 모두 "상단 밝고 하단 어둠"이면 무플립.
    func testTonemapPassNotVerticallyFlipped() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func topBand(hdr: Bool, tag: String) throws -> (top: CGFloat, bottom: CGFloat) {
            // 상단 밴드(y-up: scene y 810..1080, 원점 y=945) 만 brightness=3, 나머지는 clear 0.
            let scene = """
            {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0","hdr":\(hdr)},
             "objects":[{"id":1,"image":"models/w.json","origin":"960 945 0","size":"1920 270","brightness":3.0}]}
            """
            let files: [(String, Data)] = [
                ("scene.json", scene.data(using: .utf8)!),
                ("models/w.json", #"{"material":"materials/w.json"}"#.data(using: .utf8)!),
                ("materials/w.json", #"{"passes":[{"textures":["w"]}]}"#.data(using: .utf8)!),
                ("materials/w.tex", solidTex(255, 255, 255)),
            ]
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_hdrflip_\(tag)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
            let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                           title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
            let r = SceneRenderer()
            try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
            defer { r.teardown() }
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_hdrflip_out_\(tag)")
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.1], toDir: out).first)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
            let topC = try XCTUnwrap(rep.colorAt(x: 32, y: 3))
            let botC = try XCTUnwrap(rep.colorAt(x: 32, y: 32))
            return (topC.redComponent, botC.redComponent)
        }
        let ldr = try topBand(hdr: false, tag: "off")  // 신뢰 기준(blit 경로, 무변경)
        let hdr = try topBand(hdr: true, tag: "on")     // 톤맵 경로
        XCTAssertGreaterThan(ldr.top, ldr.bottom + 0.3, "기준(blit): 밴드가 상단")
        XCTAssertGreaterThan(hdr.top, hdr.bottom + 0.3, "톤맵도 밴드가 상단이어야(무플립 = blit 과 방향 일치)")
    }

    /// 가산 파티클 float 경로(anchor 2881558311). particlePipeline(additive) 을
    /// accPixelFormat(float)로 생성 + dst=.one 누적을 float acc 로 — 포맷 불일치면 인코드 크래시.
    /// 파티클 sim 은 고정 시드라 hdr on/off 레이아웃 동일 = 직접 대조 가능.
    func testAdditiveParticlesHDRFloatPathNoCrashClampsToWhite() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func maxRed(hdr: Bool, tag: String) throws -> CGFloat {
            let scene = """
            {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0","hdr":\(hdr)},
             "objects":[{"id":1,"name":"blob","particle":"particles/p.json","origin":"960 540 0","scale":"1 1 1"}]}
            """
            // 흰 스프라이트를 넓게 흩어 가산(무속도). 풀알파 중심의 합 ≥1 → LDR 는 클램프-per-add,
            // HDR 는 float 합 후 최종 saturate — 둘 다 순백(1.0). WE 는 클램프라 순백이 정답(ACES 압축 제거).
            let particle = """
            {"emitter":[{"name":"sphererandom","origin":"0 0 0","directions":"1 1 1","distancemin":120,"distancemax":420,"rate":10}],
             "initializer":[{"name":"lifetimerandom","min":10,"max":10},{"name":"sizerandom","min":70,"max":70},
               {"name":"colorrandom","min":"255 255 255","max":"255 255 255"}],
             "operator":[{"name":"movement","gravity":"0 0 0"}],
             "renderer":[{"name":"sprite"}],"maxcount":5,"starttime":0,"material":"materials/p.json"}
            """
            let files: [(String, Data)] = [
                ("scene.json", scene.data(using: .utf8)!),
                ("particles/p.json", particle.data(using: .utf8)!),
                ("materials/p.json", #"{"passes":[{"shader":"genericparticle","blending":"additive","textures":["particle/p"]}]}"#.data(using: .utf8)!),
                ("materials/particle/p.tex", solidTex(255, 255, 255)),
            ]
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_hdrpart_\(tag)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
            let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                           title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
            let r = SceneRenderer()
            try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 36)), project: project)
            defer { r.teardown() }
            let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_hdrpart_out_\(tag)")
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            // no-crash 게이트: 가산-파티클 float 파이프라인이 인코드되어 유효 PNG 를 내야 한다.
            let url = try XCTUnwrap(r.captureFrames(width: 64, height: 36, times: [0.5], toDir: out).first)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
            var mx: CGFloat = 0
            for y in 0..<36 {
                for x in 0..<64 {
                    if let c = rep.colorAt(x: x, y: y) { mx = max(mx, c.redComponent) }
                }
            }
            return mx
        }
        let ldrMax = try maxRed(hdr: false, tag: "off")  // 가산 클램프 = 순백
        let hdrMax = try maxRed(hdr: true, tag: "on")     // float 누적 + 최종 saturate
        XCTAssertGreaterThan(ldrMax, 0.99, "LDR 가산합 ≥1 이 순백 클램프(대조 유효 + 파티클 렌더 확인)")
        XCTAssertGreaterThan(hdrMax, 0.99, "HDR: 파티클 float 합도 최종 saturate = 순백(무크래시·ACES 압축 제거)")
    }
}
