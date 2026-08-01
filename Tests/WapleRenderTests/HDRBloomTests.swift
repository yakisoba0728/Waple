import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// #22 HDR bloom(hdr && bloom) — 추출(PS 29931 soft-knee)→blur13→합성(saturate(base+bloom) =
/// PS 29925 의 화면 순효과). 부정 컨트롤: hdrPost(클램프) 단독 조기 return 은 글로우가 0 —
/// 라우팅 테스트가 그 결함을 red 로 재현.
final class HDRBloomTests: XCTestCase {
    private final class FailingHDRBloomEncoder: HDRBloomEncoding {
        func encode(
            commandBuffer: MTLCommandBuffer,
            source: MTLTexture,
            quarter: MTLTexture,
            eighth: MTLTexture,
            bloom: MTLTexture,
            destination: MTLTexture,
            parameters: HDRBloomParameters
        ) -> Bool {
            false
        }
    }

    /// P③: 피라미드에 실제로 전달되는 파라미터를 가로채는 스파이 — 값 자체(더블카운팅 유무)를
    /// 픽셀 관측이 아니라 경계에서 직접 단언하기 위함(골든 없이도 결정적).
    private final class RecordingHDRBloomPyramidEncoder: HDRBloomPyramidEncoding {
        var received: HDRBloomPyramidParameters?
        func encode(
            commandBuffer: MTLCommandBuffer,
            source: MTLTexture,
            levels: [MTLTexture],
            scratches: [MTLTexture],
            destination: MTLTexture,
            parameters: HDRBloomPyramidParameters
        ) -> Bool {
            received = parameters
            return true
        }
    }

