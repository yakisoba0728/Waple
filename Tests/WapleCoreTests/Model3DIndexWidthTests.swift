import XCTest
@testable import WapleCore

/// 인덱스 원소 폭 회귀 핀.
///
/// **[2026-08-20 정정] 폭은 정점 수가 아니라 gateWord bit0 이 정한다 — 포맷이 자기기술한다.**
/// `.mdl` 전용 GPU 업로드 경로(0x1401d7760)가 그렇게 읽는다:
///   `movzx ecx, byte [rdi+0x18]`(0x1401d784c) → `and cl, 1`(0x1401d7853) = gateWord & 1
///   `lea r9d, [r10*2 + 2]`(0x1401d7870) = **2 또는 4** → `idiv r9d`(0x1401d7878) = 인덱스 개수
/// 그 플래그가 인자로 넘어가고(0x1401d786b) 소비처 0x14009a98d 가 `test edx,edx` → `cmove` 로
/// **0x39(R16_UINT)** / **0x2a(R32_UINT)** 를 고른다. 정점 수는 이 사슬 어디에도 안 들어간다.
///
/// 종전 규칙(`vertexCount ≤ 65535 면 u16`)은 관측 코퍼스에서 우연히 같은 답을 냈다 — 정점이
/// 65535 를 넘는 메시는 내보내기 도구가 gateWord bit0 을 세우기 때문이다. 설치본 45메시는
/// gateWord 전건 0 이고 최대 정점수가 10,995 라 두 규칙이 완전히 겹친다(파스 결과 바이트 동일
/// 확인). 갈리는 것은 **gateWord bit0 이 선 작은 메시**와 **비트가 없는 큰 메시**뿐이다.
///
/// 종전 파서는 무조건 u16 으로 읽었다. 그 오독이 위험한 이유는 조용하기 때문이다 — 정본이
/// 증상까지 못박아 뒀다: *"u32 블롭을 u16 로 읽으면 상위 워드 0 이 섞여 maxIndex 가 정확히
/// 0xFFFF 로 찍히고, 정점 수보다 작으므로 `maxIndex < vertexCount` 류의 검사로는 절대 안 걸린다"*.
/// 실제로 `Model3D.parse` 의 그 가드가 통과시켰고, 인덱스 개수만 2배가 되어 파스가 "성공"했다.
/// 실물 도달: 로컬 코퍼스 11파일 / 17메시, camera3D 씬 7개 중 5개(소행성·새턴 링·루시상·
/// 우주정거장·소닉 스테이지)가 정점 0 을 향한 슬리버 부채꼴로 그려지고 있었다.
///
/// 골든은 Waple-대-Waple 회귀라 이 결함을 구조적으로 잡지 못한다 — 그래서 여기서 핀한다.
final class Model3DIndexWidthTests: XCTestCase {

