import XCTest
@testable import Waple
import WapleCore

/// AppDelegate 에서 추출해 실제로 호출하는 순수 결정 로직(AppLogic) 검증.
/// executable 타깃 Waple 을 @testable import 로 직접 테스트한다(내부 타입 접근).
final class AppLogicTests: XCTestCase {

    private func project(_ id: String) -> WallpaperProject {
        WallpaperProject(id: id, type: .scene, fileName: nil, previewName: nil,
                         title: id, tags: [], contentRating: nil, workshopId: nil,
                         dependency: nil, folderURL: URL(fileURLWithPath: "/tmp/\(id)"))
    }

    // MARK: - MonitorMapping.assignedFolder

    func testAssignedFolder_noAssignment_returnsNil() {
        let f = MonitorMapping.assignedFolder(
            screenKey: "s1",
            assignment: { _ in nil },
            folderForEntry: { _ in URL(fileURLWithPath: "/x") })
        XCTAssertNil(f, "할당 없음 → nil(전역 사용)")
    }

    func testAssignedFolder_assignedButUnresolvable_returnsNil() {
        let f = MonitorMapping.assignedFolder(
            screenKey: "s1",
            assignment: { _ in "entryA" },
            folderForEntry: { _ in nil })   // 엔트리 폴더 해석 실패
        XCTAssertNil(f, "엔트리 폴더 미해석 → nil(전역 폴백)")
    }

    func testAssignedFolder_resolvesToFolder() {
        let target = URL(fileURLWithPath: "/lib/entryA")
        let f = MonitorMapping.assignedFolder(
            screenKey: "s1",
            assignment: { $0 == "s1" ? "entryA" : nil },
            folderForEntry: { $0 == "entryA" ? target : nil })
        XCTAssertEqual(f, target)
    }

    // MARK: - MonitorMapping.resolveProjects

    func testResolveProjects_unassignedUsesGlobal() {
        let global = project("global")
        let out = MonitorMapping.resolveProjects(
            screenKeys: ["s1", "s2"],
            global: global,
            assignedFolder: { _ in nil },
            parse: { _ in nil })
        XCTAssertEqual(out, [global, global], "모든 화면 미할당 → 전역")
    }

    func testResolveProjects_assignedUsesParsedProject() {
        let global = project("global")
        let folderA = URL(fileURLWithPath: "/lib/A")
        let out = MonitorMapping.resolveProjects(
            screenKeys: ["s1", "s2"],
            global: global,
            assignedFolder: { $0 == "s1" ? folderA : nil },
            parse: { $0 == folderA ? self.project("A") : nil })
        XCTAssertEqual(out, [project("A"), global])
    }

    func testResolveProjects_parseFailureFallsBackToGlobal() {
        let global = project("global")
        let out = MonitorMapping.resolveProjects(
            screenKeys: ["s1"],
            global: global,
            assignedFolder: { _ in URL(fileURLWithPath: "/lib/broken") },
            parse: { _ in nil })   // 파스 실패
        XCTAssertEqual(out, [global], "파스 실패 → 전역 폴백")
    }

    func testResolveProjects_parsesFolderOnlyOnce() {
        // 두 화면이 같은 할당 폴더 → parse 는 폴더당 1회만(캐시).
        let folderA = URL(fileURLWithPath: "/lib/A")
        var parseCount = 0
        let out = MonitorMapping.resolveProjects(
            screenKeys: ["s1", "s2", "s3"],
            global: project("global"),
            assignedFolder: { $0 == "s3" ? nil : folderA },  // s1,s2 → A, s3 → 전역
            parse: { _ in parseCount += 1; return self.project("A") })
        XCTAssertEqual(out, [project("A"), project("A"), project("global")])
        XCTAssertEqual(parseCount, 1, "동일 폴더는 1회만 파스(캐시)")
    }

    // MARK: - RendererSwap.apply (마운트 실패 롤백 규약)

    private final class Tok { let id: String; init(_ id: String) { self.id = id } }
    private struct MountError: Error {}

    func testRendererSwap_allSucceed_swapsAndTearsDownExisting() {
        var tornDown: [String] = []
        let existing = [Tok("old1"), Tok("old2")]
        let result = RendererSwap.apply(
            screens: ["a", "b", "c"],
            existing: existing,
            makeAndMount: { Tok("new-\($0)") },
            teardown: { tornDown.append($0.id) })

        guard case .success(let made) = result else { return XCTFail("전부 성공 시 .success") }
        XCTAssertEqual(made.map { $0.id }, ["new-a", "new-b", "new-c"])
        XCTAssertEqual(tornDown.sorted(), ["old1", "old2"], "성공 시 이전 렌더러만 정리")
    }

