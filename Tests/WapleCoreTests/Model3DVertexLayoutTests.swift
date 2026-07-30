import XCTest
import simd
@testable import WapleCore

/// 정점 레이아웃 테이블(wallpaper64.exe .rdata 덤프, FUN_1400d8060.c:81-96) 도입의 회귀/신규 경로 핀.
/// - 표준 플래그(0x0f → 48, 0x0f|skin → 80, 0x09|skin → 52)는 종전 공식과 **바이트 동일**해야 한다(무회귀).
/// - Kirby 0x00800021(stride 44, pos@0/boneIdx@12/TEXCOORD0 float4@28)은 종전 꼬리고정(uv@36)이
///   오독이던 입력 — 테이블 경로에서만 uv@28 로 교정된다.
final class Model3DVertexLayoutTests: XCTestCase {
    private func f(_ v: Float, into d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func u(_ v: UInt32, into d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    private func u16(_ v: UInt16, into d: inout Data) { var x = v; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

    /// MDLV0023 단일메시 프레이밍(정점 바이트는 호출자가 stride 에 맞춰 직접 기록).
    private func makeModel(meshFlag: UInt32, vertexBytes: Data, vCount: Int, indices: [UInt16]) -> Data {
        var d = Data("MDLV0023".utf8)
        d.append(0); u(0x0f, into: &d); u(1, into: &d); u(1, into: &d)
        d.append(Data("materials/x.json".utf8)); d.append(0)
        u(0, into: &d)
        for _ in 0..<6 { f(0, into: &d) }            // AABB
        u(meshFlag, into: &d)
        u(UInt32(vertexBytes.count), into: &d)
        d.append(vertexBytes)
        u(UInt32(indices.count * 2), into: &d)
        for i in indices { u16(i, into: &d) }
        return d
    }

    // MARK: 표준 플래그 비트동일 회귀

    /// 0x0f → stride 48: pos@0, normal@12, tangent@24, uv@40 (종전 공식과 동일 오프셋).
    func testStandardStaticStride48Layout() throws {
        var vb = Data()
        f(1, into: &vb); f(2, into: &vb); f(3, into: &vb)                  // pos
        f(0.1, into: &vb); f(0.2, into: &vb); f(0.9, into: &vb)            // normal
        f(0.5, into: &vb); f(0.6, into: &vb); f(0.7, into: &vb); f(-1, into: &vb)  // tangent
        f(0.25, into: &vb); f(0.75, into: &vb)                             // uv
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x0f, vertexBytes: vb, vCount: 1, indices: [0, 0, 0])))
        let v = m.meshes[0].vertices[0]
        XCTAssertFalse(m.meshes[0].skinned)
        XCTAssertEqual(v.position, SIMD3(1, 2, 3))
        XCTAssertEqual(v.normal, SIMD3(0.1, 0.2, 0.9))
        XCTAssertEqual(v.tangent, SIMD4(0.5, 0.6, 0.7, -1))
        XCTAssertEqual(v.uv, SIMD2(0.25, 0.75))
        XCTAssertEqual(v.boneIndices, .zero)
        XCTAssertEqual(v.weights, .zero)
    }

