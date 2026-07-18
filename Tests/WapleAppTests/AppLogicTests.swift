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

    /// F036/F035 회귀 방지: screensChanged() 는 desktopController.rebuild() 뒤 곧바로
    /// RendererSwap.apply(existing: renderers, ...) 로 재적용한다 — renderers 를 미리 비우지 않는다.
    /// 종전에는 ScreenChangeLifecycle.detachRenderersBeforeRebuild 로 재적용 '전' renderers 를 []로
    /// 선-소거해, RendererSwap 의 "mount 실패 시 existing 유지" 롤백 안전망이 이미 빈 배열을 붙잡아
    /// 무력화됐다(재적용 실패 시 화면 전체가 배경 없이 남음). 아래는 실제 screensChanged 가 호출하는
    /// 것과 동일한 RendererSwap.apply 를, 화면 하나의 마운트가 실패하는 상황으로 재현한다.
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

        // 대조군(종전 버그 재현): 재적용 '전' existing 을 선-소거하면, 위와 같은 실패에도 "생존"이
        // 무의미해진다 — existing 이 이미 비어 있으므로 지킬 것 자체가 없다.
        var preDetached = existing
        preDetached.forEach { tornDown.append($0.id) }   // 옛 detachRenderersBeforeRebuild 와 동일한 즉시 teardown
        preDetached.removeAll()
        let regressed = RendererSwap.apply(
            screens: ["s1", "s2"],
            existing: preDetached,   // 이미 []
            makeAndMount: { s -> Tok? in s == "s2" ? nil : Tok("new-\(s)") },
            teardown: { _ in })
        guard case .failure = regressed else { return XCTFail("대조군도 실패해야 의미가 있다") }
        XCTAssertTrue(preDetached.isEmpty, "선-소거 경로는 롤백 안전망이 지킬 대상 자체를 미리 없애버린다(구버전 결함 재현)")
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
}