    private func f(_ v: Float, into d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func u32(_ v: UInt32, into d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func u16(_ v: UInt16, into d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

    /// MDLV0023 단일메시. `meshFlag 0x9` = idx0 POSITION(12) | idx7 TEXCOORD0 float2(8)
    /// → `vertexLayoutTable` 산출 stride **20**, pos@0 / uv@12.
    /// (0x1 만 세우면 position 전용 stride 12 가 나와 `inferStride` 추측 경로로 새므로 쓰지 않는다.)
    ///
    /// 인덱스는 호출자가 폭을 정해 기록한다 — 정본 규칙을 테스트가 재현하면 무의미해진다.
    /// 여기서는 바이트만 내고, 폭 판정은 파서가 해야 한다.
    private func makeModel(vCount: Int, indexBlob: Data, gateWord: UInt32 = 0) -> Data {
        var d = Data("MDLV0023".utf8)
        d.append(0)
        u32(0x0f, into: &d)          // formatFlag(헤더)
        u32(1, into: &d)             // skinCount
        u32(1, into: &d)             // meshCount
        d.append(Data("materials/x.json".utf8)); d.append(0)
        u32(gateWord, into: &d)      // 인덱스 원소 폭이 이 워드의 bit0 에서 나온다
        for _ in 0..<6 { f(0, into: &d) }   // AABB
        u32(0x9, into: &d)                  // meshFlag → stride 20 (pos 12 + uv 8)
        u32(UInt32(vCount * 20), into: &d)  // vSize
        d.append(Data(count: vCount * 20))  // 정점 바이트(값은 이 테스트의 관심사가 아니다)
        u32(UInt32(indexBlob.count), into: &d)
        d.append(indexBlob)
        return d
    }

    /// gateWord bit0 = 0 — u16 (설치본 45메시 전건 이 경우).
    func testReadsU16IndicesWhenGateWordBit0Clear() throws {
        var blob = Data()
        for v in [UInt16(3), UInt16(1), UInt16(2)] { u16(v, into: &blob) }
        let m = try XCTUnwrap(Model3D.parse(makeModel(vCount: 8, indexBlob: blob, gateWord: 0)))
        XCTAssertEqual(m.meshes.count, 1)
        XCTAssertEqual(m.meshes[0].indices, [3, 1, 2])
    }

    /// **두 규칙을 가르는 자리 ①** — 정점 8개(16비트에 한참 들어간다)인데 gateWord bit0 이 서 있다.
    /// 종전 규칙은 u16 으로 읽어 12바이트를 인덱스 6개 `[3,0,1,0,2,0]` 로 만든다(삼각형 2개로
    /// 늘어나고 절반이 정점 0 을 향한다 — 바로 그 조용한 오작동이다).
    func testGateWordBit0ForcesU32EvenForSmallMeshes() throws {
        var blob = Data()
        for v in [UInt32(3), UInt32(1), UInt32(2)] { u32(v, into: &blob) }
        let m = try XCTUnwrap(Model3D.parse(makeModel(vCount: 8, indexBlob: blob, gateWord: 1)))
        XCTAssertEqual(m.meshes[0].indices, [3, 1, 2],
                       "종전(정점수) 규칙이면 [3, 0, 1, 0, 2, 0] 이 된다")
    }

    /// **두 규칙을 가르는 자리 ②** — 정점 70,000 인데 gateWord bit0 이 없다 → u16 이다.
    /// (내보내기 도구가 실제로 이런 조합을 내는지는 별개다. 규칙이 정점 수를 **안 본다**는 것을
    /// 못박는 것이 요지다.)
    func testLargeMeshWithoutGateBitStaysU16() throws {
        let vCount = 70_000
        var blob = Data()
        for v in [UInt16(3), UInt16(1), UInt16(2)] { u16(v, into: &blob) }
        let m = try XCTUnwrap(Model3D.parse(makeModel(vCount: vCount, indexBlob: blob, gateWord: 0)))
        XCTAssertEqual(m.meshes[0].indices, [3, 1, 2], "폭은 정점 수와 무관하다")
    }

    /// gateWord bit0 = 1 인 큰 메시 — u32.
    ///
    /// 폭을 틀리면(u16 으로 읽으면) 같은 12바이트가 `[4463, 1, 0, 0, 1, 0]` 이 된다.
    /// maxIndex 4463 < 70000 이라 범위 가드를 통과하고, 삼각형 1개가 2개로 늘어나며 정점 0
    /// 근처로 붕괴한다 — 이 결함이 조용한 이유다.
    func testReadsU32IndicesWhenGateWordBit0Set() throws {
        let vCount = 70_000
        var blob = Data()
        for v in [UInt32(69_999), UInt32(0), UInt32(1)] { u32(v, into: &blob) }
        let m = try XCTUnwrap(Model3D.parse(makeModel(vCount: vCount, indexBlob: blob, gateWord: 1)))
        XCTAssertEqual(m.meshes.count, 1)
        XCTAssertEqual(m.meshes[0].indices, [69_999, 0, 1],
                       "u32 블롭을 u16 로 읽으면 [4463, 1, 0, 0, 1, 0] 이 된다(종전 결함)")
        XCTAssertEqual(m.meshes[0].vertices.count, vCount)
    }

    /// 정본이 확정한 판별식 — 올바른 폭으로 읽으면 `maxIndex == vertexCount - 1` 이 성립한다.
    /// (실측 986/986. 폭을 틀리면 정확히 0xFFFF 가 나온다.)
    func testMaxIndexReachesLastVertexWhenWidthIsCorrect() throws {
        let vCount = 70_000
        var blob = Data()
        for v in [UInt32(vCount - 1), UInt32(0), UInt32(1)] { u32(v, into: &blob) }
        let m = try XCTUnwrap(Model3D.parse(makeModel(vCount: vCount, indexBlob: blob, gateWord: 1)))
        let maxIndex = try XCTUnwrap(m.meshes[0].indices.max())
        XCTAssertEqual(Int(maxIndex), vCount - 1)
        XCTAssertNotEqual(Int(maxIndex), 0xFFFF, "0xFFFF 는 u16 오독의 지문이다")
    }

    /// 폭이 맞아도 인덱스가 정점 범위를 벗어나면 거부한다(기존 가드 무회귀).
    func testRejectsOutOfRangeIndexAtU32Width() throws {
        let vCount = 70_000
        var blob = Data()
        for v in [UInt32(vCount), UInt32(0), UInt32(1)] { u32(v, into: &blob) }   // vCount 는 범위 밖
        XCTAssertNil(Model3D.parse(makeModel(vCount: vCount, indexBlob: blob, gateWord: 1)))
    }
}
