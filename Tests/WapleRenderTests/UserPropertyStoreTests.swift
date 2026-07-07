import XCTest
@testable import WapleCore
@testable import WapleRender

final class UserPropertyStoreTests: XCTestCase {
    override func tearDown() { UserPropertyStore.reset(id: "upt1"); super.tearDown() }

    func testRoundTripAndReset() {
        XCTAssertTrue(UserPropertyStore.overrides(id: "upt1").isEmpty)
        UserPropertyStore.set(.bool(false), key: "on", id: "upt1")
        UserPropertyStore.set(.number(2.5), key: "amt", id: "upt1")
        UserPropertyStore.set(.string("1 0 0"), key: "tint", id: "upt1")
        let o = UserPropertyStore.overrides(id: "upt1")
        XCTAssertEqual(o["on"], .bool(false))
        XCTAssertEqual(o["amt"], .number(2.5))
        XCTAssertEqual(o["tint"], .string("1 0 0"))
        // 씬 파서용 raw 딕셔너리
        let raw = UserPropertyStore.rawOverrides(id: "upt1")
        XCTAssertEqual(raw["on"] as? Bool, false)
        XCTAssertEqual(raw["amt"] as? Double, 2.5)
        UserPropertyStore.reset(id: "upt1")
        XCTAssertTrue(UserPropertyStore.overrides(id: "upt1").isEmpty)
    }

    func testPresetOverridesMergeBeforeUserOverrides() {
        UserPropertyStore.set(.number(0.9), key: "amount", id: "upt1")

        let overrides = UserPropertyStore.overrides(
            id: "upt1",
            presetOverrides: [
                "amount": .number(0.25),
                "enabled": .bool(true),
                "name": .string("Preset")
            ]
        )

        XCTAssertEqual(overrides["amount"], .number(0.9))
        XCTAssertEqual(overrides["enabled"], .bool(true))
        XCTAssertEqual(overrides["name"], .string("Preset"))
    }

    func testPresetRawOverridesMergeBeforeUserOverrides() {
        UserPropertyStore.set(.string("User"), key: "name", id: "upt1")

        let raw = UserPropertyStore.rawOverrides(
            id: "upt1",
            presetOverrides: [
                "enabled": .bool(false),
                "amount": .number(0.5),
                "name": .string("Preset")
            ]
        )

        XCTAssertEqual(raw["enabled"] as? Bool, false)
        XCTAssertEqual(raw["amount"] as? Double, 0.5)
        XCTAssertEqual(raw["name"] as? String, "User")
    }

    func testPresetRelativeResourceOverridesResolveAgainstPresetRoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple-preset-root-\(UUID().uuidString)", isDirectory: true)
        let files = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = files.appendingPathComponent("yeezus.jpg")
        try Data([1, 2, 3]).write(to: image)

        let raw = UserPropertyStore.rawOverrides(
            id: "upt1",
            presetOverrides: ["customimage": .string("files/yeezus.jpg"), "host": .string("franGMZ")],
            presetResourceRoot: root
        )

        XCTAssertEqual(raw["customimage"] as? String, image.path)
        XCTAssertEqual(raw["host"] as? String, "franGMZ")
    }
}
