import XCTest
import WapleCore
import WapleLibrary

final class PlaylistConfigurationStoreTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    func testLegacyPlaylistMigratesWithoutRewritingUntilTheFirstChange() throws {
        let directory = try directory()
        let file = directory.appendingPathComponent("playlist.json")
        let legacy = Data(#"{"enabled":true,"intervalMinutes":15,"ids":["a","b"],"shuffle":true}"#.utf8)
        try legacy.write(to: file)
        let store = PlaylistStore(baseDirectory: directory)
        XCTAssertEqual(try Data(contentsOf: file), legacy)
        XCTAssertTrue(store.configuration.enabled)
        XCTAssertEqual(store.configuration.mode, .timer)
        XCTAssertEqual(store.configuration.delayMinutes, 15)
        XCTAssertEqual(store.configuration.ids, ["a", "b"])
        XCTAssertTrue(store.configuration.shuffle)
        XCTAssertEqual(store.savedPlaylists.count, 1)
        var edited = store.configuration
        edited.delayMinutes = 0.025
        store.configuration = edited
        let restored = PlaylistStore(baseDirectory: directory)
        XCTAssertEqual(restored.configuration.delayMinutes, 0.025)
        XCTAssertEqual(restored.intervalMinutes, 1, "The legacy integral facade retains its lower bound")
        XCTAssertEqual(restored.ids, ["a", "b"])
        restored.intervalMinutes = 7
        XCTAssertEqual(restored.configuration.delayMinutes, 7)
    }

    func testSavedPlaylistSettingsAndScreenAssignmentsRoundTrip() throws {
        let directory = try directory()
        let store = PlaylistStore(baseDirectory: directory)
        let globalID = store.selectedPlaylistId
        store.ids = ["global"]
        let dayID = store.createPlaylist(name: "Workday")
        var day = PlaylistConfiguration(id: dayID, name: "Workday", enabled: true,
            delayMinutes: 0.5, mode: .daytime, ids: ["dawn", "night"], shuffle: true,
            videoSequence: true, updateOnPause: true, beginFirst: true, playIntro: true,
            daytimeEnds: ["dawn": 0.5, "night": 1], transitionConfigValue: 27,
            transitionTimeMillis: 2500, transitionPool: [3, 1, 3])
        store.configuration = day
        store.assignPlaylist(dayID, toScreen: "external")
        XCTAssertTrue(store.selectPlaylist(id: globalID))
        store.currentByScreen = ["primary": "global", "external": "night"]
        let restored = PlaylistStore(baseDirectory: directory)
        XCTAssertEqual(restored.selectedPlaylistId, globalID)
        XCTAssertEqual(restored.configuration(for: nil).ids, ["global"])
        XCTAssertEqual(restored.configuration(for: "external"), day)
        XCTAssertEqual(restored.configuration(for: "unknown"), restored.configuration)
        XCTAssertEqual(restored.assignedPlaylistId(forScreen: "external"), dayID)
        XCTAssertEqual(restored.currentByScreen, ["primary": "global", "external": "night"])
        XCTAssertTrue(restored.selectPlaylist(id: dayID))
        day.delayMinutes = 0.75
        restored.configuration = day
        XCTAssertEqual(PlaylistStore(baseDirectory: directory).configuration(for: "external").delayMinutes, 0.75)
    }

    func testPlaylistCRUDKeepsAssignmentsAndFallsBackSafelyWhenDeleting() throws {
        let directory = try directory()
        let store = PlaylistStore(baseDirectory: directory)
        let original = store.selectedPlaylistId
        let created = store.createPlaylist(name: "  Night  ")
        XCTAssertEqual(store.configuration.name, "Night")
        store.renamePlaylist(id: created, name: "Evening")
        store.assignPlaylist(created, toScreen: "screen")
        XCTAssertEqual(store.configuration(for: "screen").name, "Evening")
        XCTAssertFalse(store.selectPlaylist(id: "missing"))
        XCTAssertEqual(store.selectedPlaylistId, created)
        store.assignPlaylist("missing", toScreen: "screen")
        XCTAssertEqual(store.assignedPlaylistId(forScreen: "screen"), created)
        store.assignPlaylist(nil, toScreen: "screen")
        XCTAssertNil(store.assignedPlaylistId(forScreen: "screen"))
        store.assignPlaylist(created, toScreen: "screen")
        store.removePlaylist(id: created)
        XCTAssertEqual(store.selectedPlaylistId, original)
        XCTAssertNil(store.assignedPlaylistId(forScreen: "screen"))
        XCTAssertEqual(store.savedPlaylists.count, 1)
        store.removePlaylist(id: original)
        XCTAssertEqual(store.savedPlaylists.count, 1, "The last usable playlist is retained")
        XCTAssertEqual(PlaylistStore(baseDirectory: directory).savedPlaylists.count, 1)
    }

