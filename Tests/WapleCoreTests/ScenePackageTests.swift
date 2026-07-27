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

    func testRejectsInvalidMagic() {
        XCTAssertThrowsError(try ScenePackage.parse(Self.makePkg([], version: "PKGX0001"))) { e in
            XCTAssertEqual(e as? ScenePackageError, .malformed)
        }
        XCTAssertThrowsError(try ScenePackage.parse(Self.makePkg([], version: "PKGVXYZ1"))) { e in
            XCTAssertEqual(e as? ScenePackageError, .malformed)
        }
        XCTAssertThrowsError(try ScenePackage.parse(Self.makePkg([], version: "pkgv0001"))) { e in
            XCTAssertEqual(e as? ScenePackageError, .malformed)
        }
    }

    func testAcceptsKnownVersions() {
        XCTAssertNoThrow(try ScenePackage.parse(Self.makePkg([], version: "PKGV0001")))
        XCTAssertNoThrow(try ScenePackage.parse(Self.makePkg([], version: "PKGV0002")))
        XCTAssertNoThrow(try ScenePackage.parse(Self.makePkg([], version: "PKGV0024")))
    }

    /// [2026-07-27 정정] "PKGV" 뒤 4자리는 포맷 버전이다(로컬 코퍼스 169개 scene.pkg 매직 도수분포 —
    /// distinct 14값, 0023×51/0022×47/0021×30/0024×12 … 롱테일 0001·0007·0008·0011·0012 각 1건 —
    /// 는 전형적 버전 채택 곡선이지 per-file 난수 serial 이 아니다; WE-2.8-deep-KR.md B1 과 일치).
    /// "0000"·"0100" 을 수락한다고 이 값들이 실존 버전이라는 뜻은 아니다 — RePKG PackageReader.cs 가
    /// 매직을 버전 분기 없이 불투명 문자열로만 읽어 컨테이너 프레이밍이 관측된 모든 버전에서 불변이므로
    /// 파서가 값 범위를 게이트할 이유가 없다는 뜻이다(구조: "PKGV"+4 ASCII 숫자만 검증).
    func testDoesNotGateOnVersionValue() {
        XCTAssertNoThrow(try ScenePackage.parse(Self.makePkg([], version: "PKGV0000")))
        XCTAssertNoThrow(try ScenePackage.parse(Self.makePkg([], version: "PKGV0100")))
        XCTAssertNoThrow(try ScenePackage.parse(Self.makePkg([], version: "PKGV9999")))
    }
}
