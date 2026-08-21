import XCTest
import simd
@testable import WapleCore

/// G-C3-02: WE 번들 `.mdl` 의 82%(28개 중 23개)를 차지하는 **MDLV0004 / MDLV0014** 수용.
///
/// 이 두 버전은 v≥16 과 프레이밍이 다르다 — 메시 헤더에 AABB 도 per-mesh formatFlag 도 없다.
/// 매직만 화이트리스트에 넣으면 안 되는 이유가 여기 있다: v0004 의 vertexBytes 필드를
/// formatFlag 로 잘못 읽으면 미지 비트가 서서 파스가 통째로 실패한다(무증상 아님, 전멸).
final class Model3DLegacyVersionTests: XCTestCase {

    // MARK: 버전 게이트 표(simd 무의존 — 순수 정수 판정)

    func testVersionGateBoundaries() {
        // AABB 경계 16/17 — 엔진 0x1402619a6 `cmp edi, 0x11`
        XCTAssertFalse(Model3DFormat.hasAABB(version: 16))
        XCTAssertTrue(Model3DFormat.hasAABB(version: 17))
        // per-mesh formatFlag 경계 14/15 — 엔진 0x140261a19 `cmp edi, 0x0f`
        XCTAssertFalse(Model3DFormat.hasPerMeshFormatFlag(version: 14))
        XCTAssertTrue(Model3DFormat.hasPerMeshFormatFlag(version: 16))
        // 메시 트레일러 경계 20/21 — 엔진 0x140261b61 `cmp edi, 0x15`
        XCTAssertFalse(Model3DFormat.hasMeshTrailer(version: 19))
        XCTAssertTrue(Model3DFormat.hasMeshTrailer(version: 21))
        // 미목격 버전은 매직 단계에서 거부(추측 파스 금지)
        XCTAssertEqual(Model3DFormat.version(ofMagic: "MDLV0004"), 4)
        XCTAssertEqual(Model3DFormat.version(ofMagic: "MDLV0014"), 14)
        XCTAssertNil(Model3DFormat.version(ofMagic: "MDLV0015"))
        XCTAssertNil(Model3DFormat.version(ofMagic: "MDLV0018"))
        XCTAssertNil(Model3DFormat.version(ofMagic: "MDLV0013"))   // 2D 퍼펫은 PuppetModel 담당
        XCTAssertNil(Model3DFormat.version(ofMagic: "MDLVxxxx"))
        // skinCount → 메시당 머티리얼 개수. **0 은 0개다** — 엔진 리드 루프가 카운터를 먼저 재고
        // (`0x14026193e cmp dword [r15+8], ebx` / `jbe`) 0 이면 cstring 을 한 개도 안 읽는다.
        // 종전엔 여기서 1을 돌려줘 이후 전 오프셋을 cstring 길이만큼 밀었다(실물 미목격이라 무회귀).
        XCTAssertEqual(Model3DFormat.materialCount(skinCount: 0), 0)
        XCTAssertEqual(Model3DFormat.materialCount(skinCount: 1), 1)
        XCTAssertEqual(Model3DFormat.materialCount(skinCount: 2), 2)
        XCTAssertNil(Model3DFormat.materialCount(skinCount: 1 << 20))
    }

    // MARK: 실물 바이트 — audiophile glow.mdl (156B, MDLV0004, 로제타석 짝 glow.obj 로 검증된 파일)

    /// WE 2.8.42 `projects/defaultprojects/audiophile/models/audiophile/glow.mdl` 전체 156바이트.
    /// 손 디코드: magic(8) NUL | flag 0x09 | skin 1 | mesh 1 | "materials/audiophile/glow.json" NUL
    /// | gate 0 | vertexBytes 0x50(=4×20) | 정점 4 | indexBytes 0x0c | u16 인덱스 6 | EOF(말미 NUL 없음).
    private static let glowV0004Hex = """
    4d444c5630303034000900000001000000010000006d6174657269616c732f617564696f7068696c652f676c6f772e6a\
    736f6e000000000050000000683e52c0683e52c0d90a0ebf000000000000803f683e5240683e52c0d90a0ebf0000803f\
    0000803f683e5240683e5240d90a0ebf0000803f00000000683e52c0683e5240d90a0ebf00000000000000000c000000\
    000001000200000002000300
    """