    func testRemovingLibraryEntryCleansEverySavedListAndScreenSelection() throws {
        let directory = try directory()
        let store = PlaylistStore(baseDirectory: directory)
        let first = store.selectedPlaylistId
        var firstConfiguration = store.configuration
        firstConfiguration.ids = ["removed", "kept"]
        firstConfiguration.daytimeEnds = ["removed": 0.5, "kept": 1]
        store.configuration = firstConfiguration
        let second = store.createPlaylist(name: "Second")
        var secondConfiguration = store.configuration
        secondConfiguration.ids = ["removed", "other", "removed"]
        secondConfiguration.daytimeEnds = ["removed": 0.25, "other": 1]
        store.configuration = secondConfiguration
        store.assignPlaylist(first, toScreen: "first")
        store.assignPlaylist(second, toScreen: "second")
        store.currentByScreen = ["first": "removed", "second": "other"]
        store.remove("removed")
        XCTAssertEqual(store.configuration(for: "first").ids, ["kept"])
        XCTAssertEqual(store.configuration(for: "second").ids, ["other"])
        XCTAssertNil(store.configuration(for: "first").daytimeEnds["removed"])
        XCTAssertNil(store.configuration(for: "second").daytimeEnds["removed"])
        XCTAssertEqual(store.currentByScreen, ["second": "other"])
        let restored = PlaylistStore(baseDirectory: directory)
        XCTAssertEqual(restored.configuration(for: "first").ids, ["kept"])
        XCTAssertEqual(restored.currentByScreen, ["second": "other"])
    }

    func testUnsafeConfigurationValuesAreNormalizedBeforePersistence() throws {
        let directory = try directory()
        let store = PlaylistStore(baseDirectory: directory)
        var configuration = store.configuration
        configuration.delayMinutes = .nan
        configuration.transitionTimeMillis = -20
        configuration.ids = ["a"]
        configuration.daytimeEnds = ["a": 4, "orphan": 0.5]
        store.configuration = configuration
        XCTAssertEqual(store.configuration.delayMinutes, 30)
        XCTAssertEqual(store.configuration.transitionTimeMillis, 0)
        XCTAssertEqual(store.configuration.daytimeEnds, ["a": 1])
        configuration.delayMinutes = 0
        store.configuration = configuration
        XCTAssertEqual(store.configuration.delayMinutes, 0.01)
        configuration.delayMinutes = 1e100
        store.configuration = configuration
        XCTAssertEqual(store.configuration.delayMinutes, 525600)
        XCTAssertEqual(PlaylistStore(baseDirectory: directory).configuration.delayMinutes, 525600)
    }

    func testPartialRichSchemaDefaultsAndDuplicateIDsPreserveBothRecords() throws {
        let directory = try directory()
        let file = directory.appendingPathComponent("playlist.json")
        let data = Data(#"{"configurations":[{"id":"same","name":"First","ids":["a"],"mode":999},{"id":"same","name":"Second","delayMinutes":-1}],"selectedPlaylistId":"missing","assignments":{"known":"same","stale":"missing"}}"#.utf8)
        try data.write(to: file)
        let store = PlaylistStore(baseDirectory: directory)
        XCTAssertEqual(store.savedPlaylists.map(\.name), ["First", "Second"])
        XCTAssertEqual(Set(store.savedPlaylists.map(\.id)).count, 2)
        XCTAssertEqual(store.configuration.mode, .timer)
        XCTAssertEqual(store.configuration.delayMinutes, 30)
        XCTAssertEqual(store.savedPlaylists[1].delayMinutes, 0.01)
        XCTAssertEqual(store.assignedPlaylistId(forScreen: "known"), "same")
        XCTAssertNil(store.assignedPlaylistId(forScreen: "stale"))
        XCTAssertEqual(try Data(contentsOf: file), data, "Decoding does not rewrite a user's file")
    }
}
