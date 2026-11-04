import XCTest
import AppKit
@testable import Waple
import WapleCore
import WaplePolicy
import WapleLibrary
import WapleRender

final class AuditAppStateRegressionTests: XCTestCase {
    private final class Renderer: WallpaperRenderer {
        let name: String
        init(_ name: String) { self.name = name }
        func mount(in container: NSView, project: WallpaperProject) throws {}
        func pause() {}
        func resume() {}
        func teardown() {}
        func setPolicyMuted(_ muted: Bool) {}
        var isPlayingAudio: Bool { false }
    }

    private func project(id: String = "Wallpaper", type: WallpaperType = .scene) -> WallpaperProject {
        WallpaperProject(id: id, type: type, fileName: "scene.pkg", previewName: nil,
                         title: id, tags: [], contentRating: nil, workshopId: nil,
                         dependency: nil, folderURL: URL(fileURLWithPath: "/wallpapers/\(id)"))
    }

    func testLibraryIdentitySurvivesMountResolutionAndKeepsProjectMetadata() throws {
        let parsed = project().with(playbackProperties: ["playbackfullscreen": "pause"])
        let mounted = try XCTUnwrap(PresetResolver.resolve(
            project: parsed, originalFolder: parsed.folderURL, libraryEntryId: "Wallpaper-2",
            dependencyFolder: { _ in nil }, parse: { _ in nil }))
        XCTAssertEqual(mounted.id, "Wallpaper-2")
        XCTAssertEqual(mounted.folderURL, parsed.folderURL)
        XCTAssertEqual(mounted.playbackProperties, parsed.playbackProperties)
        XCTAssertNotEqual(StillWallpaper.outputURL(projectId: mounted.id, stillDir: parsed.folderURL),
                          StillWallpaper.outputURL(projectId: parsed.id, stillDir: parsed.folderURL))
    }