    private func makeFloatTexture(
        device: MTLDevice,
        width: Int,
        height: Int,
        fill: Float = 0,
        spot: (x: Range<Int>, y: Range<Int>, value: Float)? = nil
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var half = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var v = fill
                if let spot, spot.x.contains(x), spot.y.contains(y) { v = spot.value }
                let i = (y * width + x) * 4
                half[i] = Float16(v); half[i + 1] = Float16(v); half[i + 2] = Float16(v)
                half[i + 3] = 1
            }
        }
        half.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: $0.baseAddress!,
                bytesPerRow: width * 8)
        }
        return texture
    }

    private func makeBGRATexture(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func read(_ texture: MTLTexture) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!,
                bytesPerRow: texture.width * 4,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0)
        }
        return bytes
    }

    /// rgba16Float(shared) 작업 버퍼 판독 — 피라미드 중간 레벨/합성물의 구조 단언용.
    private func readFloat(_ texture: MTLTexture) -> [Float] {
        var half = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        half.withUnsafeMutableBytes {
            texture.getBytes(
                $0.baseAddress!,
                bytesPerRow: texture.width * 8,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                mipmapLevel: 0)
        }
        return half.map { Float($0) }
    }

    private func encodePass(
        device: MTLDevice,
        source: MTLTexture,
        destination: MTLTexture,
        parameters: HDRBloomParameters
    ) throws {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let pass = try XCTUnwrap(HDRBloomPass(device: device))
        let quarter = try makeFloatTexture(
            device: device,
            width: max(1, source.width / 4),
            height: max(1, source.height / 4))
        let eighth = try makeFloatTexture(
            device: device,
            width: max(1, source.width / 8),
            height: max(1, source.height / 8))
        let bloom = try makeFloatTexture(
            device: device,
            width: max(1, source.width / 8),
            height: max(1, source.height / 8))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(pass.encode(
            commandBuffer: commandBuffer,
            source: source,
            quarter: quarter,
            eighth: eighth,
            bloom: bloom,
            destination: destination,
            parameters: parameters))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// 합성 = WE 순효과 saturate(base+bloom) + knee=0(feather=0) 가드: 임계 미달 균일 0.5 입력은
    /// 블룸 0, 미드톤 무변환(0.5 → 128). PS 29925 의 EOTF_sRGB 디코드는 WE sRGB-뷰 스왑체인의
    /// 하드웨어 재인코드와 상쇄되는 쌍 — 비-sRGB(bgra8) 타깃에 디코드만 이식하면 이중 감마
    /// (실측: p50 0.047 vs 골든 0.18, 클램프 역산 ≈0.20 — HDRBloomPass 합성 셰이더 주석 참조).
    func testCombineKeepsMidtonesAndZeroKneeIsSafe() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let width = 32, height = 16
        let source = try makeFloatTexture(device: device, width: width, height: height, fill: 0.5)
        let destination = try makeBGRATexture(device: device, width: width, height: height)
        try encodePass(
            device: device,
            source: source,
            destination: destination,
            parameters: HDRBloomParameters(strength: 1, threshold: 1, feather: 0, tint: SIMD3(1, 1, 1)))
        let bytes = read(destination)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 {
                XCTAssertEqual(Float(bytes[i + channel]), 0.5 * 255, accuracy: 2,
                               "pixel \(i / 4) channel \(channel)")
            }
            XCTAssertEqual(bytes[i + 3], 255)
        }
    }

    /// 임계 초과 스팟은 주변으로 글로우가 번지고(soft-knee 추출→blur13), 스팟 자신은 saturate 로 순백.
    func testBrightSpotBloomsBeyondItsFootprint() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let width = 64, height = 32
        let source = try makeFloatTexture(
            device: device,
            width: width,
            height: height,
            spot: (x: 28..<36, y: 12..<20, value: 8))
        let destination = try makeBGRATexture(device: device, width: width, height: height)
        try encodePass(
            device: device,
            source: source,
            destination: destination,
            parameters: HDRBloomParameters(strength: 1, threshold: 1, feather: 1, tint: SIMD3(1, 1, 1)))
        let bytes = read(destination)
        func maxRGB(_ x: Int, _ y: Int) -> UInt8 {
            let i = (y * width + x) * 4
            return max(bytes[i], max(bytes[i + 1], bytes[i + 2]))
        }
        XCTAssertEqual(maxRGB(32, 16), 255)              // 스팟: EOTF(>1) → saturate
        XCTAssertGreaterThan(maxRGB(16, 16), 0)          // 스팟 밖 16px: 글로우 도달
        XCTAssertGreaterThan(maxRGB(32, 4), 0)           // 세로 방향도 번짐(2-pass 분리형)
    }

    /// 격리 가드: LDR(bgra8) 소스 유입은 인코드 전 거부 — 호출부 hdrPost(클램프) 폴백 안전.
    func testRejectsNonFloatSource() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let pass = try XCTUnwrap(HDRBloomPass(device: device))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let bgra = try makeBGRATexture(device: device, width: 32, height: 16)
        let quarter = try makeFloatTexture(device: device, width: 8, height: 4)
        let eighth = try makeFloatTexture(device: device, width: 4, height: 2)
        let bloom = try makeFloatTexture(device: device, width: 4, height: 2)
        let destination = try makeBGRATexture(device: device, width: 32, height: 16)
        XCTAssertFalse(pass.encode(
            commandBuffer: commandBuffer,
            source: bgra,
            quarter: quarter,
            eighth: eighth,
            bloom: bloom,
            destination: destination,
            parameters: .defaults))
        commandBuffer.commit()
    }

    // MARK: finalizeScene 라우팅

    private func finalize(
        device: MTLDevice,
        configure: (SceneRenderer) -> Void,
        sourceSpot value: Float = 8
    ) throws -> [UInt8] {
        let width = 64, height = 32
        let source = try makeFloatTexture(
            device: device,
            width: width,
            height: height,
            spot: (x: 28..<36, y: 12..<20, value: value))
        let destination = try makeBGRATexture(device: device, width: width, height: height)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let renderer = SceneRenderer()
        renderer.sceneIsHDR = true
        renderer.hdrPost = HDRPostPass(device: device, outputFormat: .bgra8Unorm)
        configure(renderer)
        XCTAssertTrue(renderer.finalizeScene(
            source: source,
            destination: destination,
            commandBuffer: commandBuffer,
            device: device))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return read(destination)
    }

    /// ★부정 컨트롤(보고된 결함 재현): hdr&&bloom 씬이 hdrPost 조기 return 에 삼켜지면
    /// 스팟 밖 전 픽셀이 0(saturate(0)=0) — HDR bloom 라우팅이 있어야 글로우 > 0.
    func testFinalizeRoutesHDRBloomAndSpreadsGlow() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let bytes = try finalize(device: device, configure: { renderer in
            renderer.sceneWantsHDRBloom = true
            renderer.hdrBloomPass = HDRBloomPass(device: device)
            renderer.hdrBloomParameters = HDRBloomParameters(
                strength: 1, threshold: 1, feather: 1, tint: SIMD3(1, 1, 1))
        })
        // 스팟(28..36, 12..20) 밖 픽셀들의 RGB 합 — hdrPost 단독(클램프) 경로면 정확히 0.
        var outsideSum = 0
        for y in 0..<32 {
            for x in 0..<64 where !(28..<36 ~= x && 12..<20 ~= y) {
                let i = (y * 64 + x) * 4
                outsideSum += Int(bytes[i]) + Int(bytes[i + 1]) + Int(bytes[i + 2])
            }
        }
        XCTAssertGreaterThan(outsideSum, 0, "hdr&&bloom 씬에 글로우가 전혀 없음(=hdrPost 조기 return)")
    }

    /// hdr && !bloom 무회귀: HDR bloom 미요청이면 hdrPost(클램프) 출력과 바이트 동일.
    func testFinalizeWithoutBloomRequestKeepsHDRPostByteIdentical() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let expected = try hdrPostReference(device: device)
        let bytes = try finalize(device: device, configure: { _ in })
        XCTAssertEqual(bytes, expected)
    }

    /// 패스 생성 실패/인코드 실패 시 hdrPost(클램프) 폴백(무크래시·바이트 동일).
    func testFinalizeFallsBackToHDRPostWhenBloomUnavailableOrFailing() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let expected = try hdrPostReference(device: device)
        let missing = try finalize(device: device, configure: { renderer in
            renderer.sceneWantsHDRBloom = true
            renderer.hdrBloomPass = nil
        })
        XCTAssertEqual(missing, expected)
        let failing = try finalize(device: device, configure: { renderer in
            renderer.sceneWantsHDRBloom = true
            renderer.hdrBloomPass = FailingHDRBloomEncoder()
        })
        XCTAssertEqual(failing, expected)
    }

    /// P③: 피라미드가 받는 strength 는 raw 저작값(단일레벨 hdrBloomParameters.strength 의
    /// ×max(1,iterations) 보정과 무관)이어야 하고, scatter/levels 는 하드코딩 1.619/8 이 아니라
    /// 저작 bloomhdrscatter/bloomhdriterations 그대로여야 한다 — 픽셀이 아니라 경계값 직접 단언
    /// (골든 없이 결정적, 이중보정 회귀를 확실히 잡음).
    func testFinalizeFeedsPyramidRawStrengthAndAuthoredScatterLevelsNotInflatedSingleLevelValue() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let spy = RecordingHDRBloomPyramidEncoder()
        _ = try finalize(device: device, configure: { renderer in
            renderer.sceneWantsHDRBloom = true
            renderer.hdrBloomPyramidPass = spy
            // 단일레벨 hdrBloomParameters.strength 는 저작값(2) × iterations(8) × strengthScale(1) = 16 처럼
            // 의도적으로 이미 부풀려진 값을 넣어둔다 — 피라미드가 이 값을 재사용하면(이중보정) 테스트가 잡는다.
            renderer.hdrBloomParameters = HDRBloomParameters(strength: 16, threshold: 0.5, feather: 0.2, tint: SIMD3(1, 1, 1))
            renderer.hdrBloomPyramidStrength = 2       // raw 저작 bloomhdrstrength
            renderer.hdrBloomPyramidScatter = 2.5       // raw 저작 bloomhdrscatter(≠ 하드코딩 1.619)
            renderer.hdrBloomPyramidLevels = 4          // raw 저작 bloomhdriterations(≠ 하드코딩 8)
        })
        let received = try XCTUnwrap(spy.received, "피라미드 인코더가 호출되지 않음")
        XCTAssertEqual(received.strength, 2, "피라미드 strength 는 raw 저작값이어야(단일레벨용 ×iterations 보정 재사용 금지)")
        XCTAssertEqual(received.scatter, 2.5, "피라미드 scatter 는 저작 bloomhdrscatter 여야(하드코딩 1.619 금지)")
        XCTAssertEqual(received.levels, 4, "피라미드 levels 는 저작 bloomhdriterations 여야(하드코딩 8 금지)")
        // threshold/feather/tint 는 여전히 단일레벨 hdrBloomParameters 공유(스코프 밖 — 무변경 확인).
        XCTAssertEqual(received.threshold, 0.5)
        XCTAssertEqual(received.feather, 0.2)
    }

    /// P③ 배선 확인: mount() 가 doc.bloomHDRStrength/Scatter/Iterations 를 피라미드용 raw 필드에
    /// 그대로 옮기고, 단일레벨 hdrBloomParameters.strength 는 종전대로 ×max(1,iterations) 보정을
    /// 유지해야 한다(피라미드 실패 폴백 경로 무회귀).
    func testMountWiresAuthoredBloomHDRFieldsToPyramidRawStorage() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0",
          "hdr":true,"bloom":true,"bloomhdrstrength":1.4,"bloomhdrthreshold":0.7,
          "bloomhdrfeather":0.25,"bloomhdriterations":6,"bloomhdrscatter":2.0},"objects":[]}
        """
        let files: [(String, Data)] = [("scene.json", Data(scene.utf8))]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple_p3_wire_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: "p3wire", type: .scene, fileName: "scene.pkg", previewName: nil,
            title: "p3wire", tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        defer { renderer.teardown() }
        XCTAssertEqual(renderer.hdrBloomPyramidStrength, 1.4, accuracy: 1e-4, "피라미드 raw strength = 저작 bloomhdrstrength(×iterations 미적용)")
        XCTAssertEqual(renderer.hdrBloomPyramidScatter, 2.0, accuracy: 1e-4, "피라미드 scatter = 저작 bloomhdrscatter")
        XCTAssertEqual(renderer.hdrBloomPyramidLevels, 6, "피라미드 levels = 저작 bloomhdriterations")
        // 단일레벨 폴백용 hdrBloomParameters.strength 는 종전 규약(×max(1,iterations)×strengthScale) 유지 — 무회귀.
        XCTAssertEqual(renderer.hdrBloomParameters.strength, 1.4 * 6 * HDRBloomPass.strengthScale, accuracy: 1e-4)
    }

    private func hdrPostReference(device: MTLDevice) throws -> [UInt8] {
        let width = 64, height = 32
        let source = try makeFloatTexture(
            device: device,
            width: width,
            height: height,
            spot: (x: 28..<36, y: 12..<20, value: 8))
        let destination = try makeBGRATexture(device: device, width: width, height: height)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let post = try XCTUnwrap(HDRPostPass(device: device, outputFormat: .bgra8Unorm))
        post.encode(cb: commandBuffer, src: source, dst: destination)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return read(destination)
    }

    /// 레벨 수 산출 — min(요청, **1/2** 부터 1×1 까지 halving 수). Metal 불필요(순수 함수).
    /// 2026-08-02 WE 구조 교체: WE 는 매 단계 절반이라 레벨 0 이 1/2 다(종전 1/4 시작).
    func testLevelCountClampsToAvailableMips() throws {
        XCTAssertEqual(HDRBloomPyramidPass.levelCount(requested: 8, sourceWidth: 2048, sourceHeight: 1024), 8)
        // 512×512: half 256×256 → 128/…/1 = 9단 가능, 요청 8 로 클램프.
        XCTAssertEqual(HDRBloomPyramidPass.levelCount(requested: 8, sourceWidth: 512, sourceHeight: 512), 8)
        // 64×32: half 32×16 → 16×8/8×4/4×2/2×1/1×1 — 6단으로 클램프.
        XCTAssertEqual(HDRBloomPyramidPass.levelCount(requested: 8, sourceWidth: 64, sourceHeight: 32), 6)
        XCTAssertEqual(HDRBloomPyramidPass.levelCount(requested: 3, sourceWidth: 512, sourceHeight: 512), 3)
        // 4×4: half 2×2 → 1×1 = 2단(인코드 n≥2 최소치를 정확히 만족).
        XCTAssertEqual(HDRBloomPyramidPass.levelCount(requested: 8, sourceWidth: 4, sourceHeight: 4), 2)
    }

    /// 8-레벨 피라미드가 실제 생성·합성된다 — 다운체인(최심층 레벨에 스팟 에너지 도달)
    /// + 업체인(합성물 S[0] 의 스팟 반대 코너가 0 초과). 2026-08-02 이후 가우시안 패스가 없으므로
    /// 코너 도달은 **오직 심층 레벨 기여**로만 설명된다 — 구조 단언이 더 강해졌다.
    func testEightLevelPyramidReachesDeepestLevelAndFarCorner() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let width = 512, height = 512
        let levelCount = HDRBloomPyramidPass.levelCount(
            requested: 8, sourceWidth: width, sourceHeight: height)
        XCTAssertEqual(levelCount, 8)
        let source = try makeFloatTexture(
            device: device, width: width, height: height,
            spot: (x: 248..<264, y: 248..<264, value: 8))
        let destination = try makeBGRATexture(device: device, width: width, height: height)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let pass = try XCTUnwrap(HDRBloomPyramidPass(device: device))
        var levels: [MTLTexture] = []
        var scratches: [MTLTexture] = []
        for i in 0..<levelCount {
            let w = max(1, width >> (1 + i)), h = max(1, height >> (1 + i))
            levels.append(try makeFloatTexture(device: device, width: w, height: h))
            scratches.append(try makeFloatTexture(device: device, width: w, height: h))
        }
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(pass.encode(
            commandBuffer: commandBuffer,
            source: source,
            levels: levels,
            scratches: scratches,
            destination: destination,
            parameters: HDRBloomPyramidParameters(
                strength: 2, threshold: 1, feather: 0.1, tint: SIMD3(1, 1, 1), scatter: 1.619)))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        // 다운체인: 최심층(8번째 = 512>>8 = 2×2)이 비어있지 않다.
        let deepest = readFloat(levels[7])
        XCTAssertEqual(levels[7].width, 2)
        XCTAssertEqual(levels[7].height, 2)
        XCTAssertGreaterThan(max(deepest[0], max(deepest[1], deepest[2])), 0,
                             "최심층 1×1 레벨까지 스팟이 도달하지 못함")
        // 업체인: 합성물(S[0], float)의 스팟 반대 코너 — 심층 레벨 기여분이 0 초과.
        let composite = readFloat(scratches[0])
        XCTAssertGreaterThan(max(composite[0], max(composite[1], composite[2])), 0,
                             "8-레벨 헤일로가 합성 코너에 도달하지 못함(심층 레벨 미합성)")
        // 스팟 자신은 saturate 순백.
        let px = read(destination)
        let center = (256 * width + 256) * 4
        XCTAssertEqual(max(px[center], max(px[center + 1], px[center + 2])), 255)
    }

    /// 소스가 작으면 허용 mip 수(64×32 → 6단)로 클램프된 피라미드가 생성·합성되고,
    /// 단일 레벨보다 넓은 글로우를 만든다(기존 3-레벨 테스트의 8-레벨 갱신판).
    func testPyramidClampsLevelsForSmallSource() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal") }
        let width = 64, height = 32
        let levelCount = HDRBloomPyramidPass.levelCount(
            requested: 8, sourceWidth: width, sourceHeight: height)
        XCTAssertEqual(levelCount, 6)
        let source = try makeFloatTexture(
            device: device, width: width, height: height,
            spot: (x: 28..<36, y: 12..<20, value: 8))
        let destination = try makeBGRATexture(device: device, width: width, height: height)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let pass = try XCTUnwrap(HDRBloomPyramidPass(device: device))
        var levels: [MTLTexture] = []
        var scratches: [MTLTexture] = []
        for i in 0..<levelCount {
            let w = max(1, width >> (1 + i)), h = max(1, height >> (1 + i))
            levels.append(try makeFloatTexture(device: device, width: w, height: h))
            scratches.append(try makeFloatTexture(device: device, width: w, height: h))
        }
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(pass.encode(
            commandBuffer: commandBuffer,
            source: source,
            levels: levels,
            scratches: scratches,
            destination: destination,
            parameters: HDRBloomPyramidParameters(
                strength: 2, threshold: 1, feather: 0.1, tint: SIMD3(1, 1, 1), scatter: 1.619)))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let px = read(destination)
        // 클램프된 피라미드(최심층 1×1)의 전 화면 헤일로 — 0이 아닌 픽셀이 넓게 존재.
        var nonZero = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            if px[i] > 0 || px[i + 1] > 0 || px[i + 2] > 0 { nonZero += 1 }
        }
        XCTAssertGreaterThan(nonZero, 64, "클램프된 피라미드 글로우가 너무 좁음")
    }
}
