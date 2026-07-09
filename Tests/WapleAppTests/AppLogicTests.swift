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

    func testScreenChangeDetachesRenderersBeforeWindowRebuild() {
        var existing = [Tok("old1"), Tok("old2")]
        var tornDown: [String] = []

        ScreenChangeLifecycle.detachRenderersBeforeRebuild(
            existing: &existing,
            teardown: { tornDown.append($0.id) })

        XCTAssertTrue(existing.isEmpty)
        XCTAssertEqual(tornDown.sorted(), ["old1", "old2"])
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
}
