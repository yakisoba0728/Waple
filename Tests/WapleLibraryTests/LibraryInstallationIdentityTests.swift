import XCTest
@testable import WapleLibrary

final class LibraryInstallationIdentityTests: XCTestCase {
    func testInstallationStateSurvivesReloadAndReimportButNotRemoval() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WapleInstallation-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("landscape", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = #"{"type":"web","file":"index.html","title":"Landscape"}"#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("project.json"))
        let libraryURL = root.appendingPathComponent("library", isDirectory: true)

        let first = try LibraryStore(baseDirectory: libraryURL).importFolder(folder)
        XCTAssertNotNil(first.installationID)
        let store = LibraryStore(baseDirectory: libraryURL)
        XCTAssertEqual(store.entries.first?.userStateID, first.userStateID)
        XCTAssertEqual(try store.importFolder(folder).userStateID, first.userStateID)

        XCTAssertTrue(store.remove(id: first.id))
        let next = try store.importFolder(folder)
        XCTAssertEqual(next.id, first.id)
        XCTAssertNotEqual(next.userStateID, first.userStateID)
    }

    func testLegacyEntryStillDecodesWithItsExistingStateID() throws {
        let json = #"{"id":"legacy","title":"Legacy","typeRaw":"scene","bookmark":"AA=="}"#
        let entry = try JSONDecoder().decode(LibraryEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.installationID)
        XCTAssertEqual(entry.userStateID, "legacy")
    }
}
