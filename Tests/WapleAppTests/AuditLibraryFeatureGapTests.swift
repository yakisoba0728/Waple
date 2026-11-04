import XCTest
@testable import Waple
import WapleCore
import WapleLibrary
import UniformTypeIdentifiers

final class AuditLibraryFeatureGapTests: XCTestCase {
    func testAuthoredFractionalSliderMetadataDrivesDisplayedAndCommittedValue() throws {
        let property = try XCTUnwrap(WallpaperProperties.parse(generalProperties: [
            "amount": ["type": "slider", "value": 0.4, "min": 0, "max": 1,
                       "fraction": true, "precision": 2, "step": 0.1]
        ]).first)
        let control = PropertySliderConfiguration(property)
        XCTAssertEqual(property.precision, 2)
        XCTAssertEqual(property.fraction, true)
        XCTAssertEqual(control.step, 0.1)
        XCTAssertEqual(control.decimalPlaces, 1)
        XCTAssertEqual(control.formattedValue(0.4), "0.4")
        let committed = control.committedValue(0.46)
        XCTAssertEqual(committed, 0.5, accuracy: 0.000001)
        let edited = WallpaperProperties.applying(overrides: ["amount": .number(committed)], to: [property])
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(WallpaperProperties.weUserPropertiesJSON(edited).utf8)) as? [String: [String: Any]])
        XCTAssertEqual(payload["amount"]?["value"] as? Double, 0.5)
    }

    func testIntegerSliderUsesUnitStepsAndClampsValues() throws {
        let property = try XCTUnwrap(WallpaperProperties.parse(generalProperties: [
            "count": ["type": "slider", "value": 3, "min": 0, "max": 10, "fraction": false]
        ]).first)
        let control = PropertySliderConfiguration(property)
        XCTAssertEqual(control.step, 1)
        XCTAssertEqual(control.committedValue(3.7), 4)
        XCTAssertEqual(control.formattedValue(4), "4")
        XCTAssertEqual(control.committedValue(50), 10)
        XCTAssertEqual(control.committedValue(-5), 0)
        XCTAssertEqual(control.committedValue(.nan), 0)
    }

    func testSliderInvalidMetadataCannotProduceAnInvalidControlRange() throws {
        let property = try XCTUnwrap(WallpaperProperties.parse(generalProperties: [
            "amount": ["type": "slider", "value": 1, "min": 5, "max": -1,
                       "step": -0.1, "fraction": true, "precision": 900]
        ]).first)
        let control = PropertySliderConfiguration(property)
        XCTAssertTrue(control.range.lowerBound.isFinite)
        XCTAssertTrue(control.range.upperBound.isFinite)
        XCTAssertGreaterThan(control.range.upperBound, control.range.lowerBound)
        XCTAssertEqual(control.decimalPlaces, 3)
        XCTAssertEqual(control.step, 0.001)
        XCTAssertEqual(control.committedValue(.infinity), control.range.lowerBound)
    }

    func testFileTypeMetadataRestrictsSelectedResourceWithoutChangingItsValue() throws {
        let properties = WallpaperProperties.parse(generalProperties: [
            "image": ["type": "file", "value": "old.png", "fileType": "image"],
            "movie": ["type": "file", "value": "old.mov", "fileType": "video"],
            "any": ["type": "scenetexture", "value": "old.tex"]
        ])
        let image = try XCTUnwrap(properties.first { $0.key == "image" })
        let movie = try XCTUnwrap(properties.first { $0.key == "movie" })
        let any = try XCTUnwrap(properties.first { $0.key == "any" })
        let imageURL = URL(fileURLWithPath: "/tmp/fixture.png")
        let movieURL = URL(fileURLWithPath: "/tmp/fixture.mov")
        XCTAssertEqual(PropertyResourceSelection.allowedContentTypes(for: image), [.image])
        XCTAssertEqual(PropertyResourceSelection.allowedContentTypes(for: movie), [.movie])
        XCTAssertTrue(PropertyResourceSelection.accepts(imageURL, for: image))
        XCTAssertFalse(PropertyResourceSelection.accepts(movieURL, for: image))
        XCTAssertTrue(PropertyResourceSelection.accepts(movieURL, for: movie))
        XCTAssertFalse(PropertyResourceSelection.accepts(imageURL, for: movie))
        XCTAssertTrue(PropertyResourceSelection.accepts(URL(fileURLWithPath: "/tmp/fixture.tex"), for: any))
        XCTAssertFalse(PropertyResourceSelection.accepts(URL(string: "https://example.invalid/image.png")!, for: image))
        XCTAssertEqual(image.value, .string("old.png"))
    }

    func testHiddenGroupHidesItsChildrenButKeepsRuntimeValuesAndNextGroup() throws {
        let properties = WallpaperProperties.parse(generalProperties: [
            "enabled": ["type": "bool", "value": false, "order": 0],
            "hidden": ["type": "group", "text": "Hidden", "condition": "enabled.value", "order": 1],
            "secret": ["type": "slider", "value": 0.75, "order": 2],
            "shown": ["type": "group", "text": "Shown", "order": 3],
            "amount": ["type": "slider", "value": 0.25, "order": 4]
        ])
        let sections = PropertyGrouping.sections(in: properties,
            visible: PropertyDecoration.visibleIndices(in: properties))
        let displayed = sections.flatMap(\.rows).map { properties[$0].key }
        XCTAssertEqual(displayed, ["enabled", "amount"])
        XCTAssertEqual(sections.compactMap(\.title).map { properties[$0].key }, ["shown"])
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(WallpaperProperties.weUserPropertiesJSON(properties).utf8)) as? [String: [String: Any]])
        XCTAssertEqual(payload["secret"]?["value"] as? Double, 0.75)
        let enabled = WallpaperProperties.applying(overrides: ["enabled": .bool(true)], to: properties)
        let revealed = PropertyGrouping.sections(in: enabled,
            visible: PropertyDecoration.visibleIndices(in: enabled))
        XCTAssertEqual(revealed.flatMap(\.rows).map { enabled[$0].key }, ["enabled", "secret", "amount"])
    }

    func testGroupOwnsDisplayOnlyNotesUntilTheNextExplicitGroup() {
        let properties = WallpaperProperties.parse(generalProperties: [
            "group": ["type": "group", "text": "Group", "order": 0],
            "note": ["type": "label", "text": "Note", "order": 1],
            "amount": ["type": "slider", "value": 0.5, "order": 2]
        ])
        let sections = PropertyGrouping.sections(in: properties,
            visible: PropertyDecoration.visibleIndices(in: properties))
        XCTAssertEqual(sections, [PropertySection(title: 0, rows: [1, 2])])
    }

    func testVolumePropertyParsesNumericStringsAndUsesASlider() throws {
        let property = try XCTUnwrap(WallpaperProperties.parse(generalProperties: [
            "volume": ["type": "volume", "value": "42", "min": 0, "max": 100]
        ]).first)
        XCTAssertEqual(property.value, .number(42))
        XCTAssertEqual(PropertyControl.kind(forType: property.type), .slider)
        let control = PropertySliderConfiguration(property)
        XCTAssertEqual(control.range, 0...100)
        XCTAssertEqual(control.committedValue(42.4), 42)
    }

    func testRawNonNativeVideosAreCopiedIntoImportableVideoProjects() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for ext in ["webm", "mkv", "avi"] {
            let source = directory.appendingPathComponent("fixture.\(ext)")
            let bytes = Data([0, 1, 2, 3])
            try bytes.write(to: source)
            XCTAssertTrue(VideoImport.isVideoFile(source))
            let prepared = try XCTUnwrap(VideoImport.prepare(from: source, baseDirectory: directory))
            let project = try ProjectJSONParser.parse(folderURL: prepared)
            XCTAssertEqual(project.type, .video)
            XCTAssertEqual(project.fileName, source.lastPathComponent)
            let copied = try XCTUnwrap(WallpaperPathSecurity.containedFileURL(project.fileName, root: prepared))
            try FileManager.default.removeItem(at: source)
            XCTAssertEqual(try Data(contentsOf: copied), bytes)
            let entry = try LibraryStore(baseDirectory: directory).importFolder(prepared)
            XCTAssertEqual(entry.typeRaw, "video")
        }
        let unsupported = directory.appendingPathComponent("fixture.txt")
        try Data([0]).write(to: unsupported)
        XCTAssertFalse(VideoImport.isVideoFile(unsupported))
        XCTAssertNil(VideoImport.prepare(from: unsupported, baseDirectory: directory))
    }

    func testLibraryRemovalRequestsResourceCleanupForOnlyTheRemovedIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LibraryStore(baseDirectory: directory)
        for _ in 0..<2 {
            let folder = directory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(#"{"type":"scene","file":"scene.pkg","title":"Fixture"}"#.utf8)
                .write(to: folder.appendingPathComponent("project.json"))
            _ = try store.importFolder(folder)
        }
        let viewModel = LibraryViewModel(store: store,
            playlist: PlaylistStore(baseDirectory: directory),
            monitors: MonitorAssignmentStore(baseDirectory: directory),
            favorites: FavoritesStore(baseDirectory: directory), folders: FolderStore(baseDirectory: directory))
        let removed = store.entries[0]
        let neighbor = store.entries[1]
        var cleanup: [String] = []
        viewModel.onRemoveScriptStorage = { cleanup.append($0) }
        viewModel.remove(removed)
        XCTAssertEqual(cleanup, [removed.id])
        XCTAssertEqual(viewModel.entries.map(\.id), [neighbor.id])
    }


    func testShortcutBindingRequiresUserChoiceAndOnlyDeclaredNamesCanOpenThroughAFakeOpener() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = #"{"type":"scene","file":"scene.pkg","general":{"properties":{"launch":{"type":"usershortcut","value":"/bin/sh","isbound":true,"commandtype":"shell","file":"/bin/sh"},"text":{"type":"textinput","value":""}}}}"#
        try Data(project.utf8).write(to: folder.appendingPathComponent("project.json"))
        let store = LibraryStore(baseDirectory: directory)
        let entry = try store.importFolder(folder)
        let vm = LibraryViewModel(store: store, playlist: PlaylistStore(baseDirectory: directory),
            monitors: MonitorAssignmentStore(baseDirectory: directory), favorites: FavoritesStore(baseDirectory: directory),
            folders: FolderStore(baseDirectory: directory))
        XCTAssertTrue(vm.shortcutBindings(for: entry.id).isEmpty, "Authored commands are never auto-bound")
        let chosen = URL(string: "https://example.invalid/user-choice")!
        XCTAssertFalse(vm.setShortcutBinding(chosen, propertyKey: "text", for: entry))
        XCTAssertFalse(vm.setShortcutBinding(chosen, propertyKey: "missing", for: entry))
        XCTAssertTrue(vm.setShortcutBinding(chosen, propertyKey: "launch", for: entry))
        var opened: [URL] = []
        let fakeOpener: (URL) -> Void = { opened.append($0) }
        if let selected = vm.shortcutBindings(for: entry.id)["launch"] { fakeOpener(selected) }
        XCTAssertEqual(opened, [chosen])
        XCTAssertTrue(vm.shortcutBindings(for: "other-entry").isEmpty)
        XCTAssertTrue(vm.setShortcutBinding(nil, propertyKey: "launch", for: entry))
        XCTAssertTrue(vm.shortcutBindings(for: entry.id).isEmpty)
        XCTAssertTrue(vm.setShortcutBinding(chosen, propertyKey: "launch", for: entry))
        vm.resetProperties(for: entry)
        XCTAssertTrue(vm.shortcutBindings(for: entry.id).isEmpty, "Reset returns the shortcut to unbound")
    }

}
