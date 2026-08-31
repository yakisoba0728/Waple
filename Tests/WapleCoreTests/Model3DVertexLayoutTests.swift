import XCTest
import simd
@testable import WapleCore

/// 정점 레이아웃 테이블(wallpaper64.exe .rdata 병렬 배열 — 마스크 `0x140484a20` / 크기
/// `0x1404849b0` / 속성이름 `0x140484a90` / 디스크립터 `0x140482fa0`, 각 26엔트리) 회귀·신규 경로 핀.
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

    /// 말미 채널 스킵: 0x00808021 = Kirby + idx25(0x8000 = `a_Color` float4 COLOR0, 16B) → stride 60.
    /// 테이블 인덱스 순(idx9 uv 가 idx25 보다 앞)이라 uv 오프셋은 28 로 불변, 말미 16B 만 건너뛴다.
    /// `a_Color` 는 **항상 테이블 맨 뒤**라 다른 채널의 오프셋을 절대 밀지 않는다.
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

    // MARK: TEXCOORD1-5 (idx10-24) — 2026-08-21 에 .rdata 전수 덤프로 확정

    /// **회귀 핀(종전 오독 교정).** 0x4f = 0x0f | 0x40(`a_TexCoordC1` float2 TEXCOORD1) → stride 56.
    /// 파일 순서는 테이블 인덱스 순이라 pos@0 · normal@12 · tangent@24 · **TEXCOORD0@40** ·
    /// TEXCOORD1@48 이다. 종전 표는 0x40 을 몰라 테이블을 통째로 포기하고 `inferStride` 추측 경로로
    /// 떨어졌고, 그 경로의 꼬리고정 규칙(uv@stride−8 = @48)은 **TEXCOORD1 을 uv0 으로 읽었다**.
    /// 이 테스트가 실패하면 그 오독이 되살아난 것이다.
    func testTexCoord1FlagResolvesUV0AtTableOffset() throws {
        var vb = Data()
        f(1, into: &vb); f(2, into: &vb); f(3, into: &vb)                  // pos @0
        f(0, into: &vb); f(0, into: &vb); f(1, into: &vb)                  // normal @12
        f(1, into: &vb); f(0, into: &vb); f(0, into: &vb); f(1, into: &vb) // tangent @24
        f(0.375, into: &vb); f(0.875, into: &vb)                           // TEXCOORD0 @40  ← uv0
        f(42, into: &vb); f(43, into: &vb)                                 // TEXCOORD1 @48  (미독)
        var vb2 = vb
        vb2.append(vb)                                                      // 2 정점 × 56B
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x4f, vertexBytes: vb2, vCount: 2, indices: [0, 1, 0])))
        XCTAssertEqual(m.meshes[0].vertices.count, 2, "stride 56 = 12+12+16+8+8")
        XCTAssertEqual(m.meshes[0].vertices[0].position, SIMD3(1, 2, 3))
        XCTAssertEqual(m.meshes[0].vertices[0].uv, SIMD2(0.375, 0.875), "TEXCOORD0@40 — 종전 @48 오독 교정")
        XCTAssertNotEqual(m.meshes[0].vertices[0].uv, SIMD2(42, 43), "@48(TEXCOORD1) 오독이면 실패해야 할 값")
    }

    /// TEXCOORD5 float4(idx24, 0x00400000) 까지 표에 있다 — 최상위 채널 비트도 스트라이드에 든다.
    /// 0x0040_0009 → pos(12) + TEXCOORD0 f2(8) + TEXCOORD5 f4(16) = 36.
    func testTexCoord5Vec4ContributesToStride() throws {
        var vb = Data()
        f(7, into: &vb); f(8, into: &vb); f(9, into: &vb)                  // pos @0
        f(0.5, into: &vb); f(0.25, into: &vb)                              // TEXCOORD0 @12
        f(0, into: &vb); f(0, into: &vb); f(0, into: &vb); f(0, into: &vb) // TEXCOORD5 f4 @20(미독)
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x0040_0009, vertexBytes: vb, vCount: 1, indices: [0, 0, 0])),
                              "TEXCOORD5 16B 를 stride 에 못 넣으면 36 이 안 나와 프레이밍 실패")
        XCTAssertEqual(m.meshes[0].vertices.count, 1)
        XCTAssertEqual(m.meshes[0].vertices[0].position, SIMD3(7, 8, 9))
        XCTAssertEqual(m.meshes[0].vertices[0].uv, SIMD2(0.5, 0.25))
    }

    /// 표 밖 상위 비트(bit26+)는 엔진 누산 루프가 아예 보지 않으므로 **스트라이드 기여 0** 이다
    /// (`0x140261b25 cmp rax, 0x1a` — 26엔트리만 돈다). 0x8000_000f 는 0x0f 와 바이트 동일한
    /// 레이아웃(48)이어야 한다. 종전에는 미지 비트 하나로 표를 포기하고 추측 경로로 갔다.
    func testHighBitsAboveTableAreIgnored() throws {
        var vb = Data()
        f(1, into: &vb); f(2, into: &vb); f(3, into: &vb)
        f(0, into: &vb); f(1, into: &vb); f(0, into: &vb)
        f(1, into: &vb); f(0, into: &vb); f(0, into: &vb); f(-1, into: &vb)
        f(0.125, into: &vb); f(0.875, into: &vb)
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x8000_000f, vertexBytes: vb, vCount: 1, indices: [0, 0, 0])))
        let v = m.meshes[0].vertices[0]
        XCTAssertEqual(v.position, SIMD3(1, 2, 3))
        XCTAssertEqual(v.normal, SIMD3(0, 1, 0))
        XCTAssertEqual(v.tangent, SIMD4(1, 0, 0, -1))
        XCTAssertEqual(v.uv, SIMD2(0.125, 0.875))
    }

    // MARK: uv1 (라이트맵) — TEXCOORD0 float4 의 .zw

    /// 0x27 = 0x0f 에서 TEXCOORD0 을 float4(`a_TexCoordVec4`, 0x20)로 바꾼 것 → stride 56.
    /// `generic.vert`(#if LIGHTMAP)가 vec4 로 받아 `generic.frag` 이 `.zw` 로 라이트맵을 샘플한다.
    /// 설치본 도달: arsenal `pistols.mdl` 6메시 전건이 이 플래그다.
    func testTexCoord0Float4YieldsUV1FromZW() throws {
        var vb = Data()
        f(1, into: &vb); f(2, into: &vb); f(3, into: &vb)                  // pos @0
        f(0, into: &vb); f(0, into: &vb); f(1, into: &vb)                  // normal @12
        f(1, into: &vb); f(0, into: &vb); f(0, into: &vb); f(1, into: &vb) // tangent @24
        f(2.5, into: &vb); f(-0.5, into: &vb)                              // uv0 = .xy @40 (타일링이라 [0,1] 밖일 수 있다)
        f(0.25, into: &vb); f(0.75, into: &vb)                             // uv1 = .zw @48 (라이트맵 — 아틀라스라 [0,1])
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x27, vertexBytes: vb, vCount: 1, indices: [0, 0, 0])))
        let v = m.meshes[0].vertices[0]
        XCTAssertEqual(v.uv, SIMD2(2.5, -0.5))
        XCTAssertEqual(v.uv1, SIMD2(0.25, 0.75), "TEXCOORD0 float4 의 .zw = 라이트맵 UV")
    }

    /// float2 TEXCOORD0(0x0f)에는 두 번째 세트가 없다 — uv1 은 (0,0) 이어야 한다(오탐 방지).
    func testTexCoord0Float2HasNoUV1() throws {
        var vb = Data()
        f(1, into: &vb); f(2, into: &vb); f(3, into: &vb)
        f(0, into: &vb); f(0, into: &vb); f(1, into: &vb)
        f(1, into: &vb); f(0, into: &vb); f(0, into: &vb); f(1, into: &vb)
        f(0.5, into: &vb); f(0.5, into: &vb)
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x0f, vertexBytes: vb, vCount: 1, indices: [0, 0, 0])))
        XCTAssertEqual(m.meshes[0].vertices[0].uv1, .zero)
    }

    // MARK: TEXCOORD0 부재 플래그 — 테이블 경로에서 uv0 = (0,0)

    /// 엔진 근거: 입력 레이아웃 조립부 `0x1400d7f90` 이 26엔트리를 돌며 마스크가 선 엔트리에만
    /// `D3D11_INPUT_ELEMENT_DESC`(`0x140482af0`)를 붙이고 `iVar10 += size[i]`(`0x1404849b0`) 로
    /// 오프셋을 전진시킨다 — 비트가 없으면 엘리먼트도, 스트라이드 기여도 없다. 즉 WE 에는 그
    /// 자리에 uv 속성이 **아예 없고** D3D 가 셰이더에 0 을 먹인다.
    /// 종전 Waple 은 `layout?.uv ?? stride - 8` 로 꼬리 8바이트를 uv0 으로 읽었다 —
    /// 테이블이 "없다"고 말한 것과 테이블 자체가 없는 것을 구별하지 못해서다.
    func testNoTexCoordFlagYieldsZeroUV() throws {
        // 0x03 = a_Position | a_Normal → stride 24, TEXCOORD0 없음. 꼬리 8B 는 normal.yz 다.
        var vb = Data()
        f(1, into: &vb); f(2, into: &vb); f(3, into: &vb)                  // pos @0
        f(0, into: &vb); f(0.6, into: &vb); f(0.8, into: &vb)              // normal @12 (.yz = 꼬리 8B)
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x03, vertexBytes: vb, vCount: 1, indices: [0, 0, 0])))
        let v = m.meshes[0].vertices[0]
        XCTAssertEqual(v.position, SIMD3(1, 2, 3))
        XCTAssertEqual(v.normal, SIMD3(0, 0.6, 0.8))
        XCTAssertEqual(v.uv, .zero, "종전엔 normal.yz = (0.6, 0.8) 이 uv0 으로 새어 나왔다")
        XCTAssertEqual(v.uv1, .zero)
    }

    /// 0x07 = pos | normal | tangent → stride 40. 꼬리 8B 는 tangent.zw = (0, -1).
    func testNoTexCoordWithTangentYieldsZeroUV() throws {
        var vb = Data()
        f(1, into: &vb); f(2, into: &vb); f(3, into: &vb)                  // pos @0
        f(0, into: &vb); f(1, into: &vb); f(0, into: &vb)                  // normal @12
        f(1, into: &vb); f(0, into: &vb); f(0, into: &vb); f(-1, into: &vb) // tangent @24 (.zw = 꼬리)
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x07, vertexBytes: vb, vCount: 1, indices: [0, 0, 0])))
        let v = m.meshes[0].vertices[0]
        XCTAssertEqual(v.tangent, SIMD4(1, 0, 0, -1))
        XCTAssertEqual(v.uv, .zero, "종전엔 tangent.zw = (0, -1) 이 uv0 으로 새어 나왔다")
    }

    /// TEXCOORD0 없는 **스킨** 플래그는 스키닝을 유지해야 한다 — 본/웨이트 채널의 유무는
    /// idx5·idx6 비트가 정하고 TEXCOORD0(idx7‥9)과 독립이다. 종전 `skinFieldsFit` 판정에 붙어
    /// 있던 `l.uv != nil` 이 이 플래그의 본을 통째로 지웠다(skinned=false, 본·웨이트 전부 0).
    /// 0x01800003 = pos(12) + normal(12) + blendIndices(16) + blendWeights(16) = stride 56.
    func testSkinnedFlagWithoutTexCoordKeepsSkinning() throws {
        var vb = Data()
        f(1, into: &vb); f(2, into: &vb); f(3, into: &vb)                  // pos @0
        f(0, into: &vb); f(0, into: &vb); f(1, into: &vb)                  // normal @12
        u(7, into: &vb); u(8, into: &vb); u(9, into: &vb); u(10, into: &vb) // boneIdx @24
        f(0.5, into: &vb); f(0.25, into: &vb); f(0.125, into: &vb); f(0.125, into: &vb)  // weights @40
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x0180_0003, vertexBytes: vb, vCount: 1, indices: [0, 0, 0])))
        let mesh = m.meshes[0]
        XCTAssertTrue(mesh.skinned)
        let v = mesh.vertices[0]
        XCTAssertEqual(v.position, SIMD3(1, 2, 3))
        XCTAssertEqual(v.boneIndices, SIMD4<UInt32>(7, 8, 9, 10), "종전엔 (0,0,0,0) — 스키닝이 통째로 사라졌다")
        XCTAssertEqual(v.weights, SIMD4(0.5, 0.25, 0.125, 0.125))
        XCTAssertEqual(v.uv, .zero, "종전엔 weights.w 꼬리 = (0.125, ·) 를 uv0 으로 읽었다")
    }

    /// 무회귀 대칭 핀: 추론 경로(`layout == nil`)는 꼬리고정 폴백을 **유지**해야 한다.
    /// 테이블 stride 로 정점 블롭이 나뉘지 않으면 `inferStride` 가 stride 를 다시 정하고
    /// `layout = nil` 이 된다 — 그때는 채널 위치를 모르므로 종전 규칙(uv = stride−8)이 옳다.
    func testInferredStridePathKeepsTailUVFallback() throws {
        // 플래그 0x0b(테이블 stride 32)이지만 실제 정점은 stride 36 × 2개 = 72B.
        // 72 % 32 != 0 → inferStride 가 maxIndex+1 == 2 로 36 을 산출, layout = nil.
        var vb = Data()
        for k in 0..<2 {
            f(Float(k), into: &vb); f(0, into: &vb); f(0, into: &vb)       // pos @0
            f(0, into: &vb); f(0, into: &vb); f(1, into: &vb)              // normal @12
            f(0, into: &vb); f(0, into: &vb); f(0, into: &vb)              // 미지 채널 @24
            f(0.375, into: &vb); f(0.875, into: &vb)                       // 꼬리 8B = uv @28
        }
        let m = try XCTUnwrap(Model3D.parse(makeModel(meshFlag: 0x0b, vertexBytes: vb, vCount: 2, indices: [0, 1, 1])))
        XCTAssertEqual(m.meshes[0].vertices.count, 2)
        XCTAssertEqual(m.meshes[0].vertices[0].uv, SIMD2(0.375, 0.875), "추론 경로의 꼬리고정 폴백은 유지된다")
    }

    // MARK: MDAT u16 카운트
    //
    // 엔진 근거: `FUN_140261880` 의 서브청크 루프에서 태그가 `strncmp(pcVar20,"MDAT0001",8)`
    // (완전 8바이트 비교)로 맞으면 `FUN_140261770(…+0x38)` 뒤 **`FUN_140261680(…+0x38)`** 가
    // 개수를 읽고 `if (uVar10 != 0) do { … } while` 로 그 수만큼 돈다. 항목 안의 이름은
    // `FUN_14009c500`(cstring)으로 읽는다.
    //
    // **[정정 2026-08-30]** 종전 이 MARK 는 ~~`(디컴파일 FUN_140261950:1092-1099)`~~ 였다.
    // 이름과 줄 번호가 둘 다 폐기본 기준이다: `FUN_140261950` 은 재생성 코퍼스 7,748 함수에
    // 없고(참 VA 는 −0xD0 한 `0x140261880`), `:1092-1099` 는 MDAT 가 아니라 모프 영역의
    // `FUN_1401aa940(param_3 + 0x1b, …)` 컨테이너 부기다(진짜 MDAT 파스와 2,000줄 이상 차).
    // 인용한 `FUN_140261680`·`FUN_14009c500` 도 같은 −0xD0 대응의 참 VA 형태다
    // (종전 인용형 `FUN_140261750`·`FUN_14009c5d0` 은 manifest 에 부재).
    // 줄 번호를 다시 적지 않는 이유는 Model3D.swift 의 같은 취지 지침을 따른다 —
    // 재생성이 줄 번호를 흔들므로 **태그 문자열과 호출 함수 이름**으로 grep 하는 것이 안정적이다.

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
