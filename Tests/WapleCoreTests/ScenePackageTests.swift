import XCTest
@testable import WapleCore

final class ScenePackageTests: XCTestCase {
    /// 포맷대로 합성 .pkg 바이트 생성.
    static func makePkg(_ files: [(String, Data)], version: String = "PKGV0001") -> Data {
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

    func testDataLookupFallsBackToCaseInsensitiveWindowsSeparators() throws {
        let model = Data(#"{"material":"materials/Foo.json"}"#.utf8)
        let pkg = Self.makePkg([("Models\\Foo.JSON", model)])
        let p = try ScenePackage.parse(pkg)

        XCTAssertEqual(p.data(for: "Models\\Foo.JSON"), model, "exact package path still wins")
        XCTAssertEqual(p.data(for: "models/foo.json"), model)
        XCTAssertEqual(p.data(for: "models\\foo.json"), model)
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try ScenePackage.parse(Data([0x08, 0x00]))) { e in
            XCTAssertEqual(e as? ScenePackageError, .malformed)
        }
    }

    /// 헤더는 정상 파싱되지만 엔트리 size 가 blob 끝을 넘어가면 거부돼야 한다(entry-bounds loop).
    func testRejectsEntryExtendingPastBlob() {
        let ver = Array("PKGV0001".utf8)
        let nm = Array("a.json".utf8)
        let body = Array("HI".utf8)  // 실제 2바이트
        // 헤더는 정상이나 엔트리 size 를 999 로 선언 → blobBase+0+999 > b.count
        var out = i32(ver.count) + ver + i32(1)
        out += i32(nm.count) + nm + i32(0) + i32(999)
        out += body
        XCTAssertThrowsError(try ScenePackage.parse(Data(out))) { e in
            XCTAssertEqual(e as? ScenePackageError, .malformed)
        }
    }

    func testRejectsExcessiveEntryCount() {
        let files = (0..<65_537).map { ("e\($0)", Data()) }
        XCTAssertThrowsError(try ScenePackage.parse(Self.makePkg(files))) { e in
            XCTAssertEqual(e as? ScenePackageError, .malformed)
        }
    }
}