    func testTwoImportedFoldersWithSameNameResolveToTheirOwnLibraryIdentity() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("audit-identity-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let name = "Wallpaper-\(UUID().uuidString)"
        let first = root.appendingPathComponent("a/\(name)")
        let second = root.appendingPathComponent("b/\(name)")
        for folder in [first, second] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"type":"scene","file":"scene.pkg","title":"Wallpaper"}"#.utf8)
                .write(to: folder.appendingPathComponent("project.json"))
        }
        let library = LibraryStore(baseDirectory: root.appendingPathComponent("library"))
        let firstEntry = try library.importFolder(first)
        let secondEntry = try library.importFolder(second)
        let parsed = try ProjectJSONParser.parse(folderURL: second)
        XCTAssertNotEqual(firstEntry.id, secondEntry.id)
        XCTAssertEqual(parsed.id, firstEntry.id)
        let mounted = try XCTUnwrap(PresetResolver.resolve(
            project: parsed, originalFolder: second, libraryEntryId: secondEntry.id,
            dependencyFolder: { _ in nil }, parse: { _ in nil }))
        XCTAssertEqual(mounted.id, secondEntry.id)
        XCTAssertNotEqual(mounted.id, firstEntry.id)
    }

    @MainActor func testPlaylistDriverPassesPauseStateForEachScreen() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("audit-playlist-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let driver = PlaylistDriver(stateTime: PlaylistStateTimeStore(baseDirectory: root))
        driver.sync(enabled: true, intervalMinutes: 1, shuffle: false,
                    ids: ["a", "b"], screenKeys: ["paused", "playing"], currentEntryId: nil)
        var now = Date(timeIntervalSince1970: 5_000_000)
        XCTAssertTrue(driver.tick(now: now, isPaused: { $0 == "paused" }).isEmpty)
        var advanced: [String] = []
        for _ in 0..<12 {
            now.addTimeInterval(5)
            advanced += driver.tick(now: now, isPaused: { $0 == "paused" })
        }
        XCTAssertEqual(advanced, ["playing"])
        XCTAssertEqual(driver.elapsedByScreen["paused"], 0)
        XCTAssertEqual(driver.elapsedByScreen["playing"], 60)
    }

    func testPolicyMountMutesBeforeStartingAndPausesBeforeRestoringUserMute() {
        var calls: [String] = []
        RenderPauseComposition.mount(muted: false, paused: true,
            setMuted: { calls.append("mute:\($0)") },
            mount: { calls.append("mount") }, pause: { calls.append("pause") })
        XCTAssertEqual(calls, ["mute:true", "mount", "pause", "mute:false"])
    }

    func testPolicyMuteIsAlreadyPresentWhenMountStarts() {
        var muted = false
        var muteAtMount = false
        RenderPauseComposition.mount(muted: true, paused: false,
            setMuted: { muted = $0 }, mount: { muteAtMount = muted }, pause: {})
        XCTAssertTrue(muteAtMount)
        XCTAssertTrue(muted)
    }

    func testPlaylistSwapKeepsUnchangedRendererAndOnlyRetiresChangedRenderer() {
        let unchanged = Renderer("fixed")
        let replaced = Renderer("old")
        var mounts: [String] = []
        var retired: [String] = []
        let result = RendererSwap.apply(screens: ["fixed", "next"], existing: [unchanged, replaced],
            reuse: { $0 == "fixed" ? unchanged : nil },
            makeAndMount: { key -> Renderer? in mounts.append(key); return Renderer(key) },
            teardown: { retired.append($0.name) })
        guard case .success(let renderers) = result else { return XCTFail("swap failed") }
        XCTAssertTrue(renderers[0] === unchanged)
        XCTAssertEqual(mounts, ["next"])
        XCTAssertEqual(retired, ["old"])
    }

    func testFailedPlaylistSwapDoesNotTearDownReusedOrExistingRenderer() {
        let unchanged = Renderer("fixed")
        let replaced = Renderer("old")
        var retired: [String] = []
        let result = RendererSwap.apply(screens: ["fixed", "new", "bad"], existing: [unchanged, replaced],
            reuse: { $0 == "fixed" ? unchanged : nil },
            makeAndMount: { key -> Renderer? in key == "bad" ? nil : Renderer(key) },
            teardown: { retired.append($0.name) })
        guard case .failure = result else { return XCTFail("failed mount must roll back") }
        XCTAssertEqual(retired, ["new"])
    }

    func testRendererSwapPreservesIdentityThroughWallpaperRendererExistential() {
        let unchanged: any WallpaperRenderer = Renderer("fixed")
        let replaced: any WallpaperRenderer = Renderer("old")
        var retired: [ObjectIdentifier] = []
        let result = RendererSwap.apply(screens: ["fixed", "next"], existing: [unchanged, replaced],
            reuse: { $0 == "fixed" ? unchanged : nil },
            makeAndMount: { key -> (any WallpaperRenderer)? in Renderer(key) },
            teardown: { retired.append(ObjectIdentifier($0)) })
        guard case .success(let renderers) = result else { return XCTFail("swap failed") }
        XCTAssertTrue(renderers[0] === unchanged)
        XCTAssertEqual(retired, [ObjectIdentifier(replaced)])
    }

    func testRendererSwapStillSupportsValueTokensWithoutReuse() {
        var retired: [Int] = []
        let result = RendererSwap.apply(screens: [1, 2], existing: [0],
            makeAndMount: { $0 }, teardown: { retired.append($0) })
        guard case .success(let tokens) = result else { return XCTFail("swap failed") }
        XCTAssertEqual(tokens, [1, 2])
        XCTAssertEqual(retired, [0])
    }

    func testStillCaptureCompletionOnlyAcceptsLatestRequest() {
        var requests = StillCaptureGeneration()
        let a = requests.advance()
        let b = requests.advance()
        XCTAssertTrue(requests.isCurrent(b))
        XCTAssertFalse(requests.isCurrent(a))
        requests.advance()
        XCTAssertFalse(requests.isCurrent(b), "selection/toggle invalidation must reject an already running capture")
    }

    func testStillRequestsUseIndependentIntermediateAndFinalPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audit-stills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try StillCaptureWorkspace.create(in: root)
        let b = try StillCaptureWorkspace.create(in: root)
        try Data([1]).write(to: a.appendingPathComponent("frame_t1.0.png"))
        try Data([2]).write(to: b.appendingPathComponent("frame_t1.0.png"))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try Data(contentsOf: a.appendingPathComponent("frame_t1.0.png")), Data([1]))
        XCTAssertNotEqual(StillWallpaper.outputURL(projectId: "same", stillDir: a),
                          StillWallpaper.outputURL(projectId: "same", stillDir: b))
    }

    func testOnlyLatestCapturePublishesTheSharedFinalCache() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("audit-publish-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        var requests = StillCaptureGeneration()
        let aToken = requests.advance()
        let a = try StillCaptureWorkspace.create(in: root)
        let bToken = requests.advance()
        let b = try StillCaptureWorkspace.create(in: root)
        let aFile = a.appendingPathComponent("same.png")
        let bFile = b.appendingPathComponent("same.png")
        try Data([1]).write(to: aFile)
        try Data([2]).write(to: bFile)
        XCTAssertTrue(requests.isCurrent(bToken))
        let published = StillCaptureWorkspace.publish(images: ["left": bFile, "right": bFile], from: b, to: root)
        XCTAssertEqual(published["left"], published["right"], "같은 생성 파일은 한 번만 이동한다")
        XCTAssertFalse(requests.isCurrent(aToken), "늦은 A는 publish에 도달하면 안 된다")
        try fm.removeItem(at: a)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("same.png")), Data([2]))
        XCTAssertFalse(fm.fileExists(atPath: b.path))
        let c = try StillCaptureWorkspace.create(in: root)
        let cFile = c.appendingPathComponent("same.png")
        try Data([3]).write(to: cFile)
        _ = StillCaptureWorkspace.publish(images: ["left": cFile], from: c, to: root)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("same.png")), Data([3]))
    }

    func testPublishingPreviewPreservesTheOriginalFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("audit-preview-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let request = try StillCaptureWorkspace.create(in: root)
        let original = root.appendingPathComponent("preview.png")
        try Data([7]).write(to: original)
        let published = StillCaptureWorkspace.publish(images: ["screen": original], from: request, to: root)
        XCTAssertEqual(published["screen"], original)
        XCTAssertEqual(try Data(contentsOf: original), Data([7]))
        XCTAssertFalse(fm.fileExists(atPath: request.path))
    }

    func testLargeFinderBrowserOnMainScreenDoesNotMatchSmallOtherScreen() {
        let screens = [CGRect(x: 0, y: 0, width: 2560, height: 1440),
                       CGRect(x: 2560, y: 0, width: 1280, height: 800)]
        let browser = DesktopVisibilityMonitor.WindowSnapshot(ownerName: "Finder", processId: 999,
            layer: 0, alpha: 1, bounds: CGRect(x: 100, y: 100, width: 1440, height: 1000))
        XCTAssertFalse(DesktopVisibilityMonitor.isDesktopVisible(windows: [browser], currentProcessId: 1,
                                                                screenFrames: screens))
        let desktop = DesktopVisibilityMonitor.WindowSnapshot(ownerName: "Finder", processId: 999,
            layer: 0, alpha: 1, bounds: screens[1])
        XCTAssertTrue(DesktopVisibilityMonitor.isDesktopVisible(windows: [desktop], currentProcessId: 1,
                                                               screenFrames: screens))
    }
}


final class AuditAppStateWiringTests: XCTestCase {
    func testProductionUsesTheIdentityMountPauseAndStillFreshnessGates() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Waple/AppDelegate.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("libraryEntryId: recentEntryId(mountedFolder: folderURL)"))
        XCTAssertTrue(source.contains("reuse: { reusedRenderers[$0.screenKey] }"))
        XCTAssertTrue(source.contains("try RenderPauseComposition.mount(muted: mountMute,"))
        XCTAssertTrue(source.contains("stillCaptureGeneration.isCurrent(generation)"))
        XCTAssertTrue(source.contains("StillCaptureWorkspace.create(in: stillDirectory())"))
        XCTAssertTrue(source.contains("libraryVM.onCancelPendingApply"))
    }
}