    func testRendererSwap_mountThrows_rollsBackNewKeepsExisting() {
        var tornDown: [String] = []
        let existing = [Tok("old1")]
        let result = RendererSwap.apply(
            screens: ["a", "b", "c"],
            existing: existing,
            makeAndMount: { s -> Tok? in
                if s == "b" { throw MountError() }
                return Tok("new-\(s)")
            },
            teardown: { tornDown.append($0.id) })

        guard case .failure = result else { return XCTFail("mount throw 시 .failure") }
        XCTAssertEqual(tornDown, ["new-a"], "실패 시 지금까지 만든 새 렌더러만 정리")
        XCTAssertFalse(tornDown.contains("old1"), "이전 렌더러는 유지(롤백)")
    }

    func testRendererSwap_nilMountIsSkippedNotFailure() {
        var mountCalls = 0
        let result = RendererSwap.apply(
            screens: ["a", "skip", "c"],
            existing: [Tok](),
            makeAndMount: { s -> Tok? in
                mountCalls += 1
                return s == "skip" ? nil : Tok(s)   // 지원 안 함 → 스킵
            },
            teardown: { _ in })

        guard case .success(let made) = result else { return XCTFail("nil 은 스킵, 실패 아님") }
        XCTAssertEqual(made.map { $0.id }, ["a", "c"], "nil 화면은 제외")
        XCTAssertEqual(mountCalls, 3)
    }

    // MARK: - PlaylistScheduling

    func testShouldRun() {
        XCTAssertFalse(PlaylistScheduling.shouldRun(enabled: false, ids: []))
        XCTAssertFalse(PlaylistScheduling.shouldRun(enabled: true, ids: []), "빈 목록 → 정지")
        XCTAssertFalse(PlaylistScheduling.shouldRun(enabled: false, ids: ["a"]), "비활성 → 정지")
        XCTAssertTrue(PlaylistScheduling.shouldRun(enabled: true, ids: ["a"]))
    }

    func testIntervalSeconds() {
        XCTAssertEqual(PlaylistScheduling.intervalSeconds(minutes: 5), 300)
        XCTAssertEqual(PlaylistScheduling.intervalSeconds(minutes: 30), 1800)
        XCTAssertEqual(PlaylistScheduling.intervalSeconds(minutes: 0), 60, "최소 1분 하한")
    }

    func testNextApplicableId() {
        // 다음 후보가 실제 존재하는 엔트리면 반환.
        XCTAssertEqual(
            PlaylistScheduling.nextApplicableId(after: "a", next: { _ in "b" }, entryExists: { $0 == "b" }),
            "b")
        // 순환 후보 없음(빈 목록) → nil.
        XCTAssertNil(
            PlaylistScheduling.nextApplicableId(after: "a", next: { _ in nil }, entryExists: { _ in true }))
        // 후보가 삭제된 엔트리(존재 안 함) → nil.
        XCTAssertNil(
            PlaylistScheduling.nextApplicableId(after: "a", next: { _ in "gone" }, entryExists: { _ in false }))
    }

    // MARK: - PropertyControl.sliderRange (뒤집힌/축퇴 경계에서도 ClosedRange 트랩 금지)

    func testSliderRange_invertedBounds_valid() {
        // min>max (제3자 워크샵 콘텐츠) → 종전 (min…max) 는 ClosedRange 트랩(속성 시트 열 때 앱 크래시).
        let r = PropertyControl.sliderRange(min: 5, max: 2)
        XCTAssertLessThanOrEqual(r.lowerBound, r.upperBound)
        XCTAssertEqual(r.lowerBound, 5)
    }

    func testSliderRange_degenerateAndNegative_valid() {
        let eq = PropertyControl.sliderRange(min: 0, max: 0)       // 축퇴(0폭) → NaN 썸 회피
        XCTAssertLessThan(eq.lowerBound, eq.upperBound)
        let neg = PropertyControl.sliderRange(min: nil, max: -1)   // 0…(-1) → 종전 트랩
        XCTAssertLessThanOrEqual(neg.lowerBound, neg.upperBound)
    }

    func testSliderRange_normalBounds_preserved() {
        let r = PropertyControl.sliderRange(min: 0, max: 1)        // 정상 경계는 그대로
        XCTAssertEqual(r.lowerBound, 0)
        XCTAssertEqual(r.upperBound, 1)
    }
}
