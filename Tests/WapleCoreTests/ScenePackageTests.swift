import XCTest
@testable import WapleCore

final class ScenePackageTests: XCTestCase {
    /// 포맷대로 합성 .pkg 바이트 생성.
    static func makePkg(_ files: [(String, Data)], version: String = "PKGV0001") -> Data {
        func i32(_ v: Int) -> [UInt8] {
            let u = UInt32(truncatingIfNeeded: v)
            return [UInt8(u & 0xff), UInt8((u >> 8) & 0xff), UInt8((u >> 16) & 0xff), UInt8((u >> 24) & 0xff)]
        }
        let ver = Array(version.utf8)
        var out = i32(ver.count) + ver + i32(files.count)
        var offset = 0
        for (name, data) in files {
            let nm = Array(name.utf8)
            out += i32(nm.count) + nm + i32(offset) + i32(data.count)
            offset += data.count
        }
        for (_, data) in files { out += [UInt8](data) }
        return Data(out)
    }

    func testParsesEntriesAndExtractsData() throws {
        let scene = Data(#"{"version":1}"#.utf8)
        let mat = Data("MAT".utf8)
        let pkg = Self.makePkg([("scene.json", scene), ("materials/x.json", mat)])
        let p = try ScenePackage.parse(pkg)
        XCTAssertEqual(p.entries.map(\.name), ["scene.json", "materials/x.json"])
        XCTAssertEqual(p.data(for: "scene.json"), scene)
        XCTAssertEqual(p.data(for: "materials/x.json"), mat)
        XCTAssertNil(p.data(for: "nope"))
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try ScenePackage.parse(Data([0x08, 0x00]))) { e in
            XCTAssertEqual(e as? ScenePackageError, .malformed)
        }
    }
}
