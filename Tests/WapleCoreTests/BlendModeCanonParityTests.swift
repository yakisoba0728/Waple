import XCTest
@testable import WapleCore

/// CJ: `spec/engine/blend-modes.json` 정본이 **동봉 원본 헤더와 갈리지 않는지** 본다.
///
/// 왜 필요한가 — 방법론 함정 23("구현만 고치면 정본이 낡아 다음 사람이 되돌린다")과 그 역이다.
/// `scripts/spec/measure_blend_modes.py` 는 **`WE_ROOT` 가 있어야만** 돌기 때문에(에디터
/// 드롭다운을 바이너리에서 뜬다) 이 컨테이너와 CI 에서는 재생성으로 낡음을 잡을 수 없다.
/// `check_canon_generator_keys.py`/`…_values.py` 는 생성기의 **리터럴**만 대조하고, 드롭다운
/// 표처럼 런타임에 계산되는 값은 못 본다.
///
/// 그래서 코퍼스 없이도 대조 가능한 축 — **동봉 헤더에서 파스되는 사실** — 만 여기서 잠근다.
/// 정본이 손으로 고쳐지거나 생성기가 바뀌어 헤더와 어긋나면 리눅스 CI 에서 붉어진다.
final class BlendModeCanonParityTests: XCTestCase {

