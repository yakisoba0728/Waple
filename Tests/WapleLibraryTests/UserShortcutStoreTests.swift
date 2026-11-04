import XCTest
import WapleLibrary

final class UserShortcutStoreTests: XCTestCase {
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

    private func application(in directory: URL) throws -> URL {
        let application = directory.appendingPathComponent("Fixture.app", isDirectory: true)
        let contents = application.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "test.waple.fixture",
                                   "CFBundleName": "Fixture", "CFBundleExecutable": "Fixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return application
    }

    func testUserSelectedTargetsRoundTripWithinEntryAndPropertyNamespaces() throws {
        let directory = try directory()
        let app = try application(in: directory)
        let web = URL(string: "https://example.invalid/chosen")!
        let store = UserShortcutStore(baseDirectory: directory)
        XCTAssertTrue(store.bindings(for: "entry-a").isEmpty)
        try store.set(app, propertyKey: "open", entryID: "entry-a")
        try store.set(web, propertyKey: "open", entryID: "entry-b")
        try store.set(web, propertyKey: "other", entryID: "entry-a")
        let restored = UserShortcutStore(baseDirectory: directory)
        XCTAssertEqual(restored.bindings(for: "entry-a")["open"]?.kind, .application)
        XCTAssertEqual(restored.bindings(for: "entry-a")["open"]?.targetURL, app.resolvingSymlinksInPath().standardizedFileURL)
        XCTAssertEqual(restored.bindings(for: "entry-b")["open"]?.kind, .web)
        try restored.set(nil, propertyKey: "open", entryID: "entry-a")
        XCTAssertNil(restored.bindings(for: "entry-a")["open"])
        XCTAssertNotNil(restored.bindings(for: "entry-a")["other"])
        try restored.remove(entryID: "entry-a")
        XCTAssertTrue(restored.bindings(for: "entry-a").isEmpty)
        XCTAssertEqual(UserShortcutStore(baseDirectory: directory).bindings(for: "entry-b")["open"]?.targetURL, web)
    }

    func testShellSchemesCredentialsAndNonApplicationFilesCannotBecomeBindings() throws {
        let directory = try directory()
        let script = directory.appendingPathComponent("fixture.command")
        try Data("exit 0".utf8).write(to: script)
        let store = UserShortcutStore(baseDirectory: directory)
        for url in [script, URL(string: "javascript:alert(1)")!, URL(string: "ftp://example.invalid/file")!,
                    URL(string: "https://user:password@example.invalid/")!,
                    directory.appendingPathComponent("Missing.app"), URL(string: "relative-target")!] {
            XCTAssertThrowsError(try store.set(url, propertyKey: "open", entryID: "entry"))
        }
        XCTAssertTrue(store.bindings(for: "entry").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("user-shortcuts.json").path))
    }

    func testMissingOrReplacedApplicationIsUnboundAtLookup() throws {
        let directory = try directory()
        let app = try application(in: directory)
        let store = UserShortcutStore(baseDirectory: directory)
        try store.set(app, propertyKey: "open", entryID: "entry")
        XCTAssertNotNil(store.bindings(for: "entry")["open"])
        try FileManager.default.removeItem(at: app)
        XCTAssertNil(store.bindings(for: "entry")["open"])
        try Data([0, 1]).write(to: app)
        XCTAssertNil(UserShortcutStore(baseDirectory: directory).bindings(for: "entry")["open"])
    }

    func testCorruptShortcutFileIsBackedUpBeforeAUserBindingIsSaved() throws {
        let directory = try directory()
        let file = directory.appendingPathComponent("user-shortcuts.json")
        let invalid = Data("not json".utf8)
        try invalid.write(to: file)
        let store = UserShortcutStore(baseDirectory: directory)
        XCTAssertTrue(store.bindings(for: "entry").isEmpty)
        try store.set(URL(string: "https://example.invalid/")!, propertyKey: "open", entryID: "entry")
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("user-shortcuts.json.corrupt") })
        XCTAssertEqual(try Data(contentsOf: backup), invalid)
        XCTAssertEqual(UserShortcutStore(baseDirectory: directory).bindings(for: "entry")["open"]?.kind, .web)
    }
}
