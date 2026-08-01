import XCTest
@testable import WapleRender

/// 동봉된 WE 공유 에셋이 실제로 번들에서 읽히는지. 이게 안 되면 76MB 를 넣은 의미가 없다.
final class BundledAssetsTests: XCTestCase {

    func testBundledAssetsDirectoryExists() {
        let dir = BaseAssetsSettings.bundledAssetsDirectory
        XCTAssertNotNil(dir, "동봉 에셋 디렉터리를 번들에서 못 찾았다 — Package.swift 리소스 선언 확인")
    }

    func testBundledPackIsValid() throws {
        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        XCTAssertTrue(BaseAssetsSettings.isValidBaseAssetsPack(dir),
                      "동봉본이 유효한 팩이 아니다(shaders/common.h + materials/ 필요)")
    }

    /// 워크샵 pkg 는 common_*.h 를 하나도 담지 않는다(코퍼스 162개 전수 0건).
    /// 그래서 이 6종이 동봉본에 반드시 있어야 한다.
    func testSharedHeadersArePresent() throws {
        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        for name in ["common.h", "common_blending.h", "common_perspective.h",
                     "common_blur.h", "common_fragment.h", "common_composite.h",
                     "common_vertex.h"] {
            let url = dir.appendingPathComponent("shaders/\(name)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "누락: shaders/\(name)")
        }
    }

    func testSearchRootsPutsBundledLast() {
        let roots = BaseAssetsSettings.searchRoots
        XCTAssertFalse(roots.isEmpty, "검색 루트가 비었다")
        XCTAssertEqual(roots.last, BaseAssetsSettings.bundledAssetsDirectory,
                       "동봉본은 마지막 폴백이어야 한다 — 사용자 설치본이 항상 우선")
    }

    /// 동봉본만으로 공유 에셋이 해석돼야 한다(사용자 설치본 없이).
    func testProbeResolvesFromBundleAlone() throws {
        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        let r = SceneRenderer.sharedAssetProbe("shaders/common.h", roots: [dir])
        guard case .data(let d) = r else {
            return XCTFail("동봉본에서 common.h 를 못 읽었다: \(r)")
        }
        XCTAssertGreaterThan(d.count, 100)
    }

    /// 경로 이탈은 다음 루트로 흘러가면 안 된다 — 보안 판정이지 미스가 아니다.
    func testTraversalIsRejectedNotFallenThrough() throws {
        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        let r = SceneRenderer.sharedAssetProbe("../../../etc/passwd", roots: [dir, dir])
        guard case .rejected = r else {
            return XCTFail("경로 이탈이 거부되지 않았다: \(r)")
        }
    }

    /// 앞 루트에 없으면 뒤 루트로 넘어가야 한다.
    func testFallsThroughToLaterRoot() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("waple-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let dir = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        let r = SceneRenderer.sharedAssetProbe("shaders/common.h", roots: [empty, dir])
        guard case .data = r else {
            return XCTFail("뒤 루트로 폴백하지 않았다: \(r)")
        }
    }
}
