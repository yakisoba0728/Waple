import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// 감사 V06 회귀: TexImage.noInterpolation(flags bit0, WE NoInterpolation)의 손-포팅 이펙트 경로 소비.
/// 레이어 베이스 텍스처(=체인 첫 이펙트의 texture(0)/fb) 샘플만 nearest 쌍생 샘플러로 치환되고,
/// aux 슬롯·어드레스 모드·기본(미지정) 소스는 기존과 비트동일이어야 한다.
/// 배선은 clampUVs(F162/F163)와 동일하게 빌드 시 1회 해석(Resources.resolveTextureNoInterpolation →
/// buildEffectChain(baseNoInterp:) → buildHandPortEffect(fbNearest:) → EffectShaders.source(fbNearest:)).
final class EffectShadersNoInterpolationTests: XCTestCase {
    private static let names = ["waterwaves", "scroll", "opacity", "tint", "waterripple", "shake", "pulse"]

    /// fb 샘플에 쓰이는 샘플러 식별자 전수 추출.
    private func fbSamplers(_ src: String) -> [String] {
        let re = try! NSRegularExpression(pattern: #"fb\.sample\(\s*([A-Za-z_][A-Za-z0-9_]*)"#)
        let ns = src as NSString
        return re.matches(in: src, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    // MARK: MSL 소스 계약

    /// 기본(fbNearest 미지정/false)은 기존 소스와 비트동일 — 무회귀. nearest 쌍생은 기본에 없어야 함.
    func testDefaultSourceUnchanged() {
        for n in Self.names {
            XCTAssertEqual(EffectShaders.source(for: n), EffectShaders.source(for: n, fbNearest: false), n)
            XCTAssertFalse(EffectShaders.source(for: n)!.contains("NearestFB"),
                           "\(n): 기본 소스에 nearest 쌍생이 있으면 안 됨")
        }
    }

    /// nearest 변형: 전 스톡 이펙트의 fb 샘플 사이트가 모두 nearest 쌍생 샘플러로 치환되고,
    /// 쌍생 선언이 filter::nearest 로 존재해야 함.
    func testNearestVariantRewritesAllFBSamples() throws {
        for n in Self.names {
            let src = try XCTUnwrap(EffectShaders.source(for: n, fbNearest: true), n)
            let used = fbSamplers(src)
            XCTAssertFalse(used.isEmpty, "\(n): fb 샘플 사이트 누락")
            for s in used {
                XCTAssertTrue(s.hasSuffix("NearestFB"), "\(n): fb 샘플러 \(s) 가 nearest 쌍생이 아님")
                XCTAssertTrue(src.contains("constexpr sampler \(s)(filter::nearest,"),
                              "\(n): \(s) 의 nearest 선언 누락")
            }
        }
    }

    /// aux(비-fb) 텍스처 샘플과 어드레스 모드는 불변 — NoInterpolation 은 필터만 point, 랩은 WE 그대로.
    func testAuxSamplersAndAddressModesPreserved() throws {
        let op = try XCTUnwrap(EffectShaders.source(for: "opacity", fbNearest: true))
        XCTAssertTrue(op.contains("constexpr sampler s(filter::linear, address::clamp_to_edge);"),
                      "원본 선형 샘플러 유지(aux 가 계속 사용)")
        XCTAssertTrue(op.contains("mask.sample(s,"), "mask(aux)는 선형 유지")
        XCTAssertTrue(op.contains("fb.sample(sNearestFB,"), "fb 만 nearest 쌍생")
        let wr = try XCTUnwrap(EffectShaders.source(for: "waterripple", fbNearest: true))
        // waterripple 의 fb 는 sc(clamp) 샘플러 — 쌍생도 clamp 유지(필터만 nearest).
        XCTAssertTrue(wr.contains("constexpr sampler scNearestFB(filter::nearest, address::clamp_to_edge);"))
        XCTAssertTrue(wr.contains("fb.sample(scNearestFB,"))
        XCTAssertTrue(wr.contains("normalMap.sample(s,"), "노멀맵(aux)은 repeat 선형 유지")
        XCTAssertTrue(wr.contains("constexpr sampler s(filter::linear, address::repeat);"))
        XCTAssertFalse(wr.contains("constexpr sampler sNearestFB"), "fb 가 안 쓰는 샘플러엔 쌍생 불요")
    }

    /// 미지 이펙트는 변형 여부 무관하게 nil(기존 규약).
    func testUnknownEffectNearestIsNil() {
        XCTAssertNil(EffectShaders.source(for: "nope", fbNearest: true))
    }

    /// nearest 변형 7종 전부 실제 MSL 컴파일(ev_main/ef_main) — Metal 없는 CI 는 스킵.
    func testNearestVariantsCompileMSL() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        for n in Self.names {
            let src = try XCTUnwrap(EffectShaders.source(for: n, fbNearest: true), n)
            let lib = try device.makeLibrary(source: src, options: nil)
            XCTAssertNotNil(lib.makeFunction(name: "ev_main"), "\(n): no ev_main")
            XCTAssertNotNil(lib.makeFunction(name: "ef_main"), "\(n): no ef_main")
        }
    }

    // MARK: GPU 동작(Metal 있을 때만)

    /// opacity ef_main 을 2×1 [빨강|파랑] fb 로 4×1 확대 렌더(2배 확대 = mag filter 직결).
    private func renderOpacity(fbNearest: Bool) throws -> [UInt8]? {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let src = try XCTUnwrap(EffectShaders.source(for: "opacity", fbNearest: fbNearest))
        let lib = try device.makeLibrary(source: src, options: nil)
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = lib.makeFunction(name: "ev_main")
        pd.fragmentFunction = lib.makeFunction(name: "ef_main")
        pd.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipe = try device.makeRenderPipelineState(descriptor: pd)
        let quad: [Float] = [-1, -1, 1, -1, -1, 1, 1, 1]  // float2 ×4 (triangleStrip)
        let vbuf = device.makeBuffer(bytes: quad, length: MemoryLayout<Float>.stride * quad.count)!
        func tex(_ px: [UInt8], _ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
            let t = device.makeTexture(descriptor: d)!
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
            return t
        }
        let fb = tex([255, 0, 0, 255, 0, 0, 255, 255], 2, 1)   // [빨강|파랑]
        let mask = tex([255, 255, 255, 255], 1, 1)
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 1, mipmapped: false)
        let dst = device.makeTexture(descriptor: dd)!
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        enc.setRenderPipelineState(pipe)
        enc.setVertexBuffer(vbuf, offset: 0, index: 0)
        enc.setFragmentTexture(fb, index: 0)
        enc.setFragmentTexture(mask, index: 1)
        // P = [time, alpha] — opacity params(for:) 는 [alpha], 인코더 규약은 [time]+params(applyEffect).
        let p: [Float] = [0, 1]
        p.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: 16)
        dst.getBytes(&px, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 1), mipmapLevel: 0)
        return px
    }

    /// nearest 변형은 2배 확대 시 텍셀 경계 블렌드 없이 [R,R,B,B] — 선형은 경계 픽셀이 블렌드된다
    /// (대조군이 다르다는 것 자체가 변형이 실제 필터를 바꾼다는 증거).
    func testNearestVariantMagnifiesWithoutBlending() throws {
        guard let near = try renderOpacity(fbNearest: true),
              let lin = try renderOpacity(fbNearest: false) else { throw XCTSkip("no Metal device") }
        XCTAssertEqual(Array(near[0..<4]), [255, 0, 0, 255])
        XCTAssertEqual(Array(near[4..<8]), [255, 0, 0, 255])
        XCTAssertEqual(Array(near[8..<12]), [0, 0, 255, 255])
        XCTAssertEqual(Array(near[12..<16]), [0, 0, 255, 255])
        // 선형 대조군: 경계(픽셀 1/2)는 적·청 블렌드.
        XCTAssertNotEqual(Array(lin[4..<8]), [255, 0, 0, 255])
        XCTAssertNotEqual(Array(lin[8..<12]), [0, 0, 255, 255])
    }

    // MARK: 씬 end-to-end 배선(Metal 있을 때만)

    /// flags 지정 .tex — TEXV0005/TEXI0001 헤더(42B, flags@22 = `TexImage` 의 `flags` 선언 주석 규약.
    /// r3-M56 정정 — 종전 인용 `TexImage.swift:111` 은 `VariantCondition` 선언부라 무관했다) + PNG 페이로드
    /// (TestSupport.solidTex 와 동일 구조, flags 만 가변).
    private func flaggedTex(_ rgba: [UInt8], w: Int, h: Int, flags: Int) -> Data {
        var b = Data("TEXV0005\0".utf8) + Data("TEXI0001\0".utf8)
        b.append(i32(0)); b.append(i32(flags))
        b.append(i32(w)); b.append(i32(h)); b.append(i32(w)); b.append(i32(h))
        b.append(OffscreenCapture.png(rgba: rgba, width: w, height: h)!)
        return b
    }

    /// 2×1 [빨강|파랑] 텍스처 + scroll(speedx=1) 이펙트 레이어를 t=0.35 에 렌더 → 2픽셀.
    /// uv.x = fract(in.uv.x + 0.35) → texspace 1.2 / 0.2:
    ///   nearest = [texel1(파랑), texel0(빨강)] (경계 블렌드 없음)
    ///   linear  = [0.3R+0.7B, 0.7R+0.3B] (repeat 랩 블렌드)
    private func renderScrollScene(flags: Int, tag: String) throws -> (NSColor, NSColor) {
        let scene = """
        {"general":{"orthogonalprojection":{"width":2,"height":1},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/pix.json","origin":"1 0.5 0","size":"2 1",
            "effects":[{"file":"effects/scroll/effect.json","passes":[
              {"constantshadervalues":{"repeat":"1 1","speedx":1,"speedy":0}}]}]}]}
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/pix.json", #"{"material":"materials/pix.json"}"#.data(using: .utf8)!),
            ("materials/pix.json", #"{"passes":[{"textures":["pix"]}]}"#.data(using: .utf8)!),
            ("materials/pix.tex", flaggedTex([255, 0, 0, 255, 0, 0, 255, 255], w: 2, h: 1, flags: flags)),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_nointerp_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 2, height: 1)), project: project)
        defer { r.teardown() }
        let out = URL(fileURLWithPath: "/tmp/waple_nointerp_\(tag)")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 2, height: 1, times: [0.35], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        return (try XCTUnwrap(rep.colorAt(x: 0, y: 0)), try XCTUnwrap(rep.colorAt(x: 1, y: 0)))
    }

    /// 배선 end-to-end: noInterpolation(flags bit0) 텍스처 레이어는 손-포팅 이펙트에서 nearest 로
    /// 샘플돼야 하고(구현 전 = 항상 선형이라 본 테스트가 RED), 플래그 없는 대조군은 선형 유지여야 한다.
    ///
    /// **[2026-08-20] 손-포팅 경로를 명시적으로 켠다.** 이 테스트는 pkg 에 셰이더를 싣지 않고
    /// `effects/scroll/effect.json` 만 지목한다. 종전엔 팩 루트에 `shaders/effects/scroll.*` 가 없어
    /// 번역이 실패하고 손-포팅으로 떨어지는 것을 **암묵적으로** 기대했는데, 이펙트-로컬 자산 루트가
    /// 들어오면서 동봉 스톡 `effects/scroll/shaders/effects/scroll.*` 가 실제로 해석돼 번역 경로가
    /// 성공한다. 그러면 bind 슬롯 어드레싱이 손-포팅의 repeat 가 아니라 번역 경로의 clamp 가 되어
    /// 선형 대조군이 `0.7R+0.3B` 대신 순빨강이 된다(랩 텍셀이 사라진다).
    ///
    /// 기대값을 clamp 로 바꾸지 않고 스위치를 켜는 이유가 둘이다:
    ///   ① 이 테스트의 이름과 목적이 **손-포팅 경로 검증**이다. 암묵적 기대를 명시로 바꾸는 게 맞다.
    ///   ② 이펙트-로컬 루트 이후 손-포팅 **통합** 경로를 지나가는 테스트가 하나도 남지 않는다
    ///      (`EffectShadersTests` 17건은 `EffectShaders.params/source` 순수 단위 테스트라 배선을
    ///      안 본다). 그 오라클을 여기서 붙잡아 둔다.
    ///
    /// 별건으로 남는 질문: **번역 경로의 `previous` 슬롯이 정말 clamp 인가.** 원본에서 `uvs:"repeat"`
    /// 는 **이름 있는 FBO** 의 샘플러 플래그(bit2)이고 기본이 clamp 인 것은 확정이지만, 효과 입력
    /// (`previous`)의 어드레싱은 아직 원본으로 확인하지 않았다. 그때까지 이 자리를 기대값으로 굳히지
    /// 않는다 — 굳히면 틀린 규약이 계약이 된다.
    func testSceneScrollRespectsNoInterpolationFlag() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        setenv("WAPLE_DISABLE_TRANSLATED", "1", 1)
        defer { unsetenv("WAPLE_DISABLE_TRANSLATED") }
        let (n0, n1) = try renderScrollScene(flags: 0x1, tag: "near")
        XCTAssertLessThan(n0.redComponent, 0.1, "nearest: pixel0 은 순파랑(블렌드 없음)")
        XCTAssertGreaterThan(n0.blueComponent, 0.9)
        XCTAssertGreaterThan(n1.redComponent, 0.9, "nearest: pixel1 은 순빨강(블렌드 없음)")
        XCTAssertLessThan(n1.blueComponent, 0.1)
        // 대조군(flags=0): 같은 지오메트리에서 선형 블렌드 — 필터 구분력 증명 + 무회귀.
        let (l0, l1) = try renderScrollScene(flags: 0x0, tag: "lin")
        XCTAssertEqual(l0.redComponent, 0.3, accuracy: 0.08, "linear: pixel0 = 0.3R+0.7B")
        XCTAssertEqual(l0.blueComponent, 0.7, accuracy: 0.08)
        XCTAssertEqual(l1.redComponent, 0.7, accuracy: 0.08, "linear: pixel1 = 0.7R+0.3B")
        XCTAssertEqual(l1.blueComponent, 0.3, accuracy: 0.08)
    }

    // MARK: 경로 ① 무효과 베이스 레이어(감사 V07)

    /// 2×1 [빨강|파랑] **무효과** 레이어를 8×1 프로젝션 가득(size 8×1 = 4배 확대) 드로우 → 8픽셀.
    /// f_main 샘플러 필터 직결: uv.x 픽셀중심 (i+0.5)/8 → 텍셀좌표 ×2 = (i+0.5)/4.
    ///   nearest = [R,R,R,R, B,B,B,B]  (텍셀 경계에서 절단 — 블렌드 없음)
    ///   linear  = 경계 인접 픽셀만 블렌드(pixel3 = 0.625R+0.375B, pixel4 = 0.375R+0.625B — 대조군 구분력)
    private func renderPlainScene(flags: Int, tag: String) throws -> [NSColor] {
        let scene = """
        {"general":{"orthogonalprojection":{"width":8,"height":1},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/pix.json","origin":"4 0.5 0","size":"8 1"}]}
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/pix.json", #"{"material":"materials/pix.json"}"#.data(using: .utf8)!),
            ("materials/pix.json", #"{"passes":[{"textures":["pix"]}]}"#.data(using: .utf8)!),
            ("materials/pix.tex", flaggedTex([255, 0, 0, 255, 0, 0, 255, 255], w: 2, h: 1, flags: flags)),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_nointerp_base_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 1)), project: project)
        defer { r.teardown() }
        // 경로 고정: 이펙트 없는 베이스 레이어여야 함(이펙트 보유 시 체인 출력 FBO 라 선형이 WE 정합).
        XCTAssertEqual(r.layers.count, 1)
        XCTAssertTrue(r.layers[0].effects.isEmpty, "무효과 베이스 경로여야 한다")
        let out = URL(fileURLWithPath: "/tmp/waple_nointerp_base_\(tag)")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 8, height: 1, times: [0], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        return try (0..<8).map { try XCTUnwrap(rep.colorAt(x: $0, y: 0)) }
    }

    /// 감사 V07: 무효과 레이어도 noInterpolation(flags bit0) 이면 f_main 샘플이 nearest 여야 한다
    /// (구현 전 = 베이스 경로 미배선으로 항상 선형 — 본 테스트가 RED). 플래그 없는 대조군은 선형 유지.
    func testScenePlainLayerRespectsNoInterpolationFlag() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let n = try renderPlainScene(flags: 0x1, tag: "near")
        for i in 0...3 {
            XCTAssertGreaterThan(n[i].redComponent, 0.9, "nearest: pixel\(i) = 순빨강(블렌드 없음)")
            XCTAssertLessThan(n[i].blueComponent, 0.1, "nearest: pixel\(i) = 순빨강")
        }
        for i in 4...7 {
            XCTAssertLessThan(n[i].redComponent, 0.1, "nearest: pixel\(i) = 순파랑(블렌드 없음)")
            XCTAssertGreaterThan(n[i].blueComponent, 0.9, "nearest: pixel\(i) = 순파랑")
        }
        // 대조군(flags=0): 경계 인접 픽셀은 선형 블렌드 — 필터 구분력 증명 + 무회귀.
        let l = try renderPlainScene(flags: 0x0, tag: "lin")
        XCTAssertEqual(l[3].blueComponent, 0.375, accuracy: 0.08, "linear: pixel3 = 0.625R+0.375B")
        XCTAssertEqual(l[4].redComponent, 0.375, accuracy: 0.08, "linear: pixel4 = 0.375R+0.625B")
    }

    // MARK: 경로 ② GLSL 변환(translated) 이펙트(감사 V07)

    /// 2×1 [빨강|파랑] 텍스처 + 커스텀 GLSL(uv.x +0.35 시프트) 이펙트 레이어를 2×1 에 렌더 → 2픽셀.
    /// effect.json 은 패키지에 두지 않는다 — 매니페스트 관례(단일 패스, 셰이더 effects/<name>)로
    /// translated 경로를 강제(hand-port 스톡 7종에 없는 이름이라 손-포팅 폴터도 불가).
    ///   pixel0: uv.x = 0.25+0.35 = 0.6 → texcoord 1.2 → nearest = 순파랑 / linear = 0.3R+0.7B
    ///   pixel1: uv.x = 0.75+0.35 = 1.1 → texcoord 2.2 → clamp 라 양쪽 순파랑(비구분 — 참고만)
    @discardableResult
    private func renderTranslatedScene(flags: Int, tag: String) throws -> (NSColor, NSColor) {
        let scene = """
        {"general":{"orthogonalprojection":{"width":2,"height":1},"clearcolor":"0 0 0"},
         "objects":[
           {"id":1,"image":"models/pix.json","origin":"1 0.5 0","size":"2 1",
            "effects":[{"file":"effects/warp/effect.json"}]}]}
        """
        let vert = """
        uniform mat4 g_ModelViewProjectionMatrix;
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = mul(vec4(a_Position, 1.0), g_ModelViewProjectionMatrix); v_TexCoord = a_TexCoord; }
        """
        let frag = """
        varying vec2 v_TexCoord;
        uniform sampler2D g_Texture0;
        void main() { gl_FragColor = texSample2D(g_Texture0, v_TexCoord + vec2(0.35, 0.0)); }
        """
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("models/pix.json", #"{"material":"materials/pix.json"}"#.data(using: .utf8)!),
            ("materials/pix.json", #"{"passes":[{"textures":["pix"]}]}"#.data(using: .utf8)!),
            ("materials/pix.tex", flaggedTex([255, 0, 0, 255, 0, 0, 255, 255], w: 2, h: 1, flags: flags)),
            ("shaders/effects/warp.vert", vert.data(using: .utf8)!),
            ("shaders/effects/warp.frag", frag.data(using: .utf8)!),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_nointerp_tr_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 2, height: 1)), project: project)
        defer { r.teardown() }
        // 경로 고정: 이펙트가 translated(GLSL→MSL)로 빌드됐는지 확인 — 아니면 픽셀 단정은 무의미.
        XCTAssertEqual(r.layers.count, 1)
        let bind = try XCTUnwrap(r.layers[0].effects.first?.bind, "이펙트 체인이 비어 있으면 안 됨")
        if case .translated = bind { /* 정상 경로 */ } else { XCTFail("translated 경로여야 한다: \(bind)") }
        let out = URL(fileURLWithPath: "/tmp/waple_nointerp_tr_\(tag)")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 2, height: 1, times: [0], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        return (try XCTUnwrap(rep.colorAt(x: 0, y: 0)), try XCTUnwrap(rep.colorAt(x: 1, y: 0)))
    }

    /// 감사 V07: translated(GLSL) 이펙트 경로도 베이스 noInterpolation(flags bit0) 이면 previous 바인드
    /// (=체인 첫 이펙트 입력, 베이스 직결) 샘플이 nearest 여야 한다(구현 전 = texFilter 미배선으로
    /// 항상 선형 — 본 테스트가 RED). 플래그 없는 대조군은 선형 유지.
    func testSceneTranslatedEffectRespectsNoInterpolationFlag() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let (n0, _) = try renderTranslatedScene(flags: 0x1, tag: "tnear")
        XCTAssertLessThan(n0.redComponent, 0.1, "nearest: pixel0 = 순파랑(블렌드 없음)")
        XCTAssertGreaterThan(n0.blueComponent, 0.9)
        // 대조군(flags=0): 같은 지오메트리에서 선형 블렌드 — 필터 구분력 증명 + 무회귀.
        let (l0, _) = try renderTranslatedScene(flags: 0x0, tag: "tlin")
        XCTAssertEqual(l0.redComponent, 0.3, accuracy: 0.08, "linear: pixel0 = 0.3R+0.7B")
        XCTAssertEqual(l0.blueComponent, 0.7, accuracy: 0.08)
    }

    // MARK: 경로 ③ 파티클(감사 V07)

    /// 2×1 [빨강|파랑] 알베도의 파티클 스프라이트(사이즈 8 = 4배 확대)를 8×1 프로젝션에 렌더 → 8픽셀.
    /// pf_main 샘플러 필터 직결 — 경로 ①(무효과 베이스)와 동일 기하:
    ///   nearest = [R,R,R,R, B,B,B,B] / linear = 경계 인접 픽셀 블렌드(pixel3 = 0.625R+0.375B 등)
    /// distance 0·무속도·무페이드 단일 지점 스폰(알파 1 중첩 = 멱등)으로 결정성 확보.
    private func renderParticleScene(flags: Int, tag: String) throws -> [NSColor] {
        let scene = """
        {"general":{"orthogonalprojection":{"width":8,"height":1},"clearcolor":"0 0 0"},
         "objects":[{"id":1,"name":"pixp","particle":"particles/pixp.json","origin":"4 0.5 0","scale":"1 1 1"}]}
        """
        let particle = """
        {"emitter":[{"name":"sphererandom","origin":"0 0 0","directions":"1 0 0","distancemin":0,"distancemax":0,"rate":10}],
         "initializer":[{"name":"lifetimerandom","min":10,"max":10},{"name":"sizerandom","min":8,"max":8},
           {"name":"velocityrandom","min":"0 0 0","max":"0 0 0"},
           {"name":"colorrandom","min":"255 255 255","max":"255 255 255"}],
         "operator":[{"name":"movement","gravity":"0 0 0"}],
         "renderer":[{"name":"sprite"}],"maxcount":100,"starttime":0,"material":"materials/pixp.json"}
        """
        let material = #"{"passes":[{"shader":"genericparticle","blending":"translucent","textures":["pixp"]}]}"#
        let files: [(String, Data)] = [
            ("scene.json", scene.data(using: .utf8)!),
            ("particles/pixp.json", particle.data(using: .utf8)!),
            ("materials/pixp.json", material.data(using: .utf8)!),
            ("materials/pixp.tex", flaggedTex([255, 0, 0, 255, 0, 0, 255, 255], w: 2, h: 1, flags: flags)),
        ]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_nointerp_pt_\(tag)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
                                       title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let r = SceneRenderer()
        try r.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 1)), project: project)
        defer { r.teardown() }
        XCTAssertEqual(r.particleSystems.count, 1, "파티클 시스템이 빌드돼야 한다")
        let out = URL(fileURLWithPath: "/tmp/waple_nointerp_pt_\(tag)")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = try XCTUnwrap(r.captureFrames(width: 8, height: 1, times: [0.5], toDir: out).first)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        return try (0..<8).map { try XCTUnwrap(rep.colorAt(x: $0, y: 0)) }
    }

    /// 감사 V07: 파티클 알베도도 noInterpolation(flags bit0) 이면 pf_main 샘플이 nearest 여야 한다
    /// (구현 전 = 파티클 경로 미배선으로 항상 선형 — 본 테스트가 RED). 플래그 없는 대조군은 선형 유지.
    func testSceneParticleRespectsNoInterpolationFlag() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let n = try renderParticleScene(flags: 0x1, tag: "pnear")
        for i in 0...3 {
            XCTAssertGreaterThan(n[i].redComponent, 0.9, "nearest: pixel\(i) = 순빨강(블렌드 없음)")
            XCTAssertLessThan(n[i].blueComponent, 0.1, "nearest: pixel\(i) = 순빨강")
        }
        for i in 4...7 {
            XCTAssertLessThan(n[i].redComponent, 0.1, "nearest: pixel\(i) = 순파랑(블렌드 없음)")
            XCTAssertGreaterThan(n[i].blueComponent, 0.9, "nearest: pixel\(i) = 순파랑")
        }
        // 대조군(flags=0): 경계 인접 픽셀은 선형 블렌드 — 필터 구분력 증명 + 무회귀.
        let l = try renderParticleScene(flags: 0x0, tag: "plin")
        XCTAssertEqual(l[3].blueComponent, 0.375, accuracy: 0.08, "linear: pixel3 = 0.625R+0.375B")
        XCTAssertEqual(l[4].redComponent, 0.375, accuracy: 0.08, "linear: pixel4 = 0.375R+0.625B")
    }
}
