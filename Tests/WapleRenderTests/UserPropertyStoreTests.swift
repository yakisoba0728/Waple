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

    // MARK: - C①: project.json 기본값 계층(defaults < preset < user)

    /// 유저가 전혀 건드리지 않은 키는 project.json 기본값으로 해석돼야(종전엔 이 함수 자체가 없어
    /// SceneDocument.resolveUserBindings 가 baked scene.json 값을 그대로 남겼다).
    func testProjectDefaultsFillUnsetKeys() {
        let defaults: [WallpaperProperty] = [
            .init(key: "grain", type: "slider", value: .number(0), order: nil, condition: nil),
            .init(key: "tintcolor", type: "color", value: .string("0.8 0.4 0.05"), order: nil, condition: nil),
            .init(key: "showclock", type: "bool", value: .bool(true), order: nil, condition: nil),
        ]
        let raw = UserPropertyStore.rawOverrides(id: "upt1", projectDefaults: defaults,
                                                  presetOverrides: [:], presetResourceRoot: nil)
        XCTAssertEqual(raw["grain"] as? Double, 0)
        XCTAssertEqual(raw["tintcolor"] as? String, "0.8 0.4 0.05")
        XCTAssertEqual(raw["showclock"] as? Bool, true)
    }

    /// 계층: defaults < preset < user — 유저가 건드린 키는 defaults/preset 을 모두 이긴다.
    func testUserOverrideWinsOverProjectDefaultAndPreset() {
        UserPropertyStore.set(.number(0.9), key: "grain", id: "upt1")
        let defaults: [WallpaperProperty] = [
            .init(key: "grain", type: "slider", value: .number(0), order: nil, condition: nil),
        ]
        let raw = UserPropertyStore.rawOverrides(
            id: "upt1", projectDefaults: defaults,
            presetOverrides: ["grain": .number(0.5)], presetResourceRoot: nil)
        XCTAssertEqual(raw["grain"] as? Double, 0.9, "유저 값이 preset·defaults 를 모두 이겨야")
    }

    /// preset 은 defaults 를 이기지만 user 보다는 아래.
    func testPresetOverridesProjectDefaultButLosesToUser() {
        let defaults: [WallpaperProperty] = [
            .init(key: "grain", type: "slider", value: .number(0), order: nil, condition: nil),
        ]
        let raw = UserPropertyStore.rawOverrides(
            id: "upt1", projectDefaults: defaults,
            presetOverrides: ["grain": .number(0.5)], presetResourceRoot: nil)
        XCTAssertEqual(raw["grain"] as? Double, 0.5, "preset 이 project 기본값을 이겨야")
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

    // MARK: - F357: preset(신뢰 경계 밖) 절대경로 오버라이드는 허용목록에 편입되면 안 된다.
    // WebRenderer.userSelectedResourceOverrides 는 overrides(id:presetOverrides:...) 반환값에서
    // "/"로 시작하는 문자열을 전부 "사용자가 파일피커로 직접 선택"한 리소스로 취급한다. preset 값은
    // project.json 작성자(잠재적 악성 web 배경)가 제어하므로, 절대경로가 그대로 통과하면 randomFile/
    // fetchall 브릿지로 임의 경로의 파일 존재 여부·디렉터리 목록을 배경 JS 에 노출하게 된다.

    func testPresetAbsolutePathOverrideIsRejectedWithoutPresetRoot() {
        // root=nil(비-preset 타입 web 배경이 우연히 최상위 "preset" 키를 가진 경우 포함)도
        // 절대경로 preset 값을 무검증 통과시키면 안 된다.
        let overrides = UserPropertyStore.overrides(
            id: "upt1",
            presetOverrides: ["secret": .string("/etc/passwd")]
        )
        XCTAssertNil(overrides["secret"], "root 없는 배경도 절대경로 preset 값을 허용목록에 편입시키면 안 된다")
    }

    func testPresetAbsolutePathOverrideIsRejectedEvenWithPresetRoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("waple-preset-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let overrides = UserPropertyStore.overrides(
            id: "upt1",
            presetOverrides: ["secret": .string("/etc/passwd")],
            presetResourceRoot: root
        )
        XCTAssertNil(overrides["secret"], "preset root 가 있어도 절대경로 값은 폐기해야 한다")
    }

    func testPresetAbsolutePathOverrideRawFormAlsoRejected() {
        let raw = UserPropertyStore.rawOverrides(
            id: "upt1",
            presetOverrides: ["secret": .string("/etc/passwd")]
        )
        XCTAssertNil(raw["secret"], "raw 딕셔너리(씬 파서/JS 브릿지 경유)에서도 편입되면 안 된다")
    }

    func testGenuineUserSelectedAbsolutePathStillAllowed() {
        // 진짜 사용자 선택(속성 편집 UI 파일피커 → UserPropertyStore.set)은 presetOverrides 를
        // 거치지 않는 별도 경로(UserDefaults 저장)라 F357 수정의 영향을 받으면 안 된다.
        UserPropertyStore.set(.string("/Users/someone/Pictures/chosen.jpg"), key: "images", id: "upt1")
        let overrides = UserPropertyStore.overrides(id: "upt1", presetOverrides: [:])
        XCTAssertEqual(overrides["images"], .string("/Users/someone/Pictures/chosen.jpg"))
    }
}