    /// 정본을 찾는다(심링크 규약은 `MediaPlaybackCanonTests.canonURL` 과 같다 —
    /// `linux-core-tests.sh` 가 테스트 소스를 심링크로 걸기 때문에 먼저 푼다).
    private static func canonURL() -> URL? {
        let fm = FileManager.default
        let here = (try? fm.destinationOfSymbolicLink(atPath: #filePath)) ?? #filePath
        var dir = URL(fileURLWithPath: here).deletingLastPathComponent()
        for _ in 0..<8 {
            let cand = dir.appendingPathComponent("spec/engine/blend-modes.json")
            if fm.fileExists(atPath: cand.path) { return cand }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func entries() throws -> [String: (status: String, value: [String: Any])] {
        guard let url = Self.canonURL() else {
            throw XCTSkip("spec/engine/blend-modes.json 미배치")
        }
        let raw = try Data(contentsOf: url)
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let list = try XCTUnwrap(doc["entries"] as? [[String: Any]])
        var out: [String: (status: String, value: [String: Any])] = [:]
        for e in list {
            guard let id = e["id"] as? String, let status = e["status"] as? String else { continue }
            out[id] = (status, (e["value"] as? [String: Any]) ?? [:])
        }
        return out
    }

    private func header() throws -> String {
        let fm = FileManager.default
        guard let r = bundledWEAssetsRoot() else { throw XCTSkip("WEAssets 미배치") }
        let url = r.appendingPathComponent("shaders/common_blending.h")
        guard fm.fileExists(atPath: url.path) else { throw XCTSkip("동봉 common_blending.h 없음") }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 정본의 `noOpacity` 목록이 **원본 헤더에서 파스한 것과 같은가.**
    /// (헤더의 팔이 `return mix(A,…,opacity)` 가 아닌 모드 = opacity 를 안 쓰는 모드.)
    func testOpacityApplicationMatchesTheOriginalHeader() throws {
        let arms = BlendModeFormulaParityTests.originalArms(header: try header())
        let fromHeader = Set(arms.filter { !$0.value.hasPrefix("return mix(A,") }.keys)
        let mixFromHeader = Set(arms.keys).subtracting(fromHeader)

        let all = try entries()
        let e = try XCTUnwrap(all["blend.opacityApplication"], "blend.opacityApplication 이 사라졌다")
        XCTAssertEqual(e.status, "확정")
        let none = try XCTUnwrap(e.value["opacity 무시(즉시 return)"] as? [Int])
        let mix = try XCTUnwrap(e.value["mix 적용"] as? [Int])
        XCTAssertEqual(Set(none), fromHeader,
                       "정본의 opacity 무시 목록이 헤더와 다르다 — 정본 \(none.sorted()) · 헤더 \(fromHeader.sorted())")
        XCTAssertEqual(Set(mix), mixFromHeader,
                       "정본의 mix 적용 목록이 헤더와 다르다")
    }

    /// 드롭다운 표의 정수 도메인이 **0…32** 이고, 헤더의 `#if` 집합(1…32)에 0 을 더한 것과 같은가.
    func testEditorDropdownDomainMatchesTheHeaderPlusZero() throws {
        let arms = BlendModeFormulaParityTests.originalArms(header: try header())
        let expected = Set(arms.keys).union([0])          // 0 은 fallthrough 가 담당한다

        let all = try entries()
        let e = try XCTUnwrap(all["blend.editorDropdown"], "blend.editorDropdown 이 사라졌다")
        XCTAssertEqual(e.status, "확정")
        let table = try XCTUnwrap(e.value["값→UI라벨"] as? [String: String])
        let domain = Set(table.keys.compactMap { Int($0) })
        XCTAssertEqual(domain.count, table.count, "드롭다운 표의 키에 정수가 아닌 것이 있다")
        XCTAssertEqual(domain, expected,
                       "드롭다운 도메인이 헤더 + 0 과 다르다 — 정본 \(domain.sorted()) · 기대 \(expected.sorted())")
        XCTAssertEqual(e.value["항목수"] as? Int, expected.count)
        // UI 이름은 전건 비어 있지 않고 서로 다르다(라벨이 밀리면 중복이 생긴다 — 함정 16 의 그물).
        XCTAssertFalse(table.values.contains(where: { $0.isEmpty }), "빈 라벨이 있다")
        XCTAssertEqual(Set(table.values).count, table.count,
                       "라벨이 중복이다 — 짝이 한 칸 밀렸을 때 나오는 양상이다")
    }

    /// native/emulated 가 도메인을 **정확히 이분**하는가. 그리고 native 가 엔진 고속 경로와 같은가.
    ///
    /// native 집합을 리터럴로 적는다 — 이 값은 헤더가 아니라 **바이너리**에서 온 사실이고
    /// (`bin/wallpaperui.exe` 0x14016007e / 0x1401600f3 사이), 그 자리가 바뀌면 정본과 이 단언이
    /// 함께 붉어져야 한다. 근거·재현은 `docs/re/material-blend.md` §7.6.3.
    func testNativeAndEmulatedPartitionTheDomain() throws {
        let all = try entries()
        let e = try XCTUnwrap(all["blend.nativeVsEmulated"], "blend.nativeVsEmulated 가 사라졌다")
        XCTAssertEqual(e.status, "확정")
        let native = Set(try XCTUnwrap(e.value["native"] as? [Int]))
        let emulated = Set(try XCTUnwrap(e.value["emulated"] as? [Int]))
        XCTAssertEqual(native, [0, 31],
                       "native 그룹이 {0, 31} 이 아니다: \(native.sorted()) — 엔진 고속 경로와 갈렸다")
        XCTAssertTrue(native.isDisjoint(with: emulated), "native 와 emulated 가 겹친다")
        XCTAssertEqual(native.union(emulated), Set(0...32),
                       "두 그룹의 합이 0…32 가 아니다: \(native.union(emulated).sorted())")
    }

    /// 이름이 갈리는 일곱 자리 — UI 이름과 매크로 이름이 다르다는 사실 자체를 잠근다.
    /// (함정 27: 매크로 이름만 인용하면 저작자 의도를 오독한다. 특히 `add` = 31, `subtract` = 20.)
    func testUiNamesThatDivergeFromMacroNames() throws {
        let all = try entries()
        let e = try XCTUnwrap(all["blend.editorDropdown"])
        let table = try XCTUnwrap(e.value["값→UI라벨"] as? [String: String])
        XCTAssertEqual(table["31"], "add", "UI 의 Add 는 31 이다(9 가 아니다)")
        XCTAssertEqual(table["9"], "linear_dodge", "모드 9(BlendAdd)의 UI 이름은 linear_dodge 다")
        XCTAssertEqual(table["4"], "linear_burn", "모드 4(BlendSubstract)의 UI 이름은 linear_burn 이다")
        XCTAssertEqual(table["20"], "subtract", "UI 의 Subtract 는 20 이고 식은 4 와 같다")
        XCTAssertEqual(table["5"], "darker_color")
        XCTAssertEqual(table["10"], "lighter_color")
        XCTAssertEqual(table["32"], "diffuse_light")
    }
}
