import XCTest
@testable import WapleCore

final class PuppetModelTests: XCTestCase {
    /// 실측 MDLV0013 레이아웃대로 합성 바이트 구성(설계 문서 참조).
    private func makeMDL(material: String, verts: [(SIMD3<Float>, SIMD4<UInt32>, SIMD4<Float>, SIMD2<Float>)],
                         indices: [UInt16]) -> Data {
        var d = Data("MDLV0013".utf8)
        d.append(Data([0x00, 0x09, 0x00, 0x80, 0x01, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00]))  // 13B 헤더
        d.append(Data(material.utf8)); d.append(0)
        var zero = UInt32(0); withUnsafeBytes(of: &zero) { d.append(contentsOf: $0) }   // 용도 미상 u32(0)
        var vsize = UInt32(verts.count * 52); withUnsafeBytes(of: &vsize) { d.append(contentsOf: $0) }
        for (pos, bi, w, uv) in verts {
            var p = pos; withUnsafeBytes(of: &p) { d.append(contentsOf: $0.prefix(12)) }
            var b = bi; withUnsafeBytes(of: &b) { d.append(contentsOf: $0) }
            var ww = w; withUnsafeBytes(of: &ww) { d.append(contentsOf: $0) }
            var u = uv; withUnsafeBytes(of: &u) { d.append(contentsOf: $0.prefix(8)) }
        }
        var isize = UInt32(indices.count * 2); withUnsafeBytes(of: &isize) { d.append(contentsOf: $0) }
        for i in indices { var v = i; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        d.append(Data("MDLS0001".utf8))  // 스켈레톤 섹션(phase 2)
        return d
    }

    func testParsesSyntheticMesh() throws {
        let mdl = makeMDL(material: "materials/body.json",
                          verts: [
                            (SIMD3(-1, -1, 0), SIMD4(8, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD2(0, 1)),
                            (SIMD3(1, -1, 0), SIMD4(8, 0, 0, 0), SIMD4(1, 0, 0, 0), SIMD2(1, 1)),
                            (SIMD3(0, 1, 0), SIMD4(2, 3, 0, 0), SIMD4(0.5, 0.5, 0, 0), SIMD2(0.5, 0)),
                          ],
                          indices: [0, 1, 2])
        let m = try XCTUnwrap(PuppetModel.parse(mdl))
        XCTAssertEqual(m.material, "materials/body.json")
        XCTAssertEqual(m.vertices.count, 3)
        XCTAssertEqual(m.indices, [0, 1, 2])
        XCTAssertEqual(m.vertices[0].position, SIMD3(-1, -1, 0))
        XCTAssertEqual(m.vertices[2].boneIndices, SIMD4<UInt32>(2, 3, 0, 0))
        XCTAssertEqual(m.vertices[2].weights, SIMD4<Float>(0.5, 0.5, 0, 0))
        XCTAssertEqual(m.vertices[2].uv, SIMD2<Float>(0.5, 0))
    }

    func testRejectsGarbage() {
        XCTAssertNil(PuppetModel.parse(Data("NOPE".utf8)))
        XCTAssertNil(PuppetModel.parse(Data("MDLV0013".utf8)))  // 트렁케이트
    }
}

/// 실물 스모크(env-guarded): 2809885105 의 퍼펫 2개가 파스되고 실측 수치와 일치.
final class PuppetRealFileTests: XCTestCase {
    func testParsesRealPuppets() throws {
        let base = ProcessInfo.processInfo.environment["WAPLE_REAL_PKGS"] ?? (NSHomeDirectory() + "/Downloads/backgrounds")
        let pkgURL = URL(fileURLWithPath: base).appendingPathComponent("2809885105/scene.pkg")
        guard let data = try? Data(contentsOf: pkgURL) else { throw XCTSkip("no real pkg") }
        let pkg = try ScenePackage.parse(data)
        let mdls = pkg.entries.filter { $0.name.hasSuffix("_puppet.mdl") }
        XCTAssertEqual(mdls.count, 2)
        var counts: [Int] = []
        for e in mdls {
            let m = try XCTUnwrap(PuppetModel.parse(try XCTUnwrap(pkg.data(for: e.name))), "parse fail: \(e.name)")
            XCTAssertTrue(m.material.hasPrefix("materials/"), m.material)
            XCTAssertGreaterThan(m.vertices.count, 100)
            XCTAssertGreaterThan(m.indices.count, 300)
            XCTAssertEqual(m.indices.count % 3, 0, "트라이앵글 리스트")
            let maxIdx = Int(m.indices.max() ?? 0)
            XCTAssertLessThan(maxIdx, m.vertices.count, "인덱스 범위")
            counts.append(m.vertices.count)
        }
        XCTAssertTrue(counts.contains(1406), "실측 1406 정점 모델 포함: \(counts)")
    }
}
