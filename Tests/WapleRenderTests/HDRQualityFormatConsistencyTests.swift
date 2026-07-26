import XCTest
import AppKit
import Metal
@testable import WapleCore
@testable import WapleRender

/// P①: accPixelFormat(레이어/메시/파티클 파이프라인 어태치먼트 포맷, 품질 게이트 포함)과
/// hdrActive/pooledOffscreen 의 float 승격 판정이 단일 소스여야 한다 — quality low/medium + hdr
/// 씬에서 pipeline(bgra8Unorm)과 acc 타깃(rgba16Float)이 갈라지면 렌더 패스 어태치먼트 포맷
/// 불일치(Metal validation 활성 시 어서션, 비활성 시 미정의 출력)가 된다. 코퍼스 0/460 이 quality
/// 키를 저작하지만(잠복) 스키마는 표현 가능하므로 회귀 가드로 고정한다.
final class HDRQualityFormatConsistencyTests: XCTestCase {
    private func mount(hdr: Bool, quality: String?) throws -> SceneRenderer {
        let qualityField = quality.map { ",\"quality\":\"\($0)\"" } ?? ""
        let scene = """
        {"general":{"orthogonalprojection":{"width":64,"height":64},"clearcolor":"0 0 0",
                     "hdr":\(hdr)\(qualityField)},
         "objects":[]}
        """
        let files: [(String, Data)] = [("scene.json", Data(scene.utf8))]
        let tag = "hdrq_\(quality ?? "nil")_\(UUID().uuidString)"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("waple_\(tag)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try encodePkg(files).write(to: dir.appendingPathComponent("scene.pkg"))
        let project = WallpaperProject(
            id: tag, type: .scene, fileName: "scene.pkg", previewName: nil,
            title: tag, tags: [], contentRating: nil, workshopId: nil, dependency: nil, folderURL: dir)
        let renderer = SceneRenderer()
        try renderer.mount(in: NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)), project: project)
        return renderer
    }

    /// 핵심 불변식: acc/합성 스냅샷(pooledOffscreen(bgra:true))의 실제 텍스처 포맷이 항상
    /// accPixelFormat(파이프라인 어태치먼트 포맷 결정자)과 일치해야 한다 — 그렇지 않으면 그 텍스처를
    /// 타깃으로 그리는 모든 draw call 이 포맷 불일치가 된다.
    func testPooledOffscreenBGRAMatchesAccPixelFormatAcrossQualityTiers() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        for quality in ["low", "medium", "high", "ultra"] {
            let renderer = try mount(hdr: true, quality: quality)
            defer { renderer.teardown() }
            guard let device = renderer.device else { XCTFail("no device"); continue }
            let expected = renderer.accPixelFormat
            let acc = try XCTUnwrap(renderer.pooledOffscreen(8, 8, device, bgra: true),
                                    "quality=\(quality)")
            XCTAssertEqual(acc.pixelFormat, expected,
                "quality=\(quality): pooledOffscreen(bgra:true) 포맷이 accPixelFormat 과 갈라짐 — 파이프라인/타깃 불일치")
        }
    }

    /// hdrActive 는 accPixelFormat 이 실제로 float 를 내주는 조합에서만 true 여야 한다(P① 단일소스).
    func testHDRActiveMirrorsAccPixelFormatFloatAcrossQualityTiers() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        for quality in ["low", "medium", "high", "ultra"] {
            let renderer = try mount(hdr: true, quality: quality)
            defer { renderer.teardown() }
            XCTAssertEqual(renderer.hdrActive, renderer.accPixelFormat == .rgba16Float, "quality=\(quality)")
        }
        // quality 미저작(기본 ultra) + hdr:true 는 종전과 동일하게 float 활성(무회귀).
        let ultraDefault = try mount(hdr: true, quality: nil)
        defer { ultraDefault.teardown() }
        XCTAssertTrue(ultraDefault.hdrActive)
        XCTAssertEqual(ultraDefault.accPixelFormat, .rgba16Float)
    }

    /// quality=low/medium + hdr:true 는 float 승격 없이 bgra8Unorm 로 정합(성능 우선 의도 보존).
    func testLowMediumQualityStaysBGRA8EvenWhenHDRAuthored() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal") }
        for quality in ["low", "medium"] {
            let renderer = try mount(hdr: true, quality: quality)
            defer { renderer.teardown() }
            XCTAssertFalse(renderer.hdrActive, "quality=\(quality)")
            XCTAssertEqual(renderer.accPixelFormat, .bgra8Unorm, "quality=\(quality)")
        }
        for quality in ["high", "ultra"] {
            let renderer = try mount(hdr: true, quality: quality)
            defer { renderer.teardown() }
            XCTAssertTrue(renderer.hdrActive, "quality=\(quality)")
            XCTAssertEqual(renderer.accPixelFormat, .rgba16Float, "quality=\(quality)")
        }
    }
}
