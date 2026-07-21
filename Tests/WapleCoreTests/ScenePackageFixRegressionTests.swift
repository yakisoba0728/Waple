import XCTest
@testable import WapleCore

/// ScenePackage 중복 엔트리 first-wins 규약 잠금 — 인덱스 구축이 선행자 유지(exact/normalized 모두
/// `if index[name] == nil`, ScenePackage.swift:24,29)로 구현된 의도된 디듑이다. last-wins 로 회귀하면
/// data(for:) 의 에셋 선택이 바뀌는데 기존 테스트는 중복 엔트리를 다루지 않아 전부 녹색이었다.
final class ScenePackageFixRegressionTests: XCTestCase {
    /// exact 인덱스: 동일 이름이 두 번 등장하면 첫 엔트리가 이긴다.
    func testDuplicateExactNamesKeepFirstEntry() {
        let first = Data("FIRST".utf8), second = Data("SECOND".utf8)
        let pkg = ScenePackage.assemble([(name: "a/b.json", data: first),
                                         (name: "a/b.json", data: second)])
        XCTAssertEqual(pkg.data(for: "a/b.json"), first, "중복 exact 이름은 선행 엔트리 유지(first-wins)")
    }

    /// normalized 인덱스: 대소문자/백슬래시 정규화 후 충돌이 생겨도 첫 엔트리가 이긴다
    /// (exact 일치가 normalized 조회보다 우선하는 기존 규약은 유지).
    func testDuplicateNormalizedNamesKeepFirstEntry() {
        let first = Data("FIRST".utf8), second = Data("SECOND".utf8)
        let pkg = ScenePackage.assemble([(name: #"Models\A.JSON"#, data: first),
                                         (name: "models/a.json", data: second)])
        XCTAssertEqual(pkg.data(for: "models/a.json"), second, "exact 일치는 normalized 조회보다 우선")
        XCTAssertEqual(pkg.data(for: "MODELS/A.JSON"), first,
                       "정규화 키 충돌은 선행 엔트리 유지(first-wins)")
    }
}
