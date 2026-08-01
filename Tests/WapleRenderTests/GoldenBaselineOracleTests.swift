import XCTest
@testable import WapleRender

/// 커밋된 스냅샷 기준선을 읽어 오라클로 쓴다.
///
/// 지금까지 하드 오라클이 "마운트 무크래시 + PNG 존재" 뿐이라 완전히 검은 프레임도
/// 통과했다(BACKLOG F402/F403). 기준선이 커밋됐으니 그걸 기준으로 삼는다.
struct GoldenBaseline: Decodable {
    struct Entry: Decodable {
        let id: String
        let hash: String
        let meanLuma: Double
        let deterministic: Bool
        let selfMaxDiff: Int
    }
    let label: String
    let gitSHA: String
    let captureTime: Double
    let entries: [Entry]

    /// 리포 루트 기준 `spec/golden/snapshot/<label>/manifest.json`.
    static func load(label: String = "baseline-81098bb") -> GoldenBaseline? {
        // 테스트 바이너리는 .build 안에 있으므로 소스 파일 위치에서 리포 루트를 거슬러 올라간다.
        var dir = URL(fileURLWithPath: #filePath)      // Tests/WapleRenderTests/...
            .deletingLastPathComponent()                // WapleRenderTests
            .deletingLastPathComponent()                // Tests
            .deletingLastPathComponent()                // repo root
        dir = dir.appendingPathComponent("spec/golden/snapshot/\(label)/manifest.json")
        guard let data = try? Data(contentsOf: dir) else { return nil }
        return try? JSONDecoder().decode(GoldenBaseline.self, from: data)
    }

    func entry(id: String) -> Entry? { entries.first { $0.id == id } }
}

final class GoldenBaselineOracleTests: XCTestCase {

    func testBaselineIsCommittedAndLoadable() throws {
        let b = try XCTUnwrap(GoldenBaseline.load(),
                              "커밋된 기준선을 못 읽었다 — spec/golden/snapshot/ 확인")
        XCTAssertEqual(b.gitSHA, "81098bb")
        XCTAssertEqual(b.entries.count, 170)
    }

    /// 기준선 자체에 검은 프레임이 없어야 한다. 있으면 기준선이 오염된 것이다.
    func testBaselineHasNoBlackFrames() throws {
        let b = try XCTUnwrap(GoldenBaseline.load())
        let black = b.entries.filter { $0.meanLuma <= 0.0 }
        XCTAssertTrue(black.isEmpty, "기준선에 검은 프레임: \(black.map(\.id))")
    }

    /// 비결정 씬은 회귀 판정에서 제외해야 하므로, 몇 개인지 고정해 둔다.
    /// 늘어나면 렌더러에 새 비결정성이 생긴 것이다.
    func testNonDeterministicSceneCountIsPinned() throws {
        let b = try XCTUnwrap(GoldenBaseline.load())
        let nd = b.entries.filter { !$0.deterministic }.map(\.id).sorted()
        XCTAssertEqual(nd, ["3363252053"],
                       "비결정 씬 목록이 바뀌었다 — 새 비결정성이 생겼는지 확인")
    }

    func testDeterministicScenesHaveZeroSelfDiff() throws {
        let b = try XCTUnwrap(GoldenBaseline.load())
        let bad = b.entries.filter { $0.deterministic && $0.selfMaxDiff != 0 }
        XCTAssertTrue(bad.isEmpty,
                      "결정으로 표시됐는데 self-diff 가 0 이 아니다: \(bad.map(\.id))")
    }
}