    /// `projects/defaultprojects/audiophile/models/grid/grid.mdl` 전체 176바이트 — **skinCount = 2**.
    /// 같은 메시의 fantasticcar 짝(v0014, skinCount 1)과 메시 바이트가 완전히 같고 크기 차 25B 가
    /// 정확히 `"materials/grid/grid2.json\0"` 길이다 — 오프셋 13 이 skinCount 라는 실물 근거.
    private static let gridV0004Hex = """
    4d444c5630303034000900000002000000010000006d6174657269616c732f677269642f677269642e6a736f6e006d61\
    74657269616c732f677269642f67726964322e6a736f6e000000000050000000139b41c00000008044db3f402ba1f6c0\
    62deeb3e5c1e40400000008044db3f4039b8083f0e3b0b415c1e404000000000eaad3ec096500b41b35f073f139b41c0\
    00000000eaad3ec08e8fee3e3cccf6c00c000000000001000200000002000300
    """

    private func bytes(_ hex: String) -> Data {
        var out = Data()
        var hi: UInt8? = nil
        for ch in hex where ch.isHexDigit {
            let v = UInt8(String(ch), radix: 16)!
            if let h = hi { out.append(h << 4 | v); hi = nil } else { hi = v }
        }
        XCTAssertNil(hi, "hex 자릿수가 홀수다")
        return out
    }

    func testParsesRealV0004GlowBytes() throws {
        let data = bytes(Self.glowV0004Hex)
        XCTAssertEqual(data.count, 156)
        let m = try XCTUnwrap(Model3D.parse(data), "MDLV0004 거부 — G-C3-02 회귀")
        XCTAssertEqual(m.meshes.count, 1)
        let mesh = m.meshes[0]
        XCTAssertEqual(mesh.material, "materials/audiophile/glow.json")
        XCTAssertEqual(mesh.materials, ["materials/audiophile/glow.json"])
        XCTAssertEqual(mesh.vertices.count, 4)              // 80B / stride 20(pos 12 + uv 8)
        XCTAssertEqual(mesh.indices, [0, 1, 2, 0, 2, 3])
        XCTAssertFalse(mesh.skinned)
        // 로제타석 glow.obj 의 첫 정점 x = -3.285059
        XCTAssertEqual(mesh.vertices[0].position.x, -3.285059, accuracy: 1e-5)
        XCTAssertEqual(mesh.vertices[0].position.y, -3.285059, accuracy: 1e-5)
        XCTAssertEqual(mesh.vertices[0].uv, SIMD2<Float>(0, 1))
        // v0004 는 AABB 를 담지 않는다 — 헤더 박스는 0 으로 남는다(정점 박스는 렌더가 산출).
        XCTAssertEqual(mesh.boundsMin, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(mesh.boundsMax, SIMD3<Float>(0, 0, 0))
        XCTAssertNil(mesh.trailer)                          // v<21 은 트레일러 자체가 없다
        XCTAssertTrue(m.bones.isEmpty)                      // 섹션 오탐 없음
        XCTAssertFalse(m.hasAnimation)
    }

    /// skinCount>1 — 머티리얼 cstring 은 **메시마다 skinCount 개**다(엔진 0x14026193e 루프가 메시 루프 안).
    /// 1개만 읽던 종전 코드는 이 파일에서 gateWord 자리에 문자열 바이트를 읽어 파스 전체가 실패했다.
    func testParsesV0004WithTwoSkins() throws {
        let m = try XCTUnwrap(Model3D.parse(bytes(Self.gridV0004Hex)))
        XCTAssertEqual(m.meshes.count, 1)
        XCTAssertEqual(m.meshes[0].materials,
                       ["materials/grid/grid.json", "materials/grid/grid2.json"])
        XCTAssertEqual(m.meshes[0].material, "materials/grid/grid.json")  // 렌더는 첫 스킨(선택은 G-C3-05)
        XCTAssertEqual(m.meshes[0].vertices.count, 4)
        XCTAssertEqual(m.meshes[0].indices.count, 6)
    }

    /// **무증상 회귀 방지**: 같은 바이트의 매직만 0015(미목격)로 바꾸면 거부되어야 한다.
    /// 프레이밍 표에 없는 버전을 '가까운 버전으로 대충 읽는' 회귀가 들어오면 여기서 걸린다.
    func testStillRejectsUnobservedVersions() {
        var d = bytes(Self.glowV0004Hex)
        d.replaceSubrange(0..<8, with: Data("MDLV0015".utf8))
        XCTAssertNil(Model3D.parse(d))
        d.replaceSubrange(0..<8, with: Data("MDLV0018".utf8))
        XCTAssertNil(Model3D.parse(d))
    }
}
