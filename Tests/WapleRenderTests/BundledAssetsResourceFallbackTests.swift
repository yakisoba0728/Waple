import XCTest
@testable import WapleCore
@testable import WapleRender

/// 동봉 에셋이 **리소스 폴백 경로**에서도 읽히는지.
///
/// `BundledAssetsTests` 7건은 전부 `SceneRenderer.sharedAssetProbe` 만 친다. 그 경로는
/// `SceneDocument.parse(sharedAssetProbe:)` 한 곳에서만 쓰이고 — models/util JSON 같은
/// **문서 파싱**용이다. 정작 셰이더 `#include`·이펙트 GLSL·머티리얼 JSON·폰트·텍스처 폴백은
/// 전부 `SceneRendererResources.quietAssetData` / `probeAssetData` 를 타는데, 그쪽은
/// 종전에 `BaseAssetsSettings.baseAssetsDirectory`(사용자 지정 / 자동 탐지) **하나만** 보고
/// 동봉본을 후보에 넣지 않았다.
///
/// 결과: WE 미설치 머신에서 pkg 가 담지 않는 `common_*.h`(코퍼스 162개 전수 0건 동봉)가
/// 조용히 드롭돼 셰이더가 심볼 부재로 컴파일 실패했다 — 동봉한 2,940파일의 목적이 절반만
/// 달성된 상태였다. 이 파일이 그 나머지 절반을 핀한다.
final class BundledAssetsResourceFallbackTests: XCTestCase {

    private func emptyPackage() throws -> ScenePackage {
        try ScenePackage.parse(encodePkg([("scene.json", Data("{}".utf8))]))
    }

    private func makeRoot(_ files: [String: String]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple-fallback-\(UUID().uuidString)", isDirectory: true)
        for (rel, body) in files {
            let f = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: f.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(body.utf8).write(to: f)
        }
        return dir
    }

    /// 앞 루트에 없으면 뒤 루트(=동봉본 자리)로 넘어가야 한다.
    func testQuietAssetDataFallsThroughToLaterRoot() throws {
        let a = try makeRoot([:])
        let b = try makeRoot(["shaders/common.h": "// from B"])
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

        let r = SceneRenderer()
        r.assetBaseRoots = [a, b]
        let d = try XCTUnwrap(r.quietAssetData("shaders/common.h", package: try emptyPackage()),
                              "뒤 루트로 폴백하지 않았다 — 동봉본이 리소스 경로에 안 닿는 상태")
        XCTAssertEqual(String(decoding: d, as: UTF8.self), "// from B")
    }

    /// 앞 루트가 이기는 우선순위(사용자 설치본 > 동봉본)는 유지돼야 한다.
    func testEarlierRootWins() throws {
        let a = try makeRoot(["shaders/common.h": "// from A"])
        let b = try makeRoot(["shaders/common.h": "// from B"])
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

        let r = SceneRenderer()
        r.assetBaseRoots = [a, b]
        let d = try XCTUnwrap(r.quietAssetData("shaders/common.h", package: try emptyPackage()))
        XCTAssertEqual(String(decoding: d, as: UTF8.self), "// from A")
    }

    /// pkg 동봉본이 있으면 베이스 루트보다 우선(무회귀 — 씬이 자기 사본을 이긴다).
    func testPackageWinsOverBaseRoots() throws {
        let b = try makeRoot(["shaders/common.h": "// from B"])
        defer { try? FileManager.default.removeItem(at: b) }
        let pkg = try ScenePackage.parse(encodePkg([("shaders/common.h", Data("// from pkg".utf8))]))

        let r = SceneRenderer()
        r.assetBaseRoots = [b]
        let d = try XCTUnwrap(r.quietAssetData("shaders/common.h", package: pkg))
        XCTAssertEqual(String(decoding: d, as: UTF8.self), "// from pkg")
    }

    /// 경로 이탈은 **즉시 거부**다 — 다음 루트로 흘려보내면 이탈 경로가 거기서 성공할 수 있다.
    /// (`sharedAssetProbe(_:roots:)` 가 이미 못박은 규약을 이 경로도 따라야 한다.)
    func testTraversalIsRejectedNotFallenThrough() throws {
        let a = try makeRoot([:])
        let b = try makeRoot(["shaders/common.h": "// from B"])
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

        let r = SceneRenderer()
        r.assetBaseRoots = [a, b]
        XCTAssertNil(r.quietAssetData("../../etc/passwd", package: try emptyPackage()))
        XCTAssertNil(r.quietAssetData("shaders/../../../etc/passwd", package: try emptyPackage()))
    }

    /// 실배선 핀 — 동봉본만 있는 상태(사용자 설치본 미설정)에서 `common_*.h` 6종이 전부 읽혀야 한다.
    /// 이게 깨지면 WE 미설치 머신에서 셰이더가 심볼 부재로 조용히 실패한다.
    func testBundledRootAloneResolvesSharedHeadersThroughResourcePath() throws {
        let bundled = try XCTUnwrap(BaseAssetsSettings.bundledAssetsDirectory)
        let r = SceneRenderer()
        r.assetBaseRoots = [bundled]
        let pkg = try emptyPackage()
        for name in ["common.h", "common_blending.h", "common_perspective.h",
                     "common_blur.h", "common_fragment.h", "common_composite.h"] {
            let d = r.quietAssetData("shaders/\(name)", package: pkg)
            XCTAssertNotNil(d, "동봉본만으로 shaders/\(name) 를 못 읽었다")
            XCTAssertGreaterThan(d?.count ?? 0, 50, "shaders/\(name) 내용이 비었다")
        }
    }

    /// mount 가 실제로 `searchRoots`(동봉본 포함)를 심는지 — 종전엔 `baseAssetsDirectory` 만 심었다.
    func testMountSeedsAllSearchRoots() {
        XCTAssertEqual(SceneRenderer.resolvedAssetBaseRoots(), BaseAssetsSettings.searchRoots,
                       "리소스 폴백 루트가 searchRoots 와 다르다 — 동봉본이 빠졌을 수 있다")
        XCTAssertTrue(SceneRenderer.resolvedAssetBaseRoots().contains { $0 == BaseAssetsSettings.bundledAssetsDirectory },
                      "동봉본이 리소스 폴백 루트에 없다")
    }
}
