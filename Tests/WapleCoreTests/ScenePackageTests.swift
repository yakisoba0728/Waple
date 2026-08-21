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

        // [2026-08-21] 종전 이 줄의 근거는 "exact package path still wins" 였다. `.pkg` 백엔드에는
        // 이제 **접힌 색인 하나뿐**이라(WE 와 같다) 정확 일치도 같은 색인을 지난다 — 엔트리가
        // 하나뿐이므로 답은 같고, 이 단언이 재는 것은 "원문 철자로도 닿는다" 다.
        XCTAssertEqual(p.data(for: "Models\\Foo.JSON"), model)
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

    /// [2026-07-27 정정] "PKGV" 뒤 4자리는 포맷 버전이다 — 도수 곡선이 전형적 버전 채택 곡선이지
    /// per-file 난수 serial 이 아니다.
    ///
    /// **[2026-08-21 정정 — 인용 수치와 출처가 둘 다 틀렸다]** 종전 이 주석은 "로컬 코퍼스 **169개**,
    /// 0023×51/0022×47/0021×30/0024×12 … 롱테일 0001 등" 을 적고 근거로 `WE-2.8-deep-KR.md` 를 댔다.
    /// **그 파일은 이 저장소에도 시스템 어디에도 없고**(find 전역 0건), 정본
    /// `spec/formats/pkg.json` `format.pkg.magicDistribution` 의 값은 다르다 —
    /// 0023×50 · 0022×46 · 0021×28 · 0024×13 · 0020×6 · 0018×5 · 0019×5 · 0017×3 ·
    /// 0002/0007/0008/0011/0012/0016 각 ×1 = **distinct 14종 / 합계 162**(롱테일 최소값은 0001 이
    /// 아니라 **0002**). 같은 정정이 `ScenePackage.swift` 의 매직 주석에도 적혀 있다 — 두 자리가
    /// 갈리면 다음 사람이 낡은 쪽을 근거로 삼는다.
    ///
    /// "0000"·"0100" 을 수락한다고 이 값들이 실존 버전이라는 뜻은 아니다 — RePKG PackageReader.cs 가
    /// 매직을 버전 분기 없이 불투명 문자열로만 읽어 컨테이너 프레이밍이 관측된 모든 버전에서 불변이므로
    /// 파서가 값 범위를 게이트할 이유가 없다는 뜻이다(구조: "PKGV"+4 ASCII 숫자만 검증).
    /// **엔진은 반대로 `atoi(magic+4) > 24` 를 거부한다**(`0x140276964`) — 그 이탈은
    /// `ScenePackageWEParityTests.testNoVersionCeilingUnlikeWE` 가 따로 못 박는다.
    func testDoesNotGateOnVersionValue() {
        XCTAssertNoThrow(try ScenePackage.parse(Self.makePkg([], version: "PKGV0000")))
        XCTAssertNoThrow(try ScenePackage.parse(Self.makePkg([], version: "PKGV0100")))
        XCTAssertNoThrow(try ScenePackage.parse(Self.makePkg([], version: "PKGV9999")))
    }
}