    /// 0x0f|skinMask → stride 80: pos@0, normal@12, tangent@24, boneIdx@40, weights@56, uv@72.
    func testStandardSkinnedStride80Layout() throws {
        var vb = Data()
        f(5, into: &vb); f(6, into: &vb); f(7, into: &vb)                  // pos @0
        f(0, into: &vb); f(1, into: &vb); f(0, into: &vb)                  // normal @12
        f(1, into: &vb); f(0, into: &vb); f(0, into: &vb); f(1, into: &vb) // tangent @24
        u(3, into: &vb); u(4, into: &vb); u(5, into: &vb); u(6, into: &vb) // boneIdx @40
        f(0.7, into: &vb); f(0.2, into: &vb); f(0.05, into: &vb); f(0.05, into: &vb)  // weights @56
        f(0.125, into: &vb); f(0.625, into: &vb)                           // uv @72
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x0180_000f, vertexBytes: vb, vCount: 1, indices: [0, 0, 0])))
        let v = m.meshes[0].vertices[0]
        XCTAssertTrue(m.meshes[0].skinned)
        XCTAssertEqual(v.position, SIMD3(5, 6, 7))
        XCTAssertEqual(v.normal, SIMD3(0, 1, 0))
        XCTAssertEqual(v.tangent, SIMD4(1, 0, 0, 1))
        XCTAssertEqual(v.boneIndices, SIMD4<UInt32>(3, 4, 5, 6))
        XCTAssertEqual(v.weights, SIMD4(0.7, 0.2, 0.05, 0.05))
        XCTAssertEqual(v.uv, SIMD2(0.125, 0.625))
    }

    /// 0x09|skinMask → stride 52: pos@0, boneIdx@12, weights@28, uv@44 (V0016 계열 레이아웃).
    func testStride52Layout() throws {
        var vb = Data()
        f(9, into: &vb); f(8, into: &vb); f(7, into: &vb)                  // pos @0
        u(11, into: &vb); u(12, into: &vb); u(0, into: &vb); u(0, into: &vb)  // boneIdx @12
        f(0.6, into: &vb); f(0.4, into: &vb); f(0, into: &vb); f(0, into: &vb)  // weights @28
        f(0.5, into: &vb); f(0.25, into: &vb)                              // uv @44
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x0180_0009, vertexBytes: vb, vCount: 1, indices: [0, 0, 0])))
        let v = m.meshes[0].vertices[0]
        XCTAssertTrue(m.meshes[0].skinned)
        XCTAssertEqual(v.position, SIMD3(9, 8, 7))
        XCTAssertEqual(v.normal, SIMD3(0, 0, 1))       // 채널 부재 — 기본값
        XCTAssertEqual(v.tangent, SIMD4(1, 0, 0, 1))   // 채널 부재 — 기본값
        XCTAssertEqual(v.boneIndices, SIMD4<UInt32>(11, 12, 0, 0))
        XCTAssertEqual(v.weights, SIMD4(0.6, 0.4, 0, 0))
        XCTAssertEqual(v.uv, SIMD2(0.5, 0.25))
    }

    // MARK: Kirby 0x00800021 (실물 피해 확정 — 종전 uv@36 오독)

    /// stride 44 = pos@0(12) + boneIdx@12(16) + TEXCOORD0 float4@28(16). weights 채널 부재라
    /// 스키닝은 종전대로 정적 폴터(graceful)를 유지하되, uv 는 float4 채널의 .xy(@28)로 교정.
    /// 종전 경로는 uv 를 stride-8=@36(=float4 의 .zw)으로 오독했다.
    func testKirbyChannelmapLayout() throws {
        var vb = Data()
        f(1, into: &vb); f(2, into: &vb); f(3, into: &vb)                  // pos @0
        u(7, into: &vb); u(8, into: &vb); u(9, into: &vb); u(10, into: &vb)   // boneIdx @12(미독 — weights 부재)
        f(0.25, into: &vb); f(0.5, into: &vb)                              // uv = float4 의 .xy @28
        f(9.75, into: &vb); f(9.875, into: &vb)                            // float4 의 .zw @36(종전 오독 위치)
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x0080_0021, vertexBytes: vb, vCount: 1, indices: [0, 0, 0])))
        let mm = m.meshes[0]
        XCTAssertFalse(mm.skinned, "weights 채널 부재 — 정적 폴터 유지")
        let v = mm.vertices[0]
        XCTAssertEqual(v.position, SIMD3(1, 2, 3))
        XCTAssertEqual(v.uv, SIMD2(0.25, 0.5), "TEXCOORD0 float4 의 .xy(@28) — 종전 uv@36 오독 교정")
        XCTAssertNotEqual(v.uv, SIMD2(9.75, 9.875), "@36(.zw) 오독이면 실패해야 할 값")
        XCTAssertEqual(v.boneIndices, .zero, "스킨 미적용 — 본/웨이트 미독")
        XCTAssertEqual(v.weights, .zero)
        XCTAssertEqual(v.normal, SIMD3(0, 0, 1))
        XCTAssertEqual(v.tangent, SIMD4(1, 0, 0, 1))
    }

    /// 미지 비트 채널 스킵: 0x00808021 = Kirby + idx25(0x8000, float4 color 후보 16B) → stride 60.
    /// 테이블 인덱스 순(idx9 uv 가 idx25 보다 앞)이라 uv 오프셋은 28 로 불변, 말미 16B 만 건너뛴다.
    func testUnknownTailChannelSkipped() throws {
        var vb = Data()
        f(4, into: &vb); f(5, into: &vb); f(6, into: &vb)                  // pos @0
        u(1, into: &vb); u(2, into: &vb); u(3, into: &vb); u(4, into: &vb)    // boneIdx @12
        f(0.75, into: &vb); f(0.125, into: &vb)                            // uv @28
        f(0, into: &vb); f(0, into: &vb)                                   // float4 .zw @36
        f(1, into: &vb); f(0.5, into: &vb); f(0.25, into: &vb); f(1, into: &vb)  // idx25 color 후보 @44(스킵)
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x0080_8021, vertexBytes: vb, vCount: 1, indices: [0, 0, 0])),
                            "idx25 채널을 stride 에 반영하지 못하면 프레이밍 실패")
        let v = m.meshes[0].vertices[0]
        XCTAssertEqual(v.position, SIMD3(4, 5, 6))
        XCTAssertEqual(v.uv, SIMD2(0.75, 0.125))
    }

    /// 테이블 불해결 플래그(미지 비트 0x40 = TEXCOORD1 계열, idx10-24 미대조)는 종전 추측 경로
    /// (축약 공식 → inferStride + 꼬리고정 오프셋)를 그대로 탄다(무회귀).
    func testUnknownBitFallsBackToInferredTailLayout() throws {
        // 실제 stride 56 = 기지 48 + 미지 8B, 플래그 0x4f(0x0f|0x40). 공식 48 로는 안 나눠져
        // 인덱스 maxIndex+1 추론(112/2=56)으로 프레이밍, 필드는 꼬리고정(uv@-8).
        var vb = Data()
        f(1, into: &vb); f(2, into: &vb); f(3, into: &vb)                  // pos
        f(0, into: &vb); f(0, into: &vb); f(1, into: &vb)                  // normal
        f(1, into: &vb); f(0, into: &vb); f(0, into: &vb); f(1, into: &vb) // tangent
        f(42, into: &vb); f(43, into: &vb)                                 // 미지 8B
        f(0.375, into: &vb); f(0.875, into: &vb)                           // uv @-8
        var vb2 = vb
        vb2.append(vb)                                                      // 2 정점 × 56B
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x4f, vertexBytes: vb2, vCount: 2, indices: [0, 1, 0])))
        XCTAssertEqual(m.meshes[0].vertices.count, 2)
        XCTAssertEqual(m.meshes[0].vertices[0].position, SIMD3(1, 2, 3))
        XCTAssertEqual(m.meshes[0].vertices[0].uv, SIMD2(0.375, 0.875), "추론 경로는 종전대로 uv@-8")
    }

    // MARK: MDAT u16 카운트 (디컴파일 FUN_140261950:1092-1099)

    private func makeMDAT(count: Int, boneCount: Int) -> [UInt8] {
        var d = Data("MDAT0001".utf8)
        d.append(0); u(0, into: &d)                                        // lead u8 + u32 nextOff
        u16(UInt16(count), into: &d)
        for i in 0..<count {
            u16(UInt16(i % max(1, boneCount)), into: &d)                   // u16 본 인덱스
            d.append(Data("at\(i)".utf8)); d.append(0)                     // cstring 이름
            let mat: [Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, Float(i),0,0,1]
            for x in mat { f(x, into: &d) }                                // 64B 로컬
        }
        return [UInt8](d)
    }

    /// count≥256 도 u16 리드로 수용(종전 u8+pad 는 256 이상을 빈 배열로 폴터했다).
    func testMDATAttachmentCountU16AtLeast256() throws {
        let atts = Model3D.parseAttachments(bytes: makeMDAT(count: 256, boneCount: 300), at: 0, boneCount: 300)
        XCTAssertEqual(atts.count, 256)
        XCTAssertEqual(atts[255].bone, 255)
        XCTAssertEqual(atts[255].name, "at255")
        XCTAssertEqual(atts[255].local.columns.3.x, 255)
    }

    /// 소수 카운트는 종전(u8)과 바이트 동일 결과(무회귀) — pad=0 이면 u16==u8.
    func testMDATAttachmentCountSmallUnchanged() throws {
        let atts = Model3D.parseAttachments(bytes: makeMDAT(count: 1, boneCount: 4), at: 0, boneCount: 4)
        XCTAssertEqual(atts.count, 1)
        XCTAssertEqual(atts[0].name, "at0")
        XCTAssertEqual(atts[0].bone, 0)
    }

    func testMDATAttachmentCountZeroEmpty() {
        XCTAssertTrue(Model3D.parseAttachments(bytes: makeMDAT(count: 0, boneCount: 4), at: 0, boneCount: 4).isEmpty)
    }
}
