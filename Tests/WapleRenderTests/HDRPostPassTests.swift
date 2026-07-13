import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// A2 HDR 톤맵 — 백화(>1.0 합의 [0,1] 하드클램프 = 순백) 해소 검증.
final class HDRPostPassTests: XCTestCase {

    // MARK: 커브 형태 (1x1 GPU) — >1 입력이 순백으로 클램프되지 않고 압축, hue 순서 보존.

    func testTonemapCompressesAboveOneNoWhitePlateau() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let post = try XCTUnwrap(HDRPostPass(device: device, outputFormat: .bgra8Unorm))

        // float src 를 clear 로 HDR 색(r=4,g=2,b=1)으로 채움 — half 인코딩 회피.
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
        clr.colorAttachments[0].clearColor = MTLClearColor(red: 4, green: 2, blue: 1, alpha: 1)
        clr.colorAttachments[0].storeAction = .store
        try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: clr)).endEncoding()
        post.encode(cb: cb, src: src, dst: dst)
        cb.commit(); cb.waitUntilCompleted()

        var px = [UInt8](repeating: 0, count: 4)
        dst.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
        let b = px[0], g = px[1], r = px[2]   // bgra8 바이트 순서
        XCTAssertLessThan(r, 255, "R(입력4)이 순백 클램프가 아니라 톤맵 압축돼야 함")
        XCTAssertLessThan(g, 255); XCTAssertLessThan(b, 255)
        XCTAssertGreaterThan(r, g, "단조 톤맵 = hue 순서 보존(입력 r>g)")
        XCTAssertGreaterThan(g, b, "hue 순서 보존(입력 g>b)")
        XCTAssertGreaterThan(b, 0, "0 이상 입력은 0 초과로 매핑")
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

    /// HDR 씬: 3.0 합이 톤맵 압축돼 순백(1.0) 미만. hdr=false 대조는 하드클램프(1.0) — 백화 메커니즘 직격.
    func testHDRSceneTonemapsInsteadOfWhiteClamp() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let hdrC = try brightestCenter(hdr: true, tag: "on")
        let ldrC = try brightestCenter(hdr: false, tag: "off")
        // 대조(LDR): tint 3.0 이 bgra8 [0,1] 하드클램프 = 순백.
        XCTAssertGreaterThan(ldrC.redComponent, 0.99, "LDR 경로는 백화(클램프)해야 대조 유효")
        // HDR: float 누적 → 톤맵 압축 → 순백 미만이지만 여전히 밝음(백화 해소).
        XCTAssertLessThan(hdrC.redComponent, 0.98, "HDR 톤맵이 순백 plateau 를 제거해야 함")
        XCTAssertGreaterThan(hdrC.redComponent, 0.5, "여전히 밝은 하이라이트(과압축 아님)")
        // 흰 입력(3,3,3) → per-channel 동일 톤맵 = 무채색 유지.
        XCTAssertEqual(hdrC.redComponent, hdrC.greenComponent, accuracy: 0.02)
        XCTAssertEqual(hdrC.greenComponent, hdrC.blueComponent, accuracy: 0.02)
    }

    /// Y-flip 가드: 톤맵 패스(풀스크린 삼각형 샘플)가 blit(정확 복사)과 세로 방향이 일치해야 한다.
    /// 상단 밴드만 밝은 씬을 hdr on/off 로 캡처 — 두 경로 모두 "상단 밝고 하단 어둠"이면 무플립.
    func testTonemapPassNotVerticallyFlipped() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func topBand(hdr: Bool, tag: String) throws -> (top: CGFloat, bottom: CGFloat) {
            // 상단 밴드(scene y 0..270, 원점 y=135) 만 brightness=3, 나머지는 clear 0.
            let scene = """
            {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0","hdr":\(hdr)},
             "objects":[{"id":1,"image":"models/w.json","origin":"960 135 0","size":"1920 270","brightness":3.0}]}
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

    /// 가산 파티클 float 경로(anchor 2881558311 의 주 백화원). particlePipeline(additive) 을
    /// accPixelFormat(float)로 생성 + dst=.one 누적을 float acc 로 — 포맷 불일치면 인코드 크래시.
    /// 파티클 sim 은 고정 시드라 hdr on/off 레이아웃 동일 = 직접 대조 가능.
    func testAdditiveParticlesHDRFloatPathNoCrashNoWhiteClamp() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        func maxRed(hdr: Bool, tag: String) throws -> CGFloat {
            let scene = """
            {"general":{"orthogonalprojection":{"width":1920,"height":1080},"clearcolor":"0 0 0","hdr":\(hdr)},
             "objects":[{"id":1,"name":"blob","particle":"particles/p.json","origin":"960 540 0","scale":"1 1 1"}]}
            """
            // 흰 스프라이트를 넓게 흩어 가산(무속도). 풀알파 중심의 합 ≈1(단일)~수(경미중첩) → LDR 순백 클램프,
            // HDR 톤맵으로 <1. 조밀 파일업(합 >>1)은 ACES 점근으로 HDR 도 255 가 되므로 의도적으로 성기게.
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
        let hdrMax = try maxRed(hdr: true, tag: "on")     // float 누적 + 톤맵
        XCTAssertGreaterThan(ldrMax, 0.99, "LDR 가산합 ≥1 이 순백 클램프(대조 유효 + 파티클 렌더 확인)")
        XCTAssertLessThan(hdrMax, 0.98, "HDR: 파티클 float 경로가 순백 clamp 대신 톤맵 압축")
        XCTAssertGreaterThan(hdrMax, 0.3, "파티클이 float acc 에 실제 합성됨(무크래시·비검정)")
    }
}
