import XCTest
@testable import Waple
import WapleCore
import WaplePolicy

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

    func testRendererSwap_nilMountFailsAndKeepsExisting() {
        var mountCalls = 0
        var tornDown: [String] = []
        let existing = [Tok("old1")]
        let result = RendererSwap.apply(
            screens: ["a", "skip", "c"],
            existing: existing,
            makeAndMount: { s -> Tok? in
                mountCalls += 1
                return s == "skip" ? nil : Tok(s)
            },
            teardown: { tornDown.append($0.id) })

        guard case .failure = result else { return XCTFail("nil renderer는 성공으로 취급하면 안 됨") }
        XCTAssertEqual(mountCalls, 2)
        XCTAssertEqual(tornDown, ["a"], "nil 발생 전 만든 새 렌더러만 정리")
        XCTAssertFalse(tornDown.contains("old1"), "이전 렌더러는 유지")
    }

    func testVideoPreparationBatchDeduplicatesAndBecomesReadyOnlyAfterEverySource() {
        let a = URL(fileURLWithPath: "/wallpapers/a.webm")
        let b = URL(fileURLWithPath: "/wallpapers/b.mkv")
        let convertedA = URL(fileURLWithPath: "/cache/a.mp4")
        let convertedB = URL(fileURLWithPath: "/cache/b.mp4")
        var batch = VideoPreparationBatch(sources: [a, a, b])

        XCTAssertEqual(batch.sources, [a, b], "같은 소스를 표시하는 모니터가 여럿이어도 변환은 한 번")
        guard case .pending = batch.record(source: a, output: convertedA) else {
            return XCTFail("일부만 준비된 상태는 commit 가능하면 안 됨")
        }
        guard case .ready(let outputs) = batch.record(source: b, output: convertedB) else {
            return XCTFail("모든 고유 소스 성공 후 ready")
        }
        XCTAssertEqual(outputs, [a: convertedA, b: convertedB])
    }

    func testVideoPreparationBatchFailsImmediatelyWhenAnyConversionFails() {
        let a = URL(fileURLWithPath: "/wallpapers/a.webm")
        let b = URL(fileURLWithPath: "/wallpapers/b.mkv")
        var batch = VideoPreparationBatch(sources: [a, b])

        guard case .failed(let source) = batch.record(source: a, output: nil) else {
            return XCTFail("nil 변환 결과는 배치 전체 실패")
        }
        XCTAssertEqual(source, a)
    }

    func testVideoPreparationBatchIgnoresUnknownAndDuplicateCallbacks() {
        let a = URL(fileURLWithPath: "/wallpapers/a.webm")
        let b = URL(fileURLWithPath: "/wallpapers/b.mkv")
        let unknown = URL(fileURLWithPath: "/wallpapers/stale.webm")
        let convertedA = URL(fileURLWithPath: "/cache/a.mp4")
        let convertedB = URL(fileURLWithPath: "/cache/b.mp4")
        var batch = VideoPreparationBatch(sources: [a, b])

        guard case .ignored = batch.record(source: unknown, output: convertedA) else {
            return XCTFail("현재 배치에 없는 stale callback은 상태 갱신으로 취급하면 안 됨")
        }
        guard case .pending = batch.record(source: a, output: convertedA) else {
            return XCTFail("첫 번째 등록 소스는 정상적으로 pending을 줄여야 함")
        }
        guard case .ignored = batch.record(source: a, output: convertedA) else {
            return XCTFail("이미 소비한 callback은 중복 상태 갱신으로 취급하면 안 됨")
        }
        guard case .ready(let outputs) = batch.record(source: b, output: convertedB) else {
            return XCTFail("stale/duplicate callback 뒤에도 남은 실제 소스가 배치를 완료해야 함")
        }
        XCTAssertEqual(outputs, [a: convertedA, b: convertedB])
    }

    func testVideoPreparationBatchAccumulatesOutputsAcrossReinterpretation() {
        let a = URL(fileURLWithPath: "/wallpapers/a.webm")
        let b = URL(fileURLWithPath: "/wallpapers/b.mkv")
        let oldA = URL(fileURLWithPath: "/cache/a-old.mp4")
        let newA = URL(fileURLWithPath: "/cache/a-new.mp4")
        let convertedB = URL(fileURLWithPath: "/cache/b.mp4")

        let accumulated = VideoPreparationBatch.accumulated(
            existing: [a: oldA], newlyPrepared: [a: newA, b: convertedB])

        XCTAssertEqual(accumulated, [a: newA, b: convertedB],
                       "앞 배치 A를 잃으면 A/B를 번갈아 재변환하는 ping-pong이 된다")
    }

    func testResolveProjectSlotsAllowsGlobalLessMonitorAssignments() {
        let folderA = URL(fileURLWithPath: "/lib/A")
        let out = MonitorMapping.resolveProjectSlots(
            screenKeys: ["s1", "s2"],
            global: nil,
            assignedFolder: { $0 == "s1" ? folderA : nil },
            parse: { $0 == folderA ? self.project("A") : nil })

        XCTAssertEqual(out, [project("A"), nil], "assigned screens can mount without a global wallpaper")
    }

    func testResolveProjectSlotsFallsBackToGlobalForUnassignedScreens() {
        let global = project("global")
        let folderA = URL(fileURLWithPath: "/lib/A")
        let out = MonitorMapping.resolveProjectSlots(
            screenKeys: ["s1", "s2"],
            global: global,
            assignedFolder: { $0 == "s1" ? folderA : nil },
            parse: { $0 == folderA ? self.project("A") : nil })

        XCTAssertEqual(out, [project("A"), global])
    }

    func testPresetResolverUsesDependencyProjectFromLibrary() {
        let preset = WallpaperProject(
            id: "preset1", type: .preset, fileName: nil, previewName: "preset.jpg",
            title: "Preset Title", tags: ["Relax"], contentRating: nil, workshopId: nil,
            dependency: "dep1", folderURL: URL(fileURLWithPath: "/lib/preset1", isDirectory: true),
            presetOverrides: ["amount": .number(0.75), "enabled": .bool(true)])
        let depFolder = URL(fileURLWithPath: "/lib/dep1", isDirectory: true)
        let resolved = PresetResolver.resolve(
            project: preset,
            originalFolder: preset.folderURL,
            dependencyFolder: { $0 == "dep1" ? depFolder : nil },
            parse: { folder in
                folder == depFolder
                ? WallpaperProject(id: "dep1", type: .scene, fileName: "scene.json", previewName: "dep.jpg",
                                   title: "Dep", tags: [], contentRating: nil, workshopId: nil,
                                   dependency: nil, folderURL: folder)
                : nil
            })

        guard let project = resolved else { return XCTFail("preset should resolve through dependency") }
        XCTAssertEqual(project.id, "preset1")
        XCTAssertEqual(project.type, .scene)
        XCTAssertEqual(project.fileName, "scene.json")
        XCTAssertEqual(project.previewName, "preset.jpg")
        XCTAssertEqual(project.folderURL, depFolder)
        XCTAssertEqual(project.dependency, "dep1")
        XCTAssertEqual(project.presetFolderURL, preset.folderURL)
        XCTAssertEqual(project.presetOverrides["amount"], .number(0.75))
        XCTAssertEqual(project.presetOverrides["enabled"], .bool(true))
    }

    func testPresetResolverFallsBackToSiblingDependencyFolder() {
        let presetFolder = URL(fileURLWithPath: "/wallpapers/preset1", isDirectory: true)
        let sibling = URL(fileURLWithPath: "/wallpapers/dep1", isDirectory: true)
        let preset = WallpaperProject(
            id: "preset1", type: .preset, fileName: nil, previewName: nil,
            title: "Preset", tags: [], contentRating: nil, workshopId: nil,
            dependency: "dep1", folderURL: presetFolder)

        let resolved = PresetResolver.resolve(
            project: preset,
            originalFolder: presetFolder,
            dependencyFolder: { _ in nil },
            parse: { folder in
                folder == sibling
                ? WallpaperProject(id: "dep1", type: .web, fileName: "index.html", previewName: nil,
                                   title: "Dep", tags: [], contentRating: nil, workshopId: nil,
                                   dependency: nil, folderURL: folder)
                : nil
            })

        XCTAssertEqual(resolved?.type, .web)
        XCTAssertEqual(resolved?.folderURL, sibling)
    }

    func testPresetResolverRejectsUnsafeSiblingDependencyPath() {
        let presetFolder = URL(fileURLWithPath: "/wallpapers/preset1", isDirectory: true)
        let outside = URL(fileURLWithPath: "/outside", isDirectory: true)
        let preset = WallpaperProject(
            id: "preset1", type: .preset, fileName: nil, previewName: nil,
            title: "Preset", tags: [], contentRating: nil, workshopId: nil,
            dependency: "../outside", folderURL: presetFolder)

        let resolved = PresetResolver.resolve(
            project: preset,
            originalFolder: presetFolder,
            dependencyFolder: { _ in nil },
            parse: { folder in
                folder.standardizedFileURL == outside
                ? WallpaperProject(id: "outside", type: .web, fileName: "index.html", previewName: nil,
                                   title: "Outside", tags: [], contentRating: nil, workshopId: nil,
                                   dependency: nil, folderURL: folder)
                : nil
            })

        XCTAssertNil(resolved)
    }

    /// F036/F035 관련: 감시 대상 performScreensChanged()(private, AppDelegate.swift:449)는 테스트에서
    /// 직접 호출할 수 없으므로, 이 테스트는 그 안전망이 의존하는 RendererSwap.apply 의 롤백 의미론만
    /// 잠근다 — 살아있는 existing 을 그대로 넘겼을 때 mount 실패 시 기존 렌더러가 생존함. 호출부 배선
    /// (선-소거 없이 renderers 를 그대로 넘기는지)은 미검증 — 종전 선-소거는 그 안전망이 빈 배열을 붙잡아
    /// 무력화됐다(재적용 실패 시 화면 전체가 배경 없이 남음). 아래는 실제 screensChanged 가 호출하는
    /// 것과 동일한 RendererSwap.apply 를, 화면 하나의 마운트가 실패하는 상황으로 재현한다(의미론 잠금 — 동일
    /// 의미론은 위 :107-141 에서도 고정).
    func testScreensChangedReapply_mountFailure_keepsExistingRenderersAlive() {
        var tornDown: [String] = []
        let existing = [Tok("old1"), Tok("old2")]

        // 수정된 screensChanged 흐름: 선-소거 없이 곧바로 RendererSwap.apply(existing: renderers, ...).
        let result = RendererSwap.apply(
            screens: ["s1", "s2"],
            existing: existing,
            makeAndMount: { s -> Tok? in s == "s2" ? nil : Tok("new-\(s)") },  // 화면 s2 마운트 실패
            teardown: { tornDown.append($0.id) })

        guard case .failure = result else { return XCTFail("일부 화면 마운트 실패 시 .failure 여야 한다") }
        XCTAssertFalse(tornDown.contains("old1"), "F036: 재적용 실패 시 기존 렌더러가 생존해야 한다")
        XCTAssertFalse(tornDown.contains("old2"), "F036: 재적용 실패 시 기존 렌더러가 생존해야 한다")

        // 대조군(종전 버그 형태 재현): 재적용 '전' existing 을 선-소거하면, 위와 같은 실패에서도 기존
        // 렌더러는 이미 teardown 돼 있다 — 롤백 안전망이 지킬 대상 자체가 사라진다.
        var preDetached = existing
        preDetached.forEach { tornDown.append($0.id) }   // 옛 detachRenderersBeforeRebuild 와 동일한 즉시 teardown
        preDetached.removeAll()
        let regressed = RendererSwap.apply(
            screens: ["s1", "s2"],
            existing: preDetached,   // 이미 []
            makeAndMount: { s -> Tok? in s == "s2" ? nil : Tok("new-\(s)") },
            teardown: { _ in })
        guard case .failure = regressed else { return XCTFail("대조군도 실패해야 의미가 있다") }
        XCTAssertTrue(tornDown.contains("old1") && tornDown.contains("old2"),
                      "선-소거 패턴은 같은 실패에서 기존 렌더러를 이미 잃는다(구버전 결함 형태 대조)")
    }

    func testVideoSettingsTargetsActiveVideoRenderersBeforeCurrentProject() {
        XCTAssertEqual(
            VideoSettingsTarget.projectIds(currentProjectId: "global-scene", activeVideoProjectIds: ["assigned-video"]),
            ["assigned-video"])
        XCTAssertEqual(
            VideoSettingsTarget.projectIds(currentProjectId: "global-video", activeVideoProjectIds: []),
            ["global-video"])
        XCTAssertEqual(
            VideoSettingsTarget.projectIds(currentProjectId: nil, activeVideoProjectIds: ["a", "a", "b"]),
            ["a", "b"])
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

    /// F041: 일시정지(가림·수동·슬립 사유 무관) 중엔 자동전환 타이머가 전진하면 안 된다 —
    /// "정지=화면 고정" 기대와 달리 종전엔 이 가드가 아예 없어 정지 중에도 배경이 계속 바뀌었다.
    func testShouldAdvanceNow_pausedSkipsAutoAdvance() {
        XCTAssertFalse(PlaylistScheduling.shouldAdvanceNow(isPaused: true), "정지 중엔 자동전환 보류")
        XCTAssertTrue(PlaylistScheduling.shouldAdvanceNow(isPaused: false))
    }

    func testAdvance_skipsUnapplicableCandidates() {
        let ids = ["a", "b", "c"]
        func next(_ cur: String?) -> String? {  // a→b→c→a 순환
            guard let cur, let i = ids.firstIndex(of: cur) else { return ids.first }
            return ids[(i + 1) % ids.count]
        }
        // b 적용 실패(삭제/폴더 이동) → c 로 건너뛴다. 종전(nextApplicableId)엔 b 에서 영구 정지했다.
        XCTAssertEqual(
            PlaylistScheduling.advance(from: "a", count: ids.count, next: next, apply: { $0 == "c" }), "c")
        // 첫 후보 성공 → 그대로.
        XCTAssertEqual(
            PlaylistScheduling.advance(from: "a", count: ids.count, next: next, apply: { _ in true }), "b")
        // 전부 실패 → nil(적용 없음 — 기존 배경 유지).
        XCTAssertNil(
            PlaylistScheduling.advance(from: "a", count: ids.count, next: next, apply: { _ in false }))
        // 빈 목록 → nil(무한 루프 없음).
        XCTAssertNil(
            PlaylistScheduling.advance(from: nil, count: 0, next: { _ in "x" }, apply: { _ in true }))
    }

    /// 트레이 "다음 배경"(w5d-tray) — 순환 가능한 후보가 2개 이상일 때만 활성화. 하단 바
    /// NowPlayingBar 의 .disabled(ids.count < 2) 와 대칭이어야 두 진입점의 동작이 일치한다.
    func testCanAdvance_requiresAtLeastTwoCandidates() {
        XCTAssertFalse(PlaylistScheduling.canAdvance(count: 0))
        XCTAssertFalse(PlaylistScheduling.canAdvance(count: 1), "혼자면 순환해도 자기 자신 — 무의미")
        XCTAssertTrue(PlaylistScheduling.canAdvance(count: 2))
        XCTAssertTrue(PlaylistScheduling.canAdvance(count: 5))
    }

    // MARK: - PlaylistScheduling.shuffleNext (w5d-playback)

    func testShuffleNext_excludesCurrentWhenMultipleCandidates() {
        // random 주입을 0 고정 — current("b") 제외 후보는 ["a","c"](원순서 보존), 인덱스 0 = "a".
        XCTAssertEqual(
            PlaylistScheduling.shuffleNext(current: "b", ids: ["a", "b", "c"], random: { _ in 0 }), "a")
    }
    func testShuffleNext_neverReturnsCurrentAcrossAllRandomDraws() {
        // random 이 무엇을 뽑든(0/1) current="a" 는 후보에서 이미 제외돼 결과에 나올 수 없다.
        for draw in 0..<2 {
            let picked = PlaylistScheduling.shuffleNext(current: "a", ids: ["a", "b", "c"], random: { _ in draw })
            XCTAssertNotEqual(picked, "a", "직전 곡 회피 — draw=\(draw)")
        }
    }
    func testShuffleNext_singleCandidateReturnsItselfUnavoidably() {
        // 후보가 1개뿐이면 회피 불가능 — 그대로 반환(무한루프 방지).
        XCTAssertEqual(PlaylistScheduling.shuffleNext(current: "a", ids: ["a"], random: { _ in 0 }), "a")
    }
    func testShuffleNext_emptyListIsNil() {
        XCTAssertNil(PlaylistScheduling.shuffleNext(current: nil, ids: [], random: { _ in 0 }))
    }
    func testShuffleNext_nilCurrentUsesFullList() {
        // 첫 재생(current=nil) — 회피할 직전 곡이 없으니 전체 목록이 후보.
        XCTAssertEqual(
            PlaylistScheduling.shuffleNext(current: nil, ids: ["a", "b"], random: { _ in 1 }), "b")
    }

    // MARK: - StatusIconState (w5d-tray) — 상태바 아이콘 글리프·툴팁

    func testSymbolNamePriorityErrorOverPause() {
        XCTAssertEqual(StatusIconState.symbolName(isPaused: true, hasError: true), "exclamationmark.triangle.fill")
        XCTAssertEqual(StatusIconState.symbolName(isPaused: false, hasError: true), "exclamationmark.triangle.fill",
                       "오류는 정지 여부와 무관하게 최우선 표시")
    }
    func testSymbolNamePausedWithoutError() {
        XCTAssertEqual(StatusIconState.symbolName(isPaused: true, hasError: false), "pause.circle.fill")
    }
    func testSymbolNameNormal() {
        XCTAssertEqual(StatusIconState.symbolName(isPaused: false, hasError: false), "water.waves")
    }
    func testTooltipComposesAppliedTitleAndState() {
        XCTAssertEqual(StatusIconState.tooltip(appliedTitle: "Sunset", isPaused: false, hasError: false), "Sunset")
        XCTAssertEqual(StatusIconState.tooltip(appliedTitle: "Sunset", isPaused: true, hasError: false), "Sunset · 일시정지됨")
        XCTAssertEqual(StatusIconState.tooltip(appliedTitle: "Sunset", isPaused: false, hasError: true), "Sunset · 적용 실패")
        XCTAssertEqual(StatusIconState.tooltip(appliedTitle: nil, isPaused: false, hasError: false), "Waple",
                       "적용된 배경이 없으면 앱 이름만")
        XCTAssertEqual(StatusIconState.tooltip(appliedTitle: "Sunset", isPaused: true, hasError: true), "Sunset · 적용 실패",
                       "오류 문구가 정지 문구보다 우선(심볼과 동일 우선순위)")
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

    // MARK: - StillDesktopSync (정적 배경 동기화 — 원본 백업 판정)

    func testStillBackup_freshScreen_backsUp() {
        XCTAssertTrue(StillDesktopSync.shouldBackupOriginal(
            currentPath: "/Users/x/wall.jpg", stillDirPath: "/lib/still", hasBackup: false),
            "백업 없음 + 외부 경로 → 원본 저장")
    }

    func testStillBackup_alreadyBackedUp_skips() {
        XCTAssertFalse(StillDesktopSync.shouldBackupOriginal(
            currentPath: "/Users/x/wall.jpg", stillDirPath: "/lib/still", hasBackup: true),
            "이미 백업 있음 → 유지(덮어쓰지 않음)")
    }

    func testStillBackup_selfPollutionGuard_skips() {
        // 우리 스틸이 이미 깔린 상태(재실행)에서 그걸 '원본'으로 저장하면 복원이 무의미해진다.
        XCTAssertFalse(StillDesktopSync.shouldBackupOriginal(
            currentPath: "/lib/still/wp1.png", stillDirPath: "/lib/still", hasBackup: false),
            "현재값이 still 디렉터리 내부 → 자기 오염 방지로 백업 안 함")
    }

    func testStillBackup_nilOrEmptyCurrent_skips() {
        XCTAssertFalse(StillDesktopSync.shouldBackupOriginal(
            currentPath: nil, stillDirPath: "/lib/still", hasBackup: false))
        XCTAssertFalse(StillDesktopSync.shouldBackupOriginal(
            currentPath: "", stillDirPath: "/lib/still", hasBackup: false))
    }

    func testStillIsUnder_prefixBoundary() {
        XCTAssertTrue(StillDesktopSync.isUnder("/lib/still/a.png", dir: "/lib/still"))
        XCTAssertTrue(StillDesktopSync.isUnder("/lib/still", dir: "/lib/still"), "동일 경로")
        XCTAssertFalse(StillDesktopSync.isUnder("/lib/stillage/a.png", dir: "/lib/still"),
            "형제 프리픽스(stillage)는 내부 아님")
    }

    // MARK: - StillWallpaperNotice (F044/F045: 성공 화면 수를 반영한 정확한 통지)

    func testStillWallpaperNotice_allSucceed() {
        XCTAssertEqual(StillWallpaperNotice.message(successCount: 2, totalScreens: 2), "정지 배경으로 설정했습니다")
    }

    func testStillWallpaperNotice_allFail() {
        // 종전엔 try? 로 실패를 전부 삼키고 이 경우에도 성공 메시지를 띄웠다(F044/F045).
        XCTAssertEqual(StillWallpaperNotice.message(successCount: 0, totalScreens: 2), "정지 배경 설정에 실패했습니다")
    }

    func testStillWallpaperNotice_partialSuccess() {
        XCTAssertEqual(StillWallpaperNotice.message(successCount: 1, totalScreens: 2),
                       "일부 화면만 정지 배경으로 설정했습니다(1/2)")
    }

    // MARK: - StillDesktopSync.restorePass (P-D1: 분리 모니터 백업 보존)

    func testRestorePass_preservesDisconnectedKeys() {
        let out = StillDesktopSync.restorePass(
            originals: ["s1": "/a.jpg", "s2": "/b.jpg"],
            connectedKeys: ["s1"],
            fileExists: { _ in true },
            restore: { _, _ in true })
        XCTAssertEqual(out, ["s2": "/b.jpg"], "연결 안 된 화면(s2) 백업 보존 — 종전 전체 소거 버그")
    }

    func testRestorePass_missingFile_consumesBackup() {
        let out = StillDesktopSync.restorePass(
            originals: ["s1": "/gone.jpg"],
            connectedKeys: ["s1"],
            fileExists: { _ in false },
            restore: { _, _ in XCTFail("파일 부재면 복원 시도 없음"); return false })
        XCTAssertTrue(out.isEmpty, "파일 부재 = 복원 불가 확정 → 백업 제거")
    }

    func testRestorePass_failedRestore_keepsBackup() {
        let out = StillDesktopSync.restorePass(
            originals: ["s1": "/a.jpg"],
            connectedKeys: ["s1"],
            fileExists: { _ in true },
            restore: { _, _ in false })
        XCTAssertEqual(out, ["s1": "/a.jpg"], "복원 실패 키는 보존(다음 경로에서 재시도)")
    }

    // MARK: - RecentWallpapers (작업 6: 최근 목록 push)

    func testRecentPush_frontInsertAndDedup() {
        XCTAssertEqual(RecentWallpapers.push("a", into: []), ["a"])
        XCTAssertEqual(RecentWallpapers.push("b", into: ["a"]), ["b", "a"], "선두 삽입")
        XCTAssertEqual(RecentWallpapers.push("a", into: ["b", "a"]), ["a", "b"],
                       "재적용 → 중복 제거 후 선두")
    }

    func testRecentPush_capsAtMax() {
        let ten = (0..<10).map { "id\($0)" }
        let out = RecentWallpapers.push("new", into: ten)
        XCTAssertEqual(out.count, 10)
        XCTAssertEqual(out.first, "new")
        XCTAssertFalse(out.contains("id9"), "가장 오래된 것이 밀려남")
    }

    // MARK: - VideoImport (작업 5: 원시 동영상 → 최소 project.json 배경)

    func testVideoImportPreparesManagedFolderAndProjectJSON() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WapleVI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let base = tmp.appendingPathComponent("base", isDirectory: true)
        let fake = tmp.appendingPathComponent("myclip.mp4")
        try Data("not-really-a-video".utf8).write(to: fake)  // 미리보기 추출은 실패하지만 prepare 는 성공해야

        guard let folder = VideoImport.prepare(from: fake, baseDirectory: base) else {
            return XCTFail("prepare 는 관리 폴더 URL 을 반환해야 한다")
        }
        let fm = FileManager.default
        XCTAssertEqual(folder.lastPathComponent, "myclip")
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("myclip.mp4").path), "동영상 복사")
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("project.json").path), "project.json 기록")
        let project = try ProjectJSONParser.parse(folderURL: folder)
        XCTAssertEqual(project.type, .video)
        XCTAssertEqual(project.fileName, "myclip.mp4")
        XCTAssertEqual(project.previewName, "preview.jpg")
    }

    func testUniqueFolderName_noCollision_keepsBase() {
        XCTAssertEqual(VideoImport.uniqueFolderName(base: "clip") { _ in false }, "clip")
    }

    func testUniqueFolderName_collision_suffixesFromTwo() {
        let taken: Set<String> = ["clip", "clip-2"]
        XCTAssertEqual(VideoImport.uniqueFolderName(base: "clip") { taken.contains($0) }, "clip-3")
    }

    func testVideoImportSecondImportDoesNotOverwrite() throws {
        // P-D2: imports/<이름> 충돌 시 무경고 덮어쓰기 금지 — suffix 폴더로 회피.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WapleVI-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let base = tmp.appendingPathComponent("base", isDirectory: true)
        let fake = tmp.appendingPathComponent("myclip.mp4")
        try Data("v1".utf8).write(to: fake)

        let first = VideoImport.prepare(from: fake, baseDirectory: base)
        let second = VideoImport.prepare(from: fake, baseDirectory: base)
        XCTAssertEqual(first?.lastPathComponent, "myclip")
        XCTAssertEqual(second?.lastPathComponent, "myclip-2", "충돌 → suffix, 기존 폴더 보존")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: base.appendingPathComponent("imports/myclip/project.json").path),
            "첫 가져오기 폴더는 그대로 남는다")
    }

    func testVideoImportIsVideoFile() {
        XCTAssertTrue(VideoImport.isVideoFile(URL(fileURLWithPath: "/x/a.MP4")))
        XCTAssertTrue(VideoImport.isVideoFile(URL(fileURLWithPath: "/x/a.mov")))
        XCTAssertTrue(VideoImport.isVideoFile(URL(fileURLWithPath: "/x/a.m4v")))  // 화면보호기(WapleSaverView)와 동일 컨테이너 집합
        XCTAssertFalse(VideoImport.isVideoFile(URL(fileURLWithPath: "/x/a.webm")))
        XCTAssertFalse(VideoImport.isVideoFile(URL(fileURLWithPath: "/x/folder")))
    }

    // MARK: - OcclusionMode (가림 임계값 라디오 ↔ 상태)

    func testOcclusionModeDecode() {
        XCTAssertFalse(OcclusionMode.decode(-1).enabled, "사용 안 함")
        XCTAssertTrue(OcclusionMode.decode(0).enabled)
        XCTAssertEqual(OcclusionMode.decode(0).threshold, 0, "기존 = 켜짐 + 임계값 0")
        XCTAssertEqual(OcclusionMode.decode(0.5).threshold, 0.5)
    }

    func testOcclusionModeIsSelected() {
        XCTAssertTrue(OcclusionMode.isSelected(-1, enabled: false, threshold: 0), "꺼짐 → '사용 안 함' 체크")
        XCTAssertFalse(OcclusionMode.isSelected(-1, enabled: true, threshold: 0))
        XCTAssertTrue(OcclusionMode.isSelected(0, enabled: true, threshold: 0), "켜짐+0 → '기존' 체크")
        XCTAssertFalse(OcclusionMode.isSelected(0, enabled: false, threshold: 0))
        XCTAssertTrue(OcclusionMode.isSelected(0.5, enabled: true, threshold: 0.5))
        XCTAssertFalse(OcclusionMode.isSelected(0.5, enabled: true, threshold: 0.3))
    }

    // MARK: - GeneratedUID (잠금화면 스틸 — dscl 출력 파싱)

    func testGeneratedUID_sameLine() {
        XCTAssertEqual(
            GeneratedUID.parse(dsclOutput: "GeneratedUID: ABCD1234-5678-90AB-CDEF-1234567890AB\n"),
            "ABCD1234-5678-90AB-CDEF-1234567890AB")
    }

    func testGeneratedUID_valueOnNextLine() {
        // dscl 은 값이 다음 줄에 오는 형식도 낸다.
        XCTAssertEqual(
            GeneratedUID.parse(dsclOutput: "GeneratedUID:\n ABCD1234-5678\n"),
            "ABCD1234-5678")
    }

    func testGeneratedUID_missingOrEmpty_nil() {
        XCTAssertNil(GeneratedUID.parse(dsclOutput: "No such key: GeneratedUID\n"),
            "라벨 없음 → nil")
        XCTAssertNil(GeneratedUID.parse(dsclOutput: "GeneratedUID:\n"),
            "라벨만 있고 값 없음 → nil")
        XCTAssertNil(GeneratedUID.parse(dsclOutput: ""))
    }

    func testPropertyControlKindHandlesCorpusTypesCaseInsensitively() {
        XCTAssertEqual(PropertyControl.kind(forType: "Text"), .displayOnly)
        XCTAssertEqual(PropertyControl.kind(forType: ""), .displayOnly)
        XCTAssertEqual(PropertyControl.kind(forType: "group"), .displayOnly)
        XCTAssertEqual(PropertyControl.kind(forType: "label"), .displayOnly)
        XCTAssertEqual(PropertyControl.kind(forType: "usershortcut"), .displayOnly)
        XCTAssertEqual(PropertyControl.kind(forType: "boo4"), .displayOnly)
        XCTAssertEqual(PropertyControl.kind(forType: "uwu"), .displayOnly)
        XCTAssertEqual(PropertyControl.kind(forType: "file"), .file)
        XCTAssertEqual(PropertyControl.kind(forType: "scenetexture"), .file)
        XCTAssertEqual(PropertyControl.kind(forType: "directory"), .directory)
    }

    // MARK: - 재구성 무손실 (일반 오라클, 2026-08-26)
    //
    // 배경: `PresetResolver.resolve` 가 프로젝트를 **필드 재나열**로 재구성하면서
    // `supportsAudioProcessing`·`playbackProperties` 를 흘리고 있었다. 생성자의 뒤쪽 두 인자가
    // 기본값을 갖고 있어 빼먹어도 컴파일이 통과했기 때문이다.
    //
    // **이 절의 세 테스트는 그 두 필드를 단언하지 않는다.** 오늘의 두 필드만 못 박으면 내일
    // 추가되는 세 번째 필드가 똑같이 조용히 샌다 — 그게 이 결함의 성질이다. 대신 `Mirror` 로
    // 저장 프로퍼티를 **열거해서** 부류 전체를 잡는다:
    //
    //  ① `testProbeCoversEveryStoredField` — 탐침이 모든 필드에 "기본값과 다른 값" 을 갖는지.
    //     필드가 새로 생기면 **여기서 먼저 실패**하며 탐침을 고치라고 말한다(자가 유지).
    //  ② `testWithChangesCarriesEveryFieldItWasNotToldToChange` — `with(...)` 자체의 무손실.
    //  ③ `testPresetResolveNeverLeavesAFieldAtItsInitializerDefault` — 재구성의 무손실.
    //
    // ①이 있어야 ②③이 일반적이다. ①이 없으면 새 필드가 탐침에서 기본값인 채로 남아
    // ②③이 그 필드를 못 보고 통과한다.

    /// 모든 필드가 `init` 기본값·빈값과 **다른** 프로젝트. 위 세 테스트의 공통 탐침.
    /// 딕셔너리 항목을 하나씩만 두는 것은 `String(describing:)` 비교가 순서에 흔들리지 않게 하기 위함.
    private func populatedProject(seed: String, type: WallpaperType) -> WallpaperProject {
        WallpaperProject(
            id: "id-\(seed)",
            type: type,
            fileName: "\(seed).json",
            previewName: "\(seed).jpg",
            title: "제목 \(seed)",
            tags: ["tag-\(seed)"],
            contentRating: "Everyone-\(seed)",
            workshopId: "ws-\(seed)",
            dependency: "dep-\(seed)",
            folderURL: URL(fileURLWithPath: "/lib/\(seed)", isDirectory: true),
            presetOverrides: ["ov-\(seed)": .number(0.5)],
            presetFolderURL: URL(fileURLWithPath: "/lib/\(seed)/preset", isDirectory: true),
            supportsAudioProcessing: true,
            playbackProperties: ["playbackfullscreen": "pause"]
        )
    }

    /// 필수 인자에는 빈값을, 기본값 있는 인자에는 아무것도 주지 않은 프로젝트.
    /// = **재나열이 필드를 흘렸을 때 그 자리에 남는 값**의 표본.
    private func minimalProject() -> WallpaperProject {
        WallpaperProject(id: "", type: .preset, fileName: nil, previewName: nil,
                         title: "", tags: [], contentRating: nil, workshopId: nil,
                         dependency: nil, folderURL: URL(fileURLWithPath: "/"))
    }

    /// 저장 프로퍼티를 이름 → 표현으로. `Mirror` 라서 **필드가 늘면 자동으로 따라온다**.
    private func storedFields(_ project: WallpaperProject) -> [String: String] {
        var out: [String: String] = [:]
        for child in Mirror(reflecting: project).children {
            guard let label = child.label else { continue }
            out[label] = String(describing: child.value)
        }
        return out
    }

    func testProbeCoversEveryStoredField() {
        let probe = storedFields(populatedProject(seed: "probe", type: .unknown("probe")))
        let bare = storedFields(minimalProject())
        XCTAssertFalse(probe.isEmpty, "Mirror 가 저장 프로퍼티를 하나도 못 봤다")
        XCTAssertEqual(Set(probe.keys), Set(bare.keys))
        for (label, value) in probe {
            XCTAssertNotEqual(
                value, bare[label],
                """
                탐침의 `\(label)` 이 기본값과 같다(\(value)). \
                WallpaperProject 에 필드를 추가했다면 populatedProject 에 **기본값과 다른 값**을 \
                넣어라 — 안 그러면 아래 두 무손실 테스트가 그 필드를 못 본다.
                """)
        }
    }

    func testWithChangesCarriesEveryFieldItWasNotToldToChange() {
        let probe = populatedProject(seed: "probe", type: .unknown("probe"))

        // 인자 없는 with() 는 항등. `==` 는 합성 Equatable 이라 필드가 늘어도 자동으로 덮는다.
        XCTAssertEqual(probe.with(), probe, "with() 가 무언가를 흘렸다")

        // 하나만 바꾸면 그 하나만 바뀐다.
        let changed = probe.with(title: "다른 제목")
        let before = storedFields(probe)
        for (label, value) in storedFields(changed) {
            if label == "title" {
                XCTAssertEqual(value, "다른 제목")
            } else {
                XCTAssertEqual(value, before[label], "with(title:) 이 \(label) 까지 바꿨다")
            }
        }

        // 이중 옵셔널 규약(WallpaperProject.with 주석): 리터럴 nil 은 "안 바꿈",
        // String? 변수는 옵셔널 승격으로 "그 값으로 바꿈"(nil 이어도 nil 로 덮어쓴다).
        XCTAssertEqual(probe.with(fileName: nil).fileName, probe.fileName,
                       "리터럴 nil 은 '안 바꿈' 이어야 한다")
        let absent: String? = nil
        XCTAssertNil(probe.with(fileName: absent).fileName,
                     "String? 변수는 nil 이어도 그 nil 로 덮어써야 한다")
    }

    func testPresetResolveNeverLeavesAFieldAtItsInitializerDefault() {
        let preset = populatedProject(seed: "preset", type: .preset)
        let target = populatedProject(seed: "target", type: .scene)
        let resolved = PresetResolver.resolve(
            project: preset,
            originalFolder: preset.folderURL,
            dependencyFolder: { _ in target.folderURL },
            parse: { $0 == target.folderURL ? target : nil })
        guard let resolved else { return XCTFail("프리셋이 해석되지 않았다") }

        let bare = storedFields(minimalProject())
        // resolve 는 필드를 **교차 대입**한다(presetFolderURL := project.folderURL). 그래서 같은
        // 이름끼리 맞추는 대신 **두 입력이 가진 값들의 집합**에 속하는지를 본다.
        // `Optional(...)` 껍질은 벗겨서 비교한다 — 같은 값이라도 받는 필드의 옵셔널 여부가
        // 다르면 `String(describing:)` 표기가 갈리기 때문이다(`presetFolderURL`(URL?) 에 들어간
        // `folderURL`(URL) 값이 실제로 그랬다. 이 벗기기 없이 짰다가 표준 오라클이 정상 코드에도
        // 실패해서 발견했다).
        var fromInputs = Set(storedFields(preset).values.map(Self.unwrappedDescription))
        fromInputs.formUnion(storedFields(target).values.map(Self.unwrappedDescription))

        for (label, value) in storedFields(resolved) {
            XCTAssertNotEqual(
                value, bare[label],
                "재구성이 `\(label)` 을 흘렸다 — 생성자 기본값(\(value))이 그대로 남았다")
            XCTAssertTrue(
                fromInputs.contains(Self.unwrappedDescription(value)),
                "`\(label)` 의 값(\(value))이 두 입력 어디에서도 오지 않았다")
        }
    }

    /// `Optional(x)` → `x`. 그 밖은 그대로.
    private static func unwrappedDescription(_ s: String) -> String {
        guard s.hasPrefix("Optional("), s.hasSuffix(")") else { return s }
        return String(s.dropFirst("Optional(".count).dropLast())
    }

    /// 위 일반 오라클이 실제로 무엇을 잡았는지 사람이 읽을 수 있게 남기는 회귀 못.
    /// (일반 오라클이 실패하면 어느 필드인지 메시지로 알려 주지만, 이 두 필드는 실측 결함이라
    ///  이름을 박아 둔다 — 다음 사람이 `git log` 없이도 무슨 일이 있었는지 알도록.)
    func testPresetResolveKeepsAudioAndPlaybackDeclarations() {
        let preset = populatedProject(seed: "preset", type: .preset)
        let target = populatedProject(seed: "target", type: .scene)
            .with(playbackProperties: ["playbackfocus": "mute", "playbacksleep": "stop"])
        let resolved = PresetResolver.resolve(
            project: preset,
            originalFolder: preset.folderURL,
            dependencyFolder: { _ in target.folderURL },
            parse: { $0 == target.folderURL ? target : nil })

        XCTAssertEqual(resolved?.supportsAudioProcessing, true,
                       "오디오 지원 선언이 프리셋 해석에서 사라졌다")
        // 프리셋이 선언한 축이 이기고, target 만 선언한 축은 그대로 실려 온다.
        XCTAssertEqual(resolved?.playbackProperties,
                       ["playbackfullscreen": "pause", "playbackfocus": "mute", "playbacksleep": "stop"])
    }

    /// [2026-08-26] `with(...)` 의 옵셔널 파라미터는 **이중 옵셔널**이라 `??` 를 인자 자리에
    /// 직접 쓰면 좌변이 `.some(…)` 으로 승격돼 우변이 죽는다(컴파일러는 경고만 준다).
    /// `resolve` 에서 실제로 그렇게 썼다가 앱 계층 타입체크 경고로 잡았고, 그때 죽은 것이
    /// 바로 이 "프리셋이 비면 target 값" 폴백 세 개다. 기존 테스트들은 전부 프리셋 쪽에
    /// 값이 **있는** 경우만 봐서 못 잡았다 — 그래서 없는 쪽을 여기서 못 박는다.
    func testPresetResolveFallsBackToTargetWhenPresetLeavesFieldsEmpty() {
        let preset = populatedProject(seed: "preset", type: .preset)
            .with(previewName: String?.none, contentRating: String?.none, workshopId: String?.none)
        let target = populatedProject(seed: "target", type: .scene)
        let resolved = PresetResolver.resolve(
            project: preset,
            originalFolder: preset.folderURL,
            dependencyFolder: { _ in target.folderURL },
            parse: { $0 == target.folderURL ? target : nil })

        XCTAssertEqual(resolved?.previewName, "target.jpg", "프리셋에 없으면 target 미리보기")
        XCTAssertEqual(resolved?.contentRating, "Everyone-target")
        XCTAssertEqual(resolved?.workshopId, "ws-target")
    }

    // MARK: - PlaybackPolicyGate (재생정책 stage 1, 2026-08-26)

    private func project(playback: [String: String]) -> WallpaperProject {
        WallpaperProject(id: "p", type: .scene, fileName: "scene.json", previewName: nil,
                         title: "p", tags: [], contentRating: nil, workshopId: nil,
                         dependency: nil, folderURL: URL(fileURLWithPath: "/lib/p"),
                         playbackProperties: playback)
    }

    /// 모든 축이 발화할 수 있는 최악 조건 — 무회귀 단언을 여기에 건다.
    private var hostileConditions: PlaybackConditions {
        PlaybackConditions(
            layout: .perMonitor,
            allMonitorsMask: 0b11,
            unfocusedMask: 0b11,
            maximizedMask: 0b11,
            fullscreenMask: 0b11,
            audioPlaying: true,
            displayAsleep: true,
            onBattery: true)
    }

    func testPolicyGateIsACompleteNoOpWhenNothingIsDeclared() {
        XCTAssertNil(PlaybackPolicyGate.declaredPolicy([:]), "선언 없음 → 정책 없음")
        // [2026-08-26] 종전엔 `PlaybackPolicyGate.verdict` 가 선언 없음을 `.running` 으로 단축했다.
        // 그 단축은 전역면이 없다는 전제 위에서만 옳았고, 그 전제는 깨졌다. 같은 계약을
        // **전역 = 전 축 run** 으로 표현한다 — 정책이 어디에도 없으면 무동작이라는 뜻은 그대로다.
        XCTAssertEqual(
            PlaybackPolicyResolver.verdict(for: project(playback: [:]),
                                           conditions: hostileConditions, global: .allRun),
            .running,
            "정책이 어디에도 없으면 어떤 조건에서도 무동작이어야 한다(무회귀 계약)")
    }

    func testPolicyGateTreatsEmptyStringAsAbsent() {
        let empty = Dictionary(uniqueKeysWithValues: PlaybackTrigger.allCases.map { ($0.weConfigKey, "") })
        XCTAssertNil(PlaybackPolicyGate.declaredPolicy(empty),
                     "빈 문자열은 WE 의 '전역 설정 따름' 기본 주입이라 부재와 같다")
        XCTAssertEqual(PlaybackPolicyResolver.verdict(for: project(playback: empty),
                                                      conditions: hostileConditions, global: .allRun),
                       .running)
    }

    /// 최상위 계약. 선언하지 않은 축은 `run` 이지 **WE 전역 기본값이 아니다.**
    /// `PlaybackPolicy.init(weConfig:)` 를 그대로 쓰면 여기가 깨진다 —
    /// 그쪽은 부재 키를 maximized=pause · fullscreen=pause · sleep=stop 으로 채운다.
    func testPolicyGateUndeclaredAxisIsRunNotTheWEGlobalDefault() {
        guard let policy = PlaybackPolicyGate.declaredPolicy(["playbackfocus": "mute"]) else {
            return XCTFail("한 축이라도 선언되면 정책이 나와야 한다")
        }
        XCTAssertEqual(policy.focus, .mute, "선언한 축은 그대로")
        for trigger in PlaybackTrigger.allCases where trigger != .focus {
            XCTAssertEqual(policy[trigger], .run,
                           "\(trigger.weConfigKey) 는 선언되지 않았으므로 run 이어야 한다 " +
                           "(WE 전역 기본값 \(trigger.weDefault.weConfigValue) 가 새어 들어왔다)")
        }
        // 전역 기본값과 정말 다른지 — 위 루프가 통과해도 이 셋이 같으면 계약이 무의미하다.
        XCTAssertNotEqual(PlaybackTrigger.maximized.weDefault, .run)
        XCTAssertNotEqual(PlaybackTrigger.fullscreen.weDefault, .run)
        XCTAssertNotEqual(PlaybackTrigger.displaySleep.weDefault, .run)
    }

    func testPolicyGateDeclaredAxisReachesTheEvaluator() {
        // 전체화면 축만 pause 로 선언 → 전체화면인 화면만 정지(layout=perMonitor 이므로 부분 정지).
        let verdict = PlaybackPolicyResolver.verdict(
            for: project(playback: ["playbackfullscreen": "pause"]),
            conditions: PlaybackConditions(allMonitorsMask: 0b11, fullscreenMask: 0b10),
            global: .allRun)
        XCTAssertFalse(verdict.stop)
        XCTAssertFalse(verdict.muted)
        XCTAssertFalse(verdict.isPaused(monitorIndex: 0))
        XCTAssertTrue(verdict.isPaused(monitorIndex: 1))
    }

    func testPolicyGateUnrecognisedValueFallsToRun() {
        // 매퍼 0x140141918: 미인식 문자열은 조용히 run. 오타가 '정책 없음' 이지 실패가 아니다.
        let verdict = PlaybackPolicyResolver.verdict(
            for: project(playback: ["playbackfullscreen": "paws"]),
            conditions: hostileConditions, global: .allRun)
        XCTAssertEqual(verdict, .running)
    }

    /// 프리셋 경유 마운트에서도 선언이 게이트까지 살아 도착하는가 — 결함 두 개가 만나는 자리다.
    /// 재구성이 `playbackProperties` 를 흘리던 동안 이 경로는 배선이 착지하는 순간 발화할
    /// 잠복 결함이었다(정책을 선언한 벽지가 프리셋을 거치면 조용히 정책 없음이 된다).
    func testDeclaredPolicySurvivesPresetResolutionAllTheWayToTheGate() {
        let presetFolder = URL(fileURLWithPath: "/lib/preset1", isDirectory: true)
        let depFolder = URL(fileURLWithPath: "/lib/dep1", isDirectory: true)
        let preset = WallpaperProject(
            id: "preset1", type: .preset, fileName: nil, previewName: nil,
            title: "Preset", tags: [], contentRating: nil, workshopId: nil,
            dependency: "dep1", folderURL: presetFolder)
        let dependency = WallpaperProject(
            id: "dep1", type: .scene, fileName: "scene.json", previewName: nil,
            title: "Dep", tags: [], contentRating: nil, workshopId: nil,
            dependency: nil, folderURL: depFolder,
            playbackProperties: ["playbackfullscreen": "pause"])

        guard let resolved = PresetResolver.resolve(
            project: preset,
            originalFolder: presetFolder,
            dependencyFolder: { $0 == "dep1" ? depFolder : nil },
            parse: { $0 == depFolder ? dependency : nil }) else {
            return XCTFail("프리셋이 해석되지 않았다")
        }

        let verdict = PlaybackPolicyResolver.verdict(
            for: resolved,
            conditions: PlaybackConditions(allMonitorsMask: 1, fullscreenMask: 1),
            global: .allRun)
        XCTAssertTrue(verdict.isPaused(monitorIndex: 0),
                      "프리셋 해석을 거치면서 선언한 정책이 사라졌다")
    }

    // MARK: - 파서 ↔ WaplePolicy 키 감시 (ProjectJSONParser 주석이 약속한 '앱 측 테스트')

    /// `ProjectJSONParser.parsePlaybackProperties` 는 여섯 키를 **비공개 리터럴**로 들고 있다
    /// (WapleCore 는 WaplePolicy 를 import 할 수 없다 — Package.swift 의 경고).
    /// 그 리터럴을 직접 읽을 수 없으므로 `PlaybackTrigger.allCases` 의 키를 전부 담은 json 을
    /// 먹여 **수집 결과 집합**을 대조한다 — 어느 쪽이 키를 더하거나 이름을 바꿔도 양방향으로 걸린다.
    /// 이 대조가 가능한 타깃은 `WapleAppTests` 뿐이다(WapleCore·WaplePolicy 를 동시에 보는 첫 타깃).
    func testParserCollectsExactlyThePolicyKeysWaplePolicyDeclares() {
        var properties: [String: Any] = [:]
        for trigger in PlaybackTrigger.allCases {
            properties[trigger.weConfigKey] = ["value": trigger.weDefault.weConfigValue]
        }
        let parsed = ProjectJSONParser.parse(
            json: ["type": "scene", "file": "scene.json", "general": ["properties": properties]],
            folderURL: URL(fileURLWithPath: "/lib/keys"))

        XCTAssertEqual(Set(parsed.playbackProperties.keys),
                       Set(PlaybackTrigger.allCases.map { $0.weConfigKey }),
                       "파서의 여섯 키 리터럴과 PlaybackTrigger.allCases 가 어긋났다")
        // 값도 원문 그대로여야 한다 — 게이트가 그 문자열을 액션으로 접는다.
        for trigger in PlaybackTrigger.allCases {
            XCTAssertEqual(parsed.playbackProperties[trigger.weConfigKey],
                           trigger.weDefault.weConfigValue)
        }
        // 그리고 그 원문이 게이트를 통과해 같은 액션으로 돌아오는가(파서→모델→게이트 왕복).
        guard let policy = PlaybackPolicyGate.declaredPolicy(parsed.playbackProperties) else {
            return XCTFail("여섯 축을 전부 선언했는데 정책이 나오지 않았다")
        }
        for trigger in PlaybackTrigger.allCases {
            XCTAssertEqual(policy[trigger], trigger.weDefault)
        }
    }
}
