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

    /// 현행 기준선 — GT/스냅샷 판정이 이걸 기준으로 삼는다.
    /// 2026-08-16: MDLV 인덱스 폭 수정(c69f93c) 이후 release 로 뜬 것. 종전 `baseline-31fecaa`
    /// 는 그 수정 **이전**이라 u32 메시 보유 씬 2종(3589454154 陨石 / 3706286085 FBX3 스테이지)에
    /// 대해 파괴 렌더를 기준으로 삼고 있었다 — 골든 게이트를 배선하자마자 그 2종이 잡혔고,
    /// 육안 대조로 "회귀가 아니라 개선" 임을 확인한 뒤 다시 떴다.
    /// 두 캡처 **사이에 커서를 옮겨서** 뜨고 비트동일한 것을 확인해 설치했다
    /// (scripts/mac-session/rebaseline-golden.sh — 상이 0종). 중간 기준선(f3a17da·31fecaa)은
    /// HEAD 에서 지웠다 — 리포 비대를 막고, 필요하면 커밋 이력에서 꺼낸다.
    static let currentLabel = "baseline-618d16f"
    /// WE 엔진 이식 **이전**(debug 캡처)의 최초 기준선. 이력 보존용 — 판정 기준이 아니다.
    static let historicalLabel = "baseline-81098bb"

    /// 리포 루트 기준 `spec/golden/snapshot/<label>/manifest.json`.
    static func load(label: String = GoldenBaseline.currentLabel) -> GoldenBaseline? {
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
        XCTAssertEqual(b.gitSHA, "618d16f")
        XCTAssertEqual(b.entries.count, 170)
    }

    /// 이력 기준선(이식 전)도 계속 읽혀야 한다 — 지워지면 "무엇에서 무엇으로 바뀌었나" 를 잃는다.
    func testHistoricalBaselineStillLoads() throws {
        let b = try XCTUnwrap(GoldenBaseline.load(label: GoldenBaseline.historicalLabel),
                              "이식 전 기준선이 사라졌다 — 이력 대조 근거를 잃는다")
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
    ///
    /// 현행 기준선(618d16f)은 **0종**이다. 이식 전 기준선에서 유일한 비결정이던 3363252053
    /// (파티클·광원 많은 3D 씬, selfMaxDiff=189)도 지금은 자기일관 캡처가 비트동일하다.
    /// 다만 이 필드가 재는 것은 **같은 프로세스 안의 2회 캡처**뿐이라는 것을 기억할 것 —
    /// 프로세스/세션 간 재현성은 별개이고, 그건 rebaseline-golden.sh 의 커서-이동 게이트가 본다
    /// (spec/golden/nondeterminism.json → oracle.gate.selfCheckIsIntraProcess).
    func testNonDeterministicSceneCountIsPinned() throws {
        let b = try XCTUnwrap(GoldenBaseline.load())
        let nd = b.entries.filter { !$0.deterministic }.map(\.id).sorted()
        XCTAssertEqual(nd, [], "비결정 씬 목록이 바뀌었다 — 새 비결정성이 생겼는지 확인")
    }

    func testDeterministicScenesHaveZeroSelfDiff() throws {
        let b = try XCTUnwrap(GoldenBaseline.load())
        let bad = b.entries.filter { $0.deterministic && $0.selfMaxDiff != 0 }
        XCTAssertTrue(bad.isEmpty,
                      "결정으로 표시됐는데 self-diff 가 0 이 아니다: \(bad.map(\.id))")
    }
}
